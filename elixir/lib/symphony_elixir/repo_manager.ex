defmodule SymphonyElixir.RepoManager do
  @moduledoc """
  Combines workflow-configured and locally-registered repositories, resolves
  issue routing, and handles repo registration control issues.
  """

  alias SymphonyElixir.{Config, Linear.Issue, RepoRegistry, Tracker}

  @register_repo_label "symphony:register-repo"
  @register_repo_title_prefix "register repo:"
  @explicit_repo_label_prefix "repo:"

  @type repository :: map()

  @spec control_issue?(Issue.t()) :: boolean()
  def control_issue?(%Issue{} = issue) do
    register_repo_label?(issue) or register_repo_title?(issue.title)
  end

  @spec available_repositories(Path.t() | nil) :: [repository()]
  def available_repositories(workspace \\ nil) do
    workflow_repositories =
      Config.workspace_repositories(workspace)
      |> Enum.map(&Map.put(&1, :origin, :workflow))

    registered_repositories =
      RepoRegistry.list_repositories()
      |> Enum.map(fn repository ->
        relative_path = normalize_registered_path(repository)

        %{
          name: repository.name,
          source: repository.source,
          branch: repository.branch,
          tags: repository.tags,
          relative_path: relative_path,
          path: absolute_path(workspace, relative_path),
          primary: relative_path == ".",
          origin: :registry
        }
      end)

    (workflow_repositories ++ registered_repositories)
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn repository, acc ->
      Map.put_new(acc, normalize_name(repository.name), repository)
    end)
    |> Map.values()
    |> Enum.sort_by(fn repository -> {repository.primary != true, normalize_name(repository.name)} end)
  end

  def routed_repositories(issue, workspace \\ nil)

  @spec routed_repositories(Issue.t() | nil, Path.t() | nil) :: [repository()]
  def routed_repositories(nil, workspace), do: available_repositories(workspace)

  def routed_repositories(%Issue{} = issue, workspace) do
    repositories = available_repositories(workspace)

    cond do
      repositories == [] ->
        []

      explicit_label_matches(issue, repositories) != [] ->
        explicit_label_matches(issue, repositories)

      tag_matches(issue, repositories) != [] ->
        tag_matches(issue, repositories)

      text_matches(issue, repositories) != [] ->
        text_matches(issue, repositories)

      true ->
        repositories
    end
  end

  @spec register_repository_issue(Issue.t()) :: {:ok, repository()} | {:error, term()}
  def register_repository_issue(%Issue{} = issue) do
    with {:ok, repository} <- parse_repository_registration(issue),
         :ok <- validate_registration_conflicts(repository),
         {:ok, registered} <- RepoRegistry.upsert_repository(repository, issue),
         :ok <- maybe_comment_on_issue(issue, registered),
         :ok <- maybe_complete_issue(issue) do
      {:ok, registered}
    end
  end

  @spec registration_comment(repository()) :: String.t()
  def registration_comment(repository) do
    tags =
      case repository.tags do
        [] -> "none"
        values -> Enum.join(values, ", ")
      end

    [
      "Registered repo `#{repository.name}` for future Symphony work.",
      "",
      "- source: `#{repository.source}`",
      "- path: `#{repository.path || repository.name}`",
      "- branch: `#{repository.branch || "default"}`",
      "- tags: `#{tags}`"
    ]
    |> Enum.join("\n")
  end

  defp parse_repository_registration(%Issue{} = issue) do
    with {:ok, payload} <- decode_issue_payload(issue.description),
         repository <- payload["repo"] || payload,
         true <- is_map(repository) do
      normalized = normalize_registration_map(repository, issue)

      cond do
        normalized.name == nil ->
          {:error, :missing_repository_name}

        normalized.source == nil ->
          {:error, :missing_repository_source}

        true ->
          {:ok, normalized}
      end
    else
      false -> {:error, :invalid_repository_registration}
      {:error, _reason} = error -> error
    end
  end

  defp decode_issue_payload(nil), do: {:error, :missing_repository_registration}

  defp decode_issue_payload(description) when is_binary(description) do
    yaml =
      case Regex.run(~r/```ya?ml\s*(.*?)```/ms, description, capture: :all_but_first) do
        [block] -> block
        _ -> description
      end

    case YamlElixir.read_from_string(yaml) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, :invalid_repository_registration}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_registration_map(repository, issue) do
    %{
      name:
        repository["name"] ||
          repository[:name] ||
          register_repo_name_from_title(issue.title),
      source:
        repository["source"] ||
          repository[:source] ||
          repository["url"] ||
          repository[:url] ||
          repository["remote"] ||
          repository[:remote],
      branch: repository["branch"] || repository[:branch],
      path: repository["path"] || repository[:path],
      tags: repository["tags"] || repository[:tags] || []
    }
    |> Enum.into(%{}, fn {key, value} ->
      {key, normalize_registration_value(key, value)}
    end)
  end

  defp validate_registration_conflicts(repository) do
    relative_path = repository.path || repository.name
    normalized_name = normalize_name(repository.name)

    case Enum.find(available_repositories(nil), fn existing ->
           normalize_name(existing.name) != normalized_name and
             existing.relative_path == relative_path
         end) do
      nil -> :ok
      existing -> {:error, {:repository_path_conflict, existing.name, relative_path}}
    end
  end

  defp normalize_registration_value(:tags, tags) when is_list(tags) do
    tags
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_registration_value(_key, value), do: normalize_string(value)

  defp maybe_comment_on_issue(%Issue{id: issue_id}, repository) when is_binary(issue_id) do
    Tracker.create_comment(issue_id, registration_comment(repository))
  end

  defp maybe_comment_on_issue(_issue, _repository), do: :ok

  defp maybe_complete_issue(%Issue{id: issue_id}) when is_binary(issue_id) do
    Tracker.update_issue_state(issue_id, completion_state())
  end

  defp maybe_complete_issue(_issue), do: :ok

  defp completion_state do
    tracker = Config.settings!().tracker

    Enum.find(tracker.terminal_states, &(normalize_state(&1) == "done")) ||
      List.first(tracker.terminal_states) ||
      "Done"
  end

  defp explicit_label_matches(issue, repositories) do
    explicit_names =
      issue.labels
      |> List.wrap()
      |> Enum.map(&normalize_string/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(fn label ->
        if String.starts_with?(String.downcase(label), @explicit_repo_label_prefix) do
          [String.slice(label, String.length(@explicit_repo_label_prefix)..-1//1) |> normalize_name()]
        else
          []
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.filter(repositories, fn repository ->
      MapSet.member?(explicit_names, normalize_name(repository.name))
    end)
  end

  defp tag_matches(issue, repositories) do
    issue_labels =
      issue.labels
      |> List.wrap()
      |> Enum.map(&normalize_name/1)
      |> MapSet.new()

    Enum.filter(repositories, fn repository ->
      repository.tags
      |> List.wrap()
      |> Enum.map(&normalize_name/1)
      |> Enum.any?(&MapSet.member?(issue_labels, &1))
    end)
  end

  defp text_matches(%Issue{} = issue, repositories) do
    haystack =
      [issue.title, issue.description]
      |> Enum.map(&normalize_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    Enum.filter(repositories, fn repository ->
      [repository.name | List.wrap(repository.tags)]
      |> Enum.map(&normalize_name/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.any?(&text_contains_term?(haystack, &1))
    end)
  end

  defp text_contains_term?("", _term), do: false
  defp text_contains_term?(_haystack, ""), do: false

  defp text_contains_term?(haystack, term) do
    Regex.match?(~r/(^|[^a-z0-9])#{Regex.escape(term)}([^a-z0-9]|$)/, haystack)
  end

  defp register_repo_label?(%Issue{labels: labels}) do
    Enum.any?(labels || [], fn label -> normalize_name(label) == normalize_name(@register_repo_label) end)
  end

  defp register_repo_title?(title) when is_binary(title) do
    String.starts_with?(normalize_name(title), @register_repo_title_prefix)
  end

  defp register_repo_title?(_title), do: false

  defp register_repo_name_from_title(title) when is_binary(title) do
    trimmed = String.trim(title)

    if register_repo_title?(trimmed) do
      trimmed
      |> String.slice(String.length(@register_repo_title_prefix)..-1//1)
      |> normalize_string()
    else
      nil
    end
  end

  defp register_repo_name_from_title(_title), do: nil

  defp normalize_registered_path(repository) do
    repository.path || repository.name
  end

  defp absolute_path(nil, _relative_path), do: nil
  defp absolute_path(workspace, relative_path), do: Path.expand(relative_path, workspace)

  defp normalize_text(nil), do: ""

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
  end

  defp normalize_text(_value), do: ""

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_value), do: nil

  defp normalize_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_name(_value), do: ""

  defp normalize_state(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_value), do: ""
end
