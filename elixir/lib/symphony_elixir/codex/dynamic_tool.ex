defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Config, Tracker.Local}
  alias SymphonyElixir.Linear.Client

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
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

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
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

  defp normalize_local_issue_create_arguments(_arguments), do: {:error, :invalid_local_issue_create_arguments}

  defp normalize_local_issue_state_arguments(%{} = arguments) do
    with {:ok, issue_ref} <- required_string_arg(arguments, "issueRef", :missing_local_issue_ref),
         {:ok, state_name} <- required_string_arg(arguments, "state", :missing_local_issue_state) do
      {:ok, issue_ref, state_name}
    end
  end

  defp normalize_local_issue_state_arguments(_arguments), do: {:error, :invalid_local_issue_state_arguments}

  defp normalize_local_issue_comment_arguments(%{} = arguments) do
    with {:ok, issue_ref} <- required_string_arg(arguments, "issueRef", :missing_local_issue_ref),
         {:ok, body} <- required_string_arg(arguments, "body", :missing_local_issue_comment_body) do
      {:ok, issue_ref, body}
    end
  end

  defp normalize_local_issue_comment_arguments(_arguments), do: {:error, :invalid_local_issue_comment_arguments}

  defp normalize_local_issue_release_arguments(%{} = arguments),
    do: required_string_arg(arguments, "issueRef", :missing_local_issue_ref)

  defp normalize_local_issue_release_arguments(_arguments), do: {:error, :invalid_local_issue_release_arguments}

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

  defp stringify_value(value) when is_binary(value), do: value
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify_value(_value), do: nil

  defp fetch_local_issues(nil), do: Local.list_issues()
  defp fetch_local_issues(states), do: Local.fetch_issues_by_states(states)

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
