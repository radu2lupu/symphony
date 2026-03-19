defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.PathSafety

  @primary_key false

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:project_url, :string)
      field(:sync_project_states, :boolean, default: true)
      field(:assignee, :string)
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
      field(:planning_states, {:array, :string}, default: ["Spec Review", "Needs Clarification", "Planning"])
      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:kind, :endpoint, :api_key, :project_slug, :project_url, :sync_project_states, :assignee, :active_states, :planning_states, :terminal_states],
        empty_values: []
      )
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    defmodule Repository do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false
      embedded_schema do
        field(:name, :string)
        field(:source, :string)
        field(:path, :string)
        field(:branch, :string)
        field(:tags, {:array, :string}, default: [])
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [:name, :source, :path, :branch, :tags], empty_values: [])
        |> validate_required([:name, :source])
        |> validate_change(:name, &validate_non_blank_string/2)
        |> validate_change(:source, &validate_non_blank_string/2)
        |> validate_change(:path, &validate_relative_repository_path/2)
      end

      defp validate_non_blank_string(field, value) when is_binary(value) do
        if String.trim(value) == "" do
          [{field, "must not be blank"}]
        else
          []
        end
      end

      defp validate_non_blank_string(_field, _value), do: []

      defp validate_relative_repository_path(_field, value) when value in [nil, ""], do: []

      defp validate_relative_repository_path(field, value) when is_binary(value) do
        expanded = Path.expand(value, "/workspace")

        cond do
          Path.type(value) == :absolute ->
            [{field, "must stay inside the issue workspace"}]

          expanded != "/workspace" and not String.starts_with?(expanded <> "/", "/workspace/") ->
            [{field, "must stay inside the issue workspace"}]

          true ->
            []
        end
      end

      defp validate_relative_repository_path(_field, _value), do: []
    end

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
      field(:registry_path, :string)
      embeds_many(:repositories, Repository, on_replace: :delete)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root, :registry_path], empty_values: [])
      |> cast_embed(:repositories, with: &Repository.changeset/2)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:max_concurrent_agents, :max_turns, :max_retry_backoff_ms, :max_concurrent_agents_by_state],
        empty_values: []
      )
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Memory do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    defmodule TotalRecall do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false
      embedded_schema do
        field(:enabled, :boolean, default: true)
        field(:command, :string, default: "total-recall")
        field(:verify_evidence, :boolean, default: true)
        field(:install_during_init, :boolean, default: true)
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [:enabled, :command, :verify_evidence, :install_during_init], empty_values: [])
        |> validate_required([:command])
        |> validate_change(:command, &validate_non_blank_string/2)
      end

      defp validate_non_blank_string(field, value) when is_binary(value) do
        if String.trim(value) == "" do
          [{field, "must not be blank"}]
        else
          []
        end
      end

      defp validate_non_blank_string(_field, _value), do: []
    end

    @primary_key false
    embedded_schema do
      embeds_one(:total_recall, TotalRecall, on_replace: :update, defaults_to_struct: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [])
      |> cast_embed(:total_recall, with: &TotalRecall.changeset/2)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:memory, Memory, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        default_turn_sandbox_policy(workspace || settings.workspace.root)
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        default_runtime_turn_sandbox_policy(workspace || settings.workspace.root)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:memory, with: &Memory.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
  end

  defp finalize_settings(settings) do
    tracker_project = resolve_tracker_project(settings.tracker.project_slug, settings.tracker.project_url)

    tracker = %{
      settings.tracker
      | api_key: resolve_secret_setting(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE")),
        project_slug: tracker_project.slug,
        project_url: tracker_project.url
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces")),
        registry_path:
          resolve_registry_path(
            settings.workspace.registry_path,
            settings.workspace.root,
            Path.join(Path.join(System.tmp_dir!(), "symphony_workspaces"), ".symphony_repo_registry.json")
          ),
        repositories: finalize_workspace_repositories(settings.workspace.repositories || [])
    }

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    %{settings | tracker: tracker, workspace: workspace, codex: codex}
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        Path.expand(default)

      "" ->
        Path.expand(default)

      path ->
        Path.expand(path)
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
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

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp resolve_tracker_project(project_slug_value, project_url_value) do
    project_slug =
      case project_slug_value do
        value when is_binary(value) ->
          value
          |> resolve_env_value(nil)
          |> normalize_repository_string()

        _ ->
          nil
      end

    project_url =
      case project_url_value do
        value when is_binary(value) ->
          value
          |> resolve_env_value(nil)
          |> normalize_repository_string()

        _ ->
          nil
      end

    cond do
      is_binary(project_url) ->
        %{
          slug: extract_linear_project_slug(project_url) || project_slug,
          url: project_url
        }

      is_binary(project_slug) and String.contains?(project_slug, "/project/") ->
        %{
          slug: extract_linear_project_slug(project_slug),
          url: project_slug
        }

      true ->
        %{slug: project_slug, url: nil}
    end
  end

  defp extract_linear_project_slug(value) when is_binary(value) do
    case Regex.run(~r{/project/([^/?#]+)}, value) do
      [_, project_slug] -> extract_linear_project_slug_id(project_slug)
      _ -> nil
    end
  end

  defp extract_linear_project_slug_id(project_slug) when is_binary(project_slug) do
    case Regex.run(~r/-([a-f0-9]{8,})$/i, project_slug) do
      [_, slug_id] -> slug_id
      _ -> project_slug
    end
  end

  defp finalize_workspace_repositories(repositories) when is_list(repositories) do
    Enum.map(repositories, fn repository ->
      %{
        repository
        | source: resolve_repository_source(repository.source),
          path: resolve_repository_path(repository.path),
          branch: resolve_repository_string(repository.branch),
          tags: finalize_repository_tags(repository.tags || [])
      }
    end)
  end

  defp resolve_repository_source(value) when is_binary(value) do
    value
    |> resolve_env_value(nil)
    |> normalize_repository_string()
    |> maybe_expand_local_repository_source()
  end

  defp resolve_repository_source(_value), do: nil

  defp resolve_repository_path(value) when is_binary(value) do
    value
    |> resolve_env_value(nil)
    |> normalize_repository_string()
  end

  defp resolve_repository_path(_value), do: nil

  defp resolve_repository_string(value) when is_binary(value) do
    value
    |> resolve_env_value(nil)
    |> normalize_repository_string()
  end

  defp resolve_repository_string(_value), do: nil

  defp finalize_repository_tags(tags) when is_list(tags) do
    tags
    |> Enum.map(&normalize_repository_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp finalize_repository_tags(_tags), do: []

  defp normalize_repository_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_repository_string(_value), do: nil

  defp maybe_expand_local_repository_source(nil), do: nil

  defp maybe_expand_local_repository_source(value) when is_binary(value) do
    if String.starts_with?(value, ["~", ".", "/"]) do
      Path.expand(value)
    else
      value
    end
  end

  defp resolve_registry_path(value, workspace_root, default) when is_binary(value) do
    case value |> resolve_env_value(nil) |> normalize_repository_string() do
      nil ->
        resolve_registry_path(nil, workspace_root, default)

      path ->
        if Path.type(path) == :absolute do
          Path.expand(path)
        else
          Path.expand(
            path,
            resolve_path_value(workspace_root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
          )
        end
    end
  end

  defp resolve_registry_path(_value, workspace_root, default) do
    resolve_registry_path(default, workspace_root, default)
  end

  defp default_turn_sandbox_policy(workspace) do
    writable_root =
      if is_binary(workspace) and workspace != "" do
        Path.expand(workspace)
      else
        Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
      end

    %{
      "type" => "workspaceWrite",
      "writableRoots" => [writable_root],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => true,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root) when is_binary(workspace_root) do
    with {:ok, canonical_workspace_root} <- PathSafety.canonicalize(workspace_root) do
      {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
