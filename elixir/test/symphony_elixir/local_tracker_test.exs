defmodule SymphonyElixir.LocalTrackerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Local

  test "local tracker fetches candidate issues from a file-backed store" do
    tracker_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "issues.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_active_states: ["Todo", "In Progress"]
    )

    File.write!(
      tracker_path,
      Jason.encode!(
        %{
          "issues" => [
            %{
              "id" => "issue-1",
              "identifier" => "LOC-1",
              "title" => "First local issue",
              "description" => "todo body",
              "priority" => 1,
              "state" => "Todo",
              "labels" => ["Infra", "Backend"],
              "assigned_to_worker" => true
            },
            %{
              "id" => "issue-2",
              "identifier" => "LOC-2",
              "title" => "Blocked local issue",
              "state" => "Done",
              "assigned_to_worker" => true
            }
          ]
        },
        pretty: true
      )
    )

    assert {:ok, [%Issue{id: "issue-1", identifier: "LOC-1", labels: ["infra", "backend"]}]} =
             Local.fetch_candidate_issues()

    assert {:ok, [%Issue{id: "issue-2", state: "Done"}]} =
             Local.fetch_issues_by_states(["Done"])

    assert {:ok, [%Issue{id: "issue-1"}]} = Local.fetch_issue_states_by_ids(["issue-1"])
  end

  test "local tracker persists comments and state transitions" do
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
              "id" => "issue-1",
              "identifier" => "LOC-1",
              "title" => "Track state",
              "state" => "Todo"
            }
          ]
        },
        pretty: true
      )
    )

    assert :ok = Local.create_comment("issue-1", "first note")
    assert :ok = Local.update_issue_state("issue-1", "In Progress")

    {:ok, payload} = File.read(tracker_path)
    decoded = Jason.decode!(payload)
    [issue] = decoded["issues"]

    assert issue["state"] == "In Progress"
    assert [%{"body" => "first note", "created_at" => created_at}] = issue["comments"]
    assert is_binary(created_at)
    assert is_binary(issue["updated_at"])
  end

  test "local tracker creates issues with generated ids and accepts identifier-based updates" do
    tracker_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "issues.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    File.write!(tracker_path, Jason.encode!(%{"issues" => []}, pretty: true))

    assert {:ok,
            %Issue{
              id: "local-1",
              identifier: "LOCAL-1",
              title: "Move the remaining workflow entrypoints local",
              priority: 1,
              state: "Todo",
              labels: ["go", "migration"]
            }} =
             Local.create_issue(%{
               "title" => "Move the remaining workflow entrypoints local",
               "priority" => "1",
               "labels" => ["Go", "Migration"]
             })

    assert :ok = Local.update_issue_state("LOCAL-1", "Done")
    assert :ok = Local.create_comment("LOCAL-1", "migration finished")

    assert {:ok, [%Issue{id: "local-1", state: "Done"}]} = Local.list_issues()

    {:ok, payload} = File.read(tracker_path)
    decoded = Jason.decode!(payload)
    [issue] = decoded["issues"]

    assert issue["identifier"] == "LOCAL-1"
    assert issue["state"] == "Done"
    assert [%{"body" => "migration finished"}] = Enum.map(issue["comments"], &Map.take(&1, ["body"]))
  end

  test "local tracker treats a missing file as an empty queue and surfaces invalid payloads" do
    tracker_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "missing-issues.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert {:ok, []} = Local.fetch_candidate_issues()

    File.write!(tracker_path, ~s({"issues": {"not": "a-list"}}))

    assert {:error, :invalid_local_tracker_payload} = Local.fetch_candidate_issues()
  end

  test "local tracker atomically claims and releases issues for distributed runs" do
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
              "id" => "issue-lease-1",
              "identifier" => "LOC-L1",
              "title" => "Leased issue",
              "state" => "Todo"
            },
            %{
              "id" => "issue-lease-1b",
              "identifier" => "LOC-L1B",
              "title" => "Sibling issue",
              "state" => "Todo"
            }
          ]
        },
        pretty: true
      )
    )

    assert :ok = Local.claim_issue("issue-lease-1", "runtime-a", ttl_ms: 60_000)

    assert {:error, {:issue_claimed, "runtime-a", lease_expires_at}} =
             Local.claim_issue("issue-lease-1", "runtime-b", ttl_ms: 60_000)

    assert is_binary(lease_expires_at)
    assert {:ok, [%Issue{id: "issue-lease-1b", claimed_by: nil}]} = Local.fetch_candidate_issues()

    assert {:ok, [%Issue{id: "issue-lease-1", claimed_by: "runtime-a", lease_expires_at: %DateTime{}}]} =
             Local.fetch_issue_states_by_ids(["issue-lease-1"])

    assert {:error, {:issue_claimed, "runtime-a", ^lease_expires_at}} =
             Local.release_issue_claim("issue-lease-1", "runtime-b")

    assert :ok = Local.release_issue_claim("issue-lease-1", "runtime-a")

    assert {:ok, candidates} = Local.fetch_candidate_issues()
    assert Enum.map(candidates, & &1.id) == ["issue-lease-1", "issue-lease-1b"]
  end

  test "local tracker lets expired claims return to the candidate pool" do
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
              "id" => "issue-lease-2",
              "identifier" => "LOC-L2",
              "title" => "Expiring issue",
              "state" => "Todo"
            }
          ]
        },
        pretty: true
      )
    )

    assert :ok = Local.claim_issue("issue-lease-2", "runtime-a", ttl_ms: 1)
    Process.sleep(10)

    assert {:ok, [%Issue{id: "issue-lease-2"}]} = Local.fetch_candidate_issues()
    assert :ok = Local.claim_issue("issue-lease-2", "runtime-b", ttl_ms: 60_000)

    assert {:ok, [%Issue{id: "issue-lease-2", claimed_by: "runtime-b"}]} =
             Local.fetch_issue_states_by_ids(["issue-lease-2"])
  end

  test "local tracker renews same-owner claims, supports force release, and surfaces missing refs" do
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
              "id" => "issue-lease-3",
              "identifier" => "LOC-L3",
              "title" => "Renewable issue",
              "state" => "Todo"
            }
          ]
        },
        pretty: true
      )
    )

    assert {:error, :issue_not_found} = Local.claim_issue("missing", "runtime-a")
    assert {:error, :issue_not_found} = Local.release_issue_claim("missing", "runtime-a")

    assert :ok = Local.claim_issue("issue-lease-3", "runtime-a")
    assert {:ok, [%Issue{lease_expires_at: first_expiry}]} = Local.fetch_issue_states_by_ids(["issue-lease-3"])
    assert %DateTime{} = first_expiry

    Process.sleep(10)
    assert :ok = Local.claim_issue("issue-lease-3", "runtime-a", ttl_ms: 60_000)

    assert {:ok, [%Issue{claimed_by: "runtime-a", lease_expires_at: renewed_expiry}]} =
             Local.fetch_issue_states_by_ids(["issue-lease-3"])

    assert %DateTime{} = renewed_expiry
    refute DateTime.compare(renewed_expiry, first_expiry) == :eq

    assert :ok = Local.release_issue_claim("issue-lease-3")

    assert {:ok, [%Issue{claimed_by: nil, lease_expires_at: nil}]} =
             Local.fetch_issue_states_by_ids(["issue-lease-3"])
  end

  test "local tracker normalizes raw payloads and keyword attrs" do
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
        [
          %{
            "id" => 123,
            "identifier" => "LOC-3",
            "title" => 456,
            "description" => 789,
            "priority" => "oops",
            "state" => "Todo",
            "labels" => ["API"],
            "blocked_by" => ["LOC-1"],
            "created_at" => "bad",
            "updated_at" => "bad"
          },
          "noise"
        ],
        pretty: true
      )
    )

    assert {:ok, [%Issue{} = normalized]} = Local.list_issues()
    assert normalized.id == "123"
    assert normalized.title == "456"
    assert normalized.description == "789"
    assert normalized.priority == nil
    assert normalized.labels == ["api"]
    assert normalized.blocked_by == ["LOC-1"]
    assert normalized.created_at == nil
    assert normalized.updated_at == nil
    assert {:ok, [%Issue{id: "123"}]} = Local.fetch_issues_by_states([" todo ", 42])
    assert :ok = Local.update_issue_state("LOC-3", "Done")

    assert {:ok,
            %Issue{
              identifier: "LOCAL-1",
              description: "123",
              labels: ["ops", "nil"],
              blocked_by: ["1", "LOC-9"],
              assigned_to_worker: false,
              state: "Todo"
            }} =
             Local.create_issue(
               title: "Keyword issue",
               description: 123,
               labels: [:Ops, nil, 1, "  "],
               blocked_by: [1, " ", "LOC-9"],
               assigned_to_worker: "false",
               priority: nil,
               branch_name: :feature_local,
               assignee_id: 42,
               url: "https://example.test/issues/1"
             )

    assert {:ok, %Issue{labels: ["5"], blocked_by: []}} =
             Local.create_issue(%{
               "title" => "Scalar labels",
               "labels" => 5,
               "blocked_by" => [" "],
               "assigned_to_worker" => false,
               "description" => []
             })

    assert {:ok, %Issue{assigned_to_worker: true, labels: ["go", "migration"]}} =
             Local.create_issue(%{
               "title" => "String labels",
               "labels" => " Go , Migration ",
               "assigned_to_worker" => "true",
               "description" => "   "
             })
  end

  test "local tracker surfaces validation, duplicate, decode, read, and write errors" do
    tracker_root = Path.dirname(Workflow.workflow_file_path())
    tracker_path = Path.join(tracker_root, "issues.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    File.write!(tracker_path, Jason.encode!(%{"issues" => []}, pretty: true))

    assert {:error, :missing_issue_title} = Local.create_issue(%{})
    assert {:error, :invalid_issue_priority} = Local.create_issue(%{"title" => "Bad priority", "priority" => "oops"})
    assert {:error, :invalid_assigned_to_worker} = Local.create_issue(%{"title" => "Bad worker", "assigned_to_worker" => "maybe"})

    assert {:ok, %Issue{id: "local-1", identifier: "LOCAL-1"}} =
             Local.create_issue(%{"title" => "First"})

    assert {:error, {:duplicate_issue_field, "identifier", "LOCAL-1"}} =
             Local.create_issue(%{"title" => "Duplicate", "identifier" => "LOCAL-1"})

    File.write!(tracker_path, "{")
    assert {:error, {:local_tracker_decode_failed, _reason}} = Local.fetch_candidate_issues()

    unreadable_path = Path.join(tracker_root, "issues-dir")
    File.mkdir_p!(unreadable_path)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: unreadable_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert {:error, {:local_tracker_read_failed, reason}} = Local.fetch_candidate_issues()
    assert reason in [:eisdir, :eperm]

    readonly_dir = Path.join(tracker_root, "readonly")
    File.mkdir_p!(readonly_dir)
    File.chmod!(readonly_dir, 0o555)

    on_exit(fn ->
      File.chmod!(readonly_dir, 0o755)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: Path.join(readonly_dir, "issues.json"),
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert {:error, {:local_tracker_write_failed, _reason}} =
             Local.create_issue(%{"title" => "Cannot persist"})
  end

  test "local tracker reports a missing tracker path" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert {:error, :missing_local_tracker_path} = Local.fetch_candidate_issues()
  end
end
