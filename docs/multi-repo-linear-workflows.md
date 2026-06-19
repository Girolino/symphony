# Multi-Repo Linear Symphony Workflows

Last updated: 2026-05-27

## Purpose

This document captures the Alpine Reach Symphony workflow work and the operating model we agreed on
for extending it to other repositories.

It is written for the next agent that needs to continue from here and create additional repo-specific
Linear projects, `WORKFLOW.md` contracts, and automation/watchdog surfaces.

The core decision:

- Do not turn the current Alpine Reach workflow into one large cross-repo platform yet.
- Use the same Symphony harness pattern for each repo.
- Create one Linear project and one repo-owned workflow per repo.
- Run one Symphony daemon per repo/workflow, isolated by port, workspace root, logs root, and browser
  lock path.

This gives reuse without forcing unrelated repos to share one noisy queue or one over-generalized
workflow.

## Current State

The official Symphony checkout lives here:

```text
/Users/fernandomaluf/Dropbox/harnesses/symphony
```

The first production-grade repo-specific workflow was built in:

```text
/Users/fernandomaluf/Dropbox/dr-thomas
```

That workflow is for the Alpine Reach webapp. It uses Linear as the durable queue and Symphony as the
daemon that dispatches agent workers.

Important current repo-specific files in `dr-thomas`:

```text
WORKFLOW.md
ops/symphony/README.md
ops/symphony/state-machine.json
scripts/sync-linear-symphony.ts
scripts/symphony-control.ts
scripts/symphony-guard.ts
scripts/computer-use-lock.ts
memories/workspace-memory/workflows/symphony-linear-automation.md
```

Important current harness-side changes:

- The Elixir reference implementation is used as the local Symphony service.
- The local harness has been patched so a `before_run` hook exit code of `75` is treated as an
  intentional skip instead of a broken worker.
- The harness exposes a local HTTP status API, used by repo control scripts:

```text
http://127.0.0.1:<port>/api/v1/state
```

For Alpine Reach, the port is currently:

```text
4765
```

## Architectural Model

Use this model for every repo:

```text
Linear Project -> repo WORKFLOW.md -> Symphony daemon -> isolated workspaces -> agent PRs -> review -> merge -> QA
```

Repo-specific pieces:

- Linear team and project slug
- GitHub repository
- local checkout path
- base branch and release branch
- install/build/test commands
- dev/staging/production URLs
- browser and Computer Use lock path
- production authority and release policy
- issue labels and views that make sense for the repo
- workflow prompt and validation rules

Shared pattern:

- Linear is durable state.
- Symphony is the scheduler/runner.
- The repo owns the workflow contract.
- Workers run in per-issue workspaces.
- Agents use task branches and PRs rather than direct shared-branch commits.
- Another agent reviews PRs; no human-review lane is required.
- Control Tower/status jobs summarize and route; they are not the executor.

## Recommended Shape Per Repo

For a new repo, create:

```text
<repo>/WORKFLOW.md
<repo>/ops/symphony/README.md
<repo>/ops/symphony/state-machine.json
<repo>/scripts/sync-linear-symphony.ts
<repo>/scripts/symphony-control.ts
<repo>/scripts/symphony-guard.ts
<repo>/scripts/computer-use-lock.ts
```

Then run one Symphony daemon for that repo:

```bash
/Users/fernandomaluf/Dropbox/harnesses/symphony/elixir/bin/symphony \
  /absolute/path/to/<repo>/WORKFLOW.md \
  --logs-root ~/.cache/<repo-slug>-symphony/logs \
  --port <unique-port>
```

Use a unique workspace root in that repo's `WORKFLOW.md`:

```yaml
workspace:
  root: ~/.cache/<repo-slug>-symphony/workspaces
```

Use a unique local browser/Computer Use lock:

```text
/tmp/<repo-slug>-computer-use.lock
```

Use a unique LaunchAgent name if installing a watchdog:

```text
~/Library/LaunchAgents/com.<repo-slug>.symphony.plist
```

