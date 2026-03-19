defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Codex.DynamicTool, Issue, Tracker.Local}

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

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    :ok
  end

  test "tool_specs advertises linear GraphQL, workpad, and guarded transition tools" do
    assert [
             %{
               "description" => graphql_description,
               "inputSchema" => %{
                 "properties" => %{"query" => _, "variables" => _},
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql"
             },
             %{
               "description" => workpad_description,
               "inputSchema" => %{
                 "properties" => %{
                   "action" => _,
                   "body" => _,
                   "commentId" => _,
                   "environmentStamp" => _,
                   "issueId" => _
                 },
                 "required" => ["action"],
                 "type" => "object"
               },
               "name" => "linear_workpad"
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

    assert graphql_description =~ "Linear"
    assert workpad_description =~ "workpad"
    assert transition_description =~ "approval flow"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")

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
               "supportedTools" => [
                 "linear_graphql",
                 "linear_workpad",
                 "linear_update_issue_state"
               ]
             }
           }
  end

  test "linear_graphql blocks raw issueUpdate mutations" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation SaveIssue { issueUpdate(id: \"123\", input: {stateId: \"done\"}) { success } }"
        },
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

  test "linear_workpad ensure creates or reuses the persistent workpad comment" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_workpad",
        %{
          "action" => "ensure",
          "issueId" => "issue-1",
          "environmentStamp" => "host:/tmp/workspace@abc123"
        },
        workpad_ensure: fn issue_id, body ->
          send(test_pid, {:workpad_ensure_called, issue_id, body})
          {:ok, %{id: "comment-1", body: body, created?: true}}
        end
      )

    assert_received {:workpad_ensure_called, "issue-1", body}
    assert body =~ "## Codex Workpad"
    assert body =~ "host:/tmp/workspace@abc123"
    assert response["success"] == true
    assert [%{"text" => text}] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "action" => "ensure",
             "body" => body,
             "commentId" => "comment-1",
             "created" => true,
             "header" => "## Codex Workpad"
           }
  end

  test "linear_workpad update overwrites the existing workpad comment" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_workpad",
        %{"action" => "update", "commentId" => "comment-1", "body" => "## Codex Workpad\nupdated"},
        comment_update: fn comment_id, body ->
          send(test_pid, {:comment_update_called, comment_id, body})
          :ok
        end
      )

    assert_received {:comment_update_called, "comment-1", "## Codex Workpad\nupdated"}
    assert response["success"] == true
    assert [%{"text" => text}] = response["contentItems"]
    assert Jason.decode!(text) == %{"action" => "update", "commentId" => "comment-1", "updated" => true}
  end

  test "linear_workpad validates required arguments and action names" do
    missing_action = DynamicTool.execute("linear_workpad", %{})
    assert missing_action["success"] == false
    assert [%{"text" => missing_action_text}] = missing_action["contentItems"]

    assert Jason.decode!(missing_action_text) == %{
             "error" => %{"message" => "`linear_workpad` requires an `action` of `ensure` or `update`."}
           }

    invalid_action = DynamicTool.execute("linear_workpad", %{"action" => "delete"})
    assert [%{"text" => invalid_action_text}] = invalid_action["contentItems"]

    assert Jason.decode!(invalid_action_text) == %{
             "error" => %{"message" => "`linear_workpad` action must be `ensure` or `update`, got \"delete\"."}
           }

    missing_issue =
      DynamicTool.execute("linear_workpad", %{"action" => "ensure", "environmentStamp" => "env"})

    assert [%{"text" => missing_issue_text}] = missing_issue["contentItems"]

    assert Jason.decode!(missing_issue_text) == %{
             "error" => %{"message" => "`linear_workpad.ensure` requires a non-empty `issueId` string."}
           }

    missing_environment = DynamicTool.execute("linear_workpad", %{"action" => "ensure", "issueId" => "issue-1"})
    assert [%{"text" => missing_environment_text}] = missing_environment["contentItems"]

    assert Jason.decode!(missing_environment_text) == %{
             "error" => %{
               "message" => "`linear_workpad.ensure` requires a non-empty `environmentStamp` string."
             }
           }

    missing_comment = DynamicTool.execute("linear_workpad", %{"action" => "update", "body" => "body"})
    assert [%{"text" => missing_comment_text}] = missing_comment["contentItems"]

    assert Jason.decode!(missing_comment_text) == %{
             "error" => %{"message" => "`linear_workpad.update` requires a non-empty `commentId` string."}
           }

    missing_body = DynamicTool.execute("linear_workpad", %{"action" => "update", "commentId" => "comment-1"})
    assert [%{"text" => missing_body_text}] = missing_body["contentItems"]

    assert Jason.decode!(missing_body_text) == %{
             "error" => %{"message" => "`linear_workpad.update` requires a non-empty `body` string."}
           }

    invalid_shape = DynamicTool.execute("linear_workpad", [:bad])
    assert [%{"text" => invalid_shape_text}] = invalid_shape["contentItems"]

    assert Jason.decode!(invalid_shape_text) == %{
             "error" => %{
               "message" => "`linear_workpad` expects an object with `action` plus the required fields for that action."
             }
           }
  end

  test "linear_workpad formats tracker failures" do
    response =
      DynamicTool.execute(
        "linear_workpad",
        %{"action" => "update", "commentId" => "comment-1", "body" => "updated"},
        comment_update: fn _comment_id, _body -> {:error, :boom} end
      )

    assert response["success"] == false
    assert [%{"text" => text}] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "Linear workpad tool execution failed.",
               "reason" => ":boom"
             }
           }

    ensure_failure =
      DynamicTool.execute(
        "linear_workpad",
        %{"action" => "ensure", "issueId" => "issue-1", "environmentStamp" => "env"},
        workpad_ensure: fn _issue_id, _body -> {:error, :lookup_failed} end
      )

    assert ensure_failure["success"] == false
    assert [%{"text" => ensure_failure_text}] = ensure_failure["contentItems"]

    assert Jason.decode!(ensure_failure_text) == %{
             "error" => %{
               "message" => "Linear workpad tool execution failed.",
               "reason" => ":lookup_failed"
             }
           }
  end

  test "tool_specs advertises local issue tools for the local tracker" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: "./issues.json",
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert Enum.map(DynamicTool.tool_specs(), & &1["name"]) == [
             "local_issue_list",
             "local_issue_create",
             "local_issue_state",
             "local_issue_comment",
             "local_issue_release"
           ]
  end

  test "local issue tools list, create, comment on, and move issues" do
    tracker_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "issues.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    File.write!(
      tracker_path,
      Jason.encode!(
        %{
          "issues" => [
            %{
              "id" => "local-1",
              "identifier" => "LOCAL-1",
              "title" => "Existing local issue",
              "state" => "Todo",
              "labels" => ["ops"]
            }
          ]
        },
        pretty: true
      )
    )

    listed = DynamicTool.execute("local_issue_list", %{"states" => ["Todo"]})

    assert listed["success"] == true

    assert decode_text_payload(listed) == %{
             "issues" => [
               %{
                 "assignedToWorker" => true,
                 "assigneeId" => nil,
                 "blockedBy" => [],
                 "branchName" => nil,
                 "claimedAt" => nil,
                 "claimedBy" => nil,
                 "comments" => [],
                 "createdAt" => nil,
                 "description" => nil,
                 "id" => "local-1",
                 "identifier" => "LOCAL-1",
                 "leaseExpiresAt" => nil,
                 "leaseStatus" => "unclaimed",
                 "labels" => ["ops"],
                 "priority" => nil,
                 "state" => "Todo",
                 "title" => "Existing local issue",
                 "updatedAt" => nil,
                 "url" => nil
               }
             ]
           }

    created =
      DynamicTool.execute(
        "local_issue_create",
        %{
          "title" => "Create a follow-up slice",
          "description" => "Need a second issue for parallel work.",
          "priority" => 2,
          "labels" => ["parallel", "local"],
          "state" => "In Progress",
          "identifier" => "LOCAL-2"
        }
      )

    assert created["success"] == true
    created_payload = decode_text_payload(created)
    assert created_payload["message"] == "Created LOCAL-2"
    assert created_payload["issue"]["identifier"] == "LOCAL-2"
    assert created_payload["issue"]["state"] == "In Progress"
    assert created_payload["issue"]["leaseStatus"] == "unclaimed"
    assert created_payload["issue"]["comments"] == []

    commented = DynamicTool.execute("local_issue_comment", %{"issueRef" => "LOCAL-2", "body" => "Work started"})

    assert commented["success"] == true
    assert decode_text_payload(commented)["message"] == "Appended comment to LOCAL-2"

    moved = DynamicTool.execute("local_issue_state", %{"issueRef" => "LOCAL-2", "state" => "Done"})

    assert moved["success"] == true
    assert decode_text_payload(moved)["message"] == "Updated LOCAL-2 -> Done"

    assert :ok = Local.claim_issue("LOCAL-2", "runtime-a", ttl_ms: 60_000)

    released = DynamicTool.execute("local_issue_release", %{"issueRef" => "LOCAL-2"})

    assert released["success"] == true
    assert decode_text_payload(released)["message"] == "Released lease on LOCAL-2"

    decoded_tracker = tracker_path |> File.read!() |> Jason.decode!()

    assert get_in(decoded_tracker, ["issues", Access.at(1), "identifier"]) == "LOCAL-2"
    assert get_in(decoded_tracker, ["issues", Access.at(1), "state"]) == "Done"
    assert get_in(decoded_tracker, ["issues", Access.at(1), "comments", Access.at(0), "body"]) == "Work started"
    assert get_in(decoded_tracker, ["issues", Access.at(1), "claimed_by"]) == nil
  end

  test "local issue tools validate inputs and report supported tools" do
    tracker_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "issues.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    File.write!(tracker_path, Jason.encode!(%{"issues" => []}, pretty: true))

    invalid_create = DynamicTool.execute("local_issue_create", %{})
    assert invalid_create["success"] == false

    assert decode_text_payload(invalid_create) == %{
             "error" => %{
               "message" => "`local_issue_create` requires a non-empty `title` string."
             }
           }

    invalid_list = DynamicTool.execute("local_issue_list", %{"states" => "Todo"})
    assert invalid_list["success"] == false

    assert decode_text_payload(invalid_list) == %{
             "error" => %{
               "message" => "`local_issue_list.states` must be an array of strings when provided."
             }
           }

    invalid_release = DynamicTool.execute("local_issue_release", "LOCAL-2")
    assert invalid_release["success"] == false

    assert decode_text_payload(invalid_release) == %{
             "error" => %{
               "message" => "`local_issue_release` expects an object with `issueRef`."
             }
           }

    missing_ref = DynamicTool.execute("local_issue_state", %{"state" => "Done"})
    assert missing_ref["success"] == false

    assert decode_text_payload(missing_ref) == %{
             "error" => %{
               "message" => "A non-empty `issueRef` is required."
             }
           }

    unsupported = DynamicTool.execute("linear_graphql", %{})
    assert unsupported["success"] == false

    assert decode_text_payload(unsupported) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "linear_graphql".),
               "supportedTools" => [
                 "local_issue_list",
                 "local_issue_create",
                 "local_issue_state",
                 "local_issue_comment",
                 "local_issue_release"
               ]
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
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called for multi-operation documents")
        end
      )

    assert response["success"] == false
    assert [%{"text" => text}] = response["contentItems"]

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
        %{"query" => "mutation SaveIssue { commentCreate(input: {body: \"hi\"}) { success } }"},
        allow_mutations?: false,
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when mutations are disabled")
        end
      )

    assert response["success"] == false
    assert [%{"text" => text}] = response["contentItems"]

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
        audit_metadata: %{
          session_id: "thread-1-turn-1",
          issue_id: "issue-1",
          issue_identifier: "OPE-46"
        },
        audit_fun: fn event -> send(test_pid, {:audit_event, event}) end,
        linear_client: fn _query, _variables, _opts ->
          case :atomics.add_get(counter, 1, 1) do
            1 -> {:error, {:linear_api_request, :timeout}}
            _ -> {:ok, %{"data" => %{"viewer" => %{"id" => "usr_retry"}}}}
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
    assert [%{"text" => text}] = response["contentItems"]

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

  defp decode_text_payload(response) do
    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    Jason.decode!(text)
  end
end
