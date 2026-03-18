defmodule SymphonyElixir.DashboardCLITest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO

  alias SymphonyElixir.{DashboardCLI, Workflow, WorkflowStore}

  test "dashboard cli prints help and rejects invalid argv" do
    output =
      capture_io(fn ->
        assert :ok = DashboardCLI.evaluate(["--help"])
      end)

    assert output =~ "symphony panel"
    assert {:error, message} = DashboardCLI.evaluate(["--bogus"])
    assert message =~ "Invalid option"
    assert {:error, message} = DashboardCLI.evaluate(["extra"])
    assert message =~ "Usage:"
  end

  test "dashboard cli reports workflow and port configuration errors" do
    missing_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    broken_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "BROKEN_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    on_exit(fn ->
      restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

      assert match?({:ok, _pid}, restart_result) or
               match?({:error, {:already_started, _pid}}, restart_result)
    end)

    File.write!(broken_workflow, "---\ntracker: [\n---\nBroken prompt\n")

    assert {:error, message} = DashboardCLI.evaluate(["--workflow", missing_workflow])
    assert message =~ "Workflow file not found"

    assert {:error, message} = DashboardCLI.evaluate(["--workflow", broken_workflow])
    assert message =~ "Failed to load workflow"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_path: "./issues.json",
      server_port: nil
    )

    assert {:error, message} = DashboardCLI.evaluate([])
    assert message =~ "Dashboard is not configured"

    assert {:error, message} = DashboardCLI.evaluate(["--port", "0"])
    assert message =~ "positive integer"
  end

  test "dashboard cli normalizes host overrides and restores the previous workflow path" do
    previous_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "PREVIOUS_WORKFLOW.md")
    override_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "OVERRIDE_WORKFLOW.md")

    write_workflow_file!(previous_workflow,
      tracker_kind: "local",
      tracker_path: "./prev-issues.json",
      server_port: 4010
    )

    write_workflow_file!(override_workflow,
      tracker_kind: "local",
      tracker_path: "./override-issues.json",
      server_port: 4100
    )

    Workflow.set_workflow_file_path(previous_workflow)

    output =
      capture_io(fn ->
        assert :ok = DashboardCLI.evaluate(["--workflow", override_workflow, "--host", "0.0.0.0"])
      end)

    assert output == "http://127.0.0.1:4100/\n"
    assert Workflow.workflow_file_path() == previous_workflow

    output =
      capture_io(fn ->
        assert :ok = DashboardCLI.evaluate(["--workflow", override_workflow, "--host", "::1"])
      end)

    assert output == "http://[::1]:4100/\n"
    assert Workflow.workflow_file_path() == previous_workflow

    output =
      capture_io(fn ->
        assert :ok = DashboardCLI.evaluate(["--workflow", override_workflow, "--host", "[::1]"])
      end)

    assert output == "http://[::1]:4100/\n"
    assert Workflow.workflow_file_path() == previous_workflow

    output =
      capture_io(fn ->
        assert :ok = DashboardCLI.evaluate(["--workflow", override_workflow, "--host", "panel.local"])
      end)

    assert output == "http://panel.local:4100/\n"
    assert Workflow.workflow_file_path() == previous_workflow
  end

  test "dashboard cli restores a cleared workflow path after overrides" do
    override_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "TEMP_WORKFLOW.md")

    write_workflow_file!(override_workflow,
      tracker_kind: "local",
      tracker_path: "./override-issues.json",
      server_port: 4200
    )

    Workflow.clear_workflow_file_path()

    output =
      capture_io(fn ->
        assert :ok = DashboardCLI.evaluate(["--workflow", override_workflow, "--host", "example.local"])
      end)

    assert output == "http://example.local:4200/\n"
    assert Application.get_env(:symphony_elixir, :workflow_file_path) == nil
  end
end
