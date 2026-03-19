# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## What This Repo Adds

Compared with the baseline Symphony model in [`SPEC.md`](../SPEC.md), this Elixir implementation in
this repo adds a more opinionated local setup flow:

- Stock Symphony concept: `WORKFLOW.md` is the runtime contract.
- This repo: setup generates and maintains that workflow internally under `.symphony/WORKFLOW.md`
  so you can mostly treat it as an implementation detail.
- Stock Symphony concept: one tracker project selects the work.
- This repo: setup accepts a repo root that can contain many git repos, auto-discovers them, and
  uses them as the initial multi-repo workspace set.
- Stock Symphony concept: issue eligibility depends on configured active and terminal states.
- This repo: setup and runtime sync those states from the Linear project's team workflow so the
  service follows real Linear states like `Backlog`, `Todo`, `In Review`, and `Done`.
- Stock Symphony concept: sandbox/network policy is implementation-specific.
- This repo: the default Codex turn sandbox allows outbound network access so agents can push git
  branches, talk to GitHub, and complete PR publication flows without extra manual config.
- Stock Symphony concept: you start the service against a workflow path.
- This repo: `setup.sh` bootstraps everything, remembers the configured root, and `run.sh` restarts
  against that same root without asking again.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   either set it as the `LINEAR_API_KEY` environment variable or enter it during `symphony init`
   so the wizard persists it into `WORKFLOW.md`.
3. Create a starter workflow for your repo:
   ```bash
   ./setup.sh /path/to/your-repo
   ```
   This installs the toolchain, fetches dependencies, builds Symphony, runs the interactive
   workflow wizard, analyzes the starting repos you provide, generates repo-aware agent
   instructions, stores the internal workflow at `.symphony/WORKFLOW.md`, and then starts
   Symphony.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the generated `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
./setup.sh /path/to/your-repo
```

After the first setup, restart Symphony with the remembered configured root:

```bash
./run.sh
```

If you want to generate or update the workflow but not launch Symphony yet:

