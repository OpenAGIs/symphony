defmodule SymphonyElixir.Linear.Issue do
  @moduledoc false

  alias SymphonyElixir.Issue

  @deprecated "Use SymphonyElixir.Issue instead."
  @type t :: Issue.t()

  @spec label_names(t()) :: [String.t()]
  defdelegate label_names(issue), to: Issue
end
