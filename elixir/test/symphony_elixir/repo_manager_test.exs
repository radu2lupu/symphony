defmodule SymphonyElixir.RepoManagerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Linear.Issue, RepoManager, RepoRegistry}

  test "agent runner registers a repository from a control issue and persists it locally" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-register-repo-#{System.unique_integer([:positive])}"
      )

    try do
      shared_ui_repo = Path.join(test_root, "shared-ui")
      workspace_root = Path.join(test_root, "workspaces")
      registry_path = Path.join([test_root, "registry", "repos.json"])

      File.mkdir_p!(shared_ui_repo)
      File.write!(Path.join(shared_ui_repo, "README.md"), "shared ui\n")
      System.cmd("git", ["-C", shared_ui_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", shared_ui_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", shared_ui_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", shared_ui_repo, "add", "README.md"])
      System.cmd("git", ["-C", shared_ui_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        workspace_registry_path: registry_path
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "repo-register-1",
        identifier: "MT-REG-1",
        title: "Register repo: shared-ui",
        description: """
        repo:
          source: #{shared_ui_repo}
          path: repos/shared-ui
          tags: [ui, frontend]
        """,
        state: "Todo",
        labels: ["symphony:register-repo"]
      }

      assert :ok = AgentRunner.run(issue)
      assert_receive {:memory_tracker_comment, "repo-register-1", comment}
      assert_receive {:memory_tracker_state_update, "repo-register-1", "Done"}
      assert comment =~ "Registered repo `shared-ui`"
      assert comment =~ "`repos/shared-ui`"

      assert [%{name: "shared-ui", path: "repos/shared-ui", tags: ["ui", "frontend"]}] =
               RepoRegistry.list_repositories()

      routed_issue = %Issue{
        id: "issue-2",
        identifier: "MT-UI-1",
        title: "Refresh shared UI button",
        description: "Work in the shared ui repo",
        state: "Todo",
        labels: ["repo:shared-ui"]
      }

      assert {:ok, workspace} = Workspace.create_for_issue(routed_issue)
      assert File.read!(Path.join([workspace, "repos", "shared-ui", "README.md"])) == "shared ui\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace clones only the repositories routed to an issue" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-routed-repo-clone-#{System.unique_integer([:positive])}"
      )

    try do
      app_repo = Path.join(test_root, "app")
      docs_repo = Path.join(test_root, "docs")
      workspace_root = Path.join(test_root, "workspaces")
      registry_path = Path.join(test_root, "repos.json")

      File.mkdir_p!(app_repo)
      File.mkdir_p!(docs_repo)
      File.write!(Path.join(app_repo, "APP.md"), "app\n")
      File.write!(Path.join(docs_repo, "DOCS.md"), "docs\n")

      System.cmd("git", ["-C", app_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", app_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", app_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", app_repo, "add", "APP.md"])
      System.cmd("git", ["-C", app_repo, "commit", "-m", "initial"])

      System.cmd("git", ["-C", docs_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", docs_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", docs_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", docs_repo, "add", "DOCS.md"])
      System.cmd("git", ["-C", docs_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_registry_path: registry_path,
        workspace_repositories: [
          [name: "app", source: app_repo, path: ".", tags: ["app"]],
          [name: "docs", source: docs_repo, path: "repos/docs", tags: ["docs"]]
        ]
      )

      issue = %Issue{
        id: "issue-1",
        identifier: "MT-DOCS",
        title: "Update docs navigation",
        description: "Only docs should be touched",
        state: "Todo",
        labels: ["repo:docs"]
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      refute File.exists?(Path.join(workspace, "APP.md"))
      assert File.read!(Path.join([workspace, "repos", "docs", "DOCS.md"])) == "docs\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "repo routing supports explicit labels, repo tags, and text matches" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-repo-routing-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      registry_path = Path.join(test_root, "repos.json")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_registry_path: registry_path,
        workspace_repositories: [
          [name: "app", source: "https://example.com/app.git", path: ".", tags: ["frontend"]],
          [name: "api", source: "https://example.com/api.git", tags: ["backend", "server"]]
        ]
      )

      assert [%{name: "api"}] =
               RepoManager.routed_repositories(%Issue{title: "Fix", labels: ["repo:api"]})

      assert [%{name: "api"}] =
               RepoManager.routed_repositories(%Issue{title: "Fix", labels: ["server"]})

      assert [%{name: "app"}] =
               RepoManager.routed_repositories(%Issue{
                 title: "Frontend polish",
                 description: "Need app updates",
                 labels: []
               })
    after
      File.rm_rf(test_root)
    end
  end
end
