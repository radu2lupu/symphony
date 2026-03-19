defmodule SymphonyElixir.RepoRegistry do
  @moduledoc """
  Persists the local repository registry used for multi-repo routing.
  """

  alias SymphonyElixir.Config

  @type repository :: %{
          name: String.t(),
          source: String.t(),
          branch: String.t() | nil,
          path: String.t() | nil,
          tags: [String.t()],
          origin: atom(),
          registered_at: String.t() | nil,
          source_issue_id: String.t() | nil,
          source_issue_identifier: String.t() | nil
        }

  @spec path() :: Path.t()
  def path do
    Config.workspace_registry_path()
  end

  @spec list_repositories() :: [repository()]
  def list_repositories do
    case File.read(path()) do
      {:ok, content} ->
        content
        |> Jason.decode()
        |> decode_registry()

      {:error, :enoent} ->
        []

      {:error, _reason} ->
        []
    end
  end

  @spec upsert_repository(map(), map() | nil) :: {:ok, repository()} | {:error, term()}
  def upsert_repository(repository, issue \\ nil) when is_map(repository) do
    normalized = normalize_repository(repository, issue)
    repositories = list_repositories()

    updated =
      repositories
      |> Enum.reject(&(normalize_name(&1.name) == normalize_name(normalized.name)))
      |> Kernel.++([normalized])
      |> Enum.sort_by(&normalize_name(&1.name))

    with :ok <- File.mkdir_p(Path.dirname(path())),
         :ok <- File.write(path(), Jason.encode_to_iodata!(%{version: 1, repositories: updated})) do
      {:ok, normalized}
    end
  end

  defp decode_registry({:ok, %{"repositories" => repositories}}) when is_list(repositories) do
    Enum.map(repositories, &normalize_repository(&1, nil))
  end

  defp decode_registry(_result), do: []

  defp normalize_repository(repository, issue) do
    %{
      name: repository_value(repository, "name"),
      source: repository_value(repository, "source"),
      branch: repository_optional_value(repository, "branch"),
      path: repository_optional_value(repository, "path"),
      tags: normalize_tags(Map.get(repository, "tags") || Map.get(repository, :tags) || []),
      origin: normalize_origin(Map.get(repository, "origin") || Map.get(repository, :origin) || :registry),
      registered_at: repository_optional_value(repository, "registered_at") || DateTime.utc_now() |> DateTime.to_iso8601(),
      source_issue_id: repository_optional_value(repository, "source_issue_id") || issue_value(issue, :id),
      source_issue_identifier: repository_optional_value(repository, "source_issue_identifier") || issue_value(issue, :identifier)
    }
  end

  defp repository_value(repository, key) do
    repository_optional_value(repository, key) || ""
  end

  defp repository_optional_value(repository, key) do
    repository
    |> Map.get(key)
    |> case do
      nil -> Map.get(repository, existing_atom_key(key))
      value -> value
    end
    |> normalize_string()
  end

  defp normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_tags(_tags), do: []

  defp normalize_origin(value) when value in [:workflow, "workflow"], do: :workflow
  defp normalize_origin(_value), do: :registry

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_value), do: nil

  defp issue_value(nil, _key), do: nil
  defp issue_value(issue, key), do: issue |> Map.get(key) |> normalize_string()

  defp existing_atom_key("name"), do: :name
  defp existing_atom_key("source"), do: :source
  defp existing_atom_key("branch"), do: :branch
  defp existing_atom_key("path"), do: :path
  defp existing_atom_key("registered_at"), do: :registered_at
  defp existing_atom_key("source_issue_id"), do: :source_issue_id
  defp existing_atom_key("source_issue_identifier"), do: :source_issue_identifier
  defp existing_atom_key(_key), do: nil

  defp normalize_name(name) when is_binary(name), do: String.downcase(String.trim(name))
  defp normalize_name(_name), do: ""
end
