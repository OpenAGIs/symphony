defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Linear.Issue

  defmodule FakeTracker do
    def fetch_issue_states_by_ids([issue_id]) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_id})

      case Process.get({__MODULE__, :fetch_result}) do
        nil -> {:ok, [%Issue{id: issue_id, state: "In Progress"}]}
        result -> result
      end
    end

    def update_issue_state(issue_id, state_name) do
      send(self(), {:update_issue_state_called, issue_id, state_name})

      case Process.get({__MODULE__, :update_result}) do
        nil -> :ok
        result -> result
      end
    end
  end

  test "tool_specs advertises the linear GraphQL and guarded transition tools" do
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "query" => _,
                   "variables" => _
                 },
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql"
             },
             %{
               "description" => transition_description,
               "inputSchema" => %{
                 "properties" => %{
                   "issueId" => _,
                   "state" => _
                 },
                 "required" => ["state"],
                 "type" => "object"
               },
               "name" => "linear_update_issue_state"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "Linear"
    assert transition_description =~ "approval flow"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql", "linear_update_issue_state"]
             }
           }
  end

  test "linear_graphql blocks raw issueUpdate mutations" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation SaveIssue { issueUpdate(id: \"123\", input: {stateId: \"done\"}) { success } }"},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called for raw issueUpdate mutations")
        end
      )

    assert response["success"] == false

    assert [%{"text" => text}] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` cannot call `issueUpdate`; use `linear_update_issue_state` for guarded workflow transitions."
             }
           }
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql rejects multi-operation documents before calling Linear" do
    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn _forwarded_query, _variables, _opts ->
          flunk("linear client should not be called for multi-operation documents")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` requires exactly one GraphQL operation per tool call."
             }
           }
  end

  test "linear_graphql can deny mutations when runtime policy disables them" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation SaveIssue { issueUpdate(id: \"123\") { success } }"},
        allow_mutations?: false,
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when mutations are disabled")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` mutations are disabled by the current runtime policy."
             }
           }
  end

  test "linear_graphql retries transient transport failures and emits audit events" do
    test_pid = self()
    counter = :atomics.new(1, [])

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        max_retries: 2,
        audit_metadata: %{session_id: "thread-1-turn-1", issue_id: "issue-1", issue_identifier: "OPE-46"},
        audit_fun: fn event -> send(test_pid, {:audit_event, event}) end,
        linear_client: fn _query, _variables, _opts ->
          case :atomics.add_get(counter, 1, 1) do
            1 ->
              {:error, {:linear_api_request, :timeout}}

            _ ->
              {:ok, %{"data" => %{"viewer" => %{"id" => "usr_retry"}}}}
          end
        end
      )

    assert response["success"] == true
    assert_received {:audit_event, %{event: :started, attempt: 1, tool: "linear_graphql", session_id: "thread-1-turn-1"}}
    assert_received {:audit_event, %{event: :retrying, attempt: 1, tool: "linear_graphql", issue_identifier: "OPE-46"}}
    assert_received {:audit_event, %{event: :started, attempt: 2, tool: "linear_graphql"}}
    assert_received {:audit_event, %{event: :completed, attempts: 2, success: true, tool: "linear_graphql"}}
  end

  test "linear_graphql reports timeout failures when the request exceeds the runtime limit" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        timeout_ms: 10,
        max_retries: 0,
        linear_client: fn _query, _variables, _opts ->
          Process.sleep(50)
          {:ok, %{"data" => %{"viewer" => %{"id" => "slow"}}}}
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution timed out before a response was received."
             }
           }
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert [
             %{
               "text" => missing_token_text
             }
           ] = missing_token["contentItems"]

    assert Jason.decode!(missing_token_text) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert [
             %{
               "text" => status_error_text
             }
           ] = status_error["contentItems"]

    assert Jason.decode!(status_error_text) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert [
             %{
               "text" => request_error_text
             }
           ] = request_error["contentItems"]

    assert Jason.decode!(request_error_text) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true

    assert [
             %{
               "text" => ":ok"
             }
           ] = response["contentItems"]
  end

  test "linear_update_issue_state advances the current issue into human review" do
    current_issue = %Issue{id: "issue-49", state: "In Progress", identifier: "OPE-49"}

    response =
      DynamicTool.execute(
        "linear_update_issue_state",
        %{"state" => "Human Review"},
        current_issue: current_issue,
        tracker: FakeTracker
      )

    assert_received {:fetch_issue_states_by_ids_called, "issue-49"}
    assert_received {:update_issue_state_called, "issue-49", "Human Review"}
    assert response["success"] == true

    assert [%{"text" => text}] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "issueId" => "issue-49",
             "fromState" => "In Progress",
             "toState" => "Human Review",
             "gatedTransition" => true
           }
  end

  test "linear_update_issue_state blocks cross-issue transitions" do
    response =
      DynamicTool.execute(
        "linear_update_issue_state",
        %{"issueId" => "other-issue", "state" => "Human Review"},
        current_issue: %Issue{id: "issue-49", state: "In Progress"},
        tracker: FakeTracker
      )

    assert response["success"] == false
    refute_received {:update_issue_state_called, _, _}

    assert [%{"text" => text}] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_update_issue_state` can only change the issue active in the current session."
             }
           }
  end

  test "linear_update_issue_state blocks skipping human review and merge approval" do
    response =
      DynamicTool.execute(
        "linear_update_issue_state",
        %{"state" => "Done"},
        current_issue: %Issue{id: "issue-49", state: "In Progress"},
        tracker: FakeTracker
      )

    assert_received {:fetch_issue_states_by_ids_called, "issue-49"}
    refute_received {:update_issue_state_called, _, _}
    assert response["success"] == false

    assert [%{"text" => text}] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "Blocked workflow transition that would bypass Symphony's acceptance gate.",
               "fromState" => "In Progress",
               "toState" => "Done",
               "allowedTargets" => ["Human Review"]
             }
           }
  end
end
