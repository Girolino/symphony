# AGENTS.md

> Version: v1.0.0 - 2026-06-19

## Language

- Use English for all code comments, docs, commit messages, logs, and UI text.
- Keep operational notes concrete. Prefer file paths, commands, ports, and state names over prose summaries.

## Repository Purpose

Symphony is a reusable local orchestration harness. It polls a tracker, creates isolated per-issue workspaces, starts Codex in app-server mode, and keeps workers moving according to the `WORKFLOW.md` contract supplied by the target repository.

This checkout is the generic harness:

```text
/Users/fernandomaluf/Dropbox/harnesses/symphony
```

The current implementation lives under:

```text
elixir/
```

When working inside `elixir/`, also follow `elixir/AGENTS.md`; it is more specific for Elixir implementation, specs, logging, and PR body rules.

## Core Boundaries

- Keep the harness generic. Do not bake Alpine Reach, Dr. Thomas, or any other product-specific workflow policy into the harness unless the behavior is truly reusable across repos.
- Repo-specific workflow policy belongs in the target repository's `WORKFLOW.md`, control scripts, guard scripts, state-machine files, and docs.
- For Alpine Reach, the target repo is `/Users/fernandomaluf/Dropbox/dr-thomas`. Its workflow contract is `/Users/fernandomaluf/Dropbox/dr-thomas/WORKFLOW.md`.
- The harness may expose primitives for scheduling, workspace isolation, app-server sessions, observability, retries, and hooks. The target repo decides Linear states, workpad format, branch policy, release gates, browser locks, and product validation rules.

## Local Operating Model

The agreed multi-repo model is one daemon per repo/workflow, isolated by:

- `WORKFLOW.md` path
- port
- workspace root
- logs root
- pid file
- LaunchAgent label
- Linear project slug
- browser or Computer Use lock path

For Alpine Reach today:

```text
workflow=/Users/fernandomaluf/Dropbox/dr-thomas/WORKFLOW.md
port=4765
workspace_root=~/.cache/alpine-reach-symphony/workspaces
logs_root=~/.cache/alpine-reach-symphony/logs
pid=~/.cache/alpine-reach-symphony/symphony.pid
dashboard=http://127.0.0.1:4765
```

The `dr-thomas` wrapper starts this harness through `scripts/symphony-control.ts`. Do not manage that daemon with generic process kills; use the app-owned control script when operating the live Alpine Reach lane.

## Important Files

Harness-level:

- `SPEC.md`: high-level Symphony contract.
- `README.md`: project overview and operator notes.
- `docs/multi-repo-linear-workflows.md`: local multi-repo daemon isolation model.

Elixir runtime:

