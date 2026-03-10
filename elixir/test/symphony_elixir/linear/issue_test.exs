defmodule SymphonyElixir.Linear.IssueTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue

  describe "label-driven scheduler metadata" do
    test "extracts label names and required capabilities" do
      issue = %Issue{labels: ["bug", 123, " capability:Backend ", "cap:frontend", "cap:frontend", "cap:"]}

      assert Issue.label_names(issue) == ["bug", 123, " capability:Backend ", "cap:frontend", "cap:frontend", "cap:"]
      assert Issue.required_capabilities(issue) == ["Backend", "frontend"]
    end

    test "normalizes risk labels and ignores invalid values" do
      issue = %Issue{labels: ["risk: High ", "risk:", "risk:unknown"]}

      assert Issue.risk_level(issue) == "high"
      assert Issue.risk_rank("critical") == 4
      assert Issue.risk_rank(" High ") == 3
      assert Issue.risk_rank("unknown") == 0
      assert Issue.risk_rank(nil) == 0
    end

    test "parses budget labels and rejects invalid values" do
      assert Issue.budget(%Issue{labels: ["budget: 5 "]}) == 5
      assert Issue.budget(%Issue{labels: ["budget:0"]}) == nil
      assert Issue.budget(%Issue{labels: ["budget:nope"]}) == nil
      assert Issue.budget(%Issue{labels: ["other"]}) == nil
    end

    test "returns nil when no scheduler labels are present" do
      issue = %Issue{labels: ["enhancement", "triage"]}

      assert Issue.required_capabilities(issue) == []
      assert Issue.risk_level(issue) == nil
      assert Issue.budget(issue) == nil
    end
  end
end
