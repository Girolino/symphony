# Multi-Workflow Runtime Specification

Status: Draft v0.1
Last updated: 2026-06-20

## Purpose

This document specifies the next Symphony evolution: one reusable harness that can operate multiple
workflow instances across multiple projects, expose their effective prompts/configuration in the UI,
and support more than one agent runtime.

This is an implementation specification for the local Symphony harness. It does not replace
[`SPEC.md`](../SPEC.md), which remains the language-agnostic service contract.

## Problem Statement

The current local production workflow runs Alpine Reach issues through one Linear-backed
implementation flow. That proves the runner model, but it mixes three concerns that need to become
separate before Symphony can serve every project:

- reusable orchestration primitives,
- workflow policy and prompts,
- the concrete agent runtime used to execute a turn.

Symphony should become a generic abstraction for project work. Most projects should be able to use a
shared workflow pack with small per-project overrides, while unusual cases remain expressible through
hooks, project configuration, or a custom workflow pack.

## Goals

- Support multiple configured workflow instances in one Symphony installation.
- Keep the Symphony core generic and free of Alpine Reach, Dr. Thomas, or other product-specific
  policy.
- Add a local SQL-backed authoring and publication layer for workflow instances, packs, prompts,
  templates, steps, revisions, run snapshots, and audit events.
- Introduce workflow packs as reusable templates for common work shapes such as end-to-end
  implementation, PR review, release smoke, or issue triage.
- Let each project define its own instance configuration: tracker, repo path, workspace root, logs
  root, port, lock path, hooks, state names, and validation commands.
- Show workflow inventory, active runs, prompt/config metadata, and reload errors in the UI.
- Give each run a stable run id and record the prompt/config/runtime snapshot used at dispatch.
- Preserve the existing one-daemon-per-repo/workflow isolation model unless an explicit future
  change replaces it.
- Prepare the runner boundary so Codex app-server remains one implementation and Claude Code can be
  added later without rewriting orchestration policy.

## Non-Goals

- Do not build a multi-tenant hosted control plane.
- Do not hardcode Linear state machines or PR review policy into the Symphony core.
- Do not require all projects to use identical issue states, labels, prompts, validation gates, or
  release policy.
- Do not merge all repos into one shared queue.
- Do not display or hash resolved secret values in any prompt/config inspector.
- Do not require SQL for direct `WORKFLOW.md` startup or file-based operation.
- Do not add Claude Code support as part of the first implementation phase unless the runner adapter
  boundary is already stable.
- Do not replace repo-owned guard scripts with a universal guard implementation.

## Core Concepts

### Workflow Pack

A workflow pack is a reusable template for a type of work.

Examples:

- `linear-e2e-implementation`
- `linear-pr-review`
- `linear-release-smoke`
- `github-pr-review`
- `manual-queue-triage`

A pack may include:

- default YAML configuration,
- prompt templates,
- required capability declarations,
- UI labels and phase groupings,
- documentation for expected project overrides,
- optional helper scripts that remain generic.

A pack must not include project-specific paths, ports, Linear project slugs, product URLs, or
release rules.

### Workflow Instance

A workflow instance binds a pack to a real project.

Examples:

- `alpine-reach/e2e-implementation`
- `dr-thomas/pr-review`
- `agent-rs/research-loop`
- `natuvera/release-smoke`

An instance owns:

- stable instance id,
- source mode,
- active revision or workflow path,
- display name,
- workflow pack reference,
- tracker configuration,
- repo root,
- workspace root,
- logs root,
- optional server port,
- pid file,
- browser or Computer Use lock path,
- hook commands,
- state and label names,
- agent runtime choice,
- overrides for prompt/config defaults.

The instance is the operator-facing unit shown in the UI.

### Agent Runtime

An agent runtime is the execution engine used by an instance.

Initial supported runtime:

- `codex_app_server`

Future supported runtime:

- `claude_code`

The workflow pack describes the work. The agent runtime describes how the prompt is executed.

### Run

A run is one dispatch of one issue or work item into one workflow instance.

A run must have a stable `run_id` allocated before the agent process starts. The `run_id` is the
primary key for run detail APIs and UI deep links.

`run_id` should be globally unique across future aggregated dashboards. Use UUIDv7 when available,
or a daemon-prefixed monotonic id with enough entropy to avoid collisions across daemon restarts.

Runtime-specific session ids are attributes of the run, not identifiers for the run itself. For
Codex app-server, the current `session_id` is derived from a thread id and a turn id, so it can
change across turns. The UI may display the current runtime session id, but it must not use it as
the stable run URL key.

At dispatch, Symphony must snapshot:

- workflow instance id,
- workflow pack id and version, if present,
- agent runtime kind,
- effective prompt hash,
- effective config hash,
- prompt source paths,
- config source paths,
- issue id and issue identifier,
- worker host, when assigned.

