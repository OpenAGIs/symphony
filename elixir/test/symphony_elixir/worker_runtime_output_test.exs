defmodule SymphonyElixir.WorkerRuntimeOutputTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Issue
  alias SymphonyElixir.WorkerRuntimeOutput

  test "worker runtime output persists metadata events and artifacts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-worker-runtime-output-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      logs_root = Path.join(test_root, "logs-root")
      File.mkdir_p!(Path.join(workspace, ".git"))
      File.mkdir_p!(Path.join(workspace, ".elixir_ls"))
      File.write!(Path.join(workspace, "README.md"), "hello\n")
      File.write!(Path.join(workspace, ".git/config"), "ignored\n")
      File.write!(Path.join(workspace, ".elixir_ls/cache"), "ignored\n")

      Application.put_env(:symphony_elixir, :log_file, SymphonyElixir.LogFile.default_log_file(logs_root))

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :log_file)
      end)

      context = WorkerRuntimeOutput.start(%{id: "issue-1", identifier: "MT/Output-1"}, workspace)

      :ok =
        WorkerRuntimeOutput.append_event(context, %{
          event: :session_started,
          timestamp: DateTime.utc_now(),
          nested: [%{phase: :boot}],
          issue: %Issue{identifier: "MT/Output-1", state: "Todo"}
        })

      :ok = WorkerRuntimeOutput.finish(context, {:error, :blocked})

      assert is_binary(context.run_dir)
      assert String.contains?(Path.basename(context.run_dir), "MT_Output-1")

      metadata = context.run_dir |> Path.join("metadata.json") |> File.read!() |> Jason.decode!()
      artifacts = context.run_dir |> Path.join("workspace-artifacts.json") |> File.read!() |> Jason.decode!()
      [event] = context.run_dir |> Path.join("codex-events.jsonl") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert metadata["issue"] == %{"id" => "issue-1", "identifier" => "MT/Output-1"}
      assert metadata["outcome"] == %{"status" => "error", "reason" => ":blocked"}
      assert metadata["log_file"] == Path.expand(Path.join([logs_root, "log", "symphony.log"]))
      assert [%{"path" => "README.md", "size_bytes" => 6}] = artifacts
      assert event["event"] == "session_started"
      assert is_binary(event["recorded_at"])
      assert event["nested"] == [%{"phase" => "boot"}]
      assert event["issue"]["identifier"] == "MT/Output-1"
      assert is_binary(event["timestamp"])
    after
      File.rm_rf(test_root)
    end
  end

  test "worker runtime output degrades safely when output root is unavailable" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-worker-runtime-output-disabled-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)

    previous_log_file = Application.get_env(:symphony_elixir, :log_file)
    Application.put_env(:symphony_elixir, :log_file, "/dev/null/symphony.log")

    on_exit(fn ->
      if previous_log_file do
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      else
        Application.delete_env(:symphony_elixir, :log_file)
      end

      File.rm_rf(workspace)
    end)

    log =
      capture_log(fn ->
        context = WorkerRuntimeOutput.start(%{}, workspace)
        assert context.issue_identifier == "issue"
        assert context.run_dir == nil
        assert :ok = WorkerRuntimeOutput.append_event(context, %{})
        assert :ok = WorkerRuntimeOutput.finish(context, :ok)
      end)

    assert log =~ "Failed to create worker runtime output directory"
  end

  test "worker runtime output logs write failures without crashing" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-worker-runtime-output-write-failure-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      logs_root = Path.join(test_root, "logs-root")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "hello\n")
      Application.put_env(:symphony_elixir, :log_file, SymphonyElixir.LogFile.default_log_file(logs_root))

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :log_file)
      end)

      context = WorkerRuntimeOutput.start(%{identifier: "MT-WRITE"}, workspace)
      File.rm_rf!(context.run_dir)
      File.write!(context.run_dir, "occupied\n")

      log =
        capture_log(fn ->
          assert :ok = WorkerRuntimeOutput.append_event(context, %{event: :notification})
          assert :ok = WorkerRuntimeOutput.finish(context, :ok)
        end)

      assert log =~ "Failed to append worker runtime event"
      assert log =~ "Failed to write worker runtime artifact"
    after
      File.rm_rf(test_root)
    end
  end
end
