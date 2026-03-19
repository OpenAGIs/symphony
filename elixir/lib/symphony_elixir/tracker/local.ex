defmodule SymphonyElixir.Tracker.Local do
  @moduledoc """
  File-backed tracker adapter for local multi-issue orchestration without Linear.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Config, Linear.Issue}

  @attachments_key "attachments"
  @comments_key "comments"
  @issues_key "issues"
  @default_identifier_prefix "LOCAL"
  @default_id_prefix "local"
  @default_attachment_id_prefix "attachment"

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, issues} <- fetch_issues_by_states(Config.linear_active_states()) do
      {:ok, Enum.reject(issues, &issue_claim_active?/1)}
    end
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

  @spec store_attachment(String.t(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def store_attachment(source_path, filename, content_type \\ nil)
      when is_binary(source_path) and is_binary(filename) do
    with {:ok, tracker_path} <- tracker_path(),
         {:ok, attachment_root} <- attachment_root(tracker_path),
         attachment_id <- generate_attachment_id(),
         sanitized_filename <- sanitize_filename(filename),
         target_path <- attachment_target_path(attachment_root, attachment_id, sanitized_filename),
         :ok <- File.mkdir_p(Path.dirname(target_path)),
         :ok <- copy_attachment_file(source_path, target_path),
         {:ok, %File.Stat{size: byte_size}} <- File.stat(target_path) do
      {:ok,
       %{
         "id" => attachment_id,
         "filename" => sanitized_filename,
         "content_type" => normalize_content_type(content_type),
         "byte_size" => byte_size,
         "path" => Path.relative_to(target_path, attachment_root),
         "uploaded_at" => now_iso8601()
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec discard_attachment(map()) :: :ok
  def discard_attachment(attachment) when is_map(attachment) do
    with {:ok, tracker_path} <- tracker_path(),
         {:ok, attachment_path} <- resolve_attachment_path(tracker_path, attachment) do
      File.rm(attachment_path)
      prune_empty_attachment_dirs(Path.dirname(attachment_path), attachment_root_path(tracker_path))
    end

    :ok
  end

  @spec fetch_attachment_file(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_attachment_file(issue_ref, attachment_id)
      when is_binary(issue_ref) and is_binary(attachment_id) do
    with {:ok, tracker_path} <- tracker_path(),
         {:ok, issue_maps} <- load_issue_maps(),
         {:ok, issue_map} <- find_issue_map(issue_maps, issue_ref),
         {:ok, attachment} <- find_attachment(issue_map, attachment_id),
         {:ok, attachment_path} <- resolve_attachment_path(tracker_path, attachment),
         :ok <- attachment_file_exists(attachment_path) do
      {:ok,
       %{
         attachment: attachment,
         path: attachment_path,
         filename: attachment["filename"],
         content_type: normalize_content_type(attachment["content_type"])
       }}
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

  @spec claim_issue(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def claim_issue(issue_id, owner, opts \\ [])
      when is_binary(issue_id) and is_binary(owner) do
    ttl_ms = claim_ttl_ms(opts)

    with {:ok, path} <- tracker_path() do
      claim_issue_in_tracker(path, issue_id, owner, ttl_ms)
    end
  end

  @spec release_issue_claim(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def release_issue_claim(issue_id, owner \\ nil) when is_binary(issue_id) do
    with {:ok, path} <- tracker_path() do
      release_issue_claim_in_tracker(path, issue_id, owner)
    end
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

  defp claim_issue_in_tracker(path, issue_id, owner, ttl_ms) do
    :global.trans({__MODULE__, path}, fn ->
      with {:ok, issue_maps} <- load_issue_maps(),
           {:ok, updated_issue_maps} <- apply_issue_claim(issue_maps, issue_id, owner, ttl_ms) do
        persist_issue_maps(path, updated_issue_maps)
      end
    end)
  end

  defp release_issue_claim_in_tracker(path, issue_id, owner) do
    :global.trans({__MODULE__, path}, fn ->
      with {:ok, issue_maps} <- load_issue_maps(),
           {:ok, updated_issue_maps} <- apply_issue_release(issue_maps, issue_id, owner) do
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

  defp apply_issue_claim(issue_maps, issue_id, owner, ttl_ms) do
    now = DateTime.utc_now()

    map_issue_update(issue_maps, issue_id, fn issue ->
      if issue_claim_available?(issue, owner, now) do
        {:ok, put_issue_claim(issue, owner, now, ttl_ms)}
      else
        {:error, active_claim_reason(issue)}
      end
    end)
  end

  defp apply_issue_release(issue_maps, issue_id, owner) do
    now = DateTime.utc_now()

    map_issue_update(issue_maps, issue_id, fn issue ->
      if release_allowed?(issue, owner, now) do
        {:ok, clear_issue_claim(issue)}
      else
        {:error, active_claim_reason(issue)}
      end
    end)
  end

  defp map_issue_update(issue_maps, issue_id, updater) when is_function(updater, 1) do
    {updated_issue_maps, result} =
      Enum.map_reduce(issue_maps, :issue_not_found, fn
        issue, :issue_not_found when is_map(issue) ->
          update_mapped_issue(issue, issue_id, updater)

        issue, status ->
          {issue, status}
      end)

    case result do
      :ok -> {:ok, updated_issue_maps}
      :issue_not_found -> {:error, :issue_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_mapped_issue(issue, issue_id, updater) when is_map(issue) and is_function(updater, 1) do
    if issue_matches_ref?(issue, issue_id) do
      issue
      |> updater.()
      |> mapped_issue_result(issue)
    else
      {issue, :issue_not_found}
    end
  end

  defp mapped_issue_result({:ok, updated_issue}, _original_issue), do: {updated_issue, :ok}
  defp mapped_issue_result({:error, reason}, original_issue), do: {original_issue, {:error, reason}}

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
         {:ok, attachments} <- attachments_attr(attrs),
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
         "attachments" => attachments,
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
      claimed_by: map_string(issue, "claimed_by"),
      blocked_by: normalize_blocked_by(Map.get(issue, "blocked_by")),
      attachments: normalize_attachments(Map.get(issue, @attachments_key)),
      labels: normalize_string_list(Map.get(issue, "labels")),
      assigned_to_worker: Map.get(issue, "assigned_to_worker", true) != false,
      created_at: parse_datetime(Map.get(issue, "created_at")),
      updated_at: parse_datetime(Map.get(issue, "updated_at")),
      claimed_at: parse_datetime(Map.get(issue, "claimed_at")),
      lease_expires_at: parse_datetime(Map.get(issue, "lease_expires_at"))
    }
  end

  defp normalize_issue(_issue), do: nil

  defp normalize_blocked_by(value) when is_list(value), do: value
  defp normalize_blocked_by(_value), do: []

  defp issue_claim_active?(%Issue{} = issue) do
    lease_active?(issue.claimed_by, issue.lease_expires_at, DateTime.utc_now())
  end

  defp issue_claim_available?(issue, owner, now) when is_map(issue) and is_binary(owner) do
    not lease_active?(map_string(issue, "claimed_by"), parse_datetime(Map.get(issue, "lease_expires_at")), now) or
      map_string(issue, "claimed_by") == owner
  end

  defp put_issue_claim(issue, owner, now, ttl_ms) when is_map(issue) do
    issue
    |> Map.put("claimed_by", owner)
    |> Map.put("claimed_at", timestamp_iso8601(now))
    |> Map.put("lease_expires_at", timestamp_iso8601(claim_expires_at(now, ttl_ms)))
    |> touch_updated_at()
  end

  defp clear_issue_claim(issue) when is_map(issue) do
    issue
    |> Map.put("claimed_by", nil)
    |> Map.put("claimed_at", nil)
    |> Map.put("lease_expires_at", nil)
    |> touch_updated_at()
  end

  defp release_allowed?(issue, nil, _now) when is_map(issue), do: true

  defp release_allowed?(issue, owner, now) when is_map(issue) and is_binary(owner) do
    claim_owner = map_string(issue, "claimed_by")
    claim_owner == owner or not lease_active?(claim_owner, parse_datetime(Map.get(issue, "lease_expires_at")), now)
  end

  defp active_claim_reason(issue) when is_map(issue) do
    {:issue_claimed, map_string(issue, "claimed_by"), map_string(issue, "lease_expires_at")}
  end

  defp lease_active?(claimed_by, %DateTime{} = lease_expires_at, %DateTime{} = now)
       when is_binary(claimed_by) do
    DateTime.compare(lease_expires_at, now) == :gt
  end

  defp lease_active?(_claimed_by, _lease_expires_at, _now), do: false

  defp claim_expires_at(now, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    DateTime.add(now, ttl_ms, :millisecond)
  end

  defp timestamp_iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

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

  defp normalize_attachments(value) when is_list(value) do
    value
    |> Enum.map(&normalize_attachment/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_attachments(_value), do: []

  defp normalize_attachment(attachment) when is_map(attachment) do
    %{
      "id" => map_string(attachment, "id"),
      "filename" => map_string(attachment, "filename"),
      "content_type" => normalize_content_type(Map.get(attachment, "content_type")),
      "byte_size" => parse_non_negative_integer(Map.get(attachment, "byte_size")),
      "path" => map_string(attachment, "path"),
      "uploaded_at" => map_string(attachment, "uploaded_at")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> case do
      %{"id" => _id, "filename" => _filename, "path" => _path} = normalized -> normalized
      _ -> nil
    end
  end

  defp normalize_attachment(_attachment), do: nil

  defp parse_priority(value) when is_integer(value), do: value

  defp parse_priority(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp parse_priority(_value), do: nil

  defp parse_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp parse_non_negative_integer(_value), do: nil

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

  defp attachments_attr(attrs) do
    attachments =
      case Map.get(attrs, @attachments_key) do
        value when is_list(value) -> normalize_attachments(value)
        nil -> []
        _value -> :invalid
      end

    case attachments do
      :invalid -> {:error, :invalid_issue_attachments}
      normalized -> {:ok, normalized}
    end
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
    |> timestamp_iso8601()
  end

  defp claim_ttl_ms(opts) when is_list(opts) do
    case Keyword.get(opts, :ttl_ms) do
      ttl_ms when is_integer(ttl_ms) and ttl_ms > 0 -> ttl_ms
      _ -> 180_000
    end
  end

  defp attachment_root(tracker_path) when is_binary(tracker_path) do
    attachment_root = attachment_root_path(tracker_path)

    case File.mkdir_p(attachment_root) do
      :ok -> {:ok, attachment_root}
      {:error, reason} -> {:error, {:local_tracker_attachment_write_failed, reason}}
    end
  end

  defp attachment_root_path(tracker_path) when is_binary(tracker_path) do
    tracker_path
    |> Path.basename(Path.extname(tracker_path))
    |> then(&Path.join(Path.dirname(tracker_path), "#{&1}_attachments"))
  end

  defp attachment_target_path(attachment_root, attachment_id, filename)
       when is_binary(attachment_root) and is_binary(attachment_id) and is_binary(filename) do
    Path.join([attachment_root, attachment_id, filename])
  end

  defp copy_attachment_file(source_path, target_path) do
    case File.cp(source_path, target_path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:local_tracker_attachment_write_failed, reason}}
    end
  end

  defp resolve_attachment_path(tracker_path, attachment) when is_binary(tracker_path) and is_map(attachment) do
    attachment_root = attachment_root_path(tracker_path)

    case map_string(attachment, "path") do
      path when is_binary(path) ->
        expanded = Path.expand(path, attachment_root)

        if String.starts_with?(expanded, attachment_root <> "/") or expanded == attachment_root do
          {:ok, expanded}
        else
          {:error, :invalid_attachment_path}
        end

      _ ->
        {:error, :attachment_not_found}
    end
  end

  defp attachment_file_exists(path) when is_binary(path) do
    if File.exists?(path), do: :ok, else: {:error, :attachment_file_missing}
  end

  defp prune_empty_attachment_dirs(path, stop_path) when is_binary(path) and is_binary(stop_path) do
    cond do
      path == stop_path ->
        :ok

      not String.starts_with?(path, stop_path <> "/") ->
        :ok

      true ->
        case File.ls(path) do
          {:ok, []} ->
            File.rmdir(path)
            prune_empty_attachment_dirs(Path.dirname(path), stop_path)

          _ ->
            :ok
        end
    end
  end

  defp find_issue_map(issue_maps, issue_ref) when is_list(issue_maps) and is_binary(issue_ref) do
    case Enum.find(issue_maps, &issue_matches_ref?(&1, issue_ref)) do
      %{} = issue_map -> {:ok, issue_map}
      nil -> {:error, :issue_not_found}
    end
  end

  defp find_attachment(issue_map, attachment_id) when is_map(issue_map) and is_binary(attachment_id) do
    issue_map
    |> Map.get(@attachments_key, [])
    |> normalize_attachments()
    |> Enum.find(&(Map.get(&1, "id") == attachment_id))
    |> case do
      nil -> {:error, :attachment_not_found}
      attachment -> {:ok, attachment}
    end
  end

  defp generate_attachment_id do
    "#{@default_attachment_id_prefix}-#{System.unique_integer([:positive])}"
  end

  defp sanitize_filename(filename) when is_binary(filename) do
    filename
    |> Path.basename()
    |> String.trim()
    |> case do
      "" -> "attachment"
      basename -> basename
    end
  end

  defp normalize_content_type(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      content_type -> content_type
    end
  end

  defp normalize_content_type(_value), do: nil

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