Those frozen values remain attached to the run even if the workflow file reloads while the agent is
still active.

### Source Mode

Each workflow instance has one active source mode:

- `file`: runtime behavior comes from a `WORKFLOW.md` path. The dashboard may inspect, import, or
  export, but it must not silently mutate the file.
- `database`: runtime behavior comes from a published workflow revision stored in the local
  database.
- `hybrid`: the database stores drafts and publications, while exported files or repo-owned files
  remain visible as source references.

The UI and API must show the source mode, active source path or revision id, and last-known-good
reload status.

### Draft, Revision, And Publication

A draft is mutable authoring state. It may contain invalid config or incomplete prompts while an
operator is editing.

A revision is immutable. It is created only after validation passes and contains canonical redacted
prompt/config payloads plus hashes.

A publication is an append-only event that makes one immutable revision active for one workflow
instance. Publishing must use optimistic locking so two dashboard sessions cannot accidentally
overwrite each other.

Rollback republishes a previous immutable revision as a new publication event. In-flight runs keep
their run-start revision/hash snapshots.

### Workflow Setup Wizard

The dashboard should provide a guided workflow creation flow. The intended operator action is:

```text
Create workflow -> select project folder -> choose workflow pack -> connect tracker -> configure runtime -> validate -> publish
```

The wizard should be able to:

- select or enter a local repo folder path,
- validate that the folder exists and is safe to use,
- detect Git metadata, remotes, current branch, and likely package/runtime files,
- import an existing `WORKFLOW.md` when present,
- choose a workflow pack such as implementation, PR review, release smoke, or triage,
- choose an agent runtime such as Codex app-server or Claude Code,
- select or create a Linear team/project using configured Linear credentials,
- map or create tracker states, labels, and views when supported by the tracker adapter,
- choose workspace root, logs root, port, pid file, LaunchAgent label, and lock paths,
- configure hooks and validation commands,
- preview the effective prompt/config before publishing.

Folder selection is a local privileged operation. It must be available only when the dashboard write
surface is explicitly enabled, and it should restrict browsing to configured allowed roots unless an
operator types and confirms an absolute path.

Folder inspection must canonicalize paths, reject symlink or `..` traversal escapes from allowed
roots, and report the resolved path separately from the user-entered path.

## Configuration Model

Symphony should support an explicit instance manifest before it attempts to manage many workflows.

Current implementation note: the Elixir app currently uses `ecto` for embedded schemas and
changesets only. It does not have `Ecto.Repo`, `ecto_sql`, SQLite, Postgres, migrations, or database
supervision. The current persistence model is `WORKFLOW.md` on disk, application env, GenServer
memory, workspaces, logs, and local metric files.

The first SQL backend should be local SQLite through Ecto SQL unless a later requirement needs a
server database. SQLite matches the current local-daemon operating model and keeps the workflow
catalog portable with the harness.

SQLite topology:

- Use one writable SQLite catalog file per daemon/workflow instance.
- Use WAL mode and a non-zero `busy_timeout`.
- Forbid two daemon processes from sharing the same writable catalog file.
- Store run snapshots and audit events in the daemon-local catalog that owns the run.
- Use a separate read-only discovery registry, or manifest list, for the multi-daemon dashboard to
  find daemon API URLs and catalog metadata.
- Phase 2d aggregation reads daemon APIs or read-only registry data; it must not make multiple
  daemons write to one shared SQLite file.

Suggested layout:

```text
symphony/
  workflows/
    linear-e2e-implementation/
      WORKFLOW.md
      README.md
    linear-pr-review/
      WORKFLOW.md
      README.md
  instances/
    dr-thomas.alpine-reach.e2e.yaml
    dr-thomas.alpine-reach.pr-review.yaml
```

The exact directory names may change during implementation, but the model should stay explicit:
packs are reusable definitions, instances are project bindings.

### SQL-Backed Workflow Catalog

The database is an authoring, publication, audit, and run-snapshot store. It should not be required
for direct file-based startup.

Minimum tables:

- `workflow_instances`: local instance identity, source mode, display name, repo path, active pack,
  tracker kind, runtime kind, daemon fields, and active publication pointer.
- `workflow_packs`: reusable pack identity and metadata.
- `workflow_pack_versions`: immutable pack payloads, version labels, source paths, capability
  declarations, and hashes.
- `workflow_drafts`: mutable editor state for an instance or pack.
- `workflow_revisions`: immutable validated payloads for prompts, templates, steps, config, and
  hashes.
- `workflow_publications`: append-only publication events that activate a revision for an instance.
- `workflow_run_snapshots`: run-start snapshots tying a run id to the active source mode, revision
  id or file path, prompt hash, config hash, runtime kind, and issue/work item identity.