## Port And Runtime Isolation

Every repo needs separate runtime resources.

Suggested port allocation:

```text
4765  alpine-reach / dr-thomas
4766  next repo
4767  next repo
4768  next repo
```

Do not reuse these across daemons:

- port
- workspace root
- logs root
- pid file
- LaunchAgent name
- Computer Use lock path
- Linear project slug

If two repos share a browser lock path, visual QA runs can fight over the same screen/browser.

## Linear Model

Use one Linear Project per repo.

Why:

- It keeps queue noise local to the repo.
- It keeps release state and QA state repo-specific.
- It avoids making every workflow state carry a repo prefix.
- It lets views answer one repo's operational questions cleanly.

The Alpine Reach project is:

```text
Team: ALP
Project: Alpine Reach Webapp Automation Queue
Slug: alpine-reach-webapp-automation-queue-e4c174a60d79
```

For another repo, create a similarly named project:

```text
<Product/Repo Name> Automation Queue
```

Examples:

```text
Engenious Automation Queue
RiskAssist Automation Queue
Thomas Personal Website Automation Queue
```

Recommended shared state names:

```text
Backlog
Todo
Triage
Routed
Ready for Orchestration
Claimed
Planning
Setup
Implementing
Verifying
Testing
In Progress
PR Open
Agent Review
Review Changes Requested
Merge Ready
Merging
Post-Merge Dev QA
Release Candidate
Production Smoke
Blocked
Done
Canceled
Duplicate
```

Important state semantics:

- `Backlog`: not dispatchable.
- `Todo`: accepted item, but not yet shaped.
- `Ready for Orchestration`: safe for Symphony to pick up.
- `Planning` through `Testing`: implementation and validation phases.
- `In Progress`: reconciliation-only legacy Linear bucket. Do not treat it as the real workflow
  lane. If an issue lands there, the guard should inspect workpad/branch/PRs and move it to the
  next explicit state.
- `PR Open`: implementation PR exists and should be reviewed by a different agent.
- `Agent Review`: independent review owns the PR.
- `Review Changes Requested`: implementation agent remediates review findings.
- `Merge Ready`: checks and review are green; merge steward can merge.
- `Post-Merge Dev QA`: merged-to-dev proof.
- `Release Candidate`: repo-specific develop/main release readiness.
- `Production Smoke`: read-only production validation.
- `Blocked`: only true external blockers.
- `Done`, `Canceled`, `Duplicate`: terminal.

Recommended shared labels:

```text
Automation inbox
User reported
Release blocker
Production smoke
Synthetic UX
Visual QA
Needs visual validation
Needs dev QA
CI test triage
PR review
Needs fix PR
Cross-agent handoff
Provider blocker
Automation control
Agent review
Symphony guardrail
Review loop exhausted
Symphony
Ready for orchestration
Production regression
```

Not every repo needs every label. Keep the common labels when they help route issues across
automation producers, PR review, release readiness, and smoke testing.

## Linear API Setup

The current scripts read the Linear key from:

```text
LINEAR_API_KEY
```

or:

```text
~/.config/linear-codex/env
```

with content:

```text
LINEAR_API_KEY=<key>
```

Rules:

- Never print the key.
- If a key was pasted into chat or logs, rotate it.
- Normalize malformed key files before debugging the scripts. A split or copied token can cause
  confusing `401` failures.
- Keep Linear issue/project writes in operator automation, not the app runtime.

## Repo-Owned `WORKFLOW.md`

Each repo should own its `WORKFLOW.md`.

The front matter config controls tracker, polling, workspace, hooks, agent concurrency, Codex
command, and timeouts.

Minimal repo-specific skeleton:

