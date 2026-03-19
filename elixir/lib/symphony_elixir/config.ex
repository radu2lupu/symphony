defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  require Logger

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.ProjectConfig
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}
  Workspace: {{ workspace.path }}

  Repository layout:
  {% for repository in workspace.repositories %}
  - {{ repository.name }} at {{ repository.relative_path }}
  {% endfor %}

  Planning and approval gate:
  - Start by writing a {{ guidance.spec_detail_level }} spec in the workpad before code edits.
  - Minimal spec: problem statement, chosen repo, acceptance criteria, and validation plan.
  - Standard spec: minimal spec plus scope/non-goals, implementation outline, risks, and open questions.
  - Detailed spec: standard spec plus repo-by-repo impact, user flow/API contract notes, tradeoffs, and rollout/validation matrix.
  {% if guidance.clarification_required %}
  - Clarification is required before implementation:
  {% for point in guidance.clarification_points %}
    - {{ point }}
  {% endfor %}
  - Ask focused questions, move the ticket to `{{ guidance.planning_state }}` if available, and stop without editing code.
  {% elsif guidance.execution_approval_required %}
  - After writing the spec, ask for explicit go-ahead before implementation.
  - Move the ticket to `{{ guidance.planning_state }}` while waiting if that state exists.
  - Do not edit code until the issue comments or description contain explicit approval of the plan.
  {% else %}
  - If the ask is already explicit and low-risk, proceed after recording the plan in the workpad.
  {% endif %}

  {% if guidance.frontend_artifact_required %}
  Frontend proof requirement:
  - This looks like a user-facing frontend/UI task.
  - Before handoff, include at least one screenshot of the changed UI, or a short video when the change depends on motion or interaction.
  - Reference the screenshot or video in the workpad and final message.
  - If you cannot capture visual proof, treat that as a blocker and state exactly what prevented capture.

  {% endif %}

  {% if memory.total_recall.enabled %}
  Shared memory requirement:
  - Before starting new work, run `{{ memory.total_recall.command }} query "<semantic query>"` using a high-level question such as "have we solved X before?" or "how do we usually do Y here?".
  - Do not paste the raw issue text as the query; author the query yourself based on the task.
  - When retrieved memory materially informs the task, reference it as `🧠 Relevant memory: ... 🧠`.
  - Maintain this exact block in the `## Codex Workpad` comment and keep it current for the active turn:
    - `## Shared Memory`
    - `- Query: <semantic query used this turn>`
    - `- Relevant memories: <none | short refs>`
    - `- Write summary: <what changed, why, what future agents should reuse/avoid>`
    - `- Total Recall status: ok | unavailable: <reason>`
  - After each completed turn and again when the run is wrapping up, persist a short structured summary with `{{ memory.total_recall.command }} write "<what changed, why, what future agents should reuse or avoid>"`.
  {% if memory.total_recall.verify_evidence %}
  - Symphony will verify the `## Shared Memory` block after each turn. Missing or malformed evidence fails the turn. If Total Recall is unavailable, record `Total Recall status: unavailable: <reason>` and continue.
  {% endif %}

  {% endif %}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @type workspace_repository :: %{
          name: String.t(),
          source: String.t(),
          branch: String.t() | nil,
          tags: [String.t()],
          relative_path: String.t(),
          path: Path.t() | nil,
          primary: boolean(),
          origin: atom()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        with {:ok, settings} <- Schema.parse(config) do
          {:ok, maybe_sync_linear_project_config(settings)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec total_recall_enabled?() :: boolean()
  def total_recall_enabled? do
    settings!().memory.total_recall.enabled == true
  end

  @spec total_recall_command() :: String.t()
  def total_recall_command do
    settings!().memory.total_recall.command
  end

  @spec verify_total_recall_evidence?() :: boolean()
  def verify_total_recall_evidence? do
    settings!().memory.total_recall.verify_evidence == true
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil) :: {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  @spec workspace_repositories(Path.t() | nil) :: [workspace_repository()]
  def workspace_repositories(workspace \\ nil) do
    settings = settings!()

    settings.workspace.repositories
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {repository, index} ->
      relative_path = repository_relative_path(repository, index)

      %{
        name: repository.name,
        source: repository.source,
        branch: repository.branch,
        tags: repository.tags || [],
        relative_path: relative_path,
        path: repository_absolute_path(workspace, relative_path),
        primary: relative_path == ".",
        origin: :workflow
      }
    end)
  end

  @spec workspace_registry_path() :: Path.t()
  def workspace_registry_path do
    settings!().workspace.registry_path
  end

  @spec planning_states() :: [String.t()]
  def planning_states do
    settings!().tracker.planning_states || []
  end

  @spec preferred_planning_state() :: String.t() | nil
  def preferred_planning_state do
    tracker = settings!().tracker
    active_state_set = normalized_state_set(tracker.active_states)

    Enum.find(planning_states(), fn planning_state ->
      MapSet.member?(active_state_set, Schema.normalize_issue_state(planning_state))
    end) || List.first(planning_states())
  end

  @spec dispatchable_active_states() :: [String.t()]
  def dispatchable_active_states do
    planning_state_set = normalized_state_set(planning_states())
    backlog_state = Schema.normalize_issue_state("Backlog")

    settings!().tracker.active_states
    |> Enum.reject(fn state ->
      normalized_state = Schema.normalize_issue_state(state)
      normalized_state == backlog_state or MapSet.member?(planning_state_set, normalized_state)
    end)
  end

  defp validate_semantics(settings) do
    case validate_workspace_repositories(settings) do
      :ok ->
        cond do
          is_nil(settings.tracker.kind) ->
            {:error, :missing_tracker_kind}

          settings.tracker.kind not in ["linear", "memory"] ->
            {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

          settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
            {:error, :missing_linear_api_token}

          settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
            {:error, :missing_linear_project_slug}

          true ->
            :ok
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp maybe_sync_linear_project_config(settings) do
    if sync_linear_project_states?(settings) do
      case linear_project_config_module().resolve_tracker(settings.tracker, settings.polling.interval_ms) do
        {:ok, project_config} ->
          tracker = %{
            settings.tracker
            | project_url: project_config.project_url || settings.tracker.project_url,
              active_states: project_config.active_states,
              terminal_states: project_config.terminal_states
          }

          %{settings | tracker: tracker}

        {:error, reason} ->
          Logger.warning("Failed to sync Linear project states from project config: #{inspect(reason)}")
          settings
      end
    else
      settings
    end
  end

  defp sync_linear_project_states?(settings) do
    settings.tracker.kind == "linear" and
      settings.tracker.sync_project_states != false and
      is_binary(settings.tracker.api_key) and
      is_binary(settings.tracker.project_slug)
  end

  defp linear_project_config_module do
    Application.get_env(:symphony_elixir, :linear_project_config_module, ProjectConfig)
  end

  defp normalized_state_set(states) do
    states
    |> List.wrap()
    |> Enum.map(&Schema.normalize_issue_state/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp validate_workspace_repositories(settings) do
    repositories = workspace_repositories_for_validation(settings)

    case Enum.find(repositories, &(not is_binary(&1.source))) do
      %{name: name} ->
        {:error, {:invalid_workspace_repository_source, name}}

      nil ->
        case Enum.find(repositories, &invalid_repository_path?/1) do
          %{name: name, relative_path: relative_path} ->
            {:error, {:invalid_workspace_repository_path, name, relative_path}}

          nil ->
            duplicate =
              repositories
              |> Enum.group_by(& &1.relative_path)
              |> Enum.find(fn {_path, entries} -> length(entries) > 1 end)

            case duplicate do
              {relative_path, [%{name: first}, %{name: second} | _]} ->
                {:error, {:duplicate_workspace_repository_path, relative_path, first, second}}

              nil ->
                :ok
            end
        end
    end
  end

  defp workspace_repositories_for_validation(settings) do
    settings.workspace.repositories
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {repository, index} ->
      %{
        name: repository.name,
        source: repository.source,
        relative_path: repository_relative_path(repository, index)
      }
    end)
  end

  defp repository_relative_path(repository, index) do
    repository.path || default_repository_path(repository, index)
  end

  defp default_repository_path(_repository, 0), do: "."
  defp default_repository_path(repository, _index), do: repository.name

  defp repository_absolute_path(nil, _relative_path), do: nil

  defp repository_absolute_path(workspace, relative_path) when is_binary(workspace) do
    Path.expand(relative_path, workspace)
  end

  defp invalid_repository_path?(%{relative_path: relative_path}) do
    expanded = Path.expand(relative_path, "/workspace")
    expanded != "/workspace" and not String.starts_with?(expanded <> "/", "/workspace/")
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      {:invalid_workspace_repository_source, name} ->
        "workspace.repositories #{inspect(name)} is missing a usable source"

      {:duplicate_workspace_repository_path, path, first, second} ->
        "workspace.repositories #{inspect(first)} and #{inspect(second)} resolve to the same checkout path #{inspect(path)}"

      {:invalid_workspace_repository_path, name, path} ->
        "workspace.repositories #{inspect(name)} resolves outside the issue workspace via #{inspect(path)}"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