- `workflow_audit_events`: create, validate, publish, rollback, import, export, tracker setup, and
  safety-confirmation events.

`workflow_audit_events` are append-only and immutable. Corrections are represented by new audit
events rather than updates or deletes.

Phase 1 run snapshots are in-memory/projection data. Phase 2b persists those snapshots into
`workflow_run_snapshots`, and run-detail APIs should prefer the persisted snapshot once the SQL
catalog exists.

Prompts, templates, hooks, validation commands, and workflow steps may be stored as JSON
subdocuments in drafts/revisions at first. Workflow steps must still have stable ids, explicit
positions, names, kinds, required capabilities, transition metadata, and validation metadata so the
UI can add, remove, reorder, diff, and publish them safely. If JSON subdocuments become hard to
query or validate, split them into normalized child tables later.

The catalog stores unresolved/redacted configuration. It must not store resolved API tokens or
secret values. Secret fields reference environment variables or secret aliases.

Database mode source of truth:

- Drafts are editable from the dashboard.
- Published revisions are immutable.
- The active publication pointer is the runtime source of truth.
- `WorkflowStore` loads the active published revision and still applies last-known-good reload
  semantics.

File mode source of truth:

- `WORKFLOW.md` remains the runtime source of truth.
- The dashboard may create a synthetic read-only revision for display and run snapshots.
- Import can copy a file workflow into a database draft.
- Export can write a database revision back to a `WORKFLOW.md` candidate, but must be explicit.

Hybrid mode source of truth:

- The dashboard must show both database revision and file source references.
- Operators must be able to see whether the active runtime source is file or database.

### Workflow Authoring Lifecycle

Dashboard edits never change active runtime behavior until publish.

```text
Draft created
  -> Validate
  -> Preview effective workflow
  -> Diff
  -> Publish revision
  -> Reload workflow store
  -> Last-known-good updated or reload failure recorded
```

Validation must block publication on:

- YAML/config parse errors,
- schema validation errors,
- unknown template variables,
- literal committed secrets,
- unsafe repo/workspace/log paths,
- non-loopback bind changes without explicit confirmation,
- hook or runtime command changes without explicit confirmation,
- resource collisions with other visible instances,
- missing required runtime/Symphony capabilities,
- tracker project/state/label mismatches that the selected pack requires.

Publishing should show:

- source mode,
- affected instance,
- effective prompt/config before and after,
- step order before and after,
- source paths or revision ids,
- prompt/config hashes,
- active runs that will continue using old snapshots,
- reload result.

Example instance manifest:

```yaml
id: dr-thomas.alpine-reach.e2e
display_name: Dr. Thomas / Alpine Reach E2E Implementation
workflow_pack: linear-e2e-implementation

project:
  product_name: Alpine Reach
  repo_slug: dr-thomas
  repo_root: /Users/fernandomaluf/Dropbox/dr-thomas
  workflow_path: /Users/fernandomaluf/Dropbox/dr-thomas/WORKFLOW.md

runtime:
  daemon:
    host: 127.0.0.1
    port: 4765
    logs_root: ~/.cache/alpine-reach-symphony/logs
    pid_file: ~/.cache/alpine-reach-symphony/symphony.pid
    launch_agent_label: com.alpine-reach.symphony
  workspace:
    root: ~/.cache/alpine-reach-symphony/workspaces
  locks:
    browser: /tmp/alpine-reach-computer-use.lock

agent_runtime:
  kind: codex_app_server
  command: codex --config shell_environment_policy.inherit=all app-server

overrides:
  tracker:
    kind: linear
    project_slug: alpine-reach-webapp-automation-queue-e4c174a60d79
  hooks:
    before_run: bun scripts/symphony-guard.ts --apply --before-run
  validation:
    commands:
      - bun run symphony:doctor
```

### Trust And Secret Boundary

Instance manifests, workflow files, hook commands, and agent runtime commands are trusted,
code-equivalent inputs. They can run shell commands and can control which project and credentials a
daemon uses.

Rules:

- Treat committed manifests and workflow packs with the same review standard as source code.
- Committed manifests and packs must reference secrets through environment variables such as
  `$LINEAR_API_KEY`; they must not contain literal API tokens.
- Local uncommitted operator overrides may use literal secrets only when they are outside version
  control and never surfaced in logs, UI, hashes, or API responses.
- Server bind host is part of the trusted runtime config. The default remains loopback
  `127.0.0.1`; any broader bind address must be explicit in the manifest or CLI.
- The UI must clearly show source paths for manifests, packs, and repo-owned workflow files so an
  operator can tell which trusted files are affecting the daemon.

### Effective Workflow

For each instance, Symphony should compute an effective workflow:

```text
runtime/schema defaults
  < workflow pack defaults
  < repo-owned WORKFLOW.md config or prompt body, when configured
  < published database revision, when source_mode=database or hybrid and a revision is active
  < instance manifest overrides
```