```yaml
---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "<linear-project-slug>"
  active_states:
    - Todo
    - Triage
    - Routed
    - Ready for Orchestration
    - Claimed
    - Planning
    - Setup
    - Implementing
    - Verifying
    - Testing
    - In Progress
    - PR Open
    - Agent Review
    - Review Changes Requested
    - Merge Ready
    - Merging
    - Post-Merge Dev QA
    - Release Candidate
    - Production Smoke
  terminal_states:
    - Backlog
    - Blocked
    - Done
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
polling:
  interval_ms: 60000
workspace:
  root: ~/.cache/<repo-slug>-symphony/workspaces
hooks:
  timeout_ms: 900000
  after_create: |
    git clone git@github.com:<owner>/<repo>.git .
    git fetch origin --prune
    git checkout -B <integration-branch> origin/<integration-branch>
    <install command>
  before_run: |
    git fetch origin --prune
    <repo guard command> --apply --before-run --issue "$(basename "$PWD")"
agent:
  max_concurrent_agents: 4
  max_turns: 24
  max_retry_backoff_ms: 300000
  max_concurrent_agents_by_state:
    "Production Smoke": 1
    "Post-Merge Dev QA": 1
    "Testing": 1
    "Release Candidate": 1
    "Merging": 1
    "Merge Ready": 1
    "Agent Review": 2
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
  turn_timeout_ms: 7200000
  read_timeout_ms: 10000
  stall_timeout_ms: 900000
---
# <Repo Name> Symphony Workflow

You are an autonomous Symphony worker for Linear issue `{{ issue.identifier }}`.
...
```

The prompt body should be repo-specific. It must include:

- issue metadata
- a goal contract
- non-negotiable safety/ownership rules
- state machine semantics
- workpad contract
- role routing by state
- review loop rules
- merge rules
- post-merge QA rules
- release candidate and production smoke rules if applicable
- evidence requirements

## The Symphony Workpad

Every issue should have exactly one active Linear comment starting with:

```md
## Symphony Workpad
```

The workpad is the durable handoff surface between agents.

Recommended shape:

````md
## Symphony Workpad

```text
workspace=<hostname>:<absolute path>@<short sha>
state=<current Linear state>
branch=<branch or none>
pr=<PR URL or none>
attempt=<attempt or first>
code_review_round=<0-5>
max_code_review_rounds=5
```

### Route
- Lane:
- Current owner role:
- Next truthful state:

### Plan
- [ ] ...

### Acceptance Criteria
- [ ] ...

### Validation
- [ ] ...

### Evidence
- ...

### Review Loop
- Current code-review round: 0/5
- Prior CR findings:
- Latest DeepReview run:
- Latest review verdict:

### Blockers
- none
````

The workpad prevents hidden state. A future worker should be able to resume from it without relying
on chat history.

## Guard Script Responsibilities

Every repo should have a repo-specific guard script.

The Alpine Reach guard currently handles:

- review-loop cap enforcement
- workpad/state mismatch visibility
- `In Progress`/PR-open reconciliation
- state update to `PR Open` when an open GitHub PR objectively exists
- skip exit code `75` so Symphony re-dispatches the right lane

Required guard behavior for new repos:

1. Load Linear API key safely.
2. Read repo state-machine config.
3. Fetch active Linear issues.
4. Parse the active Symphony Workpad.
5. Enforce `code_review_round <= 5` for PR review lanes.
6. Detect stale pre-PR states when an open PR already exists.
7. Update workpad and Linear state when facts prove the next state.
8. Exit `75` during `before_run` when the current stale dispatch should be skipped.

The guard should never invent work. It should only reconcile objective facts:

- Linear state
- workpad fields
- open PR URL/branch
- review round counter
- terminal state

## Review Loop

The accepted policy:

- No human-review lane.
- Another agent reviews the PR.
- Use the strongest model available.
- Use `gpt-5.5` and `xhigh` for the agent runs.
- Review is capped at 5 DeepReview `commit-review` rounds per Linear issue/PR.

Loop:

```text
PR Open -> Agent Review -> Merge Ready
                         -> Review Changes Requested -> Implementing/Verifying/Testing -> PR Open
```

If blocking findings remain after round 5:

