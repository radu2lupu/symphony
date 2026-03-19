defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.LogFile

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, logs_root: :string, port: :integer]
  @internal_workflow_path Path.join(".symphony", "WORKFLOW.md")
  @default_poll_interval_ms 30_000
  @default_max_concurrent_agents 10
  @default_max_turns 20
  @default_codex_command "codex app-server"
  @default_total_recall_command "total-recall"
  @type repository_analysis_result :: {:ok, map()} | {:error, term()}

  @type prompt_result :: String.t() | nil | {:error, term()}

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          file_exists?: (String.t() -> boolean()),
          dir_exists?: (String.t() -> boolean()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result()),
          prompt: (String.t() -> prompt_result()),
          print: (String.t() -> term()),
          mkdir_p: (String.t() -> :ok | {:error, term()}),
          write_file: (String.t(), iodata() -> :ok | {:error, term()}),
          cwd: (-> String.t()),
          env_get: (String.t() -> String.t() | nil),
          find_executable: (String.t() -> String.t() | nil),
          run_command: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()}),
          analyze_repository: (map() -> repository_analysis_result()),
          discover_repositories: (String.t() -> {:ok, [map()]} | {:error, term()}),
          resolve_linear_project_config: (map(), non_neg_integer() -> {:ok, map()} | {:error, term()})
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      :halt_ok ->
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | :halt_ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case args do
      ["init" | rest] ->
        run_init(rest, deps)

      _ ->
        evaluate_run(args, deps)
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = resolve_existing_workflow_path(workflow_path, deps)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          :ok

        {:error, reason} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @spec evaluate_run([String.t()], deps()) :: :ok | {:error, String.t()}
  defp evaluate_run(args, deps) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(default_run_target(deps), deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(workflow_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    """
    Usage:
      symphony [--logs-root <path>] [--port <port>] [path-to-project-root-or-WORKFLOW.md]
      symphony init [path-to-project-root-or-WORKFLOW.md]
    """
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      file_exists?: &File.exists?/1,
      dir_exists?: &File.dir?/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end,
      prompt: &IO.gets/1,
      print: &IO.puts/1,
      mkdir_p: &File.mkdir_p/1,
      write_file: &File.write/2,
      cwd: &File.cwd!/0,
      env_get: &System.get_env/1,
      find_executable: &System.find_executable/1,
      run_command: &System.cmd/3,
      analyze_repository: &analyze_repository/1,
      discover_repositories: &discover_repositories/1,
      resolve_linear_project_config: &SymphonyElixir.Linear.ProjectConfig.resolve_tracker/2
    }
  end

  defp run_init(args, deps) do
    case args do
      [] ->
        create_workflow("WORKFLOW.md", deps)

      [workflow_path] ->
        create_workflow(workflow_path, deps)

      _ ->
        {:error, usage_message()}
    end
  end

  defp create_workflow(workflow_path, deps) do
    expanded_path = resolve_generated_workflow_path(workflow_path, deps)
    project_root = resolve_project_root(workflow_path, expanded_path, deps)

    with :ok <- maybe_confirm_overwrite(expanded_path, deps),
         {:ok, answers} <- prompt_workflow_settings(deps, project_root),
         :ok <- deps.mkdir_p.(Path.dirname(expanded_path)) |> map_fs_error("create #{Path.dirname(expanded_path)}"),
         :ok <-
           deps.write_file.(expanded_path, render_workflow(answers))
           |> map_fs_error("write #{expanded_path}") do
      deps.print.("")
      deps.print.("Wrote starter workflow to #{expanded_path}")
      deps.print.("Start Symphony with: ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails #{expanded_path}")
      deps.print.("The generated workflow includes starter repo-aware agent instructions based on the repos you configured.")
      :halt_ok
    end
  end

  defp maybe_confirm_overwrite(workflow_path, deps) do
    if deps.file_exists?.(workflow_path) do
      with {:ok, overwrite?} <- prompt_yes_no(deps, "Overwrite existing #{workflow_path}? [y/N]: ", false) do
        if overwrite? do
          :ok
        else
          {:error, "Aborted interactive setup; workflow already exists at #{workflow_path}"}
        end
      end
    else
      :ok
    end
  end

  defp default_run_target(deps) do
    hidden_workflow = Path.join(deps.cwd.(), @internal_workflow_path)

    if deps.file_regular?.(hidden_workflow) do
      hidden_workflow
    else
      Path.expand("WORKFLOW.md", deps.cwd.())
    end
  end

  defp resolve_existing_workflow_path(target, deps) do
    expanded = Path.expand(target, deps.cwd.())

    if deps.dir_exists?.(expanded) do
      Path.join(expanded, @internal_workflow_path)
    else
      expanded
    end
  end

  defp resolve_generated_workflow_path(target, deps) do
    expanded = Path.expand(target, deps.cwd.())

    if deps.dir_exists?.(expanded) do
      Path.join(expanded, @internal_workflow_path)
    else
      expanded
    end
  end

  defp resolve_project_root(target, expanded_workflow_path, deps) do
    expanded_target = Path.expand(target, deps.cwd.())

    if deps.dir_exists?.(expanded_target) do
      expanded_target
    else
      Path.dirname(expanded_workflow_path)
    end
  end

  defp prompt_workflow_settings(deps, project_root) do
    deps.print.("Symphony interactive setup")
    deps.print.("This writes a starter WORKFLOW.md for a Linear-backed Symphony project.")
    deps.print.("")

    default_workspace_root = Path.join(project_root, ".symphony/workspaces")
    default_registry_path = Path.join(project_root, ".symphony/repos.json")

    with {:ok, api_key} <-
           prompt_default(deps, "Linear API key (leave blank to use $LINEAR_API_KEY): ", nil),
         {:ok, project_slug_input} <- prompt_required(deps, "Linear project URL or slugId: "),
         {:ok, workspace_root} <-
           prompt_default(deps, "Workspace root [#{default_workspace_root}]: ", default_workspace_root),
         {:ok, registry_path} <-
           prompt_default(deps, "Local repo registry path [#{default_registry_path}]: ", default_registry_path),
         {:ok, repositories} <- initial_repositories(project_root, deps),
         {:ok, repositories} <- analyze_repositories(repositories, deps),
         {:ok, max_concurrent_agents} <-
           prompt_integer(
             deps,
             "Max concurrent agents [#{@default_max_concurrent_agents}]: ",
             @default_max_concurrent_agents
           ),
         {:ok, max_turns} <- prompt_integer(deps, "Max turns [#{@default_max_turns}]: ", @default_max_turns),
         {:ok, codex_command} <-
           prompt_default(deps, "Codex command [#{@default_codex_command}]: ", @default_codex_command),
         {:ok, tracker_config} <-
           resolve_linear_tracker_config(
             deps,
             blank_to_nil(api_key),
             project_slug_input,
             @default_poll_interval_ms
           ),
         {:ok, total_recall} <- ensure_total_recall_ready(deps, project_root, @default_total_recall_command) do
      {:ok,
       %{
         tracker_api_key: blank_to_nil(api_key),
         tracker_project_slug: tracker_config.project_slug,
         tracker_project_url: tracker_config.project_url,
         tracker_sync_project_states: true,
         tracker_active_states: tracker_config.active_states,
         tracker_planning_states: default_planning_states(tracker_config.active_states),
         tracker_terminal_states: tracker_config.terminal_states,
         workspace_root: workspace_root,
         registry_path: registry_path,
         repositories: repositories,
         max_concurrent_agents: max_concurrent_agents,
         max_turns: max_turns,
         codex_command: codex_command,
         total_recall: total_recall
       }}
    end
  end

  defp prompt_repositories(deps, repositories) do
    index = length(repositories)
    repo_number = index + 1
    default_name = if index == 0, do: "app", else: "repo-#{repo_number}"

    deps.print.("")
    deps.print.("Repository #{repo_number}")

    with {:ok, name} <- prompt_default(deps, "  Name [#{default_name}]: ", default_name),
         {:ok, source} <- prompt_required(deps, "  Source URL or local path: "),
         {:ok, path} <- prompt_default(deps, "  Workspace path [#{default_repo_path(name, index)}]: ", default_repo_path(name, index)),
         {:ok, tags_input} <- prompt_default(deps, "  Tags (comma-separated, optional): ", ""),
         {:ok, add_another?} <- prompt_yes_no(deps, "Add another repository? [y/N]: ", false) do
      repositories = repositories ++ [%{name: name, source: source, path: path, tags: parse_tags(tags_input)}]

      if add_another? do
        prompt_repositories(deps, repositories)
      else
        {:ok, repositories}
      end
    end
  end

  defp initial_repositories(project_root, deps) do
    with {:ok, discovered_repositories} <- deps.discover_repositories.(project_root) do
      case discovered_repositories do
        [] ->
          deps.print.("No git repositories were discovered directly under #{project_root}.")
          prompt_repositories(deps, [])

        repositories ->
          deps.print.("Discovered #{length(repositories)} git repos under #{project_root}:")

          Enum.each(repositories, fn repository ->
            deps.print.("  - #{repository.name} (#{repository.path})")
          end)

          maybe_prompt_additional_repositories(deps, repositories)
      end
    end
  end

  defp maybe_prompt_additional_repositories(deps, repositories) do
    with {:ok, add_more?} <-
           prompt_yes_no(deps, "Add another repository outside this root? [y/N]: ", false) do
      if add_more? do
        prompt_repositories(deps, repositories)
      else
        {:ok, repositories}
      end
    end
  end

  defp prompt_required(deps, prompt) do
    with {:ok, value} <- prompt_default(deps, prompt, nil) do
      if value == "" do
        deps.print.("  Value is required.")
        prompt_required(deps, prompt)
      else
        {:ok, value}
      end
    end
  end

  defp prompt_integer(deps, prompt, default) do
    with {:ok, value} <- prompt_default(deps, prompt, Integer.to_string(default)) do
      case Integer.parse(value) do
        {parsed, ""} when parsed > 0 ->
          {:ok, parsed}

        _ ->
          deps.print.("  Enter a positive integer.")
          prompt_integer(deps, prompt, default)
      end
    end
  end

  defp prompt_yes_no(deps, prompt, default) do
    with {:ok, value} <- prompt_default(deps, prompt, yes_no_default(default)) do
      case String.downcase(value) do
        "y" ->
          {:ok, true}

        "yes" ->
          {:ok, true}

        "n" ->
          {:ok, false}

        "no" ->
          {:ok, false}

        "" ->
          {:ok, default}

        _ ->
          deps.print.("  Enter y or n.")
          prompt_yes_no(deps, prompt, default)
      end
    end
  end

  defp prompt_default(deps, prompt, default) do
    case deps.prompt.(prompt) do
      nil ->
        {:error, "Interactive setup cancelled while reading input"}

      {:error, reason} ->
        {:error, "Interactive setup failed: #{inspect(reason)}"}

      value when is_binary(value) ->
        trimmed = String.trim(value)
        {:ok, if(trimmed == "" and not is_nil(default), do: default, else: trimmed)}
    end
  end

  defp analyze_repositories(repositories, deps) do
    analyzed =
      Enum.map(repositories, fn repository ->
        deps.print.("Analyzing repository #{repository.name}...")

        analysis =
          case deps.analyze_repository.(repository) do
            {:ok, repo_analysis} ->
              normalize_repository_analysis(repository, repo_analysis)

            {:error, reason} ->
              deps.print.("  Could not inspect #{repository.name} (#{inspect(reason)}). Falling back to generic repo guidance.")

              generic_repository_analysis(repository)
          end

        Map.put(repository, :analysis, analysis)
      end)

    {:ok, analyzed}
  end

  defp render_workflow(settings) do
    [
      "---\n",
      "tracker:\n",
      "  kind: linear\n",
      maybe_render_api_key(settings.tracker_api_key),
      "  project_slug: ",
      yaml_string(settings.tracker_project_slug),
      "\n",
      maybe_render_project_url(settings.tracker_project_url),
      "  sync_project_states: ",
      yaml_string(settings.tracker_sync_project_states),
      "\n",
      "  active_states: ",
      yaml_string(settings.tracker_active_states),
      "\n",
      "  planning_states: ",
      yaml_string(settings.tracker_planning_states),
      "\n",
      "  terminal_states: ",
      yaml_string(settings.tracker_terminal_states),
      "\n",
      "workspace:\n",
      "  root: ",
      yaml_string(settings.workspace_root),
      "\n",
      "  registry_path: ",
      yaml_string(settings.registry_path),
      "\n",
      "  repositories:\n",
      Enum.map(settings.repositories, &render_repository/1),
      "agent:\n",
      "  max_concurrent_agents: ",
      Integer.to_string(settings.max_concurrent_agents),
      "\n",
      "  max_turns: ",
      Integer.to_string(settings.max_turns),
      "\n",
      "codex:\n",
      "  command: ",
      yaml_string(settings.codex_command),
      "\n",
      "memory:\n",
      "  total_recall:\n",
      "    enabled: ",
      yaml_string(settings.total_recall.enabled),
      "\n",
      "    command: ",
      yaml_string(settings.total_recall.command),
      "\n",
      "    verify_evidence: ",
      yaml_string(settings.total_recall.verify_evidence),
      "\n",
      "    install_during_init: ",
      yaml_string(settings.total_recall.install_during_init),
      "\n",
      "---\n\n",
      render_prompt_body(settings.repositories)
    ]
  end

  defp render_repository(repository) do
    base = [
      "    - name: ",
      yaml_string(repository.name),
      "\n",
      "      source: ",
      yaml_string(repository.source),
      "\n",
      "      path: ",
      yaml_string(repository.path),
      "\n"
    ]

    case repository.tags do
      [] ->
        base

      tags ->
        [
          base,
          "      tags:\n",
          Enum.map(tags, fn tag -> ["        - ", yaml_string(tag), "\n"] end)
        ]
    end
  end

  defp yaml_string(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ~s("#{escaped}")
  end

  defp yaml_string(value) when is_boolean(value), do: if(value, do: "true", else: "false")

  defp yaml_string(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_string/1) <> "]"
  end

  defp default_repo_path(_name, 0), do: "."
  defp default_repo_path(name, _index), do: "repos/#{name}"

  defp maybe_render_api_key(nil), do: []

  defp maybe_render_api_key(api_key) when is_binary(api_key) do
    ["  api_key: ", yaml_string(api_key), "\n"]
  end

  defp maybe_render_project_url(nil), do: []

  defp maybe_render_project_url(project_url) when is_binary(project_url) do
    ["  project_url: ", yaml_string(project_url), "\n"]
  end

  defp parse_tags(tags_input) do
    tags_input
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp yes_no_default(true), do: "y"
  defp yes_no_default(false), do: "n"

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp normalize_linear_project_slug_input(value) when is_binary(value) do
    case Regex.run(~r{/project/([^/?#]+)}, value) do
      [_, project_slug] -> extract_linear_project_slug_id(project_slug)
      _ -> value
    end
  end

  defp normalize_linear_project_url_input(value) when is_binary(value) do
    if String.contains?(value, "/project/"), do: value, else: nil
  end

  defp normalize_linear_project_url_input(_value), do: nil

  defp resolve_linear_tracker_config(deps, api_key, project_slug_input, poll_interval_ms) do
    project_slug = normalize_linear_project_slug_input(project_slug_input)
    project_url = normalize_linear_project_url_input(project_slug_input)
    api_key = api_key || deps.env_get.("LINEAR_API_KEY")

    fallback = %{
      project_slug: project_slug,
      project_url: project_url,
      active_states: ["Todo", "In Progress"],
      terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    }

    if is_binary(api_key) and project_slug not in [nil, ""] do
      tracker = %{
        endpoint: "https://api.linear.app/graphql",
        api_key: api_key,
        project_slug: project_slug
      }

      case deps.resolve_linear_project_config.(tracker, poll_interval_ms) do
        {:ok, project_config} ->
          deps.print.("Resolved Linear workflow states from the project configuration.")

          {:ok,
           %{
             fallback
             | project_url: project_config.project_url || project_url,
               active_states: project_config.active_states,
               terminal_states: project_config.terminal_states
           }}

        {:error, reason} ->
          deps.print.("Could not resolve Linear project workflow states automatically (#{inspect(reason)}). Falling back to default state mapping.")

          {:ok, fallback}
      end
    else
      if api_key in [nil, ""] do
        deps.print.("Skipping automatic Linear workflow state detection because no API key is available during setup.")
      end

      {:ok, fallback}
    end
  end

  defp extract_linear_project_slug_id(project_slug) when is_binary(project_slug) do
    case Regex.run(~r/-([a-f0-9]{8,})$/i, project_slug) do
      [_, slug_id] -> slug_id
      _ -> project_slug
    end
  end

  defp render_prompt_body(repositories) do
    [
      "You are working on a Linear issue `{{ issue.identifier }}`.\n\n",
      "Issue context:\n",
      "Identifier: {{ issue.identifier }}\n",
      "Title: {{ issue.title }}\n",
      "Current status: {{ issue.state }}\n",
      "Labels: {{ issue.labels }}\n",
      "URL: {{ issue.url }}\n\n",
      "Description:\n",
      "{% if issue.description %}\n",
      "{{ issue.description }}\n",
      "{% else %}\n",
      "No description provided.\n",
      "{% endif %}\n\n",
      "Workspace: `{{ workspace.path }}`\n",
      "Repositories:\n",
      "{% for repository in workspace.repositories %}\n",
      "- `{{ repository.name }}` at `{{ repository.relative_path }}`\n",
      "{% endfor %}\n\n",
      "Planning and approval gate:\n",
      "- Start by writing a {{ guidance.spec_detail_level }} spec in the workpad before code edits.\n",
      "- Minimal spec: problem statement, chosen repo, acceptance criteria, and validation plan.\n",
      "- Standard spec: minimal spec plus scope/non-goals, implementation outline, risks, and open questions.\n",
      "- Detailed spec: standard spec plus repo-by-repo impact, user flow/API contract notes, tradeoffs, and rollout/validation matrix.\n",
      "{% if guidance.clarification_required %}\n",
      "- Clarification is required before implementation:\n",
      "{% for point in guidance.clarification_points %}\n",
      "  - {{ point }}\n",
      "{% endfor %}\n",
      "- Ask focused questions, move the ticket to `{{ guidance.planning_state }}` if available, and stop without editing code.\n",
      "{% elsif guidance.execution_approval_required %}\n",
      "- After writing the spec, ask for explicit go-ahead before implementation.\n",
      "- Move the ticket to `{{ guidance.planning_state }}` while waiting if that state exists.\n",
      "- Do not edit code until the issue comments or description contain explicit approval of the plan.\n",
      "{% else %}\n",
      "- If the ask is already explicit and low-risk, proceed after recording the plan in the workpad.\n",
      "{% endif %}\n\n",
      "{% if guidance.frontend_artifact_required %}\n",
      "Frontend proof requirement:\n",
      "- This ticket appears user-facing from the issue context or repo signals.\n",
      "- Before handoff, capture at least one screenshot of the changed UI, or a short video when motion or interaction is the important part.\n",
      "- Reference the screenshot or video in the workpad and final message.\n",
      "- If visual capture is unavailable, treat that as a blocker and explain exactly what prevented it.\n\n",
      "{% endif %}\n",
      "{% if memory.total_recall.enabled %}\n",
      "Shared memory requirement:\n",
      "- Before starting new work, run `{{ memory.total_recall.command }} query \"<semantic query>\"` using a high-level question such as \"have we solved X before?\" or \"how do we usually do Y here?\".\n",
      "- Do not use the raw ticket text as the query; author the query yourself based on the task.\n",
      "- When retrieved memory materially informs the task, reference it as `🧠 Relevant memory: ... 🧠`.\n",
      "- Maintain this exact block in the `## Codex Workpad` comment and keep it current for the active turn:\n",
      "  - `## Shared Memory`\n",
      "  - `- Query: <semantic query used this turn>`\n",
      "  - `- Relevant memories: <none | short refs>`\n",
      "  - `- Write summary: <what changed, why, what future agents should reuse/avoid>`\n",
      "  - `- Total Recall status: ok | unavailable: <reason>`\n",
      "- After each completed turn and again when the run is wrapping up, persist a short structured summary with `{{ memory.total_recall.command }} write \"<what changed, why, what future agents should reuse or avoid>\"`.\n",
      "{% if memory.total_recall.verify_evidence %}\n",
      "- Symphony will verify the `## Shared Memory` block after each turn. Missing or malformed evidence fails the turn. If Total Recall is unavailable, record `Total Recall status: unavailable: <reason>` and continue.\n",
      "{% endif %}\n\n",
      "{% endif %}\n",
      "Routing guidance:\n",
      "- Prefer an explicit `repo:<name>` label when present.\n",
      "- Otherwise, route to the repo whose name, tags, and issue context best match the task.\n",
      "- Only edit multiple repos when the issue clearly requires coordinated changes.\n",
      "- Validate in every repo you change before ending the turn.\n\n",
      "Project-specific repo guidance:\n",
      Enum.map(repositories, &render_repository_guidance/1)
    ]
  end

  defp default_planning_states(active_states) do
    active_states
    |> List.wrap()
    |> Enum.filter(fn state ->
      normalized = String.downcase(String.trim(to_string(state)))
      normalized in ["spec review", "needs clarification", "clarification", "planning"]
    end)
    |> case do
      [] -> ["Spec Review", "Needs Clarification", "Planning"]
      states -> states
    end
  end

  defp render_repository_guidance(repository) do
    analysis = Map.get(repository, :analysis, generic_repository_analysis(repository))

    [
      "- `",
      repository.name,
      "`: ",
      analysis.summary,
      "\n",
      Enum.map(analysis.instructions, fn instruction -> ["  - ", instruction, "\n"] end)
    ]
  end

  defp ensure_total_recall_ready(deps, project_root, command) do
    executable = deps.find_executable.(command)

    cond do
      is_nil(executable) ->
        deps.print.("Total Recall CLI not found on PATH. The generated workflow enables shared memory by default; install `#{command}` before first run to activate it.")

        {:ok,
         %{
           enabled: true,
           command: command,
           verify_evidence: true,
           install_during_init: true
         }}

      total_recall_ready?(deps, executable, project_root) ->
        deps.print.("Detected Total Recall at #{executable}.")

        {:ok,
         %{
           enabled: true,
           command: command,
           verify_evidence: true,
           install_during_init: true
         }}

      true ->
        deps.print.("Detected Total Recall at #{executable} but it is not initialized for this project. Running `#{command} install`.")

        case deps.run_command.(executable, ["install"], cd: project_root, stderr_to_stdout: true) do
          {_output, 0} ->
            deps.print.("Total Recall install completed for this project.")

          {output, _status} ->
            deps.print.(
              "Total Recall install did not complete cleanly. Shared memory stays enabled in the workflow, but agents may need to record `unavailable` status until setup is fixed. Output: #{String.trim(to_string(output))}"
            )
        end

        {:ok,
         %{
           enabled: true,
           command: command,
           verify_evidence: true,
           install_during_init: true
         }}
    end
  end

  defp total_recall_ready?(deps, executable, project_root) do
    case deps.run_command.(executable, ["status"], cd: project_root, stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp discover_repositories(project_root) do
    repositories =
      project_root
      |> repository_scan_paths()
      |> Enum.filter(&git_repository_directory?/1)
      |> Enum.map(&build_discovered_repository(&1, project_root))
      |> Enum.sort_by(& &1.path)

    {:ok, repositories}
  rescue
    error ->
      {:error, {:repository_discovery_failed, Exception.message(error)}}
  end

  defp repository_scan_paths(project_root) do
    child_directories =
      project_root
      |> File.ls!()
      |> Enum.map(&Path.join(project_root, &1))
      |> Enum.filter(&File.dir?/1)
      |> Enum.reject(&ignored_repository_scan_path?/1)

    [project_root | child_directories]
  end

  defp ignored_repository_scan_path?(path) do
    name = Path.basename(path)
    String.starts_with?(name, ".") or name in ["node_modules", "_build", "deps"]
  end

  defp git_repository_directory?(path) do
    File.exists?(Path.join(path, ".git"))
  end

  defp build_discovered_repository(path, project_root) do
    relative_path = Path.relative_to(path, project_root)
    name = if(relative_path == ".", do: Path.basename(project_root), else: Path.basename(path))

    %{
      name: name,
      source: path,
      path: if(relative_path == ".", do: ".", else: relative_path),
      tags: infer_repository_tags(name)
    }
  end

  defp infer_repository_tags(name) do
    name
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.uniq()
  end

  defp analyze_repository(repository) do
    source = Map.fetch!(repository, :source)
    branch = Map.get(repository, :branch)

    case local_repository_source(source) do
      {:ok, path} ->
        inspect_repository_path(path)

      :error ->
        inspect_repository_via_git(source, branch)
    end
  end

  defp local_repository_source(source) when is_binary(source) do
    expanded =
      if String.starts_with?(source, "~") do
        Path.expand(source)
      else
        Path.expand(source, File.cwd!())
      end

    if File.dir?(expanded), do: {:ok, expanded}, else: :error
  end

  defp inspect_repository_via_git(source, branch) do
    temp_root = System.tmp_dir!()
    temp_path = Path.join(temp_root, "symphony-repo-inspect-#{System.unique_integer([:positive])}")

    case System.cmd("git", clone_args(source, branch, temp_path), stderr_to_stdout: true) do
      {_output, 0} ->
        try do
          inspect_repository_path(temp_path)
        after
          File.rm_rf(temp_path)
        end

      {output, status} ->
        File.rm_rf(temp_path)
        {:error, {:git_clone_failed, status, String.trim(output)}}
    end
  end

  defp clone_args(source, nil, temp_path), do: ["clone", "--depth", "1", "--quiet", source, temp_path]

  defp clone_args(source, branch, temp_path) do
    ["clone", "--depth", "1", "--branch", branch, "--single-branch", "--quiet", source, temp_path]
  end

  defp inspect_repository_path(path) do
    files = root_file_set(path)
    kind = detect_repository_kind(path, files)

    {:ok,
     %{
       kind: kind,
       summary: repository_kind_summary(kind),
       instructions: repository_kind_instructions(kind, files)
     }}
  end

  defp root_file_set(path) do
    path
    |> File.ls!()
    |> MapSet.new()
  end

  defp detect_repository_kind(path, files) do
    cond do
      has_xcode_project?(path) or MapSet.member?(files, "Package.swift") ->
        detect_apple_kind(path, files)

      MapSet.member?(files, "mix.exs") ->
        :elixir

      MapSet.member?(files, "package.json") ->
        detect_node_kind(path)

      MapSet.member?(files, "pyproject.toml") or MapSet.member?(files, "requirements.txt") ->
        :python

      MapSet.member?(files, "Cargo.toml") ->
        :rust

      MapSet.member?(files, "go.mod") ->
        :go

      MapSet.member?(files, "Gemfile") ->
        :ruby

      true ->
        :generic
    end
  end

  defp detect_apple_kind(path, files) do
    cond do
      has_xcode_project?(path) or has_swift_ui_app_entry?(path) ->
        :apple_app

      MapSet.member?(files, "Package.swift") ->
        :swift_package

      true ->
        :apple_app
    end
  end

  defp detect_node_kind(path) do
    package_json =
      path
      |> Path.join("package.json")
      |> File.read()
      |> case do
        {:ok, contents} -> Jason.decode(contents)
        _ -> {:error, :invalid_package_json}
      end

    case package_json do
      {:ok, decoded} when is_map(decoded) ->
        dependency_names =
          decoded
          |> Map.take(["dependencies", "devDependencies", "peerDependencies"])
          |> Map.values()
          |> Enum.filter(&is_map/1)
          |> Enum.flat_map(&Map.keys/1)
          |> MapSet.new()

        cond do
          MapSet.member?(dependency_names, "expo") or MapSet.member?(dependency_names, "react-native") ->
            :react_native

          MapSet.member?(dependency_names, "next") or MapSet.member?(dependency_names, "react") ->
            :web_app

          true ->
            :node
        end

      _ ->
        :node
    end
  end

  defp has_xcode_project?(path) do
    Path.wildcard(Path.join(path, "*.xcodeproj")) != [] or
      Path.wildcard(Path.join(path, "*.xcworkspace")) != []
  end

  defp has_swift_ui_app_entry?(path) do
    path
    |> Path.join("**/*.swift")
    |> Path.wildcard()
    |> Enum.take(50)
    |> Enum.any?(fn file ->
      case File.read(file) do
        {:ok, contents} -> String.contains?(contents, "@main") and String.contains?(contents, "App")
        _ -> false
      end
    end)
  end

  defp repository_kind_summary(:apple_app), do: "Apple app repo (Xcode/SwiftUI/UIKit)"
  defp repository_kind_summary(:swift_package), do: "Swift package or Apple library repo"
  defp repository_kind_summary(:elixir), do: "Elixir or Phoenix repo"
  defp repository_kind_summary(:react_native), do: "React Native / Expo app repo"
  defp repository_kind_summary(:web_app), do: "JavaScript or TypeScript web app repo"
  defp repository_kind_summary(:node), do: "Node package or service repo"
  defp repository_kind_summary(:python), do: "Python repo"
  defp repository_kind_summary(:rust), do: "Rust repo"
  defp repository_kind_summary(:go), do: "Go repo"
  defp repository_kind_summary(:ruby), do: "Ruby repo"
  defp repository_kind_summary(:generic), do: "Generic code repository"

  defp repository_kind_instructions(:apple_app, _files) do
    [
      "Prefer xcodebuild, xcrun, and simctl-based validation over ad-hoc scripts.",
      "If app behavior changes, run simulator-backed checks when available.",
      "Keep build outputs such as DerivedData inside the issue workspace rather than global locations."
    ]
  end

  defp repository_kind_instructions(:swift_package, _files) do
    [
      "Prefer swift test or the narrowest package-level validation available in the repo.",
      "Treat this as a library by default: validate the changed API surface instead of trying to boot an app unless the issue clearly requires it.",
      "Keep changes scoped to the package modules that match the ticket."
    ]
  end

  defp repository_kind_instructions(:elixir, _files) do
    [
      "Use mix tasks for validation and prefer the narrowest relevant test or compile command.",
      "Respect mix.exs, umbrella boundaries, and OTP application structure already present in the repo.",
      "Update docs or configuration in the same change when behavior changes."
    ]
  end

  defp repository_kind_instructions(:react_native, files) do
    package_manager = preferred_package_manager(files)

    [
      "Use #{package_manager} for installs and validation commands when the repo already uses it.",
      "Treat mobile flows as first-class validation targets when UI or runtime behavior changes.",
      "Prefer targeted app checks over generic Node-only validation when the ticket touches the mobile surface."
    ]
  end

  defp repository_kind_instructions(:web_app, files) do
    package_manager = preferred_package_manager(files)

    [
      "Use #{package_manager} for installs and validation commands when the repo already uses it.",
      "If the issue changes user-facing behavior, validate the affected user path instead of relying only on static checks.",
      "Prefer targeted test, lint, or build commands that match the changed area."
    ]
  end

  defp repository_kind_instructions(:node, files) do
    package_manager = preferred_package_manager(files)

    [
      "Use #{package_manager} and the existing package scripts already defined by the repo.",
      "Prefer targeted test or build commands over broad full-project runs when a narrower signal exists.",
      "Keep changes within the package or service boundary described by the issue."
    ]
  end

  defp repository_kind_instructions(:python, _files) do
    [
      "Prefer repo-local tooling such as pytest, tox, or pyproject-defined tasks over ad-hoc commands.",
      "Use the narrowest validation command that covers the changed modules.",
      "Respect the repo's existing environment and dependency management conventions."
    ]
  end

  defp repository_kind_instructions(:rust, _files) do
    [
      "Prefer cargo test, cargo check, and cargo fmt as the main validation surface.",
      "Keep changes scoped to the affected crate or module instead of broad cross-repo edits.",
      "Use compiler and test signals as the primary correctness check."
    ]
  end

  defp repository_kind_instructions(:go, _files) do
    [
      "Prefer go test on the narrowest relevant package set before broader runs.",
      "Keep changes within the package boundaries indicated by the issue.",
      "Use the repo's existing module and tooling structure rather than inventing a new layout."
    ]
  end

  defp repository_kind_instructions(:ruby, _files) do
    [
      "Use bundle exec with the repo's existing test and lint commands.",
      "Prefer targeted validation for the changed area before broad suite runs.",
      "Respect the framework conventions already present in the repo."
    ]
  end

  defp repository_kind_instructions(:generic, _files) do
    [
      "Start by inspecting the repo-local build and test configuration before changing code.",
      "Use the smallest validation command that proves the change.",
      "Keep changes scoped to the repo and directories that clearly match the issue."
    ]
  end

  defp preferred_package_manager(files) do
    cond do
      MapSet.member?(files, "pnpm-lock.yaml") -> "pnpm"
      MapSet.member?(files, "yarn.lock") -> "yarn"
      MapSet.member?(files, "package-lock.json") -> "npm"
      true -> "the repo's configured package manager"
    end
  end

  defp normalize_repository_analysis(repository, analysis) do
    fallback = generic_repository_analysis(repository)

    %{
      kind: Map.get(analysis, :kind, Map.get(analysis, "kind", fallback.kind)),
      summary: Map.get(analysis, :summary, Map.get(analysis, "summary", fallback.summary)),
      instructions:
        Map.get(
          analysis,
          :instructions,
          Map.get(analysis, "instructions", fallback.instructions)
        )
    }
  end

  defp generic_repository_analysis(repository) do
    %{
      kind: :generic,
      summary: "Generic repo guidance for #{repository.name}",
      instructions: repository_kind_instructions(:generic, MapSet.new())
    }
  end

  defp map_fs_error(:ok, _action), do: :ok
  defp map_fs_error({:error, reason}, action), do: {:error, "Failed to #{action}: #{inspect(reason)}"}

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