Higher-precedence sources override lower-precedence sources. Map values are deep-merged. List,
string, number, boolean, and null values replace the lower-precedence value. This keeps nested
config additive while preventing state lists, command lists, and prompt fragments from merging by
accident.

The UI and API must expose the effective workflow metadata so operators can see what the daemon is
actually using.

The first implementation may keep the current single `WORKFLOW.md` parser and add read-only
metadata around it. Later phases can add full pack inheritance.

Reload triggers depend on source mode:

- `file`: reload when the workflow file stamp changes or an explicit refresh is requested.
- `database`: reload when a publication changes the active revision pointer or an explicit refresh
  is requested.
- `hybrid`: reload according to the active runtime source, and show both file and database source
  metadata in UI/API.

### Redacted Effective Config And Hashes

There are two effective config views:

- `runtime_effective_config`: the fully resolved config the daemon uses internally.
- `operator_effective_config`: the redacted, logical config exposed to UI/API and used for hashing.

Only `operator_effective_config` may be displayed or hashed.

Rules:

- Secret-bearing fields are redacted and retain their environment-variable reference when available.
- Literal secret values must be replaced with a fixed marker such as `"<redacted>"`.
- Path fields should preserve the configured logical value for hashing instead of resolved,
  machine-specific defaults when possible.
- Hashes must be deterministic across machines. Use SHA-256 over a canonical serialized form of the
  redacted prompt/config payloads, not VM-local hash functions.
- Prompt/config hashes are captured onto the run record at dispatch and do not change for that run
  after reloads.

### Last-Known-Good Reload Status

Workflow reloads are all-or-nothing. A successful reload updates the last-known-good workflow,
metadata, prompt hash, config hash, and reload timestamp together. A failed reload keeps the previous
last-known-good workflow active and records the failed path, timestamp, and error class.

The runtime should expose reload status through an internal accessor rather than forcing API/UI
code to infer status from logs.

Minimum reload error classes:

- `workflow_missing`
- `workflow_parse_error`
- `config_validation_error`
- `manifest_parse_error`
- `pack_missing`
- `pack_validation_error`
- `capability_mismatch`
- `secret_resolution_error`

## Agent Runtime Adapter

The current `AgentRunner` is effectively a Codex app-server runner. To support Claude Code or other
engines, Symphony should introduce an adapter boundary.

Required adapter responsibilities:

- validate runtime configuration,
- start the agent process in the issue workspace,
- send the rendered prompt,
- stream events into the orchestrator,
- expose blocked/input-required conditions,
- expose usage metadata when available,
- stop the process cleanly,
- report runtime capabilities.

Conceptual callbacks:

```text
validate(config) -> ok | error
start(session) -> runtime_handle
run_turn(runtime_handle, prompt, context) -> turn_outcome
stream_events(runtime_handle) -> event
stop(runtime_handle) -> ok
capabilities(config) -> capability_set
```

The orchestrator should depend on runtime capabilities, not on Codex-specific protocol details.

### Turn Loop Ownership

The workflow orchestrator owns dispatch, retry, reconciliation, and run identity. The runtime
adapter owns the protocol needed to execute one agent turn.

The loop that decides whether to run another turn must be expressed in runtime-neutral terms:

```text
turn_outcome:
  completed
  failed
  input_required
  approval_required
  stopped
```

The Codex adapter may map Codex-specific events into this vocabulary. Future adapters must not be
forced to emit `codex_*` fields or Codex event names.

### Normalized Runtime Events

Runtime events should use generic names in orchestrator state and public projections:

- `runtime_session_started`
- `runtime_turn_started`
- `runtime_turn_completed`
- `runtime_turn_failed`
- `runtime_input_required`
- `runtime_approval_required`
- `runtime_usage_reported`
- `runtime_rate_limited`

Codex-specific fields may remain inside adapter-private payloads, logs, or compatibility views, but
new workflow-aware APIs should expose normalized runtime fields.

### Runtime Capabilities

Capabilities are used by workflow packs and the UI to decide what is safe to run.

Examples:

- `structured_events`
- `token_usage`
- `operator_input_signal`
- `mcp_tools`
- `workspace_sandbox`
- `dynamic_tools`
- `linear_graphql_tool`

If a workflow pack requires a capability that the selected runtime does not provide, startup should
fail with a clear configuration error.

Some capabilities are runtime-provided, while others are Symphony-provided. For example,
`linear_graphql_tool` may be injected by Symphony for a compatible runtime rather than implemented
by the runtime executable itself. Capability validation must record the provider so failures explain
whether the missing piece is the runtime, Symphony, or instance configuration.

Numeric runtime settings such as `turn_timeout_ms` are config fields, not capabilities. A runtime
may still expose a capability such as `enforced_turn_timeout` if it can guarantee timeout behavior.

