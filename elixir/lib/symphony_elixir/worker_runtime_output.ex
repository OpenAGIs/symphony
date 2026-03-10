defmodule SymphonyElixir.WorkerRuntimeOutput do
  @moduledoc """
  Persists upload-ready worker runtime outputs for each agent run.
  """

  require Logger

  alias SymphonyElixir.LogFile

  @excluded_prefixes [".git/", ".elixir_ls/"]

  @type t :: %{
          issue_id: String.t() | nil,
          issue_identifier: String.t(),
          run_dir: Path.t() | nil,
          workspace: Path.t(),
          started_at: DateTime.t()
        }

  @spec start(map(), Path.t()) :: t()
  def start(issue, workspace) when is_binary(workspace) do
    started_at = DateTime.utc_now()
    issue_id = Map.get(issue, :id) || Map.get(issue, "id")
    issue_identifier = issue_identifier(issue)

    run_dir =
      issue_identifier
      |> run_dir_name(started_at)
      |> then(&Path.join(runs_root(), &1))

    case File.mkdir_p(run_dir) do
      :ok ->
        %{
          issue_id: issue_id,
          issue_identifier: issue_identifier,
          run_dir: run_dir,
          workspace: workspace,
          started_at: started_at
        }

      {:error, reason} ->
        Logger.warning("Failed to create worker runtime output directory issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier} workspace=#{workspace} reason=#{inspect(reason)}")

        %{
          issue_id: issue_id,
          issue_identifier: issue_identifier,
          run_dir: nil,
          workspace: workspace,
          started_at: started_at
        }
    end
  end

  @spec append_event(t(), map()) :: :ok
  def append_event(%{run_dir: nil}, _event), do: :ok

  def append_event(%{run_dir: run_dir} = context, event) when is_map(event) do
    event_record =
      event
      |> normalize_value()
      |> Map.put("recorded_at", DateTime.utc_now() |> DateTime.to_iso8601())

    append_jsonl(Path.join(run_dir, "codex-events.jsonl"), event_record, context)
  end

  @spec finish(t(), :ok | {:error, term()}) :: :ok
  def finish(%{run_dir: nil}, _outcome), do: :ok

  def finish(%{run_dir: run_dir, workspace: workspace, started_at: started_at} = context, outcome) do
    finished_at = DateTime.utc_now()

    metadata = %{
      "issue" => %{
        "id" => context.issue_id,
        "identifier" => context.issue_identifier
      },
      "workspace" => Path.expand(workspace),
      "run_dir" => Path.expand(run_dir),
      "log_file" => LogFile.configured_log_file() |> Path.expand(),
      "started_at" => DateTime.to_iso8601(started_at),
      "finished_at" => DateTime.to_iso8601(finished_at),
      "duration_ms" => DateTime.diff(finished_at, started_at, :millisecond),
      "outcome" => normalize_outcome(outcome)
    }

    write_json(Path.join(run_dir, "metadata.json"), metadata, context)
    write_json(Path.join(run_dir, "workspace-artifacts.json"), workspace_artifacts(workspace), context)
    :ok
  end

  @spec runs_root() :: Path.t()
  def runs_root do
    Path.join(LogFile.log_directory(), "worker-runs")
  end

  defp issue_identifier(issue) do
    Map.get(issue, :identifier) || Map.get(issue, "identifier") || Map.get(issue, :id) || Map.get(issue, "id") || "issue"
  end

  defp run_dir_name(issue_identifier, started_at) do
    started_at
    |> DateTime.to_iso8601()
    |> String.replace(~r/[:\-]/, "")
    |> Kernel.<>("-#{System.unique_integer([:positive])}-#{safe_identifier(issue_identifier)}")
  end

  defp safe_identifier(identifier) do
    String.replace(to_string(identifier), ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp workspace_artifacts(workspace) do
    workspace = Path.expand(workspace)

    workspace
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(fn path ->
      relative_path = Path.relative_to(path, workspace)

      %{
        "path" => relative_path,
        "size_bytes" => File.stat!(path).size
      }
    end)
    |> Enum.reject(fn %{"path" => path} -> excluded_artifact?(path) end)
    |> Enum.sort_by(& &1["path"])
  end

  defp excluded_artifact?(path) do
    path == ".git" or Enum.any?(@excluded_prefixes, &String.starts_with?(path, &1))
  end

  defp normalize_outcome(:ok), do: %{"status" => "ok"}

  defp normalize_outcome({:error, reason}) do
    %{"status" => "error", "reason" => inspect(reason)}
  end

  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_value(%_{} = struct), do: struct |> Map.from_struct() |> normalize_value()

  defp normalize_value(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_value(list) when is_list(list), do: Enum.map(list, &normalize_value/1)
  defp normalize_value(value), do: value

  defp append_jsonl(path, payload, context) do
    encoded_payload = Jason.encode!(payload) <> "\n"

    case File.write(path, encoded_payload, [:append]) do
      :ok -> :ok
      {:error, reason} -> log_write_failure("append worker runtime event", path, reason, context)
    end
  end

  defp write_json(path, payload, context) do
    json = Jason.encode_to_iodata!(payload, pretty: true)

    case File.write(path, [json, ?\n]) do
      :ok -> :ok
      {:error, reason} -> log_write_failure("write worker runtime artifact", path, reason, context)
    end
  end

  defp log_write_failure(action, path, reason, context) do
    Logger.warning("Failed to #{action} issue_id=#{context.issue_id || "n/a"} issue_identifier=#{context.issue_identifier} output_path=#{path} reason=#{inspect(reason)}")

    :ok
  end
end
