defmodule SymphonyElixir.MetadataCacheTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.MetadataCache

  test "metadata cache start_link, get, and put operations work end to end" do
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, MetadataCache)
    assert {:ok, pid} = MetadataCache.start_link()
    assert Process.alive?(pid)
    assert MetadataCache.get_viewer_id() == nil
    assert MetadataCache.get_state_id("Todo") == nil

    :ok = MetadataCache.put_viewer_id("viewer-1")
    :ok = MetadataCache.put_state_id("Todo", "state-1")
    Process.sleep(10)

    assert MetadataCache.get_viewer_id() == "viewer-1"
    assert MetadataCache.get_state_id("Todo") == "state-1"

    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, MetadataCache)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)
  end
end
