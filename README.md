# Symphony

Symphony turns project work across one or more repositories into isolated, autonomous
implementation runs, allowing teams to manage work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

The Elixir reference implementation also ships a single-command `setup.sh` bootstrap plus an
interactive `symphony init` wizard, so you can generate a starter `WORKFLOW.md`, seed it from your
initial repos, keep it internal under `.symphony/WORKFLOW.md`, and then use `run.sh` for later
restarts without manually passing the configured root again.

## What Is Standard vs Local Here

`SPEC.md` describes the core Symphony model: poll a tracker project, create an isolated workspace
per issue, run Codex in app-server mode, and drive the issue to completion.

This Elixir tree goes further than the baseline concept in a few local ways:

- Standard Symphony concept: one tracker project drives issue selection.
- Local extension here: a single configured root can expose multiple code repos, and each issue
  gets an isolated multi-repo workspace.
- Standard Symphony concept: runtime behavior comes from `WORKFLOW.md`.
- Local extension here: setup hides that file under `.symphony/WORKFLOW.md`, generates it
  interactively, and remembers the configured root for `run.sh`.
- Standard Symphony concept: issue eligibility depends on configured active and terminal states.
- Local extension here: setup and runtime sync those states from the actual Linear project/team
  workflow so states like `Backlog` or `In Review` do not have to be hardcoded manually.
- Standard Symphony concept: sandbox policy is implementation-defined.
- Local extension here: the Elixir fork defaults Codex turn sandboxes to workspace-write with
  outbound network enabled so agents can `git push`, open PRs, and hit hosted Git remotes.
- Standard Symphony concept: you can describe one repo in the workflow.
- Local extension here: repos can be auto-discovered from a root folder, routed per issue, and
  expanded later through a local registry/control-ticket flow.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