## UI Requirements

The UI should become an operator cockpit for workflow instances, not only a live issue dashboard.

The dashboard should have three top-level operating areas:

- `Observe`: runtime queue, runs, blocked state, guardrails, metrics, and reload status.
- `Configure`: workflow instances, packs, prompts, templates, steps, validation, and tracker setup.
- `History`: drafts, publications, rollbacks, reload failures, audit events, and run snapshots.

### Workflow Inventory

Show one dense table row per workflow instance:

- instance id,
- display name,
- project/repo path,
- workflow pack,
- agent runtime,
- daemon status,
- port/API URL,
- workspace root,
- logs root,
- last successful workflow reload,
- latest config or prompt error,
- active/running/blocked/retry counts.

### Create Workflow Wizard

The `Configure` area should include a guided creation flow for a new workflow instance.

Recommended steps:

1. Select project folder.
2. Confirm repository metadata.
3. Choose workflow pack.
4. Choose agent runtime.
5. Connect tracker.
6. Configure runtime resources.
7. Configure prompts, templates, steps, hooks, and validation commands.
8. Validate and publish.

Folder selection should support:

- recent repo folders,
- configured allowed roots,
- manual absolute path entry,
- server-side path validation,
- Git remote/branch detection,
- existing `WORKFLOW.md` import,
- package/runtime detection such as `mix.exs`, `package.json`, `bun.lockb`, `mise.toml`, or
  `.tool-versions`.

Linear setup should support:

- selecting an existing Linear team and project,
- creating a new project when credentials allow it,
- previewing required states, labels, and views,
- applying tracker setup only after confirmation,
- using dry-run/preview before any mutation,
- making setup apply idempotent so re-running it does not duplicate states, labels, views, or
  projects,
- recording every tracker mutation in the audit log.

The wizard should end by creating a database draft, validating it, and publishing the first revision
only after explicit confirmation.

### Workflow Editor

The editor should be dense and operational:

- left rail: instance, pack, template, prompt, step, hook, validation, and tracker sections,
- center pane: structured forms for common fields plus raw YAML/Markdown editors for advanced
  editing,
- right inspector: source stack, effective diff, validation warnings, hashes, affected instances,
  active runs, and publication status.

Prompt editor requirements:

- Markdown editor,
- variable autocomplete,
- preview against a selected issue/run fixture,
- unknown-variable warnings,
- token estimate when available,
- prompt hash,
- source paths,
- redaction status.

Step editor requirements:

- ordered list of steps/phases,
- explicit move up/down controls in addition to any drag interaction,
- step kind, state mapping, owner role, required capabilities, hooks, validation commands, and
  transition guard labels,
- diff of step order and changed fields before publish.

Safety affordances:

- draft locks or optimistic conflict detection,
- publish confirmation for hook/runtime command changes,
- typed confirmation for broad bind hosts and unsafe paths,
- rollback to prior published revision,
- copy patch/export to `WORKFLOW.md`,
- visible audit log for every validate, publish, rollback, import, export, and tracker mutation.

### Prompt And Config Inspector

For each instance, show:

- effective prompt body,
- prompt source paths,
- prompt hash,
- redacted operator effective config,
- config source paths,
- config hash,
- active workflow pack version,
- last-known-good reload timestamp,
- current reload error, if any.

The UI should make it obvious when a daemon is using a last-known-good workflow because the latest
file reload failed.

### Run Detail

For each active run, show:

- stable run id,
- issue identifier and state,
- workflow instance id,
- workflow pack,
- agent runtime,
- workspace path,
- current runtime session id, when available,
- turn count,
- prompt hash used at run start,
- config hash used at run start,
- prompt/config source paths used at run start,
- started_at,
- last_event_at,
- blocked reason, if any,
- usage metrics when available.

This prevents a run from being misread after a prompt or config reload.

## API Requirements

Add or extend API surfaces so the UI and operator scripts can inspect workflows without scraping
HTML.

Suggested endpoints:

```text
GET /api/v1/workflows
GET /api/v1/workflows/:instance_id
GET /api/v1/workflows/:instance_id/prompt
GET /api/v1/workflows/:instance_id/config
GET /api/v1/runs/:run_id
GET /api/v1/workflow-packs
POST /api/v1/workflow-drafts
PATCH /api/v1/workflow-drafts/:draft_id
POST /api/v1/workflow-drafts/:draft_id/validate
POST /api/v1/workflow-drafts/:draft_id/publish
POST /api/v1/workflows/:instance_id/rollback
POST /api/v1/workflows/:instance_id/export
POST /api/v1/setup/folders/inspect
GET /api/v1/setup/linear/teams
GET /api/v1/setup/linear/projects
POST /api/v1/setup/linear/projects
POST /api/v1/setup/linear/apply
```

