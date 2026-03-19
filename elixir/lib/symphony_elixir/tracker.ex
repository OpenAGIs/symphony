defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Adapter, as: LinearAdapter
  alias SymphonyElixir.Tracker.Local
  alias SymphonyElixir.Tracker.Memory
  alias SymphonyElixir.Tracker.Unsupported

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback ensure_workpad_comment(String.t(), String.t()) ::
              {:ok, %{id: String.t(), body: String.t(), created?: boolean()}} | {:error, term()}
  @callback update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec ensure_workpad_comment(String.t(), String.t()) ::
          {:ok, %{id: String.t(), body: String.t(), created?: boolean()}} | {:error, term()}
  def ensure_workpad_comment(issue_id, body) do
    adapter().ensure_workpad_comment(issue_id, body)
  end

  @spec update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(comment_id, body) do
    adapter().update_comment(comment_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec claim_issue(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def claim_issue(issue_id, owner, opts \\ []) when is_binary(issue_id) and is_binary(owner) do
    case adapter() do
      Local ->
        Local.claim_issue(issue_id, owner, opts)

      _other ->
        :ok
    end
  end

  @spec release_issue_claim(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def release_issue_claim(issue_id, owner \\ nil) when is_binary(issue_id) do
    case adapter() do
      Local ->
        Local.release_issue_claim(issue_id, owner)

      _other ->
        :ok
    end
  end

  @spec adapter() :: module()
  def adapter do
    case Config.tracker_kind() do
      "local" -> Local
      "memory" -> Memory
      "linear" -> LinearAdapter
      kind when is_binary(kind) -> Config.tracker_adapter_module() || adapter_for_kind(kind)
      _kind -> Unsupported
    end
  end

  defp adapter_for_kind(kind) when is_binary(kind) do
    Application.get_env(:symphony_elixir, :tracker_adapter_modules, %{})
    |> Map.get(kind, Unsupported)
  end
end
