defmodule SymphonyElixir.LocalIssueCLI do
  @moduledoc """
  CLI helpers for inspecting and updating the local tracker store.
  """

  alias SymphonyElixir.{Config, Tracker.Local, Workflow}

  @switches [
    workflow: :string,
    help: :boolean,
    title: :string,
    description: :string,
    priority: :integer,
    labels: :string,
    state: :string,
    identifier: :string,
    id: :string
  ]

  @spec evaluate([String.t()]) :: :ok | {:error, String.t()}
  def evaluate(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: @switches,
        aliases: [h: :help, w: :workflow]
      )

    cond do
      opts[:help] ->
        IO.puts(usage())
        :ok

      invalid != [] ->
        {:error, "Invalid option(s): #{inspect(invalid)}"}

      true ->
        dispatch(argv, opts)
    end
  end

  defp dispatch([], _opts), do: {:error, usage()}
  defp dispatch(["help"], _opts), do: print_usage()

  defp dispatch(["list"], opts) do
    with_local_tracker(opts, fn path ->
      case Local.list_issues() do
        {:ok, issues} ->
          print_issue_list(path, issues)
          :ok

        {:error, reason} ->
          {:error, format_tracker_error("Failed to list local issues", reason)}
      end
    end)
  end

  defp dispatch(["create"], opts) do
    attrs =
      %{
        title: opts[:title],
        description: opts[:description],
        priority: opts[:priority],
        labels: parse_labels(opts[:labels]),
        state: opts[:state],
        identifier: opts[:identifier],
        id: opts[:id]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    with_local_tracker(opts, fn path ->
      case Local.create_issue(attrs) do
        {:ok, issue} ->
          IO.puts("Created #{issue.identifier} (#{issue.id}) in #{path}")
          IO.puts("[#{issue.state}] #{issue.title}")
          :ok

        {:error, :missing_issue_title} ->
          {:error, "Missing required option: --title"}

        {:error, reason} ->
          {:error, format_tracker_error("Failed to create local issue", reason)}
      end
    end)
  end

  defp dispatch(["state", issue_ref, state], opts) do
    with_local_tracker(opts, fn _path ->
      case Local.update_issue_state(issue_ref, state) do
        :ok ->
          IO.puts("Updated #{issue_ref} -> #{state}")
          :ok

        {:error, reason} ->
          {:error, format_tracker_error("Failed to update local issue state", reason)}
      end
    end)
  end

  defp dispatch(["comment", issue_ref | body_parts], opts) when body_parts != [] do
    body_parts
    |> Enum.join(" ")
    |> String.trim()
    |> dispatch_comment(issue_ref, opts)
  end

  defp dispatch(["release", issue_ref], opts) do
    with_local_tracker(opts, fn _path ->
      case Local.release_issue_claim(issue_ref) do
        :ok ->
          IO.puts("Released lease on #{issue_ref}")
          :ok

        {:error, reason} ->
          {:error, format_tracker_error("Failed to release local issue claim", reason)}
      end
    end)
  end

  defp dispatch(_argv, _opts), do: {:error, usage()}

  defp dispatch_comment("", _issue_ref, _opts), do: {:error, "Comment body cannot be empty"}

  defp dispatch_comment(body, issue_ref, opts) do
    with_local_tracker(opts, fn _path ->
      case Local.create_comment(issue_ref, body) do
        :ok ->
          IO.puts("Appended comment to #{issue_ref}")
          :ok

        {:error, reason} ->
          {:error, format_tracker_error("Failed to append local issue comment", reason)}
      end
    end)
  end

  defp with_local_tracker(opts, fun) when is_function(fun, 1) do
    previous_workflow = Application.get_env(:symphony_elixir, :workflow_file_path)

    if workflow_path = opts[:workflow] do
      :ok = Workflow.set_workflow_file_path(Path.expand(workflow_path))
    end

    try do
      with {:ok, _workflow} <- Workflow.current(),
           "local" <- Config.tracker_kind() || :missing_tracker_kind,
           path when is_binary(path) and path != "" <- Config.local_tracker_path() do
        fun.(path)
      else
        {:error, {:missing_workflow_file, path, _reason}} ->
          {:error, "Workflow file not found: #{path}"}

        {:error, reason} ->
          {:error, "Failed to load workflow: #{inspect(reason)}"}

        :missing_tracker_kind ->
          {:error, "Workflow tracker.kind must be set to \"local\" to use `symphony issue`."}

        nil ->
          {:error, "Workflow tracker.path must be set when tracker.kind is \"local\"."}

        kind ->
          {:error, "Workflow tracker.kind is #{inspect(kind)}; expected \"local\" for `symphony issue`."}
      end
    after
      restore_workflow_path(previous_workflow)
    end
  end

  defp restore_workflow_path(nil), do: Workflow.clear_workflow_file_path()
  defp restore_workflow_path(path), do: Workflow.set_workflow_file_path(path)

  defp parse_labels(nil), do: nil

  defp parse_labels(labels) when is_binary(labels) do
    labels
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      values -> values
    end
  end

  defp print_issue_list(path, []) do
    IO.puts("Local tracker store: #{path}")
    IO.puts("No issues found.")
  end

  defp print_issue_list(path, issues) do
    IO.puts("Local tracker store: #{path}")

    Enum.each(issues, fn issue ->
      IO.puts("#{issue.identifier} [#{issue.state}] #{issue.title}")
      IO.puts("  id=#{issue.id} priority=#{format_priority(issue.priority)} updated=#{format_datetime(issue.updated_at)}")

      if issue.labels != [] do
        IO.puts("  labels=#{Enum.join(issue.labels, ", ")}")
      end

      if issue.claimed_by do
        IO.puts("  claim=#{issue.claimed_by} expires=#{format_datetime(issue.lease_expires_at)}")
      end

      if issue.description do
        IO.puts("  #{String.trim(issue.description)}")
      end
    end)
  end

  defp format_priority(nil), do: "n/a"
  defp format_priority(priority), do: Integer.to_string(priority)

  defp format_datetime(nil), do: "n/a"

  defp format_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp format_tracker_error(prefix, :issue_not_found), do: "#{prefix}: issue not found"
  defp format_tracker_error(prefix, reason), do: "#{prefix}: #{inspect(reason)}"

  defp print_usage do
    IO.puts(usage())
    :ok
  end

  defp usage do
    """
    Usage:
      symphony issue list [--workflow PATH]
      symphony issue create --title TITLE [--description TEXT] [--priority N] [--labels a,b] [--state STATE] [--identifier ID] [--workflow PATH]
      symphony issue state ISSUE_REF STATE [--workflow PATH]
      symphony issue comment ISSUE_REF BODY... [--workflow PATH]
      symphony issue release ISSUE_REF [--workflow PATH]
    """
  end
end