- `elixir/mix.exs`: escript, deps, aliases, quality config.
- `elixir/WORKFLOW.md`: sample/local workflow contract for the harness itself.
- `elixir/lib/symphony_elixir/cli.ex`: escript entrypoint and CLI flags.
- `elixir/lib/symphony_elixir.ex`: OTP application supervision.
- `elixir/lib/symphony_elixir/workflow.ex`: `WORKFLOW.md` parsing.
- `elixir/lib/symphony_elixir/workflow_store.ex`: last-known-good workflow cache and reload loop.
- `elixir/lib/symphony_elixir/config.ex`: runtime config access.
- `elixir/lib/symphony_elixir/config/schema.ex`: typed workflow config schema.
- `elixir/lib/symphony_elixir/orchestrator.ex`: polling, dispatch, retry, stalled-worker, blocked/running state.
- `elixir/lib/symphony_elixir/workspace.ex`: issue workspace creation, hooks, cleanup, path safety.
- `elixir/lib/symphony_elixir/agent_runner.ex`: per-issue Codex run loop.
- `elixir/lib/symphony_elixir/codex/app_server.ex`: Codex app-server JSON-RPC client.
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`: injected dynamic tools such as `linear_graphql`.

Observability UI/API:

- `elixir/lib/symphony_elixir_web/router.ex`: `/`, `/api/v1/state`, `/api/v1/:issue_identifier`, `/api/v1/refresh`.
- `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`: Phoenix LiveView dashboard.
- `elixir/lib/symphony_elixir_web/presenter.ex`: shared API/UI projection layer.
- `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`: JSON API.
- `elixir/lib/symphony_elixir_web/components/layouts.ex`: HTML shell and LiveView client bootstrap.
- `elixir/priv/static/dashboard.css`: tracked dashboard stylesheet.

Tests and fixtures:

- `elixir/test/symphony_elixir/*`: runtime, API, dashboard, app-server, SSH, and config tests.
- `elixir/test/fixtures/status_dashboard_snapshots/*`: checked-in terminal dashboard snapshots.
- `elixir/test/support/*`: test helpers and live E2E support.

## Runtime Flow

1. `bin/symphony` starts as an escript built from `elixir/mix.exs`.
2. `SymphonyElixir.CLI` parses the workflow path, `--logs-root`, `--port`, and the guardrails acknowledgement flag.
3. `WorkflowStore` loads `WORKFLOW.md` and keeps polling it. Startup fails on an invalid initial workflow; later reload failures keep the last known good workflow.
4. `Config` parses YAML front matter into tracker, polling, workspace, worker, agent, codex, hooks, observability, and server settings.
5. `Orchestrator` polls the tracker, reconciles active/running/blocked/retry entries, chooses dispatchable issues, and starts one task per selected issue.
6. `Workspace` creates or reuses a sanitized issue directory under `workspace.root`, runs hooks, and enforces local workspace path safety.
7. `AgentRunner` runs `before_run`, starts Codex app-server in the issue workspace, sends the prompt, and continues turns while the issue remains active up to `agent.max_turns`.
8. `Codex.AppServer` speaks JSON-RPC over stdio or SSH, injects dynamic tools, forwards events to the orchestrator, and stops the app-server session after the run.
9. Terminal issue states stop agents and clean matching workspaces. Non-active, reassigned, or missing issues stop/release without terminal cleanup.

## Workflow Config Rules

- Runtime behavior must come from `WORKFLOW.md` and `SymphonyElixir.Config`, not ad hoc environment reads.
- Add new workflow settings through `SymphonyElixir.Config.Schema` and cover parsing/default behavior with tests.
- Keep `WORKFLOW.md`, config parsing, docs, and tests aligned when changing workflow semantics.
- `codex.command`, approval policy, thread sandbox, and explicit turn sandbox policy are passed through to Codex app-server. Compatibility depends on the installed Codex version, so validate with the local runtime when changing these fields.
- `hooks.before_run` exit status `75` is the intentional skip signal. Preserve that contract.
- Codex cwd must always be the issue workspace, never this source repo and never the workspace root.

## UI/API Rules

- The dashboard is Phoenix LiveView at `/`; the operational JSON API is under `/api/v1/*`.
- Keep data projection in `SymphonyElixirWeb.Presenter` so LiveView and controllers share the same shape.
- `/api/v1/state` returns HTTP 200 even when the payload contains `snapshot_timeout` or `snapshot_unavailable`.
- Missing issue detail should be 404, unavailable refresh should be 503, and wrong methods should return 405 JSON.
- Dashboard updates flow through `StatusDashboard.notify_update()` and `SymphonyElixirWeb.ObservabilityPubSub`; LiveView also ticks every second for elapsed runtime display.
- Static assets are served explicitly from `StaticAssets` and dependency `priv/static` files. Do not introduce a default Phoenix asset pipeline unless that migration is intentional.
- `elixir/priv/static/dashboard.css` is tracked source for the dashboard, not generated output.

## Commands

Run Elixir commands from `elixir/`.

Setup and build:

```bash
cd /Users/fernandomaluf/Dropbox/harnesses/symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
```

Run local harness:

```bash
cd /Users/fernandomaluf/Dropbox/harnesses/symphony/elixir
mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails --port 4000 --logs-root ./log ./WORKFLOW.md
```

Inspect local API:

```bash
curl http://127.0.0.1:4000/api/v1/state
curl -X POST http://127.0.0.1:4000/api/v1/refresh
```

Alpine Reach live daemon checks belong in `/Users/fernandomaluf/Dropbox/dr-thomas`:

```bash
bun run symphony:status
bun run symphony:doctor
bun run linear:symphony-sync -- --dry-run
```

## Validation

Use targeted tests while iterating, then run the proportional full gate before handoff.

Common scoped checks:

```bash
cd /Users/fernandomaluf/Dropbox/harnesses/symphony/elixir
mise exec -- mix specs.check
mise exec -- mix format --check-formatted
mise exec -- mix lint
mise exec -- mix test
```

Main gate:

```bash
make -C /Users/fernandomaluf/Dropbox/harnesses/symphony/elixir all
```

UI/API focused check:

```bash
cd /Users/fernandomaluf/Dropbox/harnesses/symphony/elixir
mise exec -- mix test test/symphony_elixir/extensions_test.exs test/symphony_elixir/observability_pubsub_test.exs test/symphony_elixir/status_dashboard_snapshot_test.exs
```

Live E2E is not routine. It creates disposable Linear resources, launches real Codex app-server work, and may use SSH/Docker workers:

```bash
cd /Users/fernandomaluf/Dropbox/harnesses/symphony/elixir
LINEAR_API_KEY=... mise exec -- make e2e
```

Only run live E2E when the task explicitly needs real external orchestration proof.

## Test And Fixture Policy

- Snapshot fixtures are terminal dashboard snapshots, not Phoenix DOM snapshots.
- Do not update `elixir/test/fixtures/status_dashboard_snapshots/*` unless the expected terminal dashboard output intentionally changed.
- Use `UPDATE_SNAPSHOTS=1` only for intentional snapshot updates.
- Phoenix LiveView/API behavior is covered by `extensions_test.exs` and related observability tests.
- Public `def` functions in `elixir/lib/` need adjacent `@spec` unless they are `@impl` callbacks; this is also enforced by `elixir/AGENTS.md`.

## Generated And Local Paths

Do not edit or stage generated, dependency, or local runtime paths:

- `elixir/_build/`
- `elixir/deps/`
- `elixir/cover/`
- `elixir/doc/`
- `elixir/tmp/`
- `elixir/log/`
- `elixir/logs/`
- `elixir/bin/`
- `elixir/.elixir_ls/`
- `elixir/.fetch/`
- `elixir/priv/static/assets/`
- `*.ez`
- `symphony_elixir-*.tar`
- env/auth files

Tracked exceptions that are source, not disposable output:

- `elixir/priv/static/dashboard.css`
- `elixir/test/fixtures/status_dashboard_snapshots/*`

## Safety And Hygiene

- Start with `git status --short --branch`; this checkout is often dirty. Preserve unrelated changes and stage paths explicitly.
- Never run destructive git cleanup against active issue workspaces or the shared harness checkout unless the user explicitly asks.
- Be careful with `mix workspace.before_remove`: it can close open GitHub PRs for the current branch through `gh`; use it only as an intentional workspace cleanup hook.
- Do not treat blocked/running/retry maps as durable state. They are in memory and restart-sensitive. Linear and the target repo workpad are the durable surfaces.
- Do not treat a paused old Codex automation as proof the live Symphony lane is dormant. For Alpine Reach, verify `bun run symphony:status` and the `http://127.0.0.1:4765/api/v1/state` surface.
- Do not treat `launchctl` reporting a periodic starter as not running as daemon failure by itself. Check the actual Symphony status/API.
- Avoid broad `pkill`, `lsof`-only daemon cleanup, or process matching that ignores workflow path, log root, and port.

## When Changing Behavior

- Runtime/scheduling changes usually require tests around `Orchestrator`, `AgentRunner`, `Workspace`, `Codex.AppServer`, or `Config.Schema`.
- Config or workflow-contract changes should update `elixir/README.md`, `elixir/WORKFLOW.md`, `SPEC.md`, or `docs/multi-repo-linear-workflows.md` when the public behavior changes.
- UI/API changes should cover both `Presenter` shape and the LiveView/controller path when the rendered or JSON behavior changes.
- Logging changes should follow `elixir/docs/logging.md`: include `issue_id`, `issue_identifier`, and `session_id` where relevant.
