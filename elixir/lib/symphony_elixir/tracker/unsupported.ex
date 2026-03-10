defmodule SymphonyElixir.Tracker.Unsupported do
  @moduledoc """
  Deterministic fallback adapter for configured tracker kinds without runtime wiring.
  """

  @behaviour SymphonyElixir.Tracker

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: {:error, unsupported_reason()}

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(_states), do: {:error, unsupported_reason()}

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(_issue_ids), do: {:error, unsupported_reason()}

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(_issue_id, _body), do: {:error, unsupported_reason()}

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(_issue_id, _state_name), do: {:error, unsupported_reason()}

  defp unsupported_reason do
    {:unsupported_tracker_adapter, SymphonyElixir.Config.tracker_kind()}
  end
end
