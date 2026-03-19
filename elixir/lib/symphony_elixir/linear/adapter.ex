defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Workpad

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment {
        id
        body
      }
    }
  }
  """

  @workpad_comments_query """
  query SymphonyFindWorkpadComment($issueId: String!) {
    issue(id: $issueId) {
      comments(first: 50) {
        nodes {
          id
          body
          resolvedAt
          updatedAt
          createdAt
        }
      }
    }
  }
  """

  @update_comment_mutation """
  mutation SymphonyUpdateComment($commentId: String!, $body: String!) {
    commentUpdate(id: $commentId, input: {body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec ensure_workpad_comment(String.t(), String.t()) ::
          {:ok, %{id: String.t(), body: String.t(), created?: boolean()}} | {:error, term()}
  def ensure_workpad_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@workpad_comments_query, %{issueId: issue_id}) do
      case active_workpad_comment(response) do
        {:ok, %{id: id, body: existing_body}} ->
          {:ok, %{id: id, body: existing_body, created?: false}}

        :not_found ->
          create_workpad_comment(issue_id, body)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(comment_id, body) when is_binary(comment_id) and is_binary(body) do
    with {:ok, response} <-
           client_module().graphql(@update_comment_mutation, %{commentId: comment_id, body: body}),
         true <- get_in(response, ["data", "commentUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_update_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp create_workpad_comment(issue_id, body) do
    with {:ok, response} <-
           client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true,
         comment_id when is_binary(comment_id) <- get_in(response, ["data", "commentCreate", "comment", "id"]),
         comment_body when is_binary(comment_body) <-
           get_in(response, ["data", "commentCreate", "comment", "body"]) do
      {:ok, %{id: comment_id, body: comment_body, created?: true}}
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  defp active_workpad_comment(response) do
    case get_in(response, ["data", "issue", "comments", "nodes"]) do
      comments when is_list(comments) ->
        comments
        |> Enum.filter(&active_workpad_comment_node?/1)
        |> Enum.sort_by(&comment_sort_key/1, :desc)
        |> List.first()
        |> normalize_workpad_comment()

      _ ->
        {:error, :comment_lookup_failed}
    end
  end

  defp active_workpad_comment_node?(comment) do
    is_nil(Map.get(comment, "resolvedAt")) and Workpad.workpad_comment?(Map.get(comment, "body"))
  end

  defp comment_sort_key(comment) do
    {Map.get(comment, "updatedAt") || "", Map.get(comment, "createdAt") || ""}
  end

  defp normalize_workpad_comment(%{"id" => id, "body" => body})
       when is_binary(id) and is_binary(body) do
    {:ok, %{id: id, body: body}}
  end

  defp normalize_workpad_comment(nil), do: :not_found
  defp normalize_workpad_comment(_comment), do: {:error, :comment_lookup_failed}

  defp resolve_state_id(issue_id, state_name) do
    alias SymphonyElixir.Linear.MetadataCache

    case MetadataCache.get_state_id(state_name) do
      id when is_binary(id) ->
        {:ok, id}

      nil ->
        with {:ok, response} <-
               client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
             state_id when is_binary(state_id) <-
               get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
          MetadataCache.put_state_id(state_name, state_id)
          {:ok, state_id}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :state_not_found}
        end
    end
  end
end
