defmodule SymphonyElixir.WorkpadTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workpad

  test "bootstrap_body follows the workflow template header and sections" do
    body = Workpad.bootstrap_body("host:/tmp/workspace@abc123")

    assert body =~ "## Codex Workpad"
    assert body =~ "```text\nhost:/tmp/workspace@abc123\n```"
    assert body =~ "### Plan"
    assert body =~ "### Acceptance Criteria"
    assert body =~ "### Validation"
    assert body =~ "### Notes"
  end

  test "workpad_comment? recognizes the marker header" do
    assert Workpad.workpad_comment?("## Codex Workpad\n\nBody")
    refute Workpad.workpad_comment?("## Something Else")
    refute Workpad.workpad_comment?(nil)
  end
end
