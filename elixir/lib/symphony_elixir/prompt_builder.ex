defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, RepoManager, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]
  @frontend_issue_patterns [
    {"frontend", ~r/\bfront[\s-]?end\b/i},
    {"ui", ~r/\bui\b/i},
    {"ux", ~r/\bux\b/i},
    {"screen", ~r/\bscreen\b/i},
    {"view", ~r/\bview\b/i},
    {"component", ~r/\bcomponent\b/i},
    {"page", ~r/\bpage\b/i},
    {"layout", ~r/\blayout\b/i},
    {"style", ~r/\bstyle|styling\b/i},
    {"css", ~r/\bcss\b/i},
    {"html", ~r/\bhtml\b/i},
    {"react", ~r/\breact\b/i},
    {"tailwind", ~r/\btailwind\b/i},
    {"swiftui", ~r/\bswiftui\b/i},
    {"animation", ~r/\banimation\b/i},
    {"visual", ~r/\bvisual\b/i},
    {"icon", ~r/\bicon\b/i},
    {"button", ~r/\bbutton\b/i},
    {"menu bar", ~r/\bmenu\s+bar\b/i},
    {"notch", ~r/\bnotch\b/i},
    {"landing", ~r/\blanding\b/i},
    {"website", ~r/\bwebsite\b/i},
    {"web", ~r/\bweb\b/i},
    {"responsive", ~r/\bresponsive\b/i}
  ]
  @frontend_repo_patterns [
    {"frontend repo", ~r/\bfront[\s-]?end\b/i},
    {"ui repo", ~r/\bui\b/i},
    {"design system repo", ~r/\bdesign\b/i},
    {"web repo", ~r/\bweb\b/i},
    {"website repo", ~r/\bwebsite\b/i},
    {"landing repo", ~r/\blanding\b/i},
    {"swiftui repo", ~r/\bswiftui\b/i},
    {"ios repo", ~r/\bios\b/i},
    {"android repo", ~r/\bandroid\b/i},
    {"mobile repo", ~r/\bmobile\b/i}
  ]
  @frontend_visual_patterns [
    {"screen", ~r/\bscreen\b/i},
    {"view", ~r/\bview\b/i},
    {"component", ~r/\bcomponent\b/i},
    {"layout", ~r/\blayout\b/i},
    {"icon", ~r/\bicon\b/i},
    {"button", ~r/\bbutton\b/i},
    {"menu bar", ~r/\bmenu\s+bar\b/i},
    {"notch", ~r/\bnotch\b/i},
    {"animation", ~r/\banimation\b/i},
    {"visual", ~r/\bvisual\b/i}
  ]
  @complexity_patterns ~r/\b(migration|redesign|architecture|workflow|multi[\s-]?repo|platform|refactor|integration|end[\s-]?to[\s-]?end|rollout|simulator)\b/i
  @acceptance_patterns ~r/\b(acceptance|criteria|validation|test plan|testing|expected|should|must|when|then|done when)\b/i
  @ambiguous_patterns ~r/\b(fix|improve|clean[\s-]?up|support|update|refactor|investigate|handle|polish)\b/i

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    workspace = Keyword.get(opts, :workspace)
    repositories = Keyword.get(opts, :repositories) || RepoManager.available_repositories(workspace)

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map(),
        "workspace" => workspace_context(workspace, repositories),
        "guidance" => guidance_context(issue, repositories),
        "memory" => memory_context()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp guidance_context(issue, repositories) do
    signals = frontend_signals(issue, repositories)
    spec_detail_level = spec_detail_level(issue, repositories, signals != [])
    clarification_points = clarification_points(issue)

    %{
      "frontend_artifact_required" => signals != [],
      "frontend_signals" => signals,
      "frontend_signal_summary" => Enum.join(signals, ", "),
      "spec_detail_level" => spec_detail_level,
      "clarification_required" => clarification_points != [],
      "clarification_points" => clarification_points,
      "execution_approval_required" => clarification_points != [] or spec_detail_level in ["standard", "detailed"],
      "planning_state" => Config.preferred_planning_state()
    }
  end

  defp spec_detail_level(issue, repositories, frontend_task?) do
    issue_text = issue_text(issue)
    issue_word_count = word_count(issue_text)
    repo_count = length(List.wrap(repositories))
    label_count = issue.labels |> List.wrap() |> length()

    score =
      0
      |> increment_if(repo_count > 1, 2)
      |> increment_if(issue_word_count > 80, 2)
      |> increment_if(issue_word_count > 30, 1)
      |> increment_if(label_count >= 3, 1)
      |> increment_if(frontend_task?, 1)
      |> increment_if(Regex.match?(@complexity_patterns, issue_text), 2)

    cond do
      score >= 4 -> "detailed"
      score >= 2 -> "standard"
      true -> "minimal"
    end
  end

  defp clarification_points(issue) do
    issue_text = issue_text(issue)
    description = issue.description |> to_string() |> String.trim()
    title = issue.title |> to_string() |> String.trim()

    []
    |> maybe_add_point(description == "", "The issue description is missing, so scope and expected outcome are not explicit yet.")
    |> maybe_add_point(
      description != "" and not Regex.match?(@acceptance_patterns, issue_text),
      "No explicit acceptance criteria, validation plan, or expected result is described yet."
    )
    |> maybe_add_point(
      Regex.match?(@ambiguous_patterns, issue_text) and word_count("#{title} #{description}") < 35,
      "The ask is phrased in a generic way and needs clarification before implementation tradeoffs can be chosen."
    )
  end

  defp frontend_signals(issue, repositories) do
    issue_text = issue_text(issue)

    repo_text =
      repositories
      |> List.wrap()
      |> Enum.flat_map(fn repository ->
        [Map.get(repository, :name) || Map.get(repository, "name"), Map.get(repository, :tags) || Map.get(repository, "tags")]
      end)
      |> List.flatten()
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n")

    issue_matches = matching_signals(issue_text, @frontend_issue_patterns)
    repo_matches = matching_signals(repo_text, @frontend_repo_patterns)
    visual_matches = matching_signals(issue_text, @frontend_visual_patterns)

    direct_matches = issue_matches

    contextual_matches =
      if repo_matches != [] and visual_matches != [] do
        repo_matches ++ visual_matches
      else
        []
      end

    (direct_matches ++ contextual_matches)
    |> Enum.uniq()
  end

  defp issue_text(issue) do
    [issue.title, issue.description, issue.labels]
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp matching_signals(text, patterns) when is_binary(text) do
    Enum.flat_map(patterns, fn {label, regex} ->
      if Regex.match?(regex, text), do: [label], else: []
    end)
  end

  defp workspace_context(workspace, repositories) do
    %{
      "path" => workspace,
      "repositories" => (repositories || RepoManager.available_repositories(workspace)) |> Enum.map(&to_solid_map/1)
    }
  end

  defp memory_context do
    %{
      "total_recall" => %{
        "enabled" => Config.total_recall_enabled?(),
        "command" => Config.total_recall_command(),
        "verify_evidence" => Config.verify_total_recall_evidence?()
      }
    }
  end

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end

  defp maybe_add_point(points, true, point), do: points ++ [point]
  defp maybe_add_point(points, false, _point), do: points

  defp increment_if(score, true, amount), do: score + amount
  defp increment_if(score, false, _amount), do: score

  defp word_count(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end
end
