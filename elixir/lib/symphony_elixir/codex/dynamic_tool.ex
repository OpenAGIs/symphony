defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  require Logger

  alias SymphonyElixir.{Config, Tracker}
  alias SymphonyElixir.Linear.{Client, Issue}

  @linear_graphql_tool "linear_graphql"
  @linear_update_issue_state_tool "linear_update_issue_state"

  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """

  @linear_update_issue_state_description """
  Transition the current Linear issue through Symphony's guarded approval flow.
  """

  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @linear_update_issue_state_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["state"],
    "properties" => %{
      "issueId" => %{
        "type" => ["string", "null"],
        "description" => "Optional current issue id; must match the issue active in this session when provided."
      },
      "state" => %{
        "type" => "string",
        "description" => "Target workflow state for the current issue."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @linear_update_issue_state_tool ->
        execute_linear_update_issue_state(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @linear_update_issue_state_tool,
        "description" => @linear_update_issue_state_description,
        "inputSchema" => @linear_update_issue_state_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)
    max_retries = Keyword.get(opts, :max_retries, 2)
    allow_mutations? = Keyword.get(opts, :allow_mutations?, true)
    audit_metadata = Keyword.get(opts, :audit_metadata, %{})
    audit_fun = Keyword.get(opts, :audit_fun)

    with {:ok, query, variables, operation_type} <-
           normalize_linear_graphql_arguments(arguments, allow_mutations?),
         {:ok, response, attempts, elapsed_ms} <-
           execute_linear_graphql_request(
             query,
             variables,
             linear_client,
             timeout_ms,
             max_retries,
             operation_type,
             %{metadata: audit_metadata, fun: audit_fun}
           ) do
      audit_tool_event(audit_fun, audit_metadata, :completed, %{
        tool: @linear_graphql_tool,
        operation_type: operation_type,
        attempts: attempts,
        elapsed_ms: elapsed_ms,
        success: graphql_success?(response)
      })

      graphql_response(response)
    else
      {:error, reason} ->
        audit_tool_event(audit_fun, audit_metadata, :failed, %{
          tool: @linear_graphql_tool,
          reason: inspect(reason)
        })

        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_linear_update_issue_state(arguments, opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    current_issue = Keyword.get(opts, :current_issue)

    with {:ok, issue_id, target_state} <- normalize_issue_state_arguments(arguments, current_issue),
         {:ok, %Issue{} = issue} <- fetch_current_issue(tracker, issue_id),
         :ok <- validate_gated_transition(issue.state, target_state),
         :ok <- tracker.update_issue_state(issue_id, target_state) do
      success_response(%{
        "issueId" => issue_id,
        "fromState" => issue.state,
        "toState" => target_state,
        "gatedTransition" => true
      })
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments, allow_mutations?) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> validate_linear_graphql_operation(query, %{}, allow_mutations?)
    end
  end

  defp normalize_linear_graphql_arguments(arguments, allow_mutations?) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            validate_linear_graphql_operation(query, variables, allow_mutations?)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments, _allow_mutations?), do: {:error, :invalid_arguments}

  defp validate_linear_graphql_operation(query, variables, allow_mutations?) do
    case detect_operation_type(query) do
      {:ok, :mutation} when not allow_mutations? ->
        {:error, :mutation_not_allowed}

      {:ok, :mutation} ->
        if issue_update_mutation?(query) do
          {:error, :issue_update_mutation_not_allowed}
        else
          {:ok, query, variables, :mutation}
        end

      {:ok, :query} ->
        {:ok, query, variables, :query}

      {:ok, other} ->
        {:error, {:unsupported_operation_type, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp normalize_issue_state_arguments(arguments, %Issue{id: current_issue_id}) when is_map(arguments) do
    requested_issue_id = Map.get(arguments, "issueId") || Map.get(arguments, :issueId) || current_issue_id

    with {:ok, issue_id} <- normalize_issue_id(requested_issue_id, current_issue_id),
         {:ok, target_state} <- normalize_target_state(arguments) do
      {:ok, issue_id, target_state}
    end
  end

  defp normalize_issue_state_arguments(arguments, current_issue) when is_map(arguments) do
    current_issue_id = Map.get(current_issue || %{}, :id)
    normalize_issue_state_arguments(arguments, %Issue{id: current_issue_id})
  end

  defp normalize_issue_state_arguments(_arguments, _current_issue), do: {:error, :invalid_issue_transition_arguments}

  defp normalize_issue_id(issue_id, current_issue_id)
       when is_binary(issue_id) and is_binary(current_issue_id) do
    if issue_id == current_issue_id, do: {:ok, issue_id}, else: {:error, :cross_issue_state_transition_not_allowed}
  end

  defp normalize_issue_id(nil, _current_issue_id), do: {:error, :missing_issue_context}
  defp normalize_issue_id(_, _current_issue_id), do: {:error, :invalid_issue_id}

  defp normalize_target_state(arguments) do
    case Map.get(arguments, "state") || Map.get(arguments, :state) do
      state when is_binary(state) ->
        trimmed = String.trim(state)

        if trimmed == "" do
          {:error, :missing_target_state}
        else
          {:ok, trimmed}
        end

      _ ->
        {:error, :missing_target_state}
    end
  end

  defp fetch_current_issue(tracker, issue_id) when is_binary(issue_id) do
    case tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{} = issue | _]} -> {:ok, issue}
      {:ok, []} -> {:error, :issue_not_found}
      {:error, reason} -> {:error, {:issue_lookup_failed, reason}}
    end
  end

  defp validate_gated_transition(current_state, target_state)
       when is_binary(current_state) and is_binary(target_state) do
    normalized_target = normalize_state_name(target_state)

    if normalized_target in allowed_transition_targets(current_state) do
      :ok
    else
      {:error,
       {:state_transition_blocked,
        %{
          from: current_state,
          to: target_state,
          allowed_targets: humanized_allowed_targets(current_state)
        }}}
    end
  end

  defp validate_gated_transition(_current_state, _target_state), do: {:error, :missing_issue_state}

  defp allowed_transition_targets(current_state) do
    todo = normalize_state_name(Config.tracker_todo_state())
    in_progress = normalize_state_name(Config.tracker_in_progress_state())
    human_review = normalize_state_name(Config.tracker_human_review_state())
    merging = normalize_state_name(Config.tracker_merging_state())
    done = normalize_state_name(Config.tracker_done_state())

    case normalize_state_name(current_state) do
      ^todo -> [in_progress]
      ^in_progress -> [human_review]
      ^human_review -> [in_progress, merging]
      ^merging -> [in_progress, done]
      _ -> []
    end
  end

  defp humanized_allowed_targets(current_state) do
    in_progress = {normalize_state_name(Config.tracker_in_progress_state()), Config.tracker_in_progress_state()}
    human_review = {normalize_state_name(Config.tracker_human_review_state()), Config.tracker_human_review_state()}
    merging = {normalize_state_name(Config.tracker_merging_state()), Config.tracker_merging_state()}
    done = {normalize_state_name(Config.tracker_done_state()), Config.tracker_done_state()}

    options = [in_progress, human_review, merging, done]

    current_state
    |> allowed_transition_targets()
    |> Enum.map(&humanized_allowed_target(&1, options))
  end

  defp humanized_allowed_target(normalized, options) do
    case Enum.find(options, fn {key, _value} -> key == normalized end) do
      {_key, value} -> value
      nil -> normalized
    end
  end

  defp normalize_state_name(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp graphql_response(response) do
    %{
      "success" => graphql_success?(response),
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(response)
        }
      ]
    }
  end

  defp graphql_success?(response) do
    case response do
      %{"errors" => errors} when is_list(errors) and errors != [] -> false
      %{errors: errors} when is_list(errors) and errors != [] -> false
      _ -> true
    end
  end

  defp execute_linear_graphql_request(query, variables, linear_client, timeout_ms, max_retries, operation_type, audit) do
    attempt_linear_graphql_request(
      query,
      variables,
      linear_client,
      max_retries + 1,
      timeout_ms,
      operation_type,
      audit
    )
  end

  defp attempt_linear_graphql_request(
         query,
         variables,
         linear_client,
         attempts_left,
         timeout_ms,
         operation_type,
         audit,
         attempt \\ 1
       ) do
    audit_metadata = Map.get(audit, :metadata, %{})
    audit_fun = Map.get(audit, :fun)

    audit_tool_event(audit_fun, audit_metadata, :started, %{
      tool: @linear_graphql_tool,
      operation_type: operation_type,
      attempt: attempt
    })

    started_at = System.monotonic_time(:millisecond)

    result =
      run_with_timeout(timeout_ms, fn ->
        linear_client.(query, variables, [])
      end)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    case result do
      {:ok, response} ->
        {:ok, response, attempt, elapsed_ms}

      {:error, reason} ->
        if attempts_left > 1 and retryable_tool_error?(reason) do
          audit_tool_event(audit_fun, audit_metadata, :retrying, %{
            tool: @linear_graphql_tool,
            operation_type: operation_type,
            attempt: attempt,
            elapsed_ms: elapsed_ms,
            reason: inspect(reason)
          })

          attempt_linear_graphql_request(
            query,
            variables,
            linear_client,
            attempts_left - 1,
            timeout_ms,
            operation_type,
            audit,
            attempt + 1
          )
        else
          {:error, reason}
        end
    end
  end

  defp run_with_timeout(timeout_ms, fun) when is_integer(timeout_ms) and timeout_ms > 0 do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :tool_timeout}
    end
  end

  defp retryable_tool_error?(:tool_timeout), do: true
  defp retryable_tool_error?({:linear_api_request, _reason}), do: true
  defp retryable_tool_error?({:linear_api_status, status}) when is_integer(status) and status >= 500, do: true
  defp retryable_tool_error?(_reason), do: false

  defp detect_operation_type(query) when is_binary(query) do
    sanitized = sanitize_graphql_document(query)

    operation_types =
      Regex.scan(~r/\b(query|mutation|subscription)\b/u, sanitized, capture: :all_but_first)
      |> List.flatten()

    cond do
      length(operation_types) > 1 ->
        {:error, :multiple_operations_not_supported}

      operation_types == ["query"] ->
        {:ok, :query}

      operation_types == ["mutation"] ->
        {:ok, :mutation}

      operation_types == ["subscription"] ->
        {:ok, :subscription}

      String.starts_with?(String.trim_leading(sanitized), "{") ->
        {:ok, :query}

      true ->
        {:error, :missing_query}
    end
  end

  defp sanitize_graphql_document(document) do
    document
    |> String.replace(~r/"""(?:.|\n|\r)*?"""/u, " ")
    |> String.replace(~r/"(?:\\.|[^"\\])*"/u, " ")
    |> String.replace(~r/#.*$/um, " ")
  end

  defp issue_update_mutation?(query) when is_binary(query) do
    Regex.match?(~r/\bissueUpdate\b/u, sanitize_graphql_document(query))
  end

  defp audit_tool_event(nil, audit_metadata, event, payload) do
    log_tool_event(event, Map.merge(audit_metadata, payload))
  end

  defp audit_tool_event(audit_fun, audit_metadata, event, payload) when is_function(audit_fun, 1) do
    details = Map.merge(audit_metadata, payload) |> Map.put(:event, event)
    log_tool_event(event, details)
    audit_fun.(details)
  end

  defp log_tool_event(event, details) do
    base =
      [
        "Dynamic tool",
        Atom.to_string(event),
        "tool=#{Map.get(details, :tool)}",
        maybe_log_field("operation_type", Map.get(details, :operation_type)),
        maybe_log_field("attempt", Map.get(details, :attempt) || Map.get(details, :attempts)),
        maybe_log_field("elapsed_ms", Map.get(details, :elapsed_ms)),
        maybe_log_field("session_id", Map.get(details, :session_id)),
        maybe_log_field("issue_id", Map.get(details, :issue_id)),
        maybe_log_field("issue_identifier", Map.get(details, :issue_identifier)),
        maybe_log_field("reason", Map.get(details, :reason))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    case event do
      :failed -> Logger.warning(base)
      :retrying -> Logger.warning(base)
      _ -> Logger.info(base)
    end
  end

  defp maybe_log_field(_key, nil), do: nil
  defp maybe_log_field(key, value), do: "#{key}=#{value}"

  defp failure_response(payload) do
    %{
      "success" => false,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp success_response(payload) do
    %{
      "success" => true,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:multiple_operations_not_supported) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires exactly one GraphQL operation per tool call."
      }
    }
  end

  defp tool_error_payload(:mutation_not_allowed) do
    %{
      "error" => %{
        "message" => "`linear_graphql` mutations are disabled by the current runtime policy."
      }
    }
  end

  defp tool_error_payload(:issue_update_mutation_not_allowed) do
    %{
      "error" => %{
        "message" => "`linear_graphql` cannot call `issueUpdate`; use `linear_update_issue_state` for guarded workflow transitions."
      }
    }
  end

  defp tool_error_payload(:invalid_issue_transition_arguments) do
    %{
      "error" => %{
        "message" => "`linear_update_issue_state` expects an object with `state` and an optional `issueId`."
      }
    }
  end

  defp tool_error_payload(:missing_issue_context) do
    %{
      "error" => %{
        "message" => "`linear_update_issue_state` requires the current issue context from the running session."
      }
    }
  end

  defp tool_error_payload(:invalid_issue_id) do
    %{
      "error" => %{
        "message" => "`linear_update_issue_state.issueId` must be a string when provided."
      }
    }
  end

  defp tool_error_payload(:cross_issue_state_transition_not_allowed) do
    %{
      "error" => %{
        "message" => "`linear_update_issue_state` can only change the issue active in the current session."
      }
    }
  end

  defp tool_error_payload(:missing_target_state) do
    %{
      "error" => %{
        "message" => "`linear_update_issue_state` requires a non-empty `state` value."
      }
    }
  end

  defp tool_error_payload(:issue_not_found) do
    %{
      "error" => %{
        "message" => "Symphony could not reload the current issue before updating its state."
      }
    }
  end

  defp tool_error_payload(:missing_issue_state) do
    %{
      "error" => %{
        "message" => "Symphony could not determine the issue's current state for approval gating."
      }
    }
  end

  defp tool_error_payload({:issue_lookup_failed, reason}) do
    %{
      "error" => %{
        "message" => "Symphony failed to reload the current issue before updating its state.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:state_transition_blocked, %{from: from, to: to, allowed_targets: allowed_targets}}) do
    %{
      "error" => %{
        "message" => "Blocked workflow transition that would bypass Symphony's acceptance gate.",
        "fromState" => from,
        "toState" => to,
        "allowedTargets" => allowed_targets
      }
    }
  end

  defp tool_error_payload(:tool_timeout) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution timed out before a response was received."
      }
    }
  end

  defp tool_error_payload({:unsupported_operation_type, operation_type}) do
    %{
      "error" => %{
        "message" => "`linear_graphql` only supports query and mutation operations.",
        "operationType" => to_string(operation_type)
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
