defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  require Logger

  alias SymphonyElixir.Issue, as: TrackerIssue
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Tracker.Local
  alias SymphonyElixir.{Config, Tracker, Workpad}

  @linear_graphql_tool "linear_graphql"
  @linear_workpad_tool "linear_workpad"
  @linear_update_issue_state_tool "linear_update_issue_state"

  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_workpad_description """
  Ensure and update the single persistent Linear workpad comment for an issue.
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

  @linear_workpad_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["action"],
    "properties" => %{
      "action" => %{
        "type" => "string",
        "enum" => ["ensure", "update"],
        "description" => "`ensure` reuses or creates the workpad comment; `update` replaces the comment body."
      },
      "issueId" => %{
        "type" => ["string", "null"],
        "description" => "Linear issue ID. Required for `ensure`."
      },
      "environmentStamp" => %{
        "type" => ["string", "null"],
        "description" => "Environment stamp used when creating the bootstrap workpad template. Required for `ensure`."
      },
      "commentId" => %{
        "type" => ["string", "null"],
        "description" => "Existing workpad comment ID. Required for `update`."
      },
      "body" => %{
        "type" => ["string", "null"],
        "description" => "Replacement workpad body. Required for `update`."
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

  @local_issue_list_tool "local_issue_list"
  @local_issue_create_tool "local_issue_create"
  @local_issue_state_tool "local_issue_state"
  @local_issue_comment_tool "local_issue_comment"
  @local_issue_release_tool "local_issue_release"

  @local_issue_list_description """
  List issues from Symphony's local JSON tracker store.
  """
  @local_issue_create_description """
  Create a new issue in Symphony's local JSON tracker store.
  """
  @local_issue_state_description """
  Update the state of an issue in Symphony's local JSON tracker store.
  """
  @local_issue_comment_description """
  Append a comment to an issue in Symphony's local JSON tracker store.
  """
  @local_issue_release_description """
  Release an active or expired lease on an issue in Symphony's local JSON tracker store.
  """

  @local_issue_list_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "states" => %{
        "type" => ["array", "null"],
        "items" => %{"type" => "string"},
        "description" => "Optional issue states to filter by."
      }
    }
  }

  @local_issue_create_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["title"],
    "properties" => %{
      "title" => %{
        "type" => "string",
        "description" => "Issue title."
      },
      "description" => %{
        "type" => ["string", "null"],
        "description" => "Optional issue description."
      },
      "priority" => %{
        "type" => ["integer", "null"],
        "description" => "Optional integer priority."
      },
      "labels" => %{
        "type" => ["array", "null"],
        "items" => %{"type" => "string"},
        "description" => "Optional issue labels."
      },
      "state" => %{
        "type" => ["string", "null"],
        "description" => "Optional initial state."
      },
      "identifier" => %{
        "type" => ["string", "null"],
        "description" => "Optional explicit issue identifier."
      }
    }
  }

  @local_issue_state_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issueRef", "state"],
    "properties" => %{
      "issueRef" => %{
        "type" => "string",
        "description" => "Issue id or identifier."
      },
      "state" => %{
        "type" => "string",
        "description" => "New issue state."
      }
    }
  }

  @local_issue_comment_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issueRef", "body"],
    "properties" => %{
      "issueRef" => %{
        "type" => "string",
        "description" => "Issue id or identifier."
      },
      "body" => %{
        "type" => "string",
        "description" => "Comment body."
      }
    }
  }

  @local_issue_release_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issueRef"],
    "properties" => %{
      "issueRef" => %{
        "type" => "string",
        "description" => "Issue id or identifier."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case {Config.tracker_kind(), tool} do
      {"linear", @linear_graphql_tool} ->
        execute_linear_graphql(arguments, opts)

      {"linear", @linear_workpad_tool} ->
        execute_linear_workpad(arguments, opts)

      {"linear", @linear_update_issue_state_tool} ->
        execute_linear_update_issue_state(arguments, opts)

      {"local", @local_issue_list_tool} ->
        execute_local_issue_list(arguments)

      {"local", @local_issue_create_tool} ->
        execute_local_issue_create(arguments)

      {"local", @local_issue_state_tool} ->
        execute_local_issue_state(arguments)

      {"local", @local_issue_comment_tool} ->
        execute_local_issue_comment(arguments)

      {"local", @local_issue_release_tool} ->
        execute_local_issue_release(arguments)

      {_kind, other} ->
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
    case Config.tracker_kind() do
      "linear" ->
        [
          %{
            "name" => @linear_graphql_tool,
            "description" => @linear_graphql_description,
            "inputSchema" => @linear_graphql_input_schema
          },
          %{
            "name" => @linear_workpad_tool,
            "description" => @linear_workpad_description,
            "inputSchema" => @linear_workpad_input_schema
          },
          %{
            "name" => @linear_update_issue_state_tool,
            "description" => @linear_update_issue_state_description,
            "inputSchema" => @linear_update_issue_state_input_schema
          }
        ]

      "local" ->
        [
          %{
            "name" => @local_issue_list_tool,
            "description" => @local_issue_list_description,
            "inputSchema" => @local_issue_list_input_schema
          },
          %{
            "name" => @local_issue_create_tool,
            "description" => @local_issue_create_description,
            "inputSchema" => @local_issue_create_input_schema
          },
          %{
            "name" => @local_issue_state_tool,
            "description" => @local_issue_state_description,
            "inputSchema" => @local_issue_state_input_schema
          },
          %{
            "name" => @local_issue_comment_tool,
            "description" => @local_issue_comment_description,
            "inputSchema" => @local_issue_comment_input_schema
          },
          %{
            "name" => @local_issue_release_tool,
            "description" => @local_issue_release_description,
            "inputSchema" => @local_issue_release_input_schema
          }
        ]

      _ ->
        []
    end
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

  defp execute_linear_workpad(arguments, opts) do
    ensure_workpad = Keyword.get(opts, :workpad_ensure, &Tracker.ensure_workpad_comment/2)
    update_comment = Keyword.get(opts, :comment_update, &Tracker.update_comment/2)

    case normalize_linear_workpad_arguments(arguments) do
      {:ok, :ensure, payload} ->
        ensure_linear_workpad(payload, ensure_workpad)

      {:ok, :update, payload} ->
        update_linear_workpad(payload, update_comment)

      {:error, reason} ->
        failure_response(tool_error_payload(reason, @linear_workpad_tool))
    end
  end

  defp execute_linear_update_issue_state(arguments, opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    current_issue = Keyword.get(opts, :current_issue)

    with {:ok, issue_id, target_state} <- normalize_issue_state_arguments(arguments, current_issue),
         {:ok, issue} <- fetch_current_issue(tracker, issue_id),
         :ok <- validate_gated_transition(Map.get(issue, :state), target_state),
         :ok <- guarded_update_issue_state(tracker, issue_id, target_state) do
      success_response(%{
        "issueId" => issue_id,
        "fromState" => Map.get(issue, :state),
        "toState" => target_state,
        "gatedTransition" => true
      })
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp ensure_linear_workpad(payload, ensure_workpad) do
    body = Workpad.bootstrap_body(payload.environment_stamp)

    case ensure_workpad.(payload.issue_id, body) do
      {:ok, %{id: comment_id, body: persisted_body, created?: created?}} ->
        success_response(%{
          "action" => "ensure",
          "commentId" => comment_id,
          "body" => persisted_body,
          "created" => created?,
          "header" => Workpad.header()
        })

      {:error, reason} ->
        failure_response(tool_error_payload(reason, @linear_workpad_tool))
    end
  end

  defp update_linear_workpad(payload, update_comment) do
    case update_comment.(payload.comment_id, payload.body) do
      :ok ->
        success_response(%{
          "action" => "update",
          "commentId" => payload.comment_id,
          "updated" => true
        })

      {:error, reason} ->
        failure_response(tool_error_payload(reason, @linear_workpad_tool))
    end
  end

  defp execute_local_issue_list(arguments) do
    with {:ok, states} <- normalize_local_issue_list_arguments(arguments),
         {:ok, issues} <- fetch_local_issues(states) do
      success_response(%{"issues" => Enum.map(issues, &issue_payload/1)})
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_local_issue_create(arguments) do
    with {:ok, attrs} <- normalize_local_issue_create_arguments(arguments),
         {:ok, issue} <- Local.create_issue(attrs) do
      success_response(%{
        "message" => "Created #{issue.identifier}",
        "issue" => issue_payload(issue)
      })
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_local_issue_state(arguments) do
    with {:ok, issue_ref, state_name} <- normalize_local_issue_state_arguments(arguments),
         :ok <- Local.update_issue_state(issue_ref, state_name) do
      success_response(%{
        "message" => "Updated #{issue_ref} -> #{state_name}",
        "issueRef" => issue_ref,
        "state" => state_name
      })
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_local_issue_comment(arguments) do
    with {:ok, issue_ref, body} <- normalize_local_issue_comment_arguments(arguments),
         :ok <- Local.create_comment(issue_ref, body) do
      success_response(%{
        "message" => "Appended comment to #{issue_ref}",
        "issueRef" => issue_ref
      })
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_local_issue_release(arguments) do
    with {:ok, issue_ref} <- normalize_local_issue_release_arguments(arguments),
         :ok <- Local.release_issue_claim(issue_ref) do
      success_response(%{
        "message" => "Released lease on #{issue_ref}",
        "issueRef" => issue_ref
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

  defp normalize_linear_graphql_arguments(_arguments, _allow_mutations?),
    do: {:error, :invalid_arguments}

  defp normalize_local_issue_list_arguments(nil), do: {:ok, nil}
  defp normalize_local_issue_list_arguments(%{} = arguments), do: normalize_states(arguments)
  defp normalize_local_issue_list_arguments(_arguments), do: {:error, :invalid_local_issue_list_arguments}

  defp normalize_local_issue_create_arguments(%{} = arguments) do
    with {:ok, title} <- required_string_arg(arguments, "title", :missing_local_issue_title),
         {:ok, description} <- optional_string_arg(arguments, "description"),
         {:ok, priority} <- optional_integer_arg(arguments, "priority"),
         {:ok, labels} <- optional_string_list_arg(arguments, "labels"),
         {:ok, state_name} <- optional_string_arg(arguments, "state"),
         {:ok, identifier} <- optional_string_arg(arguments, "identifier") do
      attrs =
        %{"title" => title}
        |> put_if_present("description", description)
        |> put_if_present("priority", priority)
        |> put_if_present("labels", labels)
        |> put_if_present("state", state_name)
        |> put_if_present("identifier", identifier)

      {:ok, attrs}
    end
  end

  defp normalize_local_issue_create_arguments(_arguments),
    do: {:error, :invalid_local_issue_create_arguments}

  defp normalize_local_issue_state_arguments(%{} = arguments) do
    with {:ok, issue_ref} <- required_string_arg(arguments, "issueRef", :missing_local_issue_ref),
         {:ok, state_name} <- required_string_arg(arguments, "state", :missing_local_issue_state) do
      {:ok, issue_ref, state_name}
    end
  end

  defp normalize_local_issue_state_arguments(_arguments),
    do: {:error, :invalid_local_issue_state_arguments}

  defp normalize_local_issue_comment_arguments(%{} = arguments) do
    with {:ok, issue_ref} <- required_string_arg(arguments, "issueRef", :missing_local_issue_ref),
         {:ok, body} <- required_string_arg(arguments, "body", :missing_local_issue_comment_body) do
      {:ok, issue_ref, body}
    end
  end

  defp normalize_local_issue_comment_arguments(_arguments),
    do: {:error, :invalid_local_issue_comment_arguments}

  defp normalize_local_issue_release_arguments(%{} = arguments),
    do: required_string_arg(arguments, "issueRef", :missing_local_issue_ref)

  defp normalize_local_issue_release_arguments(_arguments),
    do: {:error, :invalid_local_issue_release_arguments}

  defp normalize_linear_workpad_arguments(arguments) when is_map(arguments) do
    case Map.get(arguments, "action") || Map.get(arguments, :action) do
      "ensure" ->
        with {:ok, issue_id} <- require_string(arguments, ["issueId", :issueId], :missing_issue_id),
             {:ok, environment_stamp} <-
               require_string(
                 arguments,
                 ["environmentStamp", :environmentStamp],
                 :missing_environment_stamp
               ) do
          {:ok, :ensure, %{issue_id: issue_id, environment_stamp: environment_stamp}}
        end

      "update" ->
        with {:ok, comment_id} <-
               require_string(arguments, ["commentId", :commentId], :missing_comment_id),
             {:ok, body} <- require_string(arguments, ["body", :body], :missing_body) do
          {:ok, :update, %{comment_id: comment_id, body: body}}
        end

      action when is_binary(action) ->
        {:error, {:unsupported_workpad_action, action}}

      _ ->
        {:error, :missing_workpad_action}
    end
  end

  defp normalize_linear_workpad_arguments(_arguments), do: {:error, :invalid_workpad_arguments}

  defp normalize_issue_state_arguments(arguments, %TrackerIssue{id: current_issue_id})
       when is_map(arguments) do
    requested_issue_id = Map.get(arguments, "issueId") || Map.get(arguments, :issueId) || current_issue_id

    with {:ok, issue_id} <- normalize_issue_id(requested_issue_id, current_issue_id),
         {:ok, target_state} <- normalize_target_state(arguments) do
      {:ok, issue_id, target_state}
    end
  end

  defp normalize_issue_state_arguments(arguments, current_issue) when is_map(arguments) do
    current_issue_id =
      if is_map(current_issue) do
        Map.get(current_issue, :id) || Map.get(current_issue, "id")
      end

    normalize_issue_state_arguments(arguments, %TrackerIssue{id: current_issue_id})
  end

  defp normalize_issue_state_arguments(_arguments, _current_issue),
    do: {:error, :invalid_issue_transition_arguments}

  defp normalize_issue_id(issue_id, current_issue_id)
       when is_binary(issue_id) and is_binary(current_issue_id) do
    if issue_id == current_issue_id do
      {:ok, issue_id}
    else
      {:error, :cross_issue_state_transition_not_allowed}
    end
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

  defp fetch_current_issue(tracker, issue_id) when is_binary(issue_id) do
    case tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%TrackerIssue{} = issue | _]} -> {:ok, issue}
      {:ok, []} -> {:error, :issue_not_found}
      {:error, reason} -> {:error, {:issue_lookup_failed, reason}}
    end
  end

  defp guarded_update_issue_state(tracker, issue_id, target_state) do
    case tracker.update_issue_state(issue_id, target_state) do
      :ok -> :ok
      {:error, reason} -> {:error, {:issue_state_update_failed, reason}}
      other -> {:error, {:issue_state_update_failed, other}}
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
    in_progress = {
      normalize_state_name(Config.tracker_in_progress_state()),
      Config.tracker_in_progress_state()
    }

    human_review = {
      normalize_state_name(Config.tracker_human_review_state()),
      Config.tracker_human_review_state()
    }

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

  defp normalize_states(arguments) do
    case Map.get(arguments, "states") || Map.get(arguments, :states) do
      nil ->
        {:ok, nil}

      states when is_list(states) ->
        trimmed_states =
          states
          |> Enum.map(&stringify_value/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, if(trimmed_states == [], do: nil, else: trimmed_states)}

      _ ->
        {:error, :invalid_local_issue_states}
    end
  end

  defp required_string_arg(arguments, key, missing_reason) do
    case optional_string_arg(arguments, key) do
      {:ok, nil} -> {:error, missing_reason}
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp optional_string_arg(arguments, key) do
    case Map.get(arguments, key) || Map.get(arguments, String.to_atom(key)) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        trimmed = String.trim(value)
        {:ok, if(trimmed == "", do: nil, else: trimmed)}

      _ ->
        {:error, {:invalid_string_arg, key}}
    end
  end

  defp optional_integer_arg(arguments, key) do
    case Map.get(arguments, key) || Map.get(arguments, String.to_atom(key)) do
      nil -> {:ok, nil}
      value when is_integer(value) -> {:ok, value}
      _ -> {:error, {:invalid_integer_arg, key}}
    end
  end

  defp optional_string_list_arg(arguments, key) do
    case Map.get(arguments, key) || Map.get(arguments, String.to_atom(key)) do
      nil ->
        {:ok, nil}

      values when is_list(values) ->
        trimmed_values =
          values
          |> Enum.map(&stringify_value/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, if(trimmed_values == [], do: nil, else: trimmed_values)}

      _ ->
        {:error, {:invalid_string_list_arg, key}}
    end
  end

  defp require_string(arguments, keys, error_reason) do
    value = Enum.find_value(keys, fn key -> Map.get(arguments, key) end)

    case value do
      item when is_binary(item) ->
        case String.trim(item) do
          "" -> {:error, error_reason}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, error_reason}
    end
  end

  defp stringify_value(value) when is_binary(value), do: value
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify_value(_value), do: nil

  defp fetch_local_issues(nil), do: Local.list_issues()
  defp fetch_local_issues(states), do: Local.fetch_issues_by_states(states)

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

  defp execute_linear_graphql_request(
         query,
         variables,
         linear_client,
         timeout_ms,
         max_retries,
         operation_type,
         audit
       ) do
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

  defp retryable_tool_error?({:linear_api_status, status})
       when is_integer(status) and status >= 500,
       do: true

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

  defp audit_tool_event(audit_fun, audit_metadata, event, payload)
       when is_function(audit_fun, 1) do
    details = Map.merge(audit_metadata, payload) |> Map.put(:event, event)
    log_tool_event(event, details)
    audit_fun.(details)
  end

  defp log_tool_event(event, details) do
    message =
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
      :failed -> Logger.warning(message)
      :retrying -> Logger.warning(message)
      _ -> Logger.info(message)
    end
  end

  defp maybe_log_field(_key, nil), do: nil
  defp maybe_log_field(key, value), do: "#{key}=#{value}"

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

  defp tool_error_payload({:issue_state_update_failed, reason}) do
    %{
      "error" => %{
        "message" => "Symphony failed to update the current issue state through the tracker.",
        "reason" => inspect(reason)
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

  defp tool_error_payload(:invalid_local_issue_list_arguments) do
    %{
      "error" => %{
        "message" => "`local_issue_list` expects an object with optional `states`."
      }
    }
  end

  defp tool_error_payload(:missing_local_issue_title) do
    %{
      "error" => %{
        "message" => "`local_issue_create` requires a non-empty `title` string."
      }
    }
  end

  defp tool_error_payload(:invalid_local_issue_create_arguments) do
    %{
      "error" => %{
        "message" => "`local_issue_create` expects an object with `title` and optional `description`, `priority`, `labels`, `state`, and `identifier`."
      }
    }
  end

  defp tool_error_payload(:missing_local_issue_ref) do
    %{
      "error" => %{
        "message" => "A non-empty `issueRef` is required."
      }
    }
  end

  defp tool_error_payload(:missing_local_issue_state) do
    %{
      "error" => %{
        "message" => "`local_issue_state` requires a non-empty `state` string."
      }
    }
  end

  defp tool_error_payload(:invalid_local_issue_state_arguments) do
    %{
      "error" => %{
        "message" => "`local_issue_state` expects an object with `issueRef` and `state`."
      }
    }
  end

  defp tool_error_payload(:missing_local_issue_comment_body) do
    %{
      "error" => %{
        "message" => "`local_issue_comment` requires a non-empty `body` string."
      }
    }
  end

  defp tool_error_payload(:invalid_local_issue_comment_arguments) do
    %{
      "error" => %{
        "message" => "`local_issue_comment` expects an object with `issueRef` and `body`."
      }
    }
  end

  defp tool_error_payload(:invalid_local_issue_release_arguments) do
    %{
      "error" => %{
        "message" => "`local_issue_release` expects an object with `issueRef`."
      }
    }
  end

  defp tool_error_payload(:invalid_local_issue_states) do
    %{
      "error" => %{
        "message" => "`local_issue_list.states` must be an array of strings when provided."
      }
    }
  end

  defp tool_error_payload({:invalid_string_arg, key}) do
    %{
      "error" => %{
        "message" => "`#{key}` must be a string when provided."
      }
    }
  end

  defp tool_error_payload({:invalid_integer_arg, key}) do
    %{
      "error" => %{
        "message" => "`#{key}` must be an integer when provided."
      }
    }
  end

  defp tool_error_payload({:invalid_string_list_arg, key}) do
    %{
      "error" => %{
        "message" => "`#{key}` must be an array of strings when provided."
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

  defp tool_error_payload(:missing_workpad_action, @linear_workpad_tool) do
    %{"error" => %{"message" => "`linear_workpad` requires an `action` of `ensure` or `update`."}}
  end

  defp tool_error_payload(:invalid_workpad_arguments, @linear_workpad_tool) do
    %{"error" => %{"message" => "`linear_workpad` expects an object with `action` plus the required fields for that action."}}
  end

  defp tool_error_payload(:missing_issue_id, @linear_workpad_tool) do
    %{"error" => %{"message" => "`linear_workpad.ensure` requires a non-empty `issueId` string."}}
  end

  defp tool_error_payload(:missing_environment_stamp, @linear_workpad_tool) do
    %{"error" => %{"message" => "`linear_workpad.ensure` requires a non-empty `environmentStamp` string."}}
  end

  defp tool_error_payload(:missing_comment_id, @linear_workpad_tool) do
    %{"error" => %{"message" => "`linear_workpad.update` requires a non-empty `commentId` string."}}
  end

  defp tool_error_payload(:missing_body, @linear_workpad_tool) do
    %{"error" => %{"message" => "`linear_workpad.update` requires a non-empty `body` string."}}
  end

  defp tool_error_payload({:unsupported_workpad_action, action}, @linear_workpad_tool) do
    %{"error" => %{"message" => "`linear_workpad` action must be `ensure` or `update`, got #{inspect(action)}."}}
  end

  defp tool_error_payload(reason, @linear_workpad_tool) do
    %{"error" => %{"message" => "Linear workpad tool execution failed.", "reason" => inspect(reason)}}
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end

  defp issue_payload(issue) do
    %{
      "id" => issue.id,
      "identifier" => issue.identifier,
      "title" => issue.title,
      "description" => issue.description,
      "priority" => issue.priority,
      "state" => issue.state,
      "branchName" => issue.branch_name,
      "url" => issue.url,
      "assigneeId" => issue.assignee_id,
      "labels" => issue.labels || [],
      "blockedBy" => issue.blocked_by || [],
      "comments" => comments_payload(Map.get(issue, :comments, [])),
      "assignedToWorker" => Map.get(issue, :assigned_to_worker, true),
      "claimedBy" => issue.claimed_by,
      "claimedAt" => iso8601(issue.claimed_at),
      "leaseExpiresAt" => iso8601(issue.lease_expires_at),
      "leaseStatus" => issue |> Local.lease_status() |> Atom.to_string(),
      "createdAt" => iso8601(issue.created_at),
      "updatedAt" => iso8601(issue.updated_at)
    }
  end

  defp comments_payload(comments) when is_list(comments) do
    Enum.map(comments, &comment_payload/1)
  end

  defp comments_payload(_comments), do: []

  defp comment_payload(comment) when is_map(comment) do
    %{
      "body" => Map.get(comment, :body),
      "createdAt" => iso8601(Map.get(comment, :created_at))
    }
  end

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_value), do: nil

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
