defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, RepoManager, Tracker, Workspace}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    Logger.info("Starting agent run for #{issue_context(issue)}")

    cond do
      RepoManager.control_issue?(issue) ->
        case RepoManager.register_repository_issue(issue) do
          {:ok, _repository} ->
            :ok

          {:error, reason} ->
            Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
            raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
        end

      true ->
        case Workspace.create_for_issue(issue) do
          {:ok, workspace} ->
            try do
              with :ok <- Workspace.run_before_run_hook(workspace, issue),
                   :ok <- run_codex_turns(workspace, issue, codex_update_recipient, opts) do
                :ok
              else
                {:error, reason} ->
                  Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
                  raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
              end
            after
              Workspace.run_after_run_hook(workspace, issue)
            end

          {:error, reason} ->
            Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
            raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
        end
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    repositories = RepoManager.routed_repositories(issue, workspace)
    run_opts = opts |> Keyword.put(:workspace, workspace) |> Keyword.put(:repositories, repositories)

    with {:ok, session} <- AppServer.start_session(workspace) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, run_opts, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ),
         :ok <- verify_shared_memory(issue, codex_update_recipient) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    #{shared_memory_continuation_guidance()}
    """
  end

  defp shared_memory_continuation_guidance do
    if Config.total_recall_enabled?() do
      """
      - Before doing new work on this continuation turn, run `#{Config.total_recall_command()} query "<semantic query>"` again using a high-level question rather than the raw issue text.
      - Update the `## Shared Memory` block in the `## Codex Workpad` comment for this turn, including Query, Relevant memories, Write summary, and Total Recall status.
      - When the turn completes, persist a structured summary with `#{Config.total_recall_command()} write "<what changed, why, what future agents should reuse or avoid>"`.
      """
      |> String.trim_trailing()
    else
      ""
    end
  end

  defp verify_shared_memory(issue, codex_update_recipient) do
    cond do
      not Config.total_recall_enabled?() ->
        :ok

      not Config.verify_total_recall_evidence?() ->
        :ok

      true ->
        do_verify_shared_memory(issue, codex_update_recipient)
    end
  end

  defp do_verify_shared_memory(%Issue{id: issue_id} = issue, codex_update_recipient) when is_binary(issue_id) do
    case Tracker.fetch_comments(issue_id) do
      {:ok, comments} ->
        case extract_shared_memory_metadata(comments) do
          {:ok, %{status: {:ok, _status}} = memory} ->
            Logger.info("Verified shared memory evidence for #{issue_context(issue)} query=#{inspect(memory.query)}")
            emit_memory_update(codex_update_recipient, issue, :memory_verified, memory_summary("shared memory verified", memory), memory)
            :ok

          {:warning, %{status: {:unavailable, reason}} = memory} ->
            Logger.warning("Shared memory unavailable for #{issue_context(issue)} reason=#{inspect(reason)}")
            emit_memory_update(codex_update_recipient, issue, :memory_unavailable, memory_summary("shared memory unavailable", memory), memory)
            :ok

          {:error, reason} ->
            Logger.warning("Shared memory compliance failed for #{issue_context(issue)}: #{inspect(reason)}")
            emit_memory_update(codex_update_recipient, issue, :memory_non_compliant, "shared memory evidence missing or malformed", %{status: {:error, inspect(reason)}})
            {:error, {:memory_non_compliant, reason}}
        end

      {:error, reason} ->
        Logger.warning("Shared memory compliance check failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_memory_update(codex_update_recipient, issue, :memory_non_compliant, "shared memory verification failed while reading workpad", %{status: {:error, inspect(reason)}})
        {:error, {:memory_verification_failed, reason}}
    end
  end

  defp do_verify_shared_memory(_issue, _codex_update_recipient), do: :ok

  defp emit_memory_update(recipient, issue, event, payload, memory) when is_pid(recipient) do
    send_codex_update(recipient, issue, %{event: event, payload: payload, memory: memory, timestamp: DateTime.utc_now()})
  end

  defp emit_memory_update(_recipient, _issue, _event, _payload, _memory), do: :ok

  defp extract_shared_memory_metadata(comments) when is_list(comments) do
    comments
    |> Enum.sort_by(&comment_updated_at/1, {:desc, DateTime})
    |> Enum.find_value(fn comment ->
      body = Map.get(comment, :body) || Map.get(comment, "body")

      cond do
        not is_binary(body) ->
          nil

        not String.contains?(body, "## Codex Workpad") ->
          nil

        true ->
          parse_shared_memory_block(body)
      end
    end) || {:error, :missing_workpad_comment}
  end

  defp extract_shared_memory_metadata(_comments), do: {:error, :missing_workpad_comment}

  defp parse_shared_memory_block(body) when is_binary(body) do
    case Regex.run(
           ~r/## Shared Memory\s*\n- Query:\s*(.+)\n- Relevant memories:\s*(.+)\n- Write summary:\s*(.+)\n- Total Recall status:\s*(.+?)(?:\n## |\z)/s,
           body
         ) do
      [_, query, relevant_memories, write_summary, raw_status] ->
        memory = %{
          query: String.trim(query),
          relevant_memories: String.trim(relevant_memories),
          write_summary: String.trim(write_summary)
        }

        with :ok <- validate_memory_field(memory.query, :missing_query),
             :ok <- validate_memory_field(memory.relevant_memories, :missing_relevant_memories),
             :ok <- validate_memory_field(memory.write_summary, :missing_write_summary),
             {:ok, status} <- parse_total_recall_status(raw_status) do
          result = Map.put(memory, :status, status)

          case status do
            {:ok, _text} -> {:ok, result}
            {:unavailable, _reason} -> {:warning, result}
          end
        else
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :missing_shared_memory_block}
    end
  end

  defp parse_shared_memory_block(_body), do: {:error, :missing_shared_memory_block}

  defp validate_memory_field(value, reason) when is_binary(value) do
    if String.trim(value) == "" do
      {:error, reason}
    else
      :ok
    end
  end

  defp validate_memory_field(_value, reason), do: {:error, reason}

  defp comment_updated_at(comment) when is_map(comment) do
    Map.get(comment, :updated_at) || Map.get(comment, "updated_at") || ~U[1970-01-01 00:00:00Z]
  end

  defp comment_updated_at(_comment), do: ~U[1970-01-01 00:00:00Z]

  defp parse_total_recall_status(status_text) when is_binary(status_text) do
    trimmed = String.trim(status_text)

    cond do
      trimmed == "ok" ->
        {:ok, {:ok, "ok"}}

      String.starts_with?(trimmed, "unavailable:") ->
        reason = trimmed |> String.replace_prefix("unavailable:", "") |> String.trim()

        if reason == "" do
          {:error, :missing_unavailable_reason}
        else
          {:ok, {:unavailable, reason}}
        end

      true ->
        {:error, :invalid_total_recall_status}
    end
  end

  defp parse_total_recall_status(_status_text), do: {:error, :invalid_total_recall_status}

  defp memory_summary(prefix, %{query: query, write_summary: write_summary}) do
    "#{prefix}: query=#{truncate_memory_text(query)} write=#{truncate_memory_text(write_summary)}"
  end

  defp memory_summary(prefix, _memory), do: prefix

  defp truncate_memory_text(text) when is_binary(text) do
    if String.length(text) > 80 do
      String.slice(text, 0, 77) <> "..."
    else
      text
    end
  end

  defp truncate_memory_text(_text), do: "n/a"

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.dispatchable_active_states()
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
