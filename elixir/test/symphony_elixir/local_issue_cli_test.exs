defmodule SymphonyElixir.LocalIssueCLITest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO

  alias SymphonyElixir.{LocalIssueCLI, Tracker.Local, WorkflowStore}

  test "local issue cli prints help and usage errors" do
    output =
      capture_io(fn ->
        assert :ok = LocalIssueCLI.evaluate(["--help"])
      end)

    assert output =~ "symphony issue list"
    assert {:error, message} = LocalIssueCLI.evaluate([])
    assert message =~ "Usage:"
    assert {:error, message} = LocalIssueCLI.evaluate(["unknown"])
    assert message =~ "Usage:"
    assert {:error, message} = LocalIssueCLI.evaluate(["--bogus"])
    assert message =~ "Invalid option"

    help_output =
      capture_io(fn ->
        assert :ok = LocalIssueCLI.evaluate(["help"])
      end)

    assert help_output =~ "symphony issue list"
  end

  test "symphony issue commands create, list, and update local issues" do
    tracker_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "issues.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    File.write!(tracker_path, Jason.encode!(%{"issues" => []}, pretty: true))

    create_output =
      capture_io(fn ->
        assert :halt =
                 CLI.evaluate([
                   "issue",
                   "create",
                   "--title",
                   "Switch the tracker to local",
                   "--labels",
                   "go,migration",
                   "--priority",
                   "1"
                 ])
      end)

    assert create_output =~ "Created LOCAL-1"
    assert create_output =~ "[Todo] Switch the tracker to local"

    list_output =
      capture_io(fn ->
        assert :halt = CLI.evaluate(["issue", "list"])
      end)

    assert list_output =~ "LOCAL-1 [Todo] Switch the tracker to local"
    assert list_output =~ "labels=go, migration"
    assert list_output =~ "lease=unclaimed"

    state_output =
      capture_io(fn ->
        assert :halt = CLI.evaluate(["issue", "state", "LOCAL-1", "Done"])
      end)

    assert state_output =~ "Updated LOCAL-1 -> Done"
    assert {:ok, [%Issue{state: "Done"}]} = Local.list_issues()
  end

  test "local issue cli lists empty trackers and reports create, list, state, and comment failures" do
    tracker_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "issues.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    File.write!(tracker_path, Jason.encode!(%{"issues" => []}, pretty: true))

    list_output =
      capture_io(fn ->
        assert :ok = LocalIssueCLI.evaluate(["list"])
      end)

    assert list_output =~ "No issues found."

    assert {:error, "Missing required option: --title"} = LocalIssueCLI.evaluate(["create"])

    assert {:error, "Missing required option: --title"} =
             LocalIssueCLI.evaluate(["create", "--labels", " , "])

    assert {:ok, %Issue{identifier: "LOCAL-1"}} =
             Local.create_issue(%{"title" => "Existing local issue"})

    assert {:error, message} =
             LocalIssueCLI.evaluate(["create", "--title", "Duplicate", "--identifier", "LOCAL-1"])

    assert message =~ "Failed to create local issue"
    assert {:error, message} = LocalIssueCLI.evaluate(["state", "MISSING", "Done"])
    assert message =~ "issue not found"
    assert {:error, "Comment body cannot be empty"} = LocalIssueCLI.evaluate(["comment", "LOCAL-1", "   "])

    comment_output =
      capture_io(fn ->
        assert :ok = LocalIssueCLI.evaluate(["comment", "LOCAL-1", "migration", "finished"])
      end)

    assert comment_output =~ "Appended comment to LOCAL-1"

    assert {:error, message} = LocalIssueCLI.evaluate(["comment", "MISSING", "note"])
    assert message =~ "issue not found"

    File.write!(tracker_path, "{")
    assert {:error, message} = LocalIssueCLI.evaluate(["list"])
    assert message =~ "Failed to list local issues"
  end

  test "local issue cli prints descriptions and n-a values from stored issues" do
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
              "id" => "local-9",
              "identifier" => "LOCAL-9",
              "title" => "Describe me",
              "description" => "  tracked locally  ",
              "state" => "Todo"
            }
          ]
        },
        pretty: true
      )
    )

    list_output =
      capture_io(fn ->
        assert :ok = LocalIssueCLI.evaluate(["list"])
      end)

    assert list_output =~ "priority=n/a"
    assert list_output =~ "updated=n/a"
    assert list_output =~ "lease=unclaimed"
    assert list_output =~ "tracked locally"
  end

  test "local issue cli shows active claims and releases them" do
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
              "id" => "local-claim-1",
              "identifier" => "LOCAL-CLAIM-1",
              "title" => "Claimed issue",
              "state" => "Todo",
              "claimed_by" => "runtime-a",
              "lease_expires_at" => "2099-03-19T12:00:00Z"
            }
          ]
        },
        pretty: true
      )
    )

    list_output =
      capture_io(fn ->
        assert :ok = LocalIssueCLI.evaluate(["list"])
      end)

    assert list_output =~ "lease=active"
    assert list_output =~ "claim=runtime-a expires=2099-03-19T12:00:00Z"

    release_output =
      capture_io(fn ->
        assert :ok = LocalIssueCLI.evaluate(["release", "LOCAL-CLAIM-1"])
      end)

    assert release_output =~ "Released lease on LOCAL-CLAIM-1"
    assert {:ok, [%Issue{claimed_by: nil, lease_expires_at: nil}]} = Local.list_issues()

    assert {:error, message} = LocalIssueCLI.evaluate(["release", "MISSING"])
    assert message =~ "Failed to release local issue claim"
    assert message =~ "issue not found"
  end

  test "local issue cli reports workflow loading and configuration problems" do
    workflow_dir = Path.dirname(Workflow.workflow_file_path())
    missing_workflow = Path.join(workflow_dir, "MISSING_WORKFLOW.md")
    broken_workflow = Path.join(workflow_dir, "BROKEN_WORKFLOW.md")
    missing_kind_workflow = Path.join(workflow_dir, "MISSING_KIND_WORKFLOW.md")
    missing_path_workflow = Path.join(workflow_dir, "MISSING_PATH_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    on_exit(fn ->
      restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

      assert match?({:ok, _pid}, restart_result) or
               match?({:error, {:already_started, _pid}}, restart_result)
    end)

    File.write!(broken_workflow, "---\ntracker: [\n---\nBroken prompt\n")

    File.write!(
      missing_kind_workflow,
      """
      ---
      tracker:
        path: "./issues.json"
      ---
      Missing kind
      """
    )

    write_workflow_file!(missing_path_workflow,
      tracker_kind: "local",
      tracker_path: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert {:error, message} = LocalIssueCLI.evaluate(["list", "--workflow", missing_workflow])
    assert message =~ "Workflow file not found"

    assert {:error, message} = LocalIssueCLI.evaluate(["list", "--workflow", broken_workflow])
    assert message =~ "Failed to load workflow"

    assert {:error, message} = LocalIssueCLI.evaluate(["list", "--workflow", missing_kind_workflow])
    assert message =~ "tracker.kind must be set to \"local\""

    assert {:error, message} = LocalIssueCLI.evaluate(["list", "--workflow", missing_path_workflow])
    assert message =~ "tracker.path must be set"
  end

  test "local issue cli restores a cleared workflow path after workflow overrides" do
    tracker_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "issues.json")
    override_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "OVERRIDE_WORKFLOW.md")

    write_workflow_file!(override_workflow,
      tracker_kind: "local",
      tracker_path: tracker_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    File.write!(tracker_path, Jason.encode!(%{"issues" => []}, pretty: true))
    Workflow.clear_workflow_file_path()

    assert :ok = LocalIssueCLI.evaluate(["list", "--workflow", override_workflow])
    assert Application.get_env(:symphony_elixir, :workflow_file_path) == nil
  end

  test "symphony issue commands reject non-local workflows" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")

    assert {:error, message} = LocalIssueCLI.evaluate(["list"])
    assert message =~ "expected \"local\""
  end
end
