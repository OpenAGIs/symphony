defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias NimbleOptions
  alias SymphonyElixir.Workflow

  @default_active_states ["Todo", "In Progress"]
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  @default_tracker_todo_state "Todo"
  @default_tracker_in_progress_state "In Progress"
  @default_tracker_human_review_state "Human Review"
  @default_tracker_merging_state "Merging"
  @default_tracker_done_state "Done"
  @default_linear_endpoint "https://api.linear.app/graphql"
  @default_prompt_template """
  You are working on a {{ tracker.display_name }} issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """
  @default_poll_interval_ms 30_000
  @default_workspace_root Path.join(System.tmp_dir!(), "symphony_workspaces")
  @default_hook_timeout_ms 60_000
  @default_max_concurrent_agents 10
  @default_agent_max_turns 20
  @default_max_retry_backoff_ms 300_000
  @default_agent_max_retry_attempts 10
  @default_codex_command "codex app-server"
  @default_codex_turn_timeout_ms 3_600_000
  @default_codex_read_timeout_ms 5_000
  @default_codex_stall_timeout_ms 300_000
  @default_codex_dynamic_tool_timeout_ms 30_000
  @default_codex_dynamic_tool_max_retries 2
  @default_codex_dynamic_tool_allow_mutations true
  @default_codex_approval_policy %{
    "reject" => %{
      "sandbox_approval" => true,
      "rules" => true,
      "mcp_elicitations" => true
    }
  }
  @codex_execution_environments ~w(docker vm browser local_os)
  @default_codex_thread_sandbox "workspace-write"
  @default_observability_enabled true
  @default_observability_refresh_ms 1_000
  @default_observability_render_interval_ms 16
  @default_server_host "127.0.0.1"
  @default_workflow_strategy %{}
  @default_workflow_acceptance []
  @default_workflow_approvals %{}
  @default_workflow_retry %{}
  @default_workflow_writeback %{}
  @tracker_adapter_callbacks [
    {:fetch_candidate_issues, 0},
    {:fetch_issues_by_states, 1},
    {:fetch_issue_states_by_ids, 1},
    {:create_comment, 2},
    {:ensure_workpad_comment, 2},
    {:update_comment, 2},
    {:update_issue_state, 2}
  ]
  @module_name_pattern ~r/^(?:Elixir\.)?(?:[A-Z][A-Za-z0-9_]*)(?:\.[A-Z][A-Za-z0-9_]*)*$/
  @workflow_options_schema NimbleOptions.new!(
                             tracker: [
                               type: :map,
                               default: %{},
                               keys: [
                                 kind: [type: {:or, [:string, nil]}, default: nil],
                                 adapter_module: [type: {:or, [:string, nil]}, default: nil],
                                 endpoint: [type: :string, default: @default_linear_endpoint],
                                 api_key: [type: {:or, [:string, nil]}, default: nil],
                                 project_slug: [type: {:or, [:string, nil]}, default: nil],
                                 path: [type: {:or, [:string, nil]}, default: nil],
                                 assignee: [type: {:or, [:string, nil]}, default: nil],
                                 active_states: [
                                   type: {:list, :string},
                                   default: @default_active_states
                                 ],
                                 todo_state: [type: :string, default: @default_tracker_todo_state],
                                 in_progress_state: [
                                   type: :string,
                                   default: @default_tracker_in_progress_state
                                 ],
                                 human_review_state: [
                                   type: :string,
                                   default: @default_tracker_human_review_state
                                 ],
                                 merging_state: [
                                   type: :string,
                                   default: @default_tracker_merging_state
                                 ],
                                 done_state: [type: :string, default: @default_tracker_done_state],
                                 terminal_states: [
                                   type: {:list, :string},
                                   default: @default_terminal_states
                                 ]
                               ]
                             ],
                             polling: [
                               type: :map,
                               default: %{},
                               keys: [
                                 interval_ms: [type: :integer, default: @default_poll_interval_ms]
                               ]
                             ],
                             workspace: [
                               type: :map,
                               default: %{},
                               keys: [
                                 root: [
                                   type: {:or, [:string, nil]},
                                   default: @default_workspace_root
                                 ]
                               ]
                             ],
                             agent: [
                               type: :map,
                               default: %{},
                               keys: [
                                 max_concurrent_agents: [
                                   type: :integer,
                                   default: @default_max_concurrent_agents
                                 ],
                                 max_turns: [
                                   type: :pos_integer,
                                   default: @default_agent_max_turns
                                 ],
                                 max_retry_backoff_ms: [
                                   type: :pos_integer,
                                   default: @default_max_retry_backoff_ms
                                 ],
                                 capabilities: [type: {:list, :string}, default: []],
                                 max_risk_level: [type: {:or, [:string, nil]}, default: nil],
                                 max_issue_budget: [
                                   type: {:or, [:pos_integer, nil]},
                                   default: nil
                                 ],
                                 max_retry_attempts: [
                                   type: :pos_integer,
                                   default: @default_agent_max_retry_attempts
                                 ],
                                 max_concurrent_agents_by_state: [
                                   type: {:map, :string, :pos_integer},
                                   default: %{}
                                 ],
                                 max_concurrent_agents_by_capability: [
                                   type: {:map, :string, :pos_integer},
                                   default: %{}
                                 ],
                                 max_concurrent_agents_by_risk: [
                                   type: {:map, :string, :pos_integer},
                                   default: %{}
                                 ],
                                 max_concurrent_agents_by_budget: [
                                   type: {:map, :string, :pos_integer},
                                   default: %{}
                                 ]
                               ]
                             ],
                             codex: [
                               type: :map,
                               default: %{},
                               keys: [
                                 command: [type: :string, default: @default_codex_command],
                                 execution_environment: [type: {:or, [:string, nil]}, default: nil],
                                 turn_timeout_ms: [
                                   type: :integer,
                                   default: @default_codex_turn_timeout_ms
                                 ],
                                 read_timeout_ms: [
                                   type: :integer,
                                   default: @default_codex_read_timeout_ms
                                 ],
                                 stall_timeout_ms: [
                                   type: :integer,
                                   default: @default_codex_stall_timeout_ms
                                 ],
                                 dynamic_tool_timeout_ms: [
                                   type: :integer,
                                   default: @default_codex_dynamic_tool_timeout_ms
                                 ],
                                 dynamic_tool_max_retries: [
                                   type: :integer,
                                   default: @default_codex_dynamic_tool_max_retries
                                 ],
                                 dynamic_tool_allow_mutations: [
                                   type: :boolean,
                                   default: @default_codex_dynamic_tool_allow_mutations
                                 ]
                               ]
                             ],
                             hooks: [
                               type: :map,
                               default: %{},
                               keys: [
                                 after_create: [type: {:or, [:string, nil]}, default: nil],
                                 before_run: [type: {:or, [:string, nil]}, default: nil],
                                 after_run: [type: {:or, [:string, nil]}, default: nil],
                                 before_remove: [type: {:or, [:string, nil]}, default: nil],
                                 timeout_ms: [
                                   type: :pos_integer,
                                   default: @default_hook_timeout_ms
                                 ]
                               ]
                             ],
                             observability: [
                               type: :map,
                               default: %{},
                               keys: [
                                 dashboard_enabled: [
                                   type: :boolean,
                                   default: @default_observability_enabled
                                 ],
                                 refresh_ms: [
                                   type: :integer,
                                   default: @default_observability_refresh_ms
                                 ],
                                 render_interval_ms: [
                                   type: :integer,
                                   default: @default_observability_render_interval_ms
                                 ]
                               ]
                             ],
                             workflow: [
                               type: :map,
                               default: %{},
                               keys: [
                                 strategy: [type: {:map, :any, :any}, default: @default_workflow_strategy],
                                 acceptance: [type: {:list, {:map, :any, :any}}, default: @default_workflow_acceptance],
                                 approvals: [type: {:map, :any, :any}, default: @default_workflow_approvals],
                                 retry: [type: {:map, :any, :any}, default: @default_workflow_retry],
                                 writeback: [type: {:map, :any, :any}, default: @default_workflow_writeback]
                               ]
                             ],
                             server: [
                               type: :map,
                               default: %{},
                               keys: [
                                 port: [type: {:or, [:non_neg_integer, nil]}, default: nil],
                                 host: [type: :string, default: @default_server_host]
                               ]
                             ]
                           )

  @type workflow_payload :: Workflow.loaded_workflow()
  @type workflow_dsl_section :: map()
  @type workflow_acceptance_clause :: map()
  @type tracker_kind :: String.t() | nil
  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }
  @type workspace_hooks :: %{
          after_create: String.t() | nil,
          before_run: String.t() | nil,
          after_run: String.t() | nil,
          before_remove: String.t() | nil,
          timeout_ms: pos_integer()
        }

  @type issue_risk_level :: String.t() | nil

  @spec current_workflow() :: {:ok, workflow_payload()} | {:error, term()}
  def current_workflow do
    Workflow.current()
  end

  @spec tracker_kind() :: tracker_kind()
  def tracker_kind do
    get_in(validated_workflow_options(), [:tracker, :kind])
  end

  @spec tracker_display_name() :: String.t()
  def tracker_display_name do
    case tracker_kind() do
      "github" -> "GitHub"
      "jira" -> "Jira"
      "linear" -> "Linear"
      "local" -> "local tracker"
      "memory" -> "memory"
      _ -> "issue tracker"
    end
  end

  @spec tracker_adapter_module() :: module() | nil
  def tracker_adapter_module do
    validated_workflow_options()
    |> get_in([:tracker, :adapter_module])
    |> resolve_tracker_adapter_module()
  end

  @spec linear_endpoint() :: String.t()
  def linear_endpoint do
    get_in(validated_workflow_options(), [:tracker, :endpoint])
  end

  @spec linear_api_token() :: String.t() | nil
  def linear_api_token do
    validated_workflow_options()
    |> get_in([:tracker, :api_key])
    |> resolve_env_value(System.get_env("LINEAR_API_KEY"))
    |> normalize_secret_value()
  end

  @spec linear_project_slug() :: String.t() | nil
  def linear_project_slug do
    get_in(validated_workflow_options(), [:tracker, :project_slug])
  end

  @spec local_tracker_path() :: String.t() | nil
  def local_tracker_path do
    validated_workflow_options()
    |> get_in([:tracker, :path])
    |> resolve_path_value(nil)
  end

  @spec linear_assignee() :: String.t() | nil
  def linear_assignee do
    validated_workflow_options()
    |> get_in([:tracker, :assignee])
    |> resolve_env_value(System.get_env("LINEAR_ASSIGNEE"))
    |> normalize_secret_value()
  end

  @spec linear_active_states() :: [String.t()]
  def linear_active_states do
    get_in(validated_workflow_options(), [:tracker, :active_states])
  end

  @spec tracker_todo_state() :: String.t()
  def tracker_todo_state do
    get_in(validated_workflow_options(), [:tracker, :todo_state])
  end

  @spec tracker_in_progress_state() :: String.t()
  def tracker_in_progress_state do
    get_in(validated_workflow_options(), [:tracker, :in_progress_state])
  end

  @spec tracker_human_review_state() :: String.t()
  def tracker_human_review_state do
    get_in(validated_workflow_options(), [:tracker, :human_review_state])
  end

  @spec tracker_merging_state() :: String.t()
  def tracker_merging_state do
    get_in(validated_workflow_options(), [:tracker, :merging_state])
  end

  @spec tracker_done_state() :: String.t()
  def tracker_done_state do
    get_in(validated_workflow_options(), [:tracker, :done_state])
  end

  @spec linear_terminal_states() :: [String.t()]
  def linear_terminal_states do
    get_in(validated_workflow_options(), [:tracker, :terminal_states])
  end

  @spec tracker_active_states() :: [String.t()]
  def tracker_active_states do
    linear_active_states()
  end

  @spec tracker_terminal_states() :: [String.t()]
  def tracker_terminal_states do
    linear_terminal_states()
  end

  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms do
    get_in(validated_workflow_options(), [:polling, :interval_ms])
  end

  @spec workspace_root() :: Path.t()
  def workspace_root do
    validated_workflow_options()
    |> get_in([:workspace, :root])
    |> resolve_path_value(@default_workspace_root)
  end

  @spec workspace_hooks() :: workspace_hooks()
  def workspace_hooks do
    hooks = get_in(validated_workflow_options(), [:hooks])

    %{
      after_create: Map.get(hooks, :after_create),
      before_run: Map.get(hooks, :before_run),
      after_run: Map.get(hooks, :after_run),
      before_remove: Map.get(hooks, :before_remove),
      timeout_ms: Map.get(hooks, :timeout_ms)
    }
  end

  @spec hook_timeout_ms() :: pos_integer()
  def hook_timeout_ms do
    get_in(validated_workflow_options(), [:hooks, :timeout_ms])
  end

  @spec max_concurrent_agents() :: pos_integer()
  def max_concurrent_agents do
    get_in(validated_workflow_options(), [:agent, :max_concurrent_agents])
  end

  @spec max_retry_backoff_ms() :: pos_integer()
  def max_retry_backoff_ms do
    get_in(validated_workflow_options(), [:agent, :max_retry_backoff_ms])
  end

  @spec agent_capabilities() :: [String.t()]
  def agent_capabilities do
    get_in(validated_workflow_options(), [:agent, :capabilities])
  end

  @spec agent_supports_capability?(String.t() | term()) :: boolean()
  def agent_supports_capability?(capability) when is_binary(capability) do
    normalized_capability = normalize_capability(capability)

    normalized_capability != "" and normalized_capability in agent_capabilities()
  end

  def agent_supports_capability?(_capability), do: false

  @spec max_issue_risk_level() :: issue_risk_level()
  def max_issue_risk_level do
    get_in(validated_workflow_options(), [:agent, :max_risk_level])
  end

  @spec max_issue_budget() :: pos_integer() | nil
  def max_issue_budget do
    get_in(validated_workflow_options(), [:agent, :max_issue_budget])
  end

  @spec max_concurrent_agents_for_capability(term()) :: pos_integer()
  def max_concurrent_agents_for_capability(capability) when is_binary(capability) do
    capability_limits = get_in(validated_workflow_options(), [:agent, :max_concurrent_agents_by_capability])
    global_limit = max_concurrent_agents()
    Map.get(capability_limits, normalize_capability(capability), global_limit)
  end

  def max_concurrent_agents_for_capability(_capability), do: max_concurrent_agents()

  @spec max_concurrent_agents_for_risk(term()) :: pos_integer()
  def max_concurrent_agents_for_risk(risk_level) when is_binary(risk_level) do
    risk_limits = get_in(validated_workflow_options(), [:agent, :max_concurrent_agents_by_risk])
    global_limit = max_concurrent_agents()
    Map.get(risk_limits, normalize_risk_level(risk_level), global_limit)
  end

  def max_concurrent_agents_for_risk(_risk_level), do: max_concurrent_agents()

  @spec max_concurrent_agents_for_budget(term()) :: pos_integer()
  def max_concurrent_agents_for_budget(budget) when is_integer(budget) and budget > 0 do
    budget_limits = get_in(validated_workflow_options(), [:agent, :max_concurrent_agents_by_budget])
    global_limit = max_concurrent_agents()
    Map.get(budget_limits, Integer.to_string(budget), global_limit)
  end

  def max_concurrent_agents_for_budget(_budget), do: max_concurrent_agents()
  @spec agent_max_retry_attempts() :: pos_integer()
  def agent_max_retry_attempts do
    get_in(validated_workflow_options(), [:agent, :max_retry_attempts])
  end

  @spec agent_max_turns() :: pos_integer()
  def agent_max_turns do
    get_in(validated_workflow_options(), [:agent, :max_turns])
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    state_limits = get_in(validated_workflow_options(), [:agent, :max_concurrent_agents_by_state])
    global_limit = max_concurrent_agents()
    Map.get(state_limits, normalize_issue_state(state_name), global_limit)
  end

  def max_concurrent_agents_for_state(_state_name), do: max_concurrent_agents()

  @spec codex_command() :: String.t()
  def codex_command do
    get_in(validated_workflow_options(), [:codex, :command])
  end

  @spec codex_turn_timeout_ms() :: pos_integer()
  def codex_turn_timeout_ms do
    get_in(validated_workflow_options(), [:codex, :turn_timeout_ms])
  end

  @spec codex_approval_policy() :: String.t() | map()
  def codex_approval_policy do
    case resolve_codex_approval_policy() do
      {:ok, approval_policy} -> approval_policy
      {:error, _reason} -> @default_codex_approval_policy
    end
  end

  @spec codex_thread_sandbox() :: String.t()
  def codex_thread_sandbox do
    case resolve_codex_thread_sandbox() do
      {:ok, thread_sandbox} -> thread_sandbox
      {:error, _reason} -> @default_codex_thread_sandbox
    end
  end

  @spec codex_execution_environment() :: String.t() | nil
  def codex_execution_environment do
    case resolve_codex_execution_environment() do
      {:ok, execution_environment} -> execution_environment
      {:error, _reason} -> nil
    end
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case resolve_codex_turn_sandbox_policy(workspace) do
      {:ok, turn_sandbox_policy} -> turn_sandbox_policy
      {:error, _reason} -> default_codex_turn_sandbox_policy(workspace)
    end
  end

  @spec codex_read_timeout_ms() :: pos_integer()
  def codex_read_timeout_ms do
    get_in(validated_workflow_options(), [:codex, :read_timeout_ms])
  end

  @spec codex_stall_timeout_ms() :: non_neg_integer()
  def codex_stall_timeout_ms do
    validated_workflow_options()
    |> get_in([:codex, :stall_timeout_ms])
    |> max(0)
  end

  @spec codex_dynamic_tool_timeout_ms() :: pos_integer()
  def codex_dynamic_tool_timeout_ms do
    validated_workflow_options()
    |> get_in([:codex, :dynamic_tool_timeout_ms])
    |> max(1)
  end

  @spec codex_dynamic_tool_max_retries() :: non_neg_integer()
  def codex_dynamic_tool_max_retries do
    validated_workflow_options()
    |> get_in([:codex, :dynamic_tool_max_retries])
    |> max(0)
  end

  @spec codex_dynamic_tool_allow_mutations?() :: boolean()
  def codex_dynamic_tool_allow_mutations? do
    get_in(validated_workflow_options(), [:codex, :dynamic_tool_allow_mutations])
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case current_workflow() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "" do
          default_prompt_template()
        else
          prompt
        end

      _ ->
        default_prompt_template()
    end
  end

  @spec workflow_strategy() :: workflow_dsl_section()
  def workflow_strategy do
    get_in(validated_workflow_options(), [:workflow, :strategy])
  end

  @spec workflow_acceptance() :: [workflow_acceptance_clause()]
  def workflow_acceptance do
    get_in(validated_workflow_options(), [:workflow, :acceptance])
  end

  @spec workflow_approvals() :: workflow_dsl_section()
  def workflow_approvals do
    get_in(validated_workflow_options(), [:workflow, :approvals])
  end

  @spec workflow_retry() :: workflow_dsl_section()
  def workflow_retry do
    get_in(validated_workflow_options(), [:workflow, :retry])
  end

  @spec workflow_writeback() :: workflow_dsl_section()
  def workflow_writeback do
    get_in(validated_workflow_options(), [:workflow, :writeback])
  end

  @spec observability_enabled?() :: boolean()
  def observability_enabled? do
    get_in(validated_workflow_options(), [:observability, :dashboard_enabled])
  end

  @spec observability_refresh_ms() :: pos_integer()
  def observability_refresh_ms do
    get_in(validated_workflow_options(), [:observability, :refresh_ms])
  end

  @spec observability_render_interval_ms() :: pos_integer()
  def observability_render_interval_ms do
    get_in(validated_workflow_options(), [:observability, :render_interval_ms])
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 ->
        port

      _ ->
        get_in(validated_workflow_options(), [:server, :port])
    end
  end

  @spec server_host() :: String.t()
  def server_host do
    get_in(validated_workflow_options(), [:server, :host])
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, _workflow} <- current_workflow(),
         :ok <- require_tracker_adapter_module(),
         :ok <- require_tracker_kind(),
         :ok <- require_linear_token(),
         :ok <- require_linear_project(),
         :ok <- require_local_tracker_path(),
         :ok <- require_valid_codex_runtime_settings() do
      require_codex_command()
    end
  end

  @spec codex_runtime_settings(Path.t() | nil) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil) do
    with {:ok, _execution_environment} <- resolve_codex_execution_environment(),
         {:ok, approval_policy} <- resolve_codex_approval_policy(),
         {:ok, thread_sandbox} <- resolve_codex_thread_sandbox(),
         {:ok, turn_sandbox_policy} <- resolve_codex_turn_sandbox_policy(workspace) do
      {:ok,
       %{
         approval_policy: approval_policy,
         thread_sandbox: thread_sandbox,
         turn_sandbox_policy: turn_sandbox_policy
       }}
    end
  end

  defp require_tracker_kind do
    case tracker_kind() do
      "github" ->
        :ok

      "jira" ->
        :ok

      "linear" ->
        :ok

      "local" ->
        :ok

      "memory" ->
        :ok

      nil ->
        {:error, :missing_tracker_kind}

      other ->
        if custom_tracker_adapter_configured?(other) do
          :ok
        else
          {:error, {:unsupported_tracker_kind, other}}
        end
    end
  end

  defp require_tracker_adapter_module do
    case fetch_value([["tracker", "adapter_module"]], :missing) do
      :missing ->
        :ok

      nil ->
        :ok

      value when is_binary(value) ->
        case parse_tracker_adapter_module(value) do
          {:ok, _module} -> :ok
          {:error, reason} -> {:error, {:invalid_tracker_adapter_module, reason}}
        end

      value ->
        {:error, {:invalid_tracker_adapter_module, value}}
    end
  end

  defp require_linear_token do
    case tracker_kind() do
      "linear" ->
        if is_binary(linear_api_token()) do
          :ok
        else
          {:error, :missing_linear_api_token}
        end

      _ ->
        :ok
    end
  end

  defp require_linear_project do
    case tracker_kind() do
      "linear" ->
        if is_binary(linear_project_slug()) do
          :ok
        else
          {:error, :missing_linear_project_slug}
        end

      _ ->
        :ok
    end
  end

  defp require_local_tracker_path do
    case tracker_kind() do
      "local" ->
        if is_binary(local_tracker_path()) and String.trim(local_tracker_path()) != "" do
          :ok
        else
          {:error, :missing_local_tracker_path}
        end

      _ ->
        :ok
    end
  end

  defp require_codex_command do
    if byte_size(String.trim(codex_command())) > 0 do
      :ok
    else
      {:error, :missing_codex_command}
    end
  end

  defp require_valid_codex_runtime_settings do
    case codex_runtime_settings() do
      {:ok, _settings} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validated_workflow_options do
    workflow_config()
    |> extract_workflow_options()
    |> NimbleOptions.validate!(@workflow_options_schema)
  end

  defp extract_workflow_options(config) do
    %{
      tracker: extract_tracker_options(section_map(config, "tracker")),
      polling: extract_polling_options(section_map(config, "polling")),
      workspace: extract_workspace_options(section_map(config, "workspace")),
      agent: extract_agent_options(section_map(config, "agent")),
      codex: extract_codex_options(section_map(config, "codex")),
      hooks: extract_hooks_options(section_map(config, "hooks")),
      observability: extract_observability_options(section_map(config, "observability")),
      workflow: extract_workflow_dsl_options(section_map(config, "workflow")),
      server: extract_server_options(section_map(config, "server"))
    }
  end

  defp extract_tracker_options(section) do
    %{}
    |> put_if_present(
      :kind,
      normalize_tracker_kind(scalar_string_value(Map.get(section, "kind")))
    )
    |> put_if_present(:adapter_module, module_name_value(Map.get(section, "adapter_module")))
    |> put_if_present(:endpoint, scalar_string_value(Map.get(section, "endpoint")))
    |> put_if_present(:api_key, binary_value(Map.get(section, "api_key"), allow_empty: true))
    |> put_if_present(:project_slug, scalar_string_value(Map.get(section, "project_slug")))
    |> put_if_present(:path, binary_value(Map.get(section, "path")))
    |> put_if_present(:assignee, binary_value(Map.get(section, "assignee"), allow_empty: true))
    |> put_if_present(:active_states, csv_value(Map.get(section, "active_states")))
    |> put_if_present(:todo_state, scalar_string_value(Map.get(section, "todo_state")))
    |> put_if_present(:in_progress_state, scalar_string_value(Map.get(section, "in_progress_state")))
    |> put_if_present(:human_review_state, scalar_string_value(Map.get(section, "human_review_state")))
    |> put_if_present(:merging_state, scalar_string_value(Map.get(section, "merging_state")))
    |> put_if_present(:done_state, scalar_string_value(Map.get(section, "done_state")))
    |> put_if_present(:terminal_states, csv_value(Map.get(section, "terminal_states")))
  end

  defp extract_polling_options(section) do
    %{}
    |> put_if_present(:interval_ms, integer_value(Map.get(section, "interval_ms")))
  end

  defp extract_workspace_options(section) do
    %{}
    |> put_if_present(:root, binary_value(Map.get(section, "root")))
  end

  defp extract_agent_options(section) do
    %{}
    |> put_if_present(
      :max_concurrent_agents,
      integer_value(Map.get(section, "max_concurrent_agents"))
    )
    |> put_if_present(:max_turns, positive_integer_value(Map.get(section, "max_turns")))
    |> put_if_present(
      :max_retry_backoff_ms,
      positive_integer_value(Map.get(section, "max_retry_backoff_ms"))
    )
    |> put_if_present(:capabilities, capability_values(Map.get(section, "capabilities")))
    |> put_if_present(:max_risk_level, risk_level_value(Map.get(section, "max_risk_level")))
    |> put_if_present(:max_issue_budget, positive_integer_value(Map.get(section, "max_issue_budget")))
    |> put_if_present(:max_retry_attempts, positive_integer_value(Map.get(section, "max_retry_attempts")))
    |> put_if_present(
      :max_concurrent_agents_by_state,
      state_limits_value(Map.get(section, "max_concurrent_agents_by_state"))
    )
    |> put_if_present(
      :max_concurrent_agents_by_capability,
      capability_limits_value(Map.get(section, "max_concurrent_agents_by_capability"))
    )
    |> put_if_present(
      :max_concurrent_agents_by_risk,
      risk_limits_value(Map.get(section, "max_concurrent_agents_by_risk"))
    )
    |> put_if_present(
      :max_concurrent_agents_by_budget,
      budget_limits_value(Map.get(section, "max_concurrent_agents_by_budget"))
    )
  end

  defp extract_codex_options(section) do
    %{}
    |> put_if_present(:command, command_value(Map.get(section, "command")))
    |> put_if_present(:execution_environment, execution_environment_value(Map.get(section, "execution_environment")))
    |> put_if_present(:turn_timeout_ms, integer_value(Map.get(section, "turn_timeout_ms")))
    |> put_if_present(:read_timeout_ms, integer_value(Map.get(section, "read_timeout_ms")))
    |> put_if_present(:stall_timeout_ms, integer_value(Map.get(section, "stall_timeout_ms")))
    |> put_if_present(:dynamic_tool_timeout_ms, positive_integer_value(Map.get(section, "dynamic_tool_timeout_ms")))
    |> put_if_present(:dynamic_tool_max_retries, non_negative_integer_value(Map.get(section, "dynamic_tool_max_retries")))
    |> put_if_present(:dynamic_tool_allow_mutations, boolean_value(Map.get(section, "dynamic_tool_allow_mutations")))
  end

  defp extract_hooks_options(section) do
    %{}
    |> put_if_present(:after_create, hook_command_value(Map.get(section, "after_create")))
    |> put_if_present(:before_run, hook_command_value(Map.get(section, "before_run")))
    |> put_if_present(:after_run, hook_command_value(Map.get(section, "after_run")))
    |> put_if_present(:before_remove, hook_command_value(Map.get(section, "before_remove")))
    |> put_if_present(:timeout_ms, positive_integer_value(Map.get(section, "timeout_ms")))
  end

  defp extract_observability_options(section) do
    %{}
    |> put_if_present(:dashboard_enabled, boolean_value(Map.get(section, "dashboard_enabled")))
    |> put_if_present(:refresh_ms, integer_value(Map.get(section, "refresh_ms")))
    |> put_if_present(:render_interval_ms, integer_value(Map.get(section, "render_interval_ms")))
  end

  defp extract_workflow_dsl_options(section) do
    %{}
    |> put_if_present(:strategy, map_value(Map.get(section, "strategy")))
    |> put_if_present(:acceptance, list_of_maps_value(Map.get(section, "acceptance")))
    |> put_if_present(:approvals, map_value(Map.get(section, "approvals")))
    |> put_if_present(:retry, map_value(Map.get(section, "retry")))
    |> put_if_present(:writeback, map_value(Map.get(section, "writeback")))
  end

  defp extract_server_options(section) do
    %{}
    |> put_if_present(:port, non_negative_integer_value(Map.get(section, "port")))
    |> put_if_present(:host, scalar_string_value(Map.get(section, "host")))
  end

  defp section_map(config, key) do
    case Map.get(config, key) do
      section when is_map(section) -> section
      _ -> %{}
    end
  end

  defp put_if_present(map, _key, :omit), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp scalar_string_value(nil), do: :omit
  defp scalar_string_value(value) when is_binary(value), do: String.trim(value)
  defp scalar_string_value(value) when is_boolean(value), do: to_string(value)
  defp scalar_string_value(value) when is_integer(value), do: to_string(value)
  defp scalar_string_value(value) when is_float(value), do: to_string(value)
  defp scalar_string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar_string_value(_value), do: :omit

  defp binary_value(value, opts \\ [])

  defp binary_value(value, opts) when is_binary(value) do
    allow_empty = Keyword.get(opts, :allow_empty, false)

    if value == "" and not allow_empty do
      :omit
    else
      value
    end
  end

  defp binary_value(_value, _opts), do: :omit

  defp command_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      trimmed -> trimmed
    end
  end

  defp command_value(_value), do: :omit

  defp execution_environment_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      trimmed -> trimmed
    end
  end

  defp execution_environment_value(_value), do: :omit

  defp module_name_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      trimmed -> trimmed
    end
  end

  defp module_name_value(_value), do: :omit

  defp hook_command_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      _ -> String.trim_trailing(value)
    end
  end

  defp hook_command_value(_value), do: :omit

  defp csv_value(values) when is_list(values) do
    values
    |> Enum.reduce([], fn value, acc -> maybe_append_csv_value(acc, value) end)
    |> Enum.reverse()
    |> case do
      [] -> :omit
      normalized_values -> normalized_values
    end
  end

  defp csv_value(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> :omit
      normalized_values -> normalized_values
    end
  end

  defp csv_value(_value), do: :omit

  defp maybe_append_csv_value(acc, value) do
    case scalar_string_value(value) do
      :omit ->
        acc

      normalized ->
        append_csv_value_if_present(acc, normalized)
    end
  end

  defp append_csv_value_if_present(acc, value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      acc
    else
      [trimmed | acc]
    end
  end

  defp integer_value(value) do
    case parse_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp positive_integer_value(value) do
    case parse_positive_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp non_negative_integer_value(value) do
    case parse_non_negative_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp boolean_value(value) when is_boolean(value), do: value

  defp boolean_value(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _ -> :omit
    end
  end

  defp boolean_value(_value), do: :omit

  defp map_value(value) when is_map(value), do: normalize_keys(value)
  defp map_value(_value), do: :omit

  defp list_of_maps_value(values) when is_list(values) do
    values
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_keys/1)
    |> case do
      [] -> :omit
      normalized_values -> normalized_values
    end
  end

  defp list_of_maps_value(_value), do: :omit

  defp state_limits_value(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {state_name, limit}, acc ->
      case parse_positive_integer(limit) do
        {:ok, parsed} ->
          Map.put(acc, normalize_issue_state(to_string(state_name)), parsed)

        :error ->
          acc
      end
    end)
  end

  defp state_limits_value(_value), do: :omit

  defp capability_values(value) when is_list(value) do
    value
    |> Enum.reduce([], fn capability, acc ->
      case scalar_string_value(capability) do
        :omit -> acc
        normalized -> [normalize_capability(normalized) | acc]
      end
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.uniq()
    |> case do
      [] -> :omit
      capabilities -> capabilities
    end
  end

  defp capability_values(value) when is_binary(value) do
    value
    |> csv_value()
    |> case do
      :omit -> :omit
      capabilities -> capability_values(capabilities)
    end
  end

  defp capability_values(_value), do: :omit

  defp capability_limits_value(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {capability, limit}, acc ->
      case parse_positive_integer(limit) do
        {:ok, parsed} -> Map.put(acc, normalize_capability(to_string(capability)), parsed)
        :error -> acc
      end
    end)
  end

  defp capability_limits_value(_value), do: :omit

  defp risk_level_value(value) when is_binary(value) do
    case normalize_risk_level(value) do
      nil -> :omit
      normalized -> normalized
    end
  end

  defp risk_level_value(_value), do: :omit

  defp risk_limits_value(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {risk_level, limit}, acc ->
      normalized_risk_level = normalize_risk_level(to_string(risk_level))

      case {normalized_risk_level, parse_positive_integer(limit)} do
        {nil, _} -> acc
        {_, :error} -> acc
        {normalized, {:ok, parsed}} -> Map.put(acc, normalized, parsed)
      end
    end)
  end

  defp risk_limits_value(_value), do: :omit

  defp budget_limits_value(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {budget, limit}, acc ->
      case {parse_positive_integer(budget), parse_positive_integer(limit)} do
        {{:ok, normalized_budget}, {:ok, parsed}} ->
          Map.put(acc, Integer.to_string(normalized_budget), parsed)

        _ ->
          acc
      end
    end)
  end

  defp budget_limits_value(_value), do: :omit

  defp normalize_capability(capability) when is_binary(capability) do
    capability
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_risk_level(level) when is_binary(level) do
    level
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> {:ok, parsed}
      :error -> :error
    end
  end

  defp parse_integer(_value), do: :error

  defp parse_positive_integer(value) do
    case parse_integer(value) do
      {:ok, parsed} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_non_negative_integer(value) do
    case parse_integer(value) do
      {:ok, parsed} when parsed >= 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp fetch_value(paths, default) do
    config = workflow_config()

    case resolve_config_value(config, paths) do
      :missing -> default
      value -> value
    end
  end

  defp resolve_codex_execution_environment do
    case fetch_value([["codex", "execution_environment"]], :missing) do
      :missing -> {:ok, nil}
      nil -> {:ok, nil}
      value when is_binary(value) -> validate_codex_execution_environment(value)
      value -> {:error, {:invalid_codex_execution_environment, value}}
    end
  end

  defp validate_codex_execution_environment(value) do
    execution_environment = String.trim(value)

    cond do
      execution_environment == "" ->
        {:error, {:invalid_codex_execution_environment, value}}

      execution_environment in @codex_execution_environments ->
        {:ok, execution_environment}

      true ->
        reason = {:unsupported_value, execution_environment, @codex_execution_environments}
        {:error, {:invalid_codex_execution_environment, reason}}
    end
  end

  defp resolve_codex_approval_policy do
    case fetch_value([["codex", "approval_policy"]], :missing) do
      :missing ->
        {:ok, @default_codex_approval_policy}

      nil ->
        {:ok, @default_codex_approval_policy}

      value when is_binary(value) ->
        approval_policy = String.trim(value)

        if approval_policy == "" do
          {:error, {:invalid_codex_approval_policy, value}}
        else
          {:ok, approval_policy}
        end

      value when is_map(value) ->
        {:ok, value}

      value ->
        {:error, {:invalid_codex_approval_policy, value}}
    end
  end

  defp resolve_codex_thread_sandbox do
    case fetch_value([["codex", "thread_sandbox"]], :missing) do
      :missing ->
        codex_execution_environment_thread_sandbox()

      nil ->
        codex_execution_environment_thread_sandbox()

      value when is_binary(value) ->
        thread_sandbox = String.trim(value)

        if thread_sandbox == "" do
          {:error, {:invalid_codex_thread_sandbox, value}}
        else
          {:ok, thread_sandbox}
        end

      value ->
        {:error, {:invalid_codex_thread_sandbox, value}}
    end
  end

  defp resolve_codex_turn_sandbox_policy(workspace) do
    case fetch_value([["codex", "turn_sandbox_policy"]], :missing) do
      :missing ->
        codex_execution_environment_turn_sandbox_policy(workspace)

      nil ->
        codex_execution_environment_turn_sandbox_policy(workspace)

      value when is_map(value) ->
        {:ok, value}

      value ->
        {:error, {:invalid_codex_turn_sandbox_policy, {:unsupported_value, value}}}
    end
  end

  defp codex_execution_environment_thread_sandbox do
    case resolve_codex_execution_environment() do
      {:ok, nil} -> {:ok, @default_codex_thread_sandbox}
      {:ok, execution_environment} -> {:ok, execution_environment_thread_sandbox(execution_environment)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp codex_execution_environment_turn_sandbox_policy(workspace) do
    case resolve_codex_execution_environment() do
      {:ok, nil} -> {:ok, default_codex_turn_sandbox_policy(workspace)}
      {:ok, execution_environment} -> {:ok, execution_environment_turn_sandbox_policy(execution_environment, workspace)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execution_environment_thread_sandbox("docker"), do: "workspace-write"
  defp execution_environment_thread_sandbox("vm"), do: "workspace-write"
  defp execution_environment_thread_sandbox("browser"), do: "read-only"
  defp execution_environment_thread_sandbox("local_os"), do: "danger-full-access"

  defp execution_environment_turn_sandbox_policy("docker", workspace),
    do: default_codex_turn_sandbox_policy(workspace)

  defp execution_environment_turn_sandbox_policy("vm", _workspace) do
    %{
      "type" => "externalSandbox",
      "networkAccess" => "restricted"
    }
  end

  defp execution_environment_turn_sandbox_policy("browser", _workspace) do
    %{
      "type" => "readOnly",
      "access" => %{"type" => "fullAccess"},
      "networkAccess" => false
    }
  end

  defp execution_environment_turn_sandbox_policy("local_os", _workspace) do
    %{"type" => "dangerFullAccess"}
  end

  defp default_codex_turn_sandbox_policy(workspace) do
    writable_root =
      if is_binary(workspace) and String.trim(workspace) != "" do
        Path.expand(workspace)
      else
        Path.expand(workspace_root())
      end

    %{
      "type" => "workspaceWrite",
      "writableRoots" => [writable_root],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_tracker_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_tracker_kind(_kind), do: nil

  defp custom_tracker_adapter_configured?(kind) when is_binary(kind) do
    configured_module = tracker_adapter_module()

    not is_nil(configured_module) or not is_nil(env_tracker_adapter_module(kind))
  end

  defp env_tracker_adapter_module(kind) when is_binary(kind) do
    Application.get_env(:symphony_elixir, :tracker_adapter_modules, %{})
    |> Map.get(kind)
  end

  defp resolve_tracker_adapter_module(nil), do: nil

  defp resolve_tracker_adapter_module(value) when is_binary(value) do
    case parse_tracker_adapter_module(value) do
      {:ok, module} -> module
      {:error, _reason} -> nil
    end
  end

  defp parse_tracker_adapter_module(value) when is_binary(value) do
    adapter_module = String.trim(value)

    cond do
      adapter_module == "" ->
        {:error, value}

      not Regex.match?(@module_name_pattern, adapter_module) ->
        {:error, {:invalid_module_name, adapter_module}}

      true ->
        module =
          adapter_module
          |> String.trim_leading("Elixir.")
          |> String.split(".", trim: true)
          |> Module.concat()

        case Code.ensure_compiled(module) do
          {:module, ^module} -> validate_tracker_adapter_callbacks(module)
          {:error, _reason} -> {:error, {:module_not_found, adapter_module}}
        end
    end
  end

  defp validate_tracker_adapter_callbacks(module) when is_atom(module) do
    missing_callbacks =
      Enum.reject(@tracker_adapter_callbacks, fn {name, arity} ->
        function_exported?(module, name, arity)
      end)

    case missing_callbacks do
      [] -> {:ok, module}
      callbacks -> {:error, {:missing_callbacks, module, callbacks}}
    end
  end

  defp default_prompt_template do
    String.replace(@default_prompt_template, "{{ tracker.display_name }}", tracker_display_name())
  end

  defp workflow_config do
    case current_workflow() do
      {:ok, %{config: config}} when is_map(config) ->
        normalize_keys(config)

      _ ->
        %{}
    end
  end

  defp resolve_config_value(%{} = config, paths) do
    Enum.reduce_while(paths, :missing, fn path, _acc ->
      case get_in_path(config, path) do
        :missing -> {:cont, :missing}
        value -> {:halt, value}
      end
    end)
  end

  defp get_in_path(config, path) when is_list(path) and is_map(config) do
    get_in_path(config, path, 0)
  end

  defp get_in_path(_, _), do: :missing

  defp get_in_path(config, [], _depth), do: config

  defp get_in_path(%{} = current, [segment | rest], _depth) do
    case Map.fetch(current, normalize_key(segment)) do
      {:ok, value} -> get_in_path(value, rest, 0)
      :error -> :missing
    end
  end

  defp get_in_path(_, _, _depth), do: :missing

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp resolve_path_value(:missing, default), do: default
  defp resolve_path_value(nil, default), do: default

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      path ->
        path
        |> String.trim()
        |> preserve_command_name(workflow_file_dir())
        |> then(fn
          "" -> default
          resolved -> resolved
        end)
    end
  end

  defp resolve_path_value(_value, default), do: default

  defp preserve_command_name(path, workflow_dir) do
    cond do
      uri_path?(path) ->
        path

      path in [".", ".."] or String.starts_with?(path, "~") or String.contains?(path, "/") or
          String.contains?(path, "\\") ->
        Path.expand(path, workflow_dir)

      true ->
        path
    end
  end

  defp workflow_file_dir do
    Workflow.workflow_file_path()
    |> Path.expand()
    |> Path.dirname()
  end

  defp uri_path?(path) do
    String.match?(to_string(path), ~r/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//)
  end

  defp resolve_env_value(:missing, fallback), do: fallback
  defp resolve_env_value(nil, fallback), do: fallback

  defp resolve_env_value(value, fallback) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} ->
        env_name
        |> System.get_env()
        |> then(fn
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end)

      :error ->
        trimmed
    end
  end

  defp resolve_env_value(_value, fallback), do: fallback

  defp normalize_path_token(value) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> trimmed
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(value) do
    case System.get_env(value) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_secret_value(_value), do: nil
end
