defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps =
      base_deps(%{
        file_regular?: fn _path ->
          send(parent, :file_checked)
          true
        end,
        set_workflow_file_path: fn _path ->
          send(parent, :workflow_set)
          :ok
        end,
        set_logs_root: fn _path ->
          send(parent, :logs_root_set)
          :ok
        end,
        set_server_port_override: fn _port ->
          send(parent, :port_set)
          :ok
        end,
        ensure_all_started: fn ->
          send(parent, :started)
          {:ok, [:symphony_elixir]}
        end
      })

    assert {:error, banner} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert banner =~ "This Symphony implementation is a low key engineering preview."
    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ "SymphonyElixir is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :file_checked
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :started
  end

  test "defaults to WORKFLOW.md when workflow path is missing" do
    deps =
      base_deps(%{
        file_regular?: fn path -> Path.basename(path) == "WORKFLOW.md" end,
        set_workflow_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
      })

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "defaults to hidden .symphony workflow in cwd when present" do
    cwd = "/tmp/project-root"
    hidden_workflow = Path.join(cwd, ".symphony/WORKFLOW.md")
    parent = self()

    deps =
      base_deps(%{
        cwd: fn -> cwd end,
        file_regular?: fn path ->
          send(parent, {:workflow_checked, path})
          path == hidden_workflow
        end,
        set_workflow_file_path: fn path ->
          send(parent, {:workflow_set, path})
          :ok
        end
      })

    assert :ok = CLI.evaluate([@ack_flag], deps)
    assert_received {:workflow_checked, ^hidden_workflow}
    assert_received {:workflow_set, ^hidden_workflow}
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps =
      base_deps(%{
        file_regular?: fn path ->
          send(parent, {:workflow_checked, path})
          path == expanded_path
        end,
        set_workflow_file_path: fn path ->
          send(parent, {:workflow_set, path})
          :ok
        end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
      })

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
  end

  test "accepts a project root and resolves the hidden workflow path inside it" do
    parent = self()
    project_root = "/tmp/project-root"
    hidden_workflow = Path.join(project_root, ".symphony/WORKFLOW.md")

    deps =
      base_deps(%{
        dir_exists?: fn path -> path == project_root end,
        file_regular?: fn path ->
          send(parent, {:workflow_checked, path})
          path == hidden_workflow
        end,
        set_workflow_file_path: fn path ->
          send(parent, {:workflow_set, path})
          :ok
        end
      })

    assert :ok = CLI.evaluate([@ack_flag, project_root], deps)
    assert_received {:workflow_checked, ^hidden_workflow}
    assert_received {:workflow_set, ^hidden_workflow}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps =
      base_deps(%{
        file_regular?: fn _path -> true end,
        set_workflow_file_path: fn _path -> :ok end,
        set_logs_root: fn path ->
          send(parent, {:logs_root, path})
          :ok
        end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
      })

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when workflow file does not exist" do
    deps =
      base_deps(%{
        file_regular?: fn _path -> false end,
        set_workflow_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
      })

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "returns startup error when app cannot start" do
    deps =
      base_deps(%{
        file_regular?: fn _path -> true end,
        set_workflow_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:error, :boom} end
      })

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Failed to start Symphony with workflow"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps =
      base_deps(%{
        file_regular?: fn _path -> true end,
        set_workflow_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
      })

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
  end

  test "interactive init writes a starter workflow with prompted config" do
    parent = self()
    cwd = "/tmp/symphony-cli"
    workflow_path = "tmp/generated/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path, cwd)
    project_root = Path.dirname(expanded_path)
    workspace_root = Path.join(project_root, ".symphony/workspaces")
    registry_path = Path.join(project_root, ".symphony/repos.json")

    deps =
      interactive_deps(
        [
          "lin_api_123\n",
          "linear-project\n",
          "\n",
          "\n",
          "app\n",
          "git@github.com:acme/app.git\n",
          "\n",
          "frontend, ios\n",
          "y\n",
          "shared-ui\n",
          "git@github.com:acme/shared-ui.git\n",
          "\n",
          "ui, frontend\n",
          "n\n",
          "12\n",
          "30\n",
          "codex --model gpt-5.3-codex app-server\n"
        ],
        %{
          cwd: fn -> cwd end,
          file_exists?: fn _path -> false end,
          resolve_linear_project_config: fn tracker, _ttl_ms ->
            assert tracker.project_slug == "linear-project"

            {:ok,
             %{
               project_url: "https://linear.app/acme/project/linear-project",
               active_states: ["Backlog", "Todo", "In Progress", "In Review"],
               terminal_states: ["Done", "Canceled"]
             }}
          end,
          mkdir_p: fn path ->
            send(parent, {:mkdir_p, path})
            :ok
          end,
          write_file: fn path, content ->
            send(parent, {:write_file, path, IO.iodata_to_binary(content)})
            :ok
          end,
          analyze_repository: fn repository ->
            case repository.name do
              "app" ->
                {:ok,
                 %{
                   kind: :apple_app,
                   summary: "Apple app repo (Xcode/SwiftUI/UIKit)",
                   instructions: [
                     "Prefer xcodebuild-based verification.",
                     "Keep DerivedData in the workspace."
                   ]
                 }}

              "shared-ui" ->
                {:ok,
                 %{
                   kind: :node,
                   summary: "Node package or service repo",
                   instructions: [
                     "Use the repo package manager.",
                     "Run targeted package tests."
                   ]
                 }}
            end
          end,
          print: fn message ->
            send(parent, {:print, message})
            :ok
          end
        }
      )

    assert :halt_ok = CLI.evaluate(["init", workflow_path], deps)
    assert_received {:mkdir_p, _dir}
    assert_received {:write_file, ^expanded_path, content}
    assert content =~ ~s(api_key: "lin_api_123")
    assert content =~ ~s(project_slug: "linear-project")
    assert content =~ ~s(project_url: "https://linear.app/acme/project/linear-project")
    assert content =~ ~s(sync_project_states: true)
    assert content =~ ~s(active_states: ["Backlog", "Todo", "In Progress", "In Review"])
    assert content =~ ~s(planning_states: ["Spec Review", "Needs Clarification", "Planning"])
    assert content =~ ~s(terminal_states: ["Done", "Canceled"])
    assert content =~ ~s(root: "#{workspace_root}")
    assert content =~ ~s(registry_path: "#{registry_path}")
    assert content =~ ~s(name: "app")
    assert content =~ ~s(source: "git@github.com:acme/app.git")
    assert content =~ ~s(path: ".")
    assert content =~ ~s(- "frontend")
    assert content =~ ~s(- "ios")
    assert content =~ ~s(name: "shared-ui")
    assert content =~ ~s(path: "repos/shared-ui")
    assert content =~ ~s(max_concurrent_agents: 12)
    assert content =~ ~s(max_turns: 30)
    assert content =~ ~s(command: "codex --model gpt-5.3-codex app-server")
    assert content =~ "memory:"
    assert content =~ ~s(enabled: true)
    assert content =~ ~s(command: "total-recall")
    assert content =~ ~s(verify_evidence: true)
    assert content =~ ~s(install_during_init: true)
    assert content =~ "You are working on a Linear issue"
    assert content =~ "Planning and approval gate:"
    assert content =~ "ask for explicit go-ahead before implementation"
    assert content =~ "Shared memory requirement:"
    assert content =~ "## Shared Memory"
    assert content =~ "Frontend proof requirement:"
    assert content =~ "capture at least one screenshot of the changed UI"
    assert content =~ "`app`: Apple app repo (Xcode/SwiftUI/UIKit)"
    assert content =~ "Prefer xcodebuild-based verification."
    assert content =~ "`shared-ui`: Node package or service repo"
    assert content =~ "Run targeted package tests."
    assert_received {:print, "Symphony interactive setup"}
    assert_received {:print, "Resolved Linear workflow states from the project configuration."}
    assert_received {:print, "No git repositories were discovered directly under " <> ^project_root <> "."}
    assert_received {:print, "Analyzing repository app..."}
    assert_received {:print, "Analyzing repository shared-ui..."}
    assert_received {:print, "Detected Total Recall at /usr/local/bin/total-recall."}
    assert_received {:print, "Wrote starter workflow to " <> ^expanded_path}
  end

  test "interactive init normalizes a full linear project url down to the project slug" do
    parent = self()
    project_root = "/tmp/project-root"
    hidden_workflow = Path.join(project_root, ".symphony/WORKFLOW.md")

    deps =
      interactive_deps(
        [
          "\n",
          "https://linear.app/team-name/project/project-slug-2687ec99687c/issues\n",
          "\n",
          "\n",
          "app\n",
          "git@github.com:acme/app.git\n",
          "\n",
          "\n",
          "n\n",
          "\n",
          "\n",
          "\n"
        ],
        %{
          dir_exists?: fn path -> path == project_root end,
          discover_repositories: fn ^project_root -> {:ok, []} end,
          env_get: fn
            "LINEAR_API_KEY" -> "env-token"
            _key -> nil
          end,
          resolve_linear_project_config: fn _tracker, _ttl_ms ->
            {:ok,
             %{
               project_url: "https://linear.app/team-name/project/project-slug-2687ec99687c/issues",
               active_states: ["Backlog", "Todo", "In Progress"],
               terminal_states: ["Done", "Canceled"]
             }}
          end,
          write_file: fn path, content ->
            send(parent, {:write_file, path, IO.iodata_to_binary(content)})
            :ok
          end
        }
      )

    assert :halt_ok = CLI.evaluate(["init", project_root], deps)
    assert_received {:write_file, ^hidden_workflow, content}
    assert content =~ ~s(project_slug: "2687ec99687c")
    assert content =~ ~s(project_url: "https://linear.app/team-name/project/project-slug-2687ec99687c/issues")
    assert content =~ ~s(active_states: ["Backlog", "Todo", "In Progress"])
  end

  test "interactive init accepts a project root and writes the hidden workflow file there" do
    parent = self()
    project_root = "/tmp/project-root"
    hidden_workflow = Path.join(project_root, ".symphony/WORKFLOW.md")

    deps =
      interactive_deps(
        [
          "\n",
          "linear-project\n",
          "\n",
          "\n",
          "app\n",
          "git@github.com:acme/app.git\n",
          "\n",
          "\n",
          "n\n",
          "\n",
          "\n",
          "\n"
        ],
        %{
          dir_exists?: fn path -> path == project_root end,
          resolve_linear_project_config: fn _tracker, _ttl_ms ->
            {:ok,
             %{
               project_url: "https://linear.app/acme/project/linear-project",
               active_states: ["Backlog", "Todo", "In Progress"],
               terminal_states: ["Done", "Canceled"]
             }}
          end,
          mkdir_p: fn path ->
            send(parent, {:mkdir_p, path})
            :ok
          end,
          write_file: fn path, content ->
            send(parent, {:write_file, path, IO.iodata_to_binary(content)})
            :ok
          end
        }
      )

    assert :halt_ok = CLI.evaluate(["init", project_root], deps)
    assert_received {:mkdir_p, mkdir_path}
    assert mkdir_path == Path.dirname(hidden_workflow)
    assert_received {:write_file, ^hidden_workflow, content}
    assert content =~ ~s(project_slug: "linear-project")
    assert content =~ ~s(sync_project_states: true)
  end

  test "interactive init auto-discovers repos under the project root" do
    parent = self()
    project_root = "/tmp/project-root"
    hidden_workflow = Path.join(project_root, ".symphony/WORKFLOW.md")

    deps =
      interactive_deps(
        [
          "\n",
          "linear-project\n",
          "\n",
          "\n",
          "n\n",
          "\n",
          "\n",
          "\n"
        ],
        %{
          dir_exists?: fn path -> path == project_root end,
          discover_repositories: fn ^project_root ->
            {:ok,
             [
               %{name: "ios-app", source: "/repos/ios-app", path: "ios-app", tags: ["ios", "app"]},
               %{name: "shared-ui", source: "/repos/shared-ui", path: "shared-ui", tags: ["shared", "ui"]}
             ]}
          end,
          analyze_repository: fn repository ->
            {:ok,
             %{
               summary: "Detected #{repository.name}",
               instructions: ["Use focused validation."]
             }}
          end,
          resolve_linear_project_config: fn _tracker, _ttl_ms ->
            {:ok,
             %{
               project_url: "https://linear.app/acme/project/linear-project",
               active_states: ["Backlog", "Todo", "In Progress"],
               terminal_states: ["Done", "Canceled"]
             }}
          end,
          write_file: fn path, content ->
            send(parent, {:write_file, path, IO.iodata_to_binary(content)})
            :ok
          end,
          print: fn message ->
            send(parent, {:print, message})
            :ok
          end
        }
      )

    assert :halt_ok = CLI.evaluate(["init", project_root], deps)
    assert_received {:write_file, ^hidden_workflow, content}
    assert content =~ ~s(name: "ios-app")
    assert content =~ ~s(source: "/repos/ios-app")
    assert content =~ ~s(path: "ios-app")
    assert content =~ "`ios-app`: Detected ios-app"
    assert_received {:print, "Discovered 2 git repos under /tmp/project-root:"}
    assert_received {:print, "  - ios-app (ios-app)"}
    assert_received {:print, "  - shared-ui (shared-ui)"}
  end

  test "interactive init aborts when overwrite is declined" do
    parent = self()
    workflow_path = "/tmp/existing/WORKFLOW.md"

    deps =
      interactive_deps(
        ["n\n"],
        %{
          file_exists?: fn path -> path == workflow_path end,
          write_file: fn _path, _content ->
            send(parent, :write_attempted)
            :ok
          end
        }
      )

    assert {:error, message} = CLI.evaluate(["init", workflow_path], deps)
    assert message =~ "Aborted interactive setup"
    refute_received :write_attempted
  end

  test "interactive init omits api_key when left blank" do
    parent = self()
    workflow_path = "/tmp/generated/WORKFLOW.md"

    deps =
      interactive_deps(
        [
          "\n",
          "linear-project\n",
          "\n",
          "\n",
          "app\n",
          "git@github.com:acme/app.git\n",
          "\n",
          "\n",
          "n\n",
          "\n",
          "\n",
          "\n"
        ],
        %{
          file_exists?: fn _path -> false end,
          analyze_repository: fn _repository -> {:error, :not_available} end,
          resolve_linear_project_config: fn _tracker, _ttl_ms ->
            {:error, :missing_api_key}
          end,
          write_file: fn path, content ->
            send(parent, {:write_file, path, IO.iodata_to_binary(content)})
            :ok
          end
        }
      )

    assert :halt_ok = CLI.evaluate(["init", workflow_path], deps)
    assert_received {:write_file, ^workflow_path, content}
    refute content =~ "api_key:"
    assert content =~ ~s(project_slug: "linear-project")
    assert content =~ ~s(sync_project_states: true)
    assert content =~ "Project-specific repo guidance:"
    assert content =~ "Generic repo guidance for app"
  end

  test "interactive init runs total recall install when status is not ready" do
    parent = self()
    workflow_path = "/tmp/generated/WORKFLOW.md"

    deps =
      interactive_deps(
        [
          "\n",
          "linear-project\n",
          "\n",
          "\n",
          "app\n",
          "git@github.com:acme/app.git\n",
          "\n",
          "\n",
          "n\n",
          "\n",
          "\n",
          "\n"
        ],
        %{
          file_exists?: fn _path -> false end,
          analyze_repository: fn _repository -> {:error, :not_available} end,
          resolve_linear_project_config: fn _tracker, _ttl_ms -> {:error, :missing_api_key} end,
          find_executable: fn
            "total-recall" -> "/usr/local/bin/total-recall"
            _command -> nil
          end,
          run_command: fn
            "/usr/local/bin/total-recall", ["status"], _opts ->
              send(parent, :total_recall_status_checked)
              {"not ready", 1}

            "/usr/local/bin/total-recall", ["install"], _opts ->
              send(parent, :total_recall_install_ran)
              {"installed", 0}
          end,
          write_file: fn _path, _content -> :ok end,
          print: fn message ->
            send(parent, {:print, message})
            :ok
          end
        }
      )

    assert :halt_ok = CLI.evaluate(["init", workflow_path], deps)
    assert_received :total_recall_status_checked
    assert_received :total_recall_install_ran
    assert_received {:print, "Detected Total Recall at /usr/local/bin/total-recall but it is not initialized for this project. Running `total-recall install`."}
    assert_received {:print, "Total Recall install completed for this project."}
  end

  defp base_deps(overrides) do
    Map.merge(
      %{
        file_regular?: fn _path -> false end,
        file_exists?: fn _path -> false end,
        dir_exists?: fn _path -> false end,
        set_workflow_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
        prompt: fn _prompt -> nil end,
        print: fn _message -> :ok end,
        mkdir_p: fn _path -> :ok end,
        write_file: fn _path, _content -> :ok end,
        cwd: fn -> File.cwd!() end,
        env_get: fn _key -> nil end,
        find_executable: fn
          "total-recall" -> "/usr/local/bin/total-recall"
          _command -> nil
        end,
        run_command: fn
          "/usr/local/bin/total-recall", ["status"], _opts -> {"ok", 0}
          command, args, _opts -> flunk("unexpected command: #{inspect({command, args})}")
        end,
        analyze_repository: fn _repository -> {:error, :not_implemented} end,
        discover_repositories: fn _project_root -> {:ok, []} end,
        resolve_linear_project_config: fn _tracker, _ttl_ms ->
          {:error, :not_implemented}
        end
      },
      overrides
    )
  end

  defp interactive_deps(responses, overrides) do
    parent = self()
    responses_key = make_ref()
    Process.put(responses_key, responses)

    prompt = fn prompt ->
      send(parent, {:prompt, prompt})

      case Process.get(responses_key, []) do
        [next | rest] ->
          Process.put(responses_key, rest)
          next

        [] ->
          nil
      end
    end

    base_deps(Map.put(overrides, :prompt, prompt))
  end
end
