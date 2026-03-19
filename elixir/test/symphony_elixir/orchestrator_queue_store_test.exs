defmodule SymphonyElixir.OrchestratorQueueStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.OrchestratorQueueStore

  test "load returns an empty state when the queue file is missing" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-store-missing-#{System.unique_integer([:positive])}")

    write_workflow_file!(Application.fetch_env!(:symphony_elixir, :workflow_file_path),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    on_exit(fn -> File.rm_rf(workspace_root) end)

    assert {:ok, %{retry_attempts: %{}, dead_letters: %{}}} = OrchestratorQueueStore.load()
    assert OrchestratorQueueStore.queue_state_path() =~ ".symphony/orchestrator_queue.json"
  end

  test "persist and load round-trip retry and dead-letter entries" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-store-roundtrip-#{System.unique_integer([:positive])}")

    write_workflow_file!(Application.fetch_env!(:symphony_elixir, :workflow_file_path),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    on_exit(fn -> File.rm_rf(workspace_root) end)

    queue_state = %{
      retry_attempts: %{
        "issue-1" => %{
          attempt: 2,
          identifier: "MT-500",
          retry_at_unix_ms: 123_456,
          error: "boom"
        },
        "ignored-retry" => %{"bad" => true}
      },
      dead_letters: %{
        "issue-2" => %{
          attempt: 4,
          identifier: "MT-501",
          failed_at: "2026-03-10T00:00:00Z",
          error: nil
        },
        "ignored-dead-letter" => %{"bad" => true}
      }
    }

    assert :ok = OrchestratorQueueStore.persist(queue_state)

    assert {:ok,
            %{
              retry_attempts: %{
                "issue-1" => %{
                  attempt: 2,
                  identifier: "MT-500",
                  retry_at_unix_ms: 123_456,
                  error: "boom"
                }
              },
              dead_letters: %{
                "issue-2" => %{
                  attempt: 4,
                  identifier: "MT-501",
                  failed_at: "2026-03-10T00:00:00Z",
                  error: nil
                }
              }
            }} = OrchestratorQueueStore.load()
  end

  test "load returns empty state for unexpected JSON payloads and errors for invalid JSON" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-store-invalid-#{System.unique_integer([:positive])}")

    write_workflow_file!(Application.fetch_env!(:symphony_elixir, :workflow_file_path),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    on_exit(fn -> File.rm_rf(workspace_root) end)

    path = OrchestratorQueueStore.queue_state_path()
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, ~s({"foo":"bar"}))
    assert {:ok, %{retry_attempts: %{}, dead_letters: %{}}} = OrchestratorQueueStore.load()

    File.write!(path, ~s({"retry_attempts":[],"dead_letters":[]}))
    assert {:ok, %{retry_attempts: %{}, dead_letters: %{}}} = OrchestratorQueueStore.load()

    File.write!(path, "not-json")
    assert {:error, _reason} = OrchestratorQueueStore.load()
  end

  test "load returns an error when the queue path is a directory" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-store-read-error-#{System.unique_integer([:positive])}")

    write_workflow_file!(Application.fetch_env!(:symphony_elixir, :workflow_file_path),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    on_exit(fn -> File.rm_rf(workspace_root) end)

    path = OrchestratorQueueStore.queue_state_path()
    File.mkdir_p!(path)

    assert {:error, :eisdir} = OrchestratorQueueStore.load()
  end

  test "persist returns an error when the queue state is not JSON encodable" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-store-encode-#{System.unique_integer([:positive])}")

    write_workflow_file!(Application.fetch_env!(:symphony_elixir, :workflow_file_path),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    on_exit(fn -> File.rm_rf(workspace_root) end)

    assert {:error, reason} =
             OrchestratorQueueStore.persist(%{
               retry_attempts: %{
                 "issue-3" => %{
                   attempt: 1,
                   identifier: "MT-502",
                   retry_at_unix_ms: 1,
                   error: self()
                 }
               },
               dead_letters: %{}
             })

    assert match?(%Jason.EncodeError{}, reason) or match?(%Protocol.UndefinedError{}, reason)
  end

  test "persist returns an error when the queue directory cannot be created" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-store-write-error-#{System.unique_integer([:positive])}")

    write_workflow_file!(Application.fetch_env!(:symphony_elixir, :workflow_file_path),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    on_exit(fn -> File.rm_rf(workspace_root) end)

    File.mkdir_p!(workspace_root)
    File.write!(Path.join(workspace_root, ".symphony"), "not-a-directory")

    assert {:error, :enotdir} =
             OrchestratorQueueStore.persist(%{
               retry_attempts: %{},
               dead_letters: %{}
             })
  end
end
