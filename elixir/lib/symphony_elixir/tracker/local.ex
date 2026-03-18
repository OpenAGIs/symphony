defmodule SymphonyElixir.Tracker.Local do
  @moduledoc """
  File-backed tracker adapter for local multi-issue orchestration without Linear.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Config, Linear.Issue}

  @comments_key "comments"
  @issues_key "issues"
  @default_identifier_prefix "LOCAL"
  @default_id_prefix "local"

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    fetch_issues_by_states(Config.linear_active_states())
  end

  @spec list_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def list_issues do
    issue_entries()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    with {:ok, issues} <- issue_entries() do
      {:ok,
       Enum.filter(issues, fn %Issue{state: state} ->
         MapSet.member?(normalized_states, normalize_state(state))
       end)}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    with {:ok, issues} <- issue_entries() do
      {:ok,
       Enum.filter(issues, fn %Issue{id: id} ->
         MapSet.member?(wanted_ids, id)
       end)}
    end
  end

  @spec create_issue(map() | keyword()) :: {:ok, Issue.t()} | {:error, term()}
  def create_issue(attrs) when is_list(attrs) do
    attrs
    |> Enum.into(%{})
    |> create_issue()
  end

  def create_issue(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with :ok <- validate_create_issue_attrs(attrs),
         {:ok, path} <- tracker_path() do
      create_issue_in_tracker(path, attrs)
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    update_issue(issue_id, fn issue ->
      comments =
        issue
        |> Map.get(@comments_key, [])
        |> List.wrap()
        |> Kernel.++([
          %{
            "body" => body,
            "created_at" => now_iso8601()
          }
        ])

      issue
      |> Map.put(@comments_key, comments)
      |> touch_updated_at()
    end)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    update_issue(issue_id, fn issue ->
      issue
      |> Map.put("state", state_name)
      |> touch_updated_at()
    end)
  end

  defp issue_entries do
    with {:ok, issue_maps} <- load_issue_maps() do
      {:ok,
       issue_maps
       |> Enum.map(&normalize_issue/1)
       |> Enum.reject(&is_nil/1)}
    end
  end

  defp update_issue(issue_id, updater) when is_function(updater, 1) do
    with {:ok, path} <- tracker_path() do
      update_issue_in_tracker(path, issue_id, updater)
    end
  end

  defp create_issue_in_tracker(path, attrs) do
    :global.trans({__MODULE__, path}, fn ->
      with {:ok, issue_maps} <- load_issue_maps(),
           {:ok, issue_map} <- build_issue_map(issue_maps, attrs),
           :ok <- persist_issue_maps(path, issue_maps ++ [issue_map]) do
        {:ok, normalize_issue(issue_map)}
      end
    end)
  end

  defp update_issue_in_tracker(path, issue_id, updater) do
    :global.trans({__MODULE__, path}, fn ->
      with {:ok, issue_maps} <- load_issue_maps(),
           {:ok, updated_issue_maps} <- apply_issue_update(issue_maps, issue_id, updater) do
        persist_issue_maps(path, updated_issue_maps)
      end
    end)
  end

  defp apply_issue_update(issue_maps, issue_id, updater) do
    {updated_issue_maps, found?} =
      Enum.map_reduce(issue_maps, false, fn
        issue, found? when is_map(issue) ->
          if issue_matches_ref?(issue, issue_id) do
            {updater.(issue), true}
          else
            {issue, found?}
          end

        issue, found? ->
          {issue, found?}
      end)

    if found? do
      {:ok, updated_issue_maps}
    else
      {:error, :issue_not_found}
    end
  end

  defp load_issue_maps do
    with {:ok, path} <- tracker_path() do
      case File.read(path) do
        {:ok, contents} ->
          decode_issue_maps(contents)

        {:error, :enoent} ->
          {:ok, []}

        {:error, reason} ->
          {:error, {:local_tracker_read_failed, reason}}
      end
    end
  end

  defp decode_issue_maps(contents) when is_binary(contents) do
    if String.trim(contents) == "" do
      {:ok, []}
    else
      case Jason.decode(contents) do
        {:ok, %{@issues_key => issue_maps}} when is_list(issue_maps) ->
          {:ok, issue_maps}

        {:ok, issue_maps} when is_list(issue_maps) ->
          {:ok, issue_maps}

        {:ok, _decoded} ->
          {:error, :invalid_local_tracker_payload}

        {:error, reason} ->
          {:error, {:local_tracker_decode_failed, reason}}
      end
    end
  end

  defp persist_issue_maps(path, issue_maps) do
    payload = Jason.encode_to_iodata!(%{@issues_key => issue_maps}, pretty: true)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      case File.write(path, [payload, ?\n]) do
        :ok -> :ok
        {:error, reason} -> {:error, {:local_tracker_write_failed, reason}}
      end
    end
  end

  defp build_issue_map(issue_maps, attrs) do
    existing_ids = existing_values(issue_maps, "id")
    existing_identifiers = existing_values(issue_maps, "identifier")
    title = optional_trimmed_value(attrs, "title")

    with {:ok, description} <- optional_string_attr(attrs, "description"),
         {:ok, priority} <- priority_attr(attrs),
         {:ok, state} <- state_attr(attrs),
         {:ok, labels} <- labels_attr(attrs),
         {:ok, assigned_to_worker} <- assigned_to_worker_attr(attrs),
         {:ok, identifier} <-
           unique_string_attr_or_generate(
             attrs,
             "identifier",
             existing_identifiers,
             generate_prefixed_identifier(existing_identifiers, @default_identifier_prefix)
           ),
         {:ok, id} <-
           unique_string_attr_or_generate(
             attrs,
             "id",
             existing_ids,
             generate_prefixed_identifier(existing_ids, @default_id_prefix)
           ) do
      now = now_iso8601()

      {:ok,
       %{
         "id" => id,
         "identifier" => identifier,
         "title" => title,
         "description" => description,
         "priority" => priority,
         "state" => state,
         "labels" => labels,
         "assigned_to_worker" => assigned_to_worker,
         "created_at" => now,
         "updated_at" => now
       }
       |> maybe_put("branch_name", optional_trimmed_value(attrs, "branch_name"))
       |> maybe_put("url", optional_trimmed_value(attrs, "url"))
       |> maybe_put("assignee_id", optional_trimmed_value(attrs, "assignee_id"))
       |> maybe_put("blocked_by", blocked_by_attr(attrs))}
    end
  end

  defp normalize_issue(issue) when is_map(issue) do
    %Issue{
      id: map_string(issue, "id"),
      identifier: map_string(issue, "identifier"),
      title: map_string(issue, "title"),
      description: map_string(issue, "description"),
      priority: parse_priority(Map.get(issue, "priority")),
      state: map_string(issue, "state"),
      branch_name: map_string(issue, "branch_name"),
      url: map_string(issue, "url"),
      assignee_id: map_string(issue, "assignee_id"),
      blocked_by: normalize_blocked_by(Map.get(issue, "blocked_by")),
      labels: normalize_string_list(Map.get(issue, "labels")),
      assigned_to_worker: Map.get(issue, "assigned_to_worker", true) != false,
      created_at: parse_datetime(Map.get(issue, "created_at")),
      updated_at: parse_datetime(Map.get(issue, "updated_at"))
    }
  end

  defp normalize_issue(_issue), do: nil

  defp normalize_blocked_by(value) when is_list(value), do: value
  defp normalize_blocked_by(_value), do: []

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&list_value_to_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
  end

  defp normalize_string_list(_values), do: []

  defp list_value_to_string(value) when is_binary(value), do: value
  defp list_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp list_value_to_string(_value), do: nil

  defp parse_priority(value) when is_integer(value), do: value

  defp parse_priority(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp parse_priority(_value), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> parsed
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp map_string(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      nil -> nil
      value -> to_string(value)
    end
  end

  defp touch_updated_at(issue) when is_map(issue) do
    Map.put(issue, "updated_at", now_iso8601())
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  defp validate_create_issue_attrs(attrs) do
    case optional_trimmed_value(attrs, "title") do
      nil -> {:error, :missing_issue_title}
      _title -> :ok
    end
  end

  defp optional_string_attr(attrs, key) do
    {:ok, optional_trimmed_value(attrs, key)}
  end

  defp optional_trimmed_value(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> nil
          trimmed -> trimmed
        end

      nil ->
        nil

      value ->
        value
        |> to_string()
        |> String.trim()
        |> case do
          "" -> nil
          trimmed -> trimmed
        end
    end
  end

  defp priority_attr(attrs) do
    case Map.fetch(attrs, "priority") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} ->
        case parse_priority(value) do
          nil -> {:error, :invalid_issue_priority}
          priority -> {:ok, priority}
        end
    end
  end

  defp state_attr(attrs) do
    {:ok, optional_trimmed_value(attrs, "state") || default_issue_state()}
  end

  defp labels_attr(attrs) do
    labels =
      case Map.get(attrs, "labels") do
        value when is_binary(value) ->
          value
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)

        value when is_list(value) ->
          value

        nil ->
          []

        value ->
          [to_string(value)]
      end
      |> normalize_string_list()

    {:ok, labels}
  end

  defp blocked_by_attr(attrs) do
    case Map.get(attrs, "blocked_by") do
      value when is_list(value) ->
        value
        |> Enum.map(&to_string/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> case do
          [] -> nil
          blockers -> blockers
        end

      _ ->
        nil
    end
  end

  defp assigned_to_worker_attr(attrs) do
    case Map.get(attrs, "assigned_to_worker") do
      nil -> {:ok, true}
      value when value in [true, false] -> {:ok, value}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _value -> {:error, :invalid_assigned_to_worker}
    end
  end

  defp unique_string_attr_or_generate(attrs, key, existing_values, generated) do
    case optional_trimmed_value(attrs, key) do
      nil ->
        {:ok, generated}

      value ->
        if MapSet.member?(existing_values, value) do
          {:error, {:duplicate_issue_field, key, value}}
        else
          {:ok, value}
        end
    end
  end

  defp existing_values(issue_maps, key) do
    issue_maps
    |> Enum.reduce(MapSet.new(), fn
      %{} = issue, values ->
        case Map.get(issue, key) do
          value when is_binary(value) -> MapSet.put(values, value)
          _ -> values
        end

      _issue, values ->
        values
    end)
  end

  defp generate_prefixed_identifier(existing_values, prefix) do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn sequence ->
      candidate = "#{prefix}-#{sequence}"
      if MapSet.member?(existing_values, candidate), do: nil, else: candidate
    end)
  end

  defp default_issue_state do
    Enum.at(Config.linear_active_states(), 0, "Todo")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp issue_matches_ref?(issue, ref) when is_map(issue) and is_binary(ref) do
    id = map_string(issue, "id")
    identifier = map_string(issue, "identifier")
    ref == id or ref == identifier
  end

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp tracker_path do
    case Config.local_tracker_path() do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :missing_local_tracker_path}
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