The existing `/api/v1/state` shape may remain for backward compatibility. New workflow-aware fields
should be additive until callers migrate.

Literal workflow routes must be registered before any catch-all issue detail route such as
`/api/v1/:issue_identifier`. Route tests should prove that `/api/v1/workflows` resolves to workflow
inventory, not issue detail.

Write APIs must be disabled unless dashboard write mode is explicitly enabled. When enabled, write
APIs must keep CSRF protections for browser requests, require a local write token or equivalent
operator authentication, and record audit events for all mutations.

## State And Isolation Model

The default operating model remains one daemon per repo/workflow instance, isolated by:

- workflow path or instance manifest,
- port,
- workspace root,
- logs root,
- pid file,
- LaunchAgent label,
- Linear project slug,
- browser or Computer Use lock path,
- SSH worker host pool and per-host concurrency limit, when configured.

The multi-workflow UI may aggregate multiple daemon APIs in a later phase, but the first phase
should not require one process to supervise every project.

When multiple instance manifests are visible to one operator UI, Symphony should warn about obvious
resource collisions before dispatch:

- duplicate port/host pairs,
- duplicate workspace roots,
- duplicate logs roots,
- duplicate pid files,
- duplicate browser or Computer Use lock paths,
- duplicate LaunchAgent labels.

## Implementation Phases

### Implementation Workspace

Implementation work for this specification should happen in an isolated git worktree, not in the
shared harness checkout.

Required local path:

```text
/Users/fernandomaluf/Dropbox/worktrees/symphony
```

Rules:

- Create the parent directory when needed.
- Create the worktree from the Symphony repository on a dedicated implementation branch.
- Keep the shared checkout at `/Users/fernandomaluf/Dropbox/harnesses/symphony` available for
  reference and live daemon inspection, but do not use it for the implementation edits.
- Preserve unrelated changes in either checkout. Stage and commit paths explicitly.
- Run validation from the implementation worktree unless a test explicitly needs to inspect a live
  daemon started elsewhere.

### Phase 1: Read-Only Workflow Metadata And Run Snapshots

- Add an internal workflow identity model.
- Compute deterministic redacted prompt/config hashes for the currently loaded `WORKFLOW.md`.
- Allocate stable run ids at dispatch.
- Snapshot workflow instance id, runtime kind, prompt hash, config hash, and source paths onto each
  run before the agent process starts.
- Keep Phase 1 run snapshots in memory/projections; persistence arrives with the SQL catalog.
- Expose last-known-good reload status and latest reload error through an internal accessor.
- Add workflow metadata to existing state projections.
- Show workflow name, prompt hash, config hash, source path, and reload status in the UI.
- Keep the current single workflow path runtime behavior.

### Phase 2a: Source Modes And Single-Instance Manifests

- Add instance manifest parsing.
- Allow the CLI to start from an instance manifest.
- Keep direct `WORKFLOW.md` startup for backward compatibility.
- Add `/api/v1/workflows` returning the single local instance for the current daemon.
- Render the current instance in the UI.
- Document the one-daemon-per-instance operating model.
- Enforce manifest trust and secret rules for committed manifests where detectable.
- Preserve loopback `127.0.0.1` as the default server bind host.
- Add explicit `file`, `database`, and `hybrid` source-mode fields even if only `file` is active at
  first.

### Phase 2b: Local SQL Workflow Catalog

- Add a local SQLite-backed Ecto SQL repository for workflow authoring data.
- Add migrations and schemas for instances, packs, pack versions, drafts, revisions, publications,
  run snapshots, and audit events.
- Persist run-start snapshots into `workflow_run_snapshots`.
- Configure one writable SQLite catalog per daemon with WAL and busy timeout.
- Keep direct file mode working without requiring the database.
- Add import from `WORKFLOW.md` into a database draft.
- Add explicit export from a database revision to a `WORKFLOW.md` candidate.
- Store unresolved/redacted config only; never store resolved secrets.
- Add append-only publication and rollback semantics.

### Phase 2c: Dashboard Workflow Setup And Editing

- Add the `Configure` and `History` dashboard areas.
- Add the create-workflow wizard with project folder selection, repo inspection, pack selection,
  agent runtime selection, tracker setup, runtime resource setup, validation, and publish.
- Add workflow draft editing for prompts, templates, steps, hooks, validation commands, and tracker
  setup.
- Add preview, diff, validation, publish, rollback, import, export, and audit-log UI.
- Add guarded write APIs with local write-mode/auth requirements.
- Keep dashboard edits inert until explicit publish.

### Phase 2d: Multi-Daemon Workflow Inventory

- Add read-only aggregation of multiple daemon APIs or manifest entries.
- Detect obvious port/path/lock collisions across visible instances.
- Keep runtime execution isolated per daemon.
- Do not move multiple workflow instances into one process in this phase.

