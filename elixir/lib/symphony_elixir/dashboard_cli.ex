defmodule SymphonyElixir.DashboardCLI do
  @moduledoc """
  CLI helpers for discovering the local observability dashboard URL.
  """

  alias SymphonyElixir.{Config, Workflow}

  @switches [workflow: :string, port: :integer, host: :string, help: :boolean]

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

      argv != [] ->
        {:error, usage()}

      true ->
        print_dashboard_url(opts)
    end
  end

  defp print_dashboard_url(opts) do
    previous_workflow = Application.get_env(:symphony_elixir, :workflow_file_path)

    if workflow_path = opts[:workflow] do
      :ok = Workflow.set_workflow_file_path(Path.expand(workflow_path))
    end

    try do
      with {:ok, _workflow} <- Workflow.current(),
           port when is_integer(port) and port > 0 <- opts[:port] || Config.server_port(),
           host <- opts[:host] || Config.server_host(),
           url when is_binary(url) <- dashboard_url(host, port) do
        IO.puts(url)
        :ok
      else
        {:error, {:missing_workflow_file, path, _reason}} ->
          {:error, "Workflow file not found: #{path}"}

        {:error, reason} ->
          {:error, "Failed to load workflow: #{inspect(reason)}"}

        nil ->
          {:error, "Dashboard is not configured. Set server.port in WORKFLOW.md or pass --port."}

        port when not is_integer(port) or port <= 0 ->
          {:error, "Dashboard port must be a positive integer. Got: #{inspect(port)}"}
      end
    after
      restore_workflow_path(previous_workflow)
    end
  end

  defp restore_workflow_path(nil), do: Workflow.clear_workflow_file_path()
  defp restore_workflow_path(path), do: Workflow.set_workflow_file_path(path)

  defp dashboard_url(host, port) when is_integer(port) and port > 0 do
    "http://#{dashboard_host(host)}:#{port}/"
  end

  defp dashboard_host(host) when host in ["", nil, "0.0.0.0", "::", "[::]"], do: "127.0.0.1"

  defp dashboard_host(host) when is_binary(host) do
    trimmed_host = String.trim(host)

    cond do
      trimmed_host in ["", "0.0.0.0", "::", "[::]"] ->
        "127.0.0.1"

      String.starts_with?(trimmed_host, "[") and String.ends_with?(trimmed_host, "]") ->
        trimmed_host

      String.contains?(trimmed_host, ":") ->
        "[#{trimmed_host}]"

      true ->
        trimmed_host
    end
  end

  defp usage do
    """
    Usage:
      symphony panel [--workflow PATH] [--host HOST] [--port PORT]
    """
  end
end