- do not run a sixth review
- split remaining independent root causes into smaller Linear issues
- label them for Symphony and fix PR routing
- close/supersede the current PR only when safe
- leave evidence in the original workpad

## Visual QA And Computer Use

Synthetic user exploration is valuable as a signal producer.

The lane should:

- run frequently if the app has many UX bugs
- cover all important product surfaces, not only the latest example
- use screenshots and visual inspection
- create Linear issues with exact route, viewport, repro steps, expected vs observed, and screenshot
  paths
- label issues with `Synthetic UX`, `Visual QA`, and usually `Needs visual validation`
- avoid patching directly outside Symphony once the Symphony workflow is active

Computer Use/browser workers must be serialized per machine or per browser resource.

Each repo needs its own lock path:

```bash
<repo>/scripts/computer-use-lock.ts run \
  --owner "<issue-id>" \
  -- <browser-or-qa-command>
```

If multiple repo daemons might use the same physical browser/screen, prefer a global lock for those
lanes or stagger schedules.

## What Happens To Old Codex Automations

Once a repo's Symphony daemon is live, old cron automations should be converted.

Keep or convert these as producers/status surfaces:

- Visual QA signal production
- user-report ingestion
- production smoke signal ingestion
- release blocker discovery
- automation Control Tower / Chief of Staff summary
- worktree and branch hygiene

Pause or replace direct worker lanes:

- bug scan patchers
- CI/test triage patchers
- release blocker resolver patchers
- synthetic UX resolver patchers
- PR review/merge stewards
- post-merge dev QA patchers
- cross-agent handoff patchers

Reason: once Symphony owns execution, direct patch/review/merge crons can race the same branch or PR.
The correct flow is:

```text
automation finds signal -> Linear issue -> Symphony executes state machine
```

## Release And Production Authority

Production authority is repo-specific.

For Alpine Reach:

- normal work merges task branches into `develop`
- release readiness evaluates `origin/develop -> origin/main`
- production actions require an explicit release-candidate or production-deploy issue
- production smoke is read-only validation after main/release changes

For another repo, define:

- integration branch
- production branch
- deployment mechanism
- whether deploy is automatic or manual
- whether production credentials are reachable by agents
- what proof is required before `Done`

Do not copy Alpine Reach production commands blindly into another repo.

## Control Tower

The Control Tower / Chief of Staff concept is useful, but it is not the executor.

It should answer:

- what is running
- what is blocked
- what merged
- what is waiting for review
- what needs production smoke
- which automation signals were no-ops
- whether Symphony, launchd, Linear, GitHub, and browser locks look healthy

It should not:

- patch code directly
- merge PRs directly
- bypass Linear issue state
- become a second hidden state machine

## Setup Checklist For A New Repo

1. Inspect the target repo.
   - Read `AGENTS.md`, `CLAUDE.md`, package manager lockfile, branch model, CI, deploy docs, env
     requirements, and test commands.
   - Confirm whether `develop` exists or whether the repo uses another integration branch.

2. Create a Linear project for the repo.
   - Name it `<Repo/Product> Automation Queue`.
   - Create or sync states, labels, and views.
   - Store the project slug in the repo's `ops/symphony/state-machine.json`.

3. Add repo-local Symphony files.
   - `WORKFLOW.md`
   - `ops/symphony/state-machine.json`
   - `ops/symphony/README.md`
   - `scripts/sync-linear-symphony.ts`
   - `scripts/symphony-control.ts`
   - `scripts/symphony-guard.ts`
   - `scripts/computer-use-lock.ts`

4. Customize repo config.
   - GitHub repo
   - base/integration branch
   - install command
   - build/test/typecheck/lint commands
   - dev/prod URLs
   - workspace root
   - logs root
   - port
   - lock path
   - LaunchAgent name

5. Write the repo-specific workflow prompt.
   - Keep state machine terms consistent.
   - Include workpad contract.
   - Include PR review loop.
   - Include repo-specific verification rules.
   - Include release and production authority.