### Phase 3: Workflow Packs

- Add pack directories and inheritance/override rules.
- Add validation that pack defaults plus instance overrides produce a valid existing workflow config.
- Add pack-level capability declarations.
- Parse and display required capabilities, but defer hard capability mismatch enforcement until the
  runtime adapter reports normalized capabilities.
- Keep repo-owned prompt/config support so project policy can stay close to project code.

### Phase 4: Runtime Adapter Boundary

- Extract Codex app-server-specific behavior behind a runtime adapter.
- Keep current Codex behavior unchanged.
- Add adapter capability reporting.
- Define normalized turn outcomes, runtime events, blocked reasons, and usage metrics.
- Rename new workflow-aware state/projections away from `codex_*` fields while preserving backward
  compatibility where needed.
- Decide and document whether the orchestrator or adapter owns the multi-turn continuation loop.
- Add tests proving orchestration is runtime-agnostic for startup, turn execution, events, blocked
  signals, usage, and stop.
- Enforce workflow pack capability requirements using adapter and Symphony-provided capability
  reports.

### Phase 5: Additional Runtimes And Packs

- Add a Claude Code runtime adapter.
- Add a PR review workflow pack.
- Add targeted UI affordances for PR review runs.
- Decide whether the first PR review tracker is Linear-driven, GitHub-driven, or supports both.
- Keep project-specific review policy in instance config or repo-owned scripts.

## Testing Requirements

Each phase should include proportional tests.

Phase 1:

- workflow metadata projection tests,
- redacted prompt/config hash stability tests,
- run id allocation tests,
- run id uniqueness tests across daemon restarts or generated daemon prefixes,
- run-start snapshot tests,
- mid-run workflow reload regression tests proving run hashes do not change,
- reload error tests,
- secret redaction tests,
- dashboard rendering tests.

Phase 2a:

- instance manifest parsing tests,
- CLI startup compatibility tests,
- path expansion tests,
- trust/secret validation tests,
- loopback default tests,
- source-mode projection tests,
- API shape tests.

Phase 2b:

- SQLite repository startup tests,
- WAL and busy-timeout configuration tests,
- shared writable catalog rejection tests,
- migration tests,
- workflow catalog schema tests,
- import/export tests for `WORKFLOW.md`,
- draft/revision/publication/rollback tests,
- persisted run snapshot tests,
- audit event tests,
- audit append-only immutability tests,
- file mode without database tests,
- secret non-persistence tests.

Phase 2c:

- create-workflow wizard LiveView tests,
- folder inspection tests,
- safe path, symlink, traversal, canonicalization, and allowed-root tests,
- Linear team/project selection tests using fake tracker clients,
- tracker setup dry-run/apply/idempotency tests,
- draft edit/validate/publish tests,
- publish blocking tests for unsafe changes,
- write-mode/auth tests,
- rollback UI/API tests.

Phase 2d:

- multi-daemon inventory aggregation tests,
- resource collision detection tests,
- read-only aggregation failure tests.

Phase 3:

- pack inheritance tests,
- override precedence tests,
- capability declaration parsing tests,
- invalid pack/config error tests.

Phase 4:

- runtime adapter contract tests,
- Codex adapter regression tests,
- orchestrator tests that use a fake runtime adapter,
- normalized event and blocked vocabulary tests,
- required capability validation tests,
- no new `codex_*` keys in workflow-aware projections.

Phase 5:

- runtime-specific smoke tests,
- PR review pack rendering tests,
- integration tests for capability mismatch failures.

Cross-cutting:

- route precedence tests for `/api/v1/workflows` and future literal API paths,
- legacy `/api/v1/state` tests that assert required existing fields remain present without requiring
  strict full-payload equality,
- deterministic SHA-256 hash tests over canonical redacted payloads.

### Required Validation Gate

Before handoff, implementation branches must run the strongest proportional gate needed to prove the
harness still works.

Minimum gate for code changes:

```bash
cd /Users/fernandomaluf/Dropbox/worktrees/symphony/elixir
mise exec -- mix specs.check
mise exec -- mix format --check-formatted
mise exec -- mix lint
mise exec -- mix test
make all
```

Additional gates by scope:

- UI/API changes: run focused dashboard/API tests and route-precedence tests.
- Config, manifest, workflow-store, or pack changes: run parser, reload, redaction, hash, and
  compatibility tests.
- SQL catalog changes: run migrations, repository tests, import/export tests, publication/rollback
  tests, and a file-mode startup check proving the database is not required for direct
  `WORKFLOW.md` operation.
- Dashboard workflow setup changes: run wizard, folder inspection, tracker setup, write-mode/auth,
  draft validation, publish, rollback, and audit-log tests.