```bash
./setup.sh /path/to/your-repo --init-only
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Generate a starter workflow interactively:

```bash
./bin/symphony init /path/to/your-repo
```

The wizard asks for the Linear project URL or `slugId`, workspace root, local repo registry path, one or more
repositories, and a few runtime defaults, then writes a valid starter workflow file.

If you prefer a single guided entrypoint, use `./setup.sh` instead. It wraps `mise trust`,
`mise install`, `mix setup`, `mix build`, `symphony init`, and finally launches Symphony.

After setup finishes once, `run.sh` reuses the last configured root automatically so you do not
need to pass it again on restarts.

- When you point `setup.sh` or `symphony init` at a project root directory, Symphony keeps the
  generated workflow internal at `.symphony/WORKFLOW.md` so you do not need to manage it directly.
- If that root already contains git repos directly under it, setup auto-discovers them and uses
  them as the initial repo set before asking whether you want to add any extra repos outside it.
- If you enter a Linear API key during setup, `symphony init` writes it to `tracker.api_key` in the
  generated workflow so local runs do not require exporting `LINEAR_API_KEY`.
- The project prompt accepts either the raw Linear project `slugId` or a full Linear project URL; setup
  extracts the API-facing `slugId` from real Linear project URLs automatically.
- Setup also resolves the project's team workflow states from Linear and writes them into the hidden
  workflow so project-specific states like `Backlog`, `In Review`, or any custom planning state are
  tracked correctly.
- At runtime, `tracker.sync_project_states: true` keeps the effective `active_states` and
  `terminal_states` aligned with the current Linear project/team workflow even if the Linear setup
  changes later.
- `tracker.planning_states` declares the pre-development states Symphony should treat as
  clarification/spec-review/approval holds. Tickets in those states are visible in Linear but are
  not dispatched for implementation until a human moves them forward.
- Prompt generation now detects frontend/UI-heavy tickets from issue context and repo signals, and
  requires a screenshot or short video artifact in the workpad/final handoff before the ticket is
  considered complete.
- Prompt generation also writes a scoped spec gate into each agent session: low-complexity work gets
  a minimal spec, more complex work gets a standard or detailed spec, and the agent is told to ask
  clarification questions and wait for explicit go-ahead when the ask is underspecified or
  high-impact.
- When a full Linear project URL is provided, Symphony also preserves it for dashboard/status links
  instead of reconstructing a potentially wrong browser URL from the `slugId` alone.
- If you leave the API key blank, the generated workflow relies on `LINEAR_API_KEY` at runtime.
- The setup flow inspects the initial repos you provide and writes starter per-repo guidance into
  the prompt body, so the generated workflow is not just a blank template.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
  sync_project_states: true
  planning_states:
    - Spec Review
    - Needs Clarification
    - Planning
workspace:
  root: ~/code/workspaces
  registry_path: .symphony/repos.json
  repositories:
    - name: app
      source: git@github.com:your-org/your-repo.git
      path: .
hooks:
  after_create: |
    if command -v mise >/dev/null 2>&1; then
      mise trust && mise exec -- mix deps.get
    fi
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `workspace.repositories` is optional. When present, Symphony clones the first repository into the
  issue workspace root by default and clones later repositories into sibling subdirectories named
  after each repository unless `path` overrides it.
- `tracker.sync_project_states` defaults to `true`. When enabled, Symphony derives `active_states`
  and `terminal_states` from the Linear project's team workflow instead of relying only on static
  defaults in the file.
- `tracker.planning_states` declares the pre-development states Symphony should treat as
  clarification/spec-review holds. If a synced Linear project exposes one of those states, Symphony
  will stop dispatching work there until a human advances the issue.
- The default Codex turn sandbox policy in this repo uses `workspaceWrite` plus outbound network
  access, so `git fetch`, `git push`, and PR publication flows can work from inside agent turns.
- `workspace.registry_path` is optional. Symphony uses it to persist repos that were registered at
  runtime via control tickets. Relative paths are resolved under `workspace.root`.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace, with outbound network enabled
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, body, workspace path, configured repository layout, and a scoped
  planning/clarification gate.
- Prefer `workspace.repositories` for Git-backed workspace population. Keep `hooks.after_create`
  for extra setup such as dependency installs, generated files, or project-specific bootstrap.
- Symphony can also grow the repo set without code changes: create a Linear issue titled
  `Register repo: <name>` or labeled `symphony:register-repo`, include a YAML payload describing
  `name`, `source`, optional `path`, `branch`, and `tags`, and Symphony will persist it to the
  local registry file at `workspace.registry_path`.
- Normal issue routing uses the following precedence:
  - explicit label `repo:<name>`
  - issue labels matching repo tags
  - issue title/description mentioning a repo name or tag
  - fallback to all available repos
- `workspace.repositories[].path` is relative to the issue workspace. Use `.` for the primary repo
  if you want repo-local `AGENTS.md`, `.codex/skills`, and other root-scoped tooling to behave the
  same as the legacy single-repo clone-at-root setup.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
  registry_path: .symphony/repos.json
  repositories:
    - name: app
      source: $SOURCE_REPO_URL
      path: .
    - name: shared-ui
      source: $SHARED_UI_REPO_URL
      path: repos/shared-ui
hooks:
codex:
  command: "$CODEX_BIN app-server --model gpt-5.3-codex"
```

Example repo registration control ticket body:

```yaml
repo:
  name: shared-ui
  source: git@github.com:your-org/shared-ui.git
  path: repos/shared-ui
  tags:
    - ui
    - frontend
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_CODEX_COMMAND` defaults to `codex app-server`

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`,
runs a real agent turn, verifies the workspace side effect, requires Codex to comment on and close
the Linear issue, then marks the project completed so the run remains visible in Linear.
`make e2e` fails fast with a clear error if `LINEAR_API_KEY` is unset.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
