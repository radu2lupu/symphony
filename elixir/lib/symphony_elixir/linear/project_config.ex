defmodule SymphonyElixir.Linear.ProjectConfig do
  @moduledoc """
  Resolves project-level Linear metadata needed for Symphony tracker settings.
  """

  require Logger

  @cache_table :symphony_linear_project_config_cache
  @default_cache_ttl_ms 30_000
  @state_types_active ["backlog", "unstarted", "started"]
  @state_types_terminal ["completed", "canceled"]

  @project_query """
  query SymphonyLinearProjectConfig($projectSlug: String!) {
    projects(filter: {slugId: {eq: $projectSlug}}, first: 1) {
      nodes {
        id
        url
        teams(first: 20) {
          nodes {
            id
            key
            name
            states(first: 100) {
              nodes {
                id
                name
                type
              }
            }
          }
        }
      }
    }
  }
  """

  @type tracker_settings :: %{
          required(:endpoint) => String.t(),
          required(:api_key) => String.t(),
          required(:project_slug) => String.t()
        }

  @type resolved_project_config :: %{
          project_url: String.t() | nil,
          active_states: [String.t()],
          terminal_states: [String.t()]
        }

  @spec resolve_tracker(map(), non_neg_integer()) ::
          {:ok, resolved_project_config()} | {:error, term()}
  def resolve_tracker(tracker, cache_ttl_ms \\ @default_cache_ttl_ms)
      when is_map(tracker) and is_integer(cache_ttl_ms) and cache_ttl_ms >= 0 do
    with {:ok, tracker_settings} <- normalize_tracker(tracker),
         {:ok, cached_or_fetched} <- fetch_cached_project_config(tracker_settings, cache_ttl_ms) do
      {:ok, cached_or_fetched}
    end
  end

  @spec fetch_tracker(map()) :: {:ok, resolved_project_config()} | {:error, term()}
  def fetch_tracker(tracker) when is_map(tracker) do
    with {:ok, tracker_settings} <- normalize_tracker(tracker) do
      fetch_project_config(tracker_settings)
    end
  end

  defp normalize_tracker(%{endpoint: endpoint, api_key: api_key, project_slug: project_slug})
       when is_binary(endpoint) and is_binary(api_key) and is_binary(project_slug) do
    {:ok, %{endpoint: endpoint, api_key: api_key, project_slug: project_slug}}
  end

  defp normalize_tracker(_tracker), do: {:error, :invalid_tracker}

  defp fetch_cached_project_config(tracker, cache_ttl_ms) do
    now_ms = System.monotonic_time(:millisecond)
    cache_key = cache_key(tracker)

    case lookup_cache(cache_key, now_ms, cache_ttl_ms) do
      {:ok, resolved_config} ->
        {:ok, resolved_config}

      :miss ->
        with {:ok, resolved_config} <- fetch_project_config(tracker) do
          put_cache(cache_key, now_ms, resolved_config)
          {:ok, resolved_config}
        end
    end
  end

  defp lookup_cache(cache_key, now_ms, cache_ttl_ms) do
    table = ensure_cache_table()
    effective_ttl_ms = max(cache_ttl_ms, 0)

    case :ets.lookup(table, cache_key) do
      [{^cache_key, cached_at_ms, resolved_config}] when now_ms - cached_at_ms <= effective_ttl_ms ->
        {:ok, resolved_config}

      _ ->
        :miss
    end
  end

  defp put_cache(cache_key, now_ms, resolved_config) do
    table = ensure_cache_table()
    true = :ets.insert(table, {cache_key, now_ms, resolved_config})
    :ok
  end

  defp ensure_cache_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        :ets.new(@cache_table, [:named_table, :public, read_concurrency: true])

      table ->
        table
    end
  end

  defp cache_key(tracker) do
    {tracker.endpoint, tracker.project_slug, :erlang.phash2(tracker.api_key)}
  end

  defp fetch_project_config(tracker) do
    with {:ok, response} <- post_graphql_request(tracker, @project_query, %{projectSlug: tracker.project_slug}),
         {:ok, project} <- decode_project(response),
         {:ok, states} <- decode_project_states(project) do
      {:ok,
       %{
         project_url: Map.get(project, "url"),
         active_states: states.active_states,
         terminal_states: states.terminal_states
       }}
    end
  end

  defp post_graphql_request(tracker, query, variables) do
    payload = %{"query" => query, "variables" => variables}

    case Req.post(tracker.endpoint,
           headers: [
             {"authorization", tracker.api_key},
             {"content-type", "application/json"}
           ],
           json: payload
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Linear project config request failed status=#{status} body=#{inspect(body)}")
        {:error, {:linear_api_status, status}}

      {:error, reason} ->
        Logger.error("Linear project config request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  defp decode_project(%{"data" => %{"projects" => %{"nodes" => [project | _]}}}) when is_map(project) do
    {:ok, project}
  end

  defp decode_project(%{"data" => %{"projects" => %{"nodes" => []}}}), do: {:error, :linear_project_not_found}
  defp decode_project(%{"errors" => errors}) when is_list(errors), do: {:error, {:linear_graphql_errors, errors}}
  defp decode_project(_response), do: {:error, :invalid_linear_project_response}

  defp decode_project_states(project) when is_map(project) do
    state_nodes =
      project
      |> get_in(["teams", "nodes"])
      |> List.wrap()
      |> Enum.flat_map(fn team -> get_in(team, ["states", "nodes"]) |> List.wrap() end)

    active_states = derive_states_by_type(state_nodes, @state_types_active)
    terminal_states = derive_states_by_type(state_nodes, @state_types_terminal)

    cond do
      active_states == [] ->
        {:error, :missing_linear_active_states}

      terminal_states == [] ->
        {:error, :missing_linear_terminal_states}

      true ->
        {:ok, %{active_states: active_states, terminal_states: terminal_states}}
    end
  end

  defp derive_states_by_type(state_nodes, type_order) when is_list(state_nodes) and is_list(type_order) do
    type_order
    |> Enum.flat_map(fn state_type ->
      state_nodes
      |> Enum.filter(&(Map.get(&1, "type") == state_type))
      |> Enum.map(&Map.get(&1, "name"))
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end
end
