defmodule SymphonyElixir.Linear.IssueTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Issue
  alias SymphonyElixir.Linear.Issue, as: LinearIssue

  describe "label-driven scheduler metadata" do
    test "extracts label names and required capabilities" do
      issue = %Issue{labels: ["bug", 123, " capability:Backend ", "cap:frontend", "cap:frontend", "cap:"]}

      assert LinearIssue.label_names(issue) == ["bug", 123, " capability:Backend ", "cap:frontend", "cap:frontend", "cap:"]
      assert LinearIssue.required_capabilities(issue) == ["Backend", "frontend"]
    end

    test "normalizes risk labels and ignores invalid values" do
      issue = %Issue{labels: ["risk: High ", "risk:", "risk:unknown"]}

      assert LinearIssue.risk_level(issue) == "high"
      assert LinearIssue.risk_rank("critical") == 4
      assert LinearIssue.risk_rank(" High ") == 3
      assert LinearIssue.risk_rank("unknown") == 0
      assert LinearIssue.risk_rank(nil) == 0
    end

    test "parses budget labels and rejects invalid values" do
      assert LinearIssue.budget(%Issue{labels: ["budget: 5 "]}) == 5
      assert LinearIssue.budget(%Issue{labels: ["budget:0"]}) == nil
      assert LinearIssue.budget(%Issue{labels: ["budget:nope"]}) == nil
      assert LinearIssue.budget(%Issue{labels: ["other"]}) == nil
    end

    test "returns nil when no scheduler labels are present" do
      issue = %Issue{labels: ["enhancement", "triage"]}

      assert LinearIssue.required_capabilities(issue) == []
      assert LinearIssue.risk_level(issue) == nil
      assert LinearIssue.budget(issue) == nil
    end
  end
end
