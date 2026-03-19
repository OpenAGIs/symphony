defmodule SymphonyElixir.Issue do
  @moduledoc """
  Normalized tracker issue representation used by the orchestrator.
  """

  @type comment :: %{
          body: String.t(),
          created_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :claimed_by,
    blocked_by: [],
    labels: [],
    comments: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil,
    claimed_at: nil,
    lease_expires_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          claimed_by: String.t() | nil,
          blocked_by: [String.t()],
          labels: [String.t()],
          comments: [comment()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          claimed_at: DateTime.t() | nil,
          lease_expires_at: DateTime.t() | nil
        }

  @risk_levels %{
    "low" => 1,
    "medium" => 2,
    "high" => 3,
    "critical" => 4
  }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end

  @spec required_capabilities(t()) :: [String.t()]
  def required_capabilities(%__MODULE__{} = issue) do
    issue
    |> label_names()
    |> Enum.reduce([], fn label, acc ->
      case parse_prefixed_label(label, ["capability:", "cap:"]) do
        nil -> acc
        capability -> [capability | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  @spec risk_level(t()) :: String.t() | nil
  def risk_level(%__MODULE__{} = issue) do
    issue
    |> label_names()
    |> Enum.find_value(fn label -> parse_prefixed_label(label, ["risk:"]) end)
    |> normalize_risk_level()
  end

  @spec budget(t()) :: pos_integer() | nil
  def budget(%__MODULE__{} = issue) do
    issue
    |> label_names()
    |> Enum.find_value(fn label -> parse_prefixed_label(label, ["budget:"]) end)
    |> parse_budget_value()
  end

  @spec risk_rank(String.t() | nil) :: non_neg_integer()
  def risk_rank(level) when is_binary(level) do
    Map.get(@risk_levels, normalize_risk_level(level), 0)
  end

  def risk_rank(_level), do: 0

  defp parse_prefixed_label(label, prefixes) when is_binary(label) and is_list(prefixes) do
    normalized_label = String.trim(label)

    Enum.find_value(prefixes, fn prefix ->
      prefix_length = byte_size(prefix)

      if String.starts_with?(String.downcase(normalized_label), prefix) do
        normalized_label
        |> binary_part(prefix_length, byte_size(normalized_label) - prefix_length)
        |> String.trim()
        |> empty_to_nil()
      end
    end)
  end

  defp parse_prefixed_label(_label, _prefixes), do: nil

  defp normalize_risk_level(level) when is_binary(level) do
    level
    |> String.trim()
    |> String.downcase()
    |> empty_to_nil()
  end

  defp normalize_risk_level(_level), do: nil

  defp parse_budget_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_budget_value(_value), do: nil

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
