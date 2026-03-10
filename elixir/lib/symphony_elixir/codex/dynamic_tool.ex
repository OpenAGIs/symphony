defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.{Tracker, Workpad}

  @linear_graphql_tool "linear_graphql"
  @linear_workpad_tool "linear_workpad"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_workpad_description """
  Ensure and update the single persistent Linear workpad comment for an issue.
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

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @linear_workpad_tool ->
        execute_linear_workpad(arguments, opts)

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
        "name" => @linear_workpad_tool,
        "description" => @linear_workpad_description,
        "inputSchema" => @linear_workpad_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
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

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_linear_workpad_arguments(arguments) when is_map(arguments) do
    case Map.get(arguments, "action") || Map.get(arguments, :action) do
      "ensure" ->
        with {:ok, issue_id} <- require_string(arguments, ["issueId", :issueId], :missing_issue_id),
             {:ok, environment_stamp} <-
               require_string(arguments, ["environmentStamp", :environmentStamp], :missing_environment_stamp) do
          {:ok, :ensure, %{issue_id: issue_id, environment_stamp: environment_stamp}}
        end

      "update" ->
        with {:ok, comment_id} <- require_string(arguments, ["commentId", :commentId], :missing_comment_id),
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

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    %{
      "success" => success,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(response)
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
end
