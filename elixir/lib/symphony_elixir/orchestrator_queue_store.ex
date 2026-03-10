defmodule SymphonyElixir.OrchestratorQueueStore do
  @moduledoc """
  Persists retry and dead-letter queue state under the configured workspace root.
  """

  require Logger

  alias SymphonyElixir.Config

  @queue_dir ".symphony"
  @queue_file "orchestrator_queue.json"

  @type retry_entry :: %{
          required(:attempt) => pos_integer(),
          required(:identifier) => String.t(),
          required(:retry_at_unix_ms) => integer(),
          optional(:error) => String.t() | nil
        }

  @type dead_letter_entry :: %{
          required(:attempt) => pos_integer(),
          required(:identifier) => String.t(),
          required(:failed_at) => String.t(),
          optional(:error) => String.t() | nil
        }

  @type queue_state :: %{
          retry_attempts: %{optional(String.t()) => retry_entry()},
          dead_letters: %{optional(String.t()) => dead_letter_entry()}
        }

  @spec load() :: {:ok, queue_state()} | {:error, term()}
  def load do
    path = queue_state_path()

    case File.read(path) do
      {:ok, contents} -> decode(contents)
      {:error, :enoent} -> {:ok, empty_state()}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec persist(queue_state()) :: :ok | {:error, term()}
  def persist(%{retry_attempts: retry_attempts, dead_letters: dead_letters})
      when is_map(retry_attempts) and is_map(dead_letters) do
    path = queue_state_path()
    tmp_path = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, payload} <- encode(%{retry_attempts: retry_attempts, dead_letters: dead_letters}),
         :ok <- File.write(tmp_path, payload),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("Failed persisting orchestrator queue state path=#{path}: #{inspect(reason)}")
        File.rm(tmp_path)
        error
    end
  end

  @spec queue_state_path() :: Path.t()
  def queue_state_path do
    Path.join([Config.workspace_root(), @queue_dir, @queue_file])
  end

  defp empty_state do
    %{retry_attempts: %{}, dead_letters: %{}}
  end

  defp encode(state) do
    {:ok,
     Jason.encode!(%{
       retry_attempts: state.retry_attempts,
       dead_letters: state.dead_letters
     })}
  rescue
    error in [Jason.EncodeError, Protocol.UndefinedError] -> {:error, error}
  end

  defp decode(contents) when is_binary(contents) do
    case Jason.decode(contents) do
      {:ok, %{"retry_attempts" => retry_attempts, "dead_letters" => dead_letters}} ->
        {:ok, %{retry_attempts: load_retry_attempts(retry_attempts), dead_letters: load_dead_letters(dead_letters)}}

      {:ok, _payload} ->
        {:ok, empty_state()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_retry_attempts(entries) when is_map(entries) do
    Enum.reduce(entries, %{}, fn
      {issue_id, %{"attempt" => attempt, "identifier" => identifier, "retry_at_unix_ms" => retry_at_unix_ms} = entry}, acc
      when is_binary(issue_id) and is_integer(attempt) and attempt > 0 and
             is_binary(identifier) and is_integer(retry_at_unix_ms) ->
        Map.put(acc, issue_id, %{
          attempt: attempt,
          identifier: identifier,
          retry_at_unix_ms: retry_at_unix_ms,
          error: normalize_optional_string(Map.get(entry, "error"))
        })

      _, acc ->
        acc
    end)
  end

  defp load_retry_attempts(_entries), do: %{}

  defp load_dead_letters(entries) when is_map(entries) do
    Enum.reduce(entries, %{}, fn
      {issue_id, %{"attempt" => attempt, "identifier" => identifier, "failed_at" => failed_at} = entry}, acc
      when is_binary(issue_id) and is_integer(attempt) and attempt > 0 and
             is_binary(identifier) and is_binary(failed_at) ->
        Map.put(acc, issue_id, %{
          attempt: attempt,
          identifier: identifier,
          failed_at: failed_at,
          error: normalize_optional_string(Map.get(entry, "error"))
        })

      _, acc ->
        acc
    end)
  end

  defp load_dead_letters(_entries), do: %{}

  defp normalize_optional_string(value) when is_binary(value), do: value
  defp normalize_optional_string(_value), do: nil
end
