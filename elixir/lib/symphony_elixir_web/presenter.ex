defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard, Tracker.Local}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running_count = length(snapshot.running)
        capacity_limit = Config.max_concurrent_agents()

        %{
          generated_at: generated_at,
          counts: %{
            running: running_count,
            retrying: length(snapshot.retrying)
          },
          capacity: %{
            running: running_count,
            limit: capacity_limit,
            available: max(capacity_limit - running_count, 0)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits,
          polling: polling_payload(snapshot)
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        tracked = tracked_issue(issue_identifier)

        if is_nil(running) and is_nil(retry) and is_nil(tracked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, tracked)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, tracked) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, tracked),
      status: issue_status(running, retry, tracked),
      workspace: %{
        path: Path.join(Config.workspace_root(), issue_identifier)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: tracked_issue_payload(tracked)
    }
  end

  defp issue_id_from_entries(running, retry, tracked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (tracked && tracked.id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil, nil), do: "running"
  defp issue_status(nil, _retry, nil), do: "retrying"
  defp issue_status(_running, _retry, nil), do: "running"
  defp issue_status(nil, nil, tracked), do: tracked.state || "tracked"
  defp issue_status(_running, _retry, _tracked), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error
    }
  end

  defp running_issue_payload(running) do
    %{
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error
    }
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp polling_payload(snapshot) do
    polling = Map.get(snapshot, :polling, %{})

    %{
      checking?: Map.get(polling, :checking?, false),
      next_poll_in_ms: Map.get(polling, :next_poll_in_ms),
      poll_interval_ms: Map.get(polling, :poll_interval_ms)
    }
  end

  defp tracked_issue(issue_identifier) do
    if Config.tracker_kind() == "local" do
      case Local.list_issues() do
        {:ok, issues} -> Enum.find(issues, &(&1.identifier == issue_identifier))
        _ -> nil
      end
    end
  end

  defp tracked_issue_payload(nil), do: %{}

  defp tracked_issue_payload(issue) do
    %{
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      description: issue.description,
      state: issue.state,
      priority: issue.priority,
      labels: issue.labels || [],
      branch_name: issue.branch_name,
      url: issue.url,
      blocked_by: issue.blocked_by || [],
      attachments: tracked_issue_attachments(issue),
      assigned_to_worker: Map.get(issue, :assigned_to_worker, true),
      created_at: iso8601(issue.created_at),
      updated_at: iso8601(issue.updated_at),
      claimed_by: issue.claimed_by,
      claimed_at: iso8601(issue.claimed_at),
      lease_expires_at: iso8601(issue.lease_expires_at)
    }
  end

  defp tracked_issue_attachments(issue) do
    issue
    |> Map.get(:attachments, [])
    |> Enum.map(fn attachment ->
      preview_kind = Local.attachment_preview_kind(attachment)

      %{
        id: attachment["id"],
        filename: attachment["filename"],
        content_type: attachment["content_type"],
        byte_size: attachment["byte_size"],
        uploaded_at: attachment["uploaded_at"],
        preview_kind: Atom.to_string(preview_kind),
        preview_url: attachment_preview_url(issue, attachment),
        download_url: attachment_download_url(issue, attachment)
      }
    end)
  end

  defp attachment_download_url(issue, attachment) do
    issue_ref = issue.id || issue.identifier
    attachment_id = attachment["id"]

    if is_binary(issue_ref) and is_binary(attachment_id) do
      "/api/v1/local-issues/#{URI.encode(issue_ref)}/attachments/#{URI.encode(attachment_id)}"
    end
  end

  defp attachment_preview_url(issue, attachment) do
    issue_ref = issue.id || issue.identifier
    attachment_id = attachment["id"]

    if is_binary(issue_ref) and is_binary(attachment_id) do
      "/api/v1/local-issues/#{URI.encode(issue_ref)}/attachments/#{URI.encode(attachment_id)}/preview"
    end
  end

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