- Orchestrator, workspace, agent-runner, or runtime-adapter changes: run focused scheduler,
  lifecycle, fake-runtime, Codex-adapter, retry, blocked-state, and stop/reconciliation tests.
- Static asset or dashboard CSS changes: verify rendered dashboard behavior, not only compilation.
- Practical runtime validation is required when the implementation changes external orchestration,
  agent launch, prompt delivery, turn handling, blocked/input-required handling, runtime event
  normalization, dynamic tool injection, workspace lifecycle, or runtime adapter behavior. Cost from
  real Codex or Claude Code usage is not a reason to skip this validation.
- Live E2E remains non-routine because it creates disposable Linear resources and launches real
  agents, but it must run when fake/local tests cannot prove the changed behavior or when the
  changed behavior is specifically about real external orchestration.
- Codex-backed changes must include at least one real Codex app-server run through Symphony unless
  the change is provably documentation-only or UI-only.
- Claude Code runtime support, once implemented, must include at least one real Claude Code run
  through Symphony before handoff.

If a required gate cannot run, the handoff must state the exact command, failure/blocker, and the
remaining risk.

## Compatibility Rules

- Existing `./bin/symphony /path/to/WORKFLOW.md` startup must continue to work.
- Direct file-mode startup must not require a database, migrations, or writable catalog path.
- A daemon using database mode must load only immutable published revisions, not mutable drafts.
- Existing `/api/v1/state` callers must not break during initial phases.
- Existing Alpine Reach daemon control scripts should continue using their repo-owned wrapper until
  an instance manifest intentionally replaces that entrypoint.
- Existing `hooks.before_run` exit code `75` skip behavior must be preserved.
- Existing Codex app-server dynamic tools should continue to work for Codex-backed instances.
- Existing Codex `session_id` may remain visible, but new run detail APIs must use stable `run_id`.
- Existing catch-all issue detail routes must not shadow new literal workflow API routes.

## Risks And Trade-Offs

- Pack inheritance can become a hidden source of policy drift if operators cannot inspect the
  effective prompt/config. The UI must show effective values and hashes.
- A single global workflow catalog can tempt product-specific policy into the harness. Reviews
  should reject product rules that belong in project instances or repo-owned scripts.
- Claude Code support may not map cleanly to Codex app-server events. The adapter boundary should
  model capabilities and normalized events rather than assuming protocol parity.
- Aggregating multiple daemons in one UI is useful, but it should not weaken process isolation in
  the first implementation.
- Prompt hashes are useful for auditability, but they are not enough by themselves. Run detail must
  also record the workflow instance, pack, config hash, and runtime kind used at run start.
- Displaying the wrong config view can leak secrets. Operator-facing config must be redacted before
  hashing, logging, or rendering.
- A SQL catalog can become the wrong source of truth if file mode, database mode, and hybrid mode
  are not explicit in UI/API and run snapshots.
- A shared writable SQLite catalog can create lock contention or cross-daemon coupling. Keep one
  writable catalog per daemon and aggregate read-only.
- A workflow editor can accidentally make drafts live if the runtime reads mutable rows. Runtime
  loading must use immutable published revisions only.
- Folder selection, hook editing, runtime command editing, and tracker setup make the dashboard a
  privileged local write surface. Write mode, auth, confirmations, audit events, and rollback are
  required before exposing these controls.
- A manifest registry can hide resource collisions. Aggregated UI should warn about duplicate ports,
  workspace roots, logs roots, pid files, LaunchAgent labels, and browser locks.
- A runtime adapter that only wraps Codex names will make Claude Code support brittle. New public
  state should use normalized runtime names and keep Codex details adapter-private or
  compatibility-only.

## Open Questions And Current Directions

- Workflow pack location: keep first-party packs in this repository first. Design the loader with an
  explicit search path so target repos can provide custom packs later.
- Instance manifest location: prefer target-repo-owned manifests for project policy, plus an
  optional local registry in this repository for operator discovery.
- First SQL backend: use local SQLite through Ecto SQL for the first implementation. Revisit server
  databases only if the harness becomes multi-machine or multi-operator.
- Dashboard write access: keep disabled by default. Enable only on loopback with explicit local
  write auth or an operator flag.
- File export policy: provide explicit export to `WORKFLOW.md`, but do not require database
  publications to auto-commit generated files.
- UI aggregation vs in-process supervision: aggregate existing per-daemon APIs read-only before
  attempting one process that supervises multiple workflow instances.
- Minimum Claude Code event model: define against a fake adapter first. Required events are
  turn-start, turn-end, blocked/input-required, optional usage, and clean stop.
- PR review tracker: model tracker as pluggable. Support both Linear and GitHub in the design, but
  ship one end-to-end workflow first.
- Guard scripts: extract reusable mechanisms such as exit-75 handling, hook invocation, lock
  acquisition, and workpad parsing helpers. Keep the decision content repo-owned.