6. Sync Linear.
   - Run dry-run first.
   - Apply only after the dry-run shows expected creates/updates.

7. Start Symphony.
   - Run status command.
   - Verify `http://127.0.0.1:<port>/api/v1/state`.
   - Install launchd watchdog only after manual start/status is stable.

8. Seed a no-code smoke issue.
   - Create a Linear issue that requires no repo edits.
   - Move it to `Ready for Orchestration`.
   - Confirm Symphony claims it, updates the workpad, and reaches `Done`.

9. Seed a tiny PR smoke issue.
   - Make a harmless docs/config change.
   - Confirm task branch, PR, review, merge, post-merge QA routing, and cleanup.

10. Convert old automations.
    - Producers create/update Linear issues.
    - Symphony owns execution.

## Validation Checklist

Before calling a new repo workflow live:

- Linear API key works headlessly.
- Linear project slug is correct.
- State and label sync reports no missing states/labels/views.
- `WORKFLOW.md` parses.
- Symphony starts on the intended unique port.
- Status API returns valid JSON.
- A no-code Linear issue can run to terminal state.
- A PR issue can open a PR into the correct branch.
- `Agent Review` can run without self-review.
- Review loop cap is enforced.
- `In Progress` with an already-open PR reconciles to `PR Open`.
- Computer Use/browser lock prevents overlapping visual/browser sessions.
- Old direct patch/review/merge automations are paused or converted.
- Control Tower reports status but does not execute hidden work.

## Common Failure Modes

### Issue lands in `In Progress` and stops moving

Cause:

- Linear default UI/API behavior placed it in generic `In Progress`.
- The workpad or PR link was stale.
- Symphony active states did not include `In Progress`, or the guard did not reconcile it.

Fix:

- Treat `In Progress` as dispatchable but reconciliation-only.
- Guard checks workpad branch, Linear branch, issue id, and GitHub PRs.
- If open PR exists, update workpad `state=PR Open`, set `pr=<url>`, move Linear to `PR Open`, and
  exit `75` during `before_run`.

### Agent keeps reviewing after the cap

Cause:

- Review counter was not durable or guard was missing.

Fix:

- Store `code_review_round=<0-5>` in the workpad.
- Guard blocks `PR Open`/`Agent Review` at `>= 5`.
- Move to `Triage`, label `Symphony guardrail` and `Review loop exhausted`, then split smaller issues.

### Browser jobs collide

Cause:

- Multiple daemons or automations drive one physical browser/screen.

Fix:

- Use a lock script.
- Use unique per-repo lock paths unless the shared physical browser requires a single global lock.
- Cap browser-heavy states to one concurrent worker.

### Old crons race Symphony

Cause:

- Legacy automations still patch/review/merge directly.

Fix:

- Convert crons into issue producers and status reporters.
- Let Symphony own branch/PR/review/merge/QA states.

### Linear auth fails with 401

Cause:

- Missing key, malformed saved key, split token, or rotated key.

Fix:

- Check `LINEAR_API_KEY` or `~/.config/linear-codex/env`.
- Do not print the value.
- Rotate any exposed key.

### LaunchAgent looks not running

Cause:

- The LaunchAgent is a periodic starter and exits after ensuring the daemon is alive.

Fix:

- Check the repo's `symphony:status`, not only `launchctl print`.

## Open Implementation Work For Future Agents

The current approach works, but these improvements would make setup easier:

- Extract reusable TypeScript templates for `sync-linear-symphony.ts`, `symphony-control.ts`,
  `symphony-guard.ts`, and `computer-use-lock.ts`.
- Create a generator that takes a repo config and writes the repo-local files.
- Maintain a small port/LaunchAgent registry so repo daemons do not collide.
- Add a harness-level example directory with a generic `WORKFLOW.md` template.
- Add a read-only command that lists every configured repo Symphony daemon and health status.

Do not do these abstractions before a second repo proves the pattern. For now, copy the Alpine Reach
shape carefully, customize it per repo, and keep the workflow owned by the target repo.
