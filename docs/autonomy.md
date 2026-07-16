# Symphony Autonomy Pipeline

This fork runs Symphony as a self-maintaining lane: Linear issues enter the
queue, isolated Codex sessions implement and verify them, independent sessions
review and arbitrate, approved changes land, and a promotion loop moves the
release pin only after real checks pass. The safety model is not "trust the
agent"; it is a set of bounded states, review rules, gates, rollback paths,
and issue-filing obligations encoded in the repository.

The main contract surfaces are:

- [CONSTITUTION.md](../CONSTITUTION.md), the protected autonomy boundary.
- [REVIEW.md](../REVIEW.md), the reviewer rulebook.
- [elixir/WORKFLOW.md](../elixir/WORKFLOW.md), the lane workflow and prompt.
- [scripts/promote.sh](../scripts/promote.sh), the release promotion path.
- [scripts/auto-promote.sh](../scripts/auto-promote.sh), the land-to-live
  driver.
- [scripts/install-lane.sh](../scripts/install-lane.sh), the durable launchd
  lane installer.

## 1. Intake and Queue Maintenance

The durable queue is Linear. `elixir/WORKFLOW.md` configures the SYM project,
the active states (`Todo`, `In Progress`, `Agent Review`, `Arbiter`,
`Merging`, `Rework`), terminal states, polling interval, workspace root,
hooks, agent limits, and role-boundary states.

Recurring and failure-driven intake uses the ops issue path:

- [scripts/upkeep-heartbeat.sh](../scripts/upkeep-heartbeat.sh) files the
  recurring "Symphony upkeep" issue with `mix ops.file_issue`.
- [SymphonyElixir.OpsIssue](../elixir/lib/symphony_elixir/ops_issue.ex)
  deduplicates open operational issues by exact title, attaches them to the
  configured project when possible, and creates them in a dispatchable
  unstarted state.
- [scripts/lane-watchdog.sh](../scripts/lane-watchdog.sh) checks the lane
  daemon HTTP health endpoint, restarts the launchd job when unhealthy, and
  files a deduplicated issue for the incident.
- [scripts/credential-probe.sh](../scripts/credential-probe.sh) checks named
  Linear and GitHub credentials without printing secret values. If Linear is
  the broken credential, it falls back to a GitHub issue; if every channel is
  down, it writes a durable local marker.

`CONSTITUTION.md` C4 requires every automated FAIL to become a deduplicated
issue, not just a log line.

## 2. Workspace Bootstrap and Implementation

For each dispatchable issue, the orchestrator creates or reuses an isolated
workspace under the configured workspace root. The local SYM workflow runs an
`after_create` hook that shallow-clones `git@github.com:Girolino/symphony.git`
and prepares Elixir dependencies. The `before_remove` hook runs
`mix workspace.before_remove` for repository-owned cleanup.

The implementation lane is handled by:

- [SymphonyElixir.Orchestrator](../elixir/lib/symphony_elixir/orchestrator.ex),
  which polls Linear, reconciles running/blocked/retry/parked issues, enforces
  capacity, dispatches candidates, retries failures, and parks repeated
  failures.
- [SymphonyElixir.Workspace](../elixir/lib/symphony_elixir/workspace.ex),
  which enforces workspace path safety and hook execution.
- [SymphonyElixir.AgentRunner](../elixir/lib/symphony_elixir/agent_runner.ex),
  which starts Codex app-server in the issue workspace, sends the issue prompt,
  continues turns while the issue stays active, and stops at configured
  role-boundary states so the next role gets a fresh session.
- [SymphonyElixir.Codex.AppServer](../elixir/lib/symphony_elixir/codex/app_server.ex),
  which runs app-server JSON-RPC, enforces turn/read timeouts, handles dynamic
  tools, and streams session events back to the orchestrator.

The lane prompt in `elixir/WORKFLOW.md` requires one persistent `## Codex
Workpad`, reproduction before implementation, a pull-sync before edits,
validation proportional to the change, PR feedback sweeps, and explicit role
isolation.

## 3. Review, Arbiter, and Merging

Implementation sessions do not approve their own work. When an implementer
moves an issue to `Agent Review`, `AgentRunner` sees the role boundary and
ends the session. A fresh reviewer session reads `REVIEW.md`, the PR diff, the
workpad, and issue history.

The review outcomes are bounded:

- **Approve** records the review round and moves the issue to `Merging`.
- **Request changes** posts one review comment with rule-cited findings,
  records the round in the workpad, and moves the issue back to `In Progress`.
- **Deadlock** after the bounded review rounds moves the issue to `Arbiter`.

The arbiter is a separate role and its decision is final under
`CONSTITUTION.md` C6. It may accept the implementation, uphold the review with
binding instructions, or defer with a decision packet and re-open condition.

`Merging` is the land lane. The workflow requires the
[land skill](../.codex/skills/land/SKILL.md) instead of direct `gh pr merge`,
so the merge loop can wait for checks, handle conflicts, and complete the
issue after the PR is merged.

## 4. Promotion and Production Protection

Landing a PR updates `origin/main`; it does not by itself move production.
Promotion is handled by the release scripts:

1. [scripts/auto-promote.sh](../scripts/auto-promote.sh) runs from a dedicated
   clone, compares `origin/main` with the current release pin, and calls
   `scripts/promote.sh` when main is ahead.
2. `scripts/promote.sh` takes an exclusive promotion lock, refuses tracked
   working-tree changes, and runs the full gate with `make all` unless the
   operator explicitly narrows the run.
3. The script fast-forwards `origin/main`, builds a versioned release under the
   release store, and runs a boot health check on a disposable memory-tracker
   workflow before flipping anything live.
4. The current release symlink is flipped atomically and read back. Optional
   consumer control commands are run after the flip.
5. `mix prod.smoke` runs a real production smoke journey through
   [SymphonyElixir.ProdSmoke](../elixir/lib/symphony_elixir/prod_smoke.ex):
   it creates disposable Linear resources, boots the compiled escript, waits
   for one real Codex turn to complete the issue, checks `/api/v1/state` and
   dashboard surfaces, cleans up resources, and writes a machine-readable
   report.
6. Any post-flip failure rolls the pin back to the previous release, reruns
   consumer commands against the rollback target, and files a deduplicated
   failure issue.

`CONSTITUTION.md` C7 protects the release pin: it moves only through
`scripts/promote.sh`.

## 5. Constitution Boundary

The constitution is the set of invariants the autonomous lanes cannot remove
from underneath themselves:

- C1 restricts pushes to `origin`.
- C2 scopes lane writes to issue workspaces and owned branches/PRs.
- C3 caps budgets and makes circuit breakers park the issue, not the system.
- C4 requires every automated FAIL to become an issue.
- C5 keeps secrets referenced by name and resolved at the edge.
- C6 makes arbiter decisions final.
- C7 reserves release pin movement for `scripts/promote.sh`.

`mix constitution.check` enforces the protected-file boundary during agent-lane
runs (`SYMPHONY_AGENT_LANE=1`). Reviewers also enforce the same safety model
through `REVIEW.md`, especially the autonomy rules RV-A1 through RV-A5.

## 6. Liveness Bounds and Circuit Breaker

The lane must not wait forever. The liveness audit in
[elixir/test/symphony_elixir/liveness_audit_test.exs](../elixir/test/symphony_elixir/liveness_audit_test.exs)
names the five wait classes and their bounds:

| Wait class | Bound | Default action |
| --- | --- | --- |
| Candidate wait | `polling.interval_ms` | Poll again and dispatch eligible work. |
| Running turn | `codex.turn_timeout_ms` | Return a turn timeout to the runner. |
| Stalled stream | `codex.stall_timeout_ms` | Restart with backoff, or block when the last Codex event requires input. |
| Blocked issue | `agent.blocked_max_age_ms` | Re-enter the retry path with carried failure count. |
| Retry loop | `agent.max_consecutive_failures`, with delay capped by `agent.max_retry_backoff_ms` | Park the issue and file a deduplicated ops issue. |

The runtime proofs are in
[elixir/test/symphony_elixir/orchestrator_liveness_test.exs](../elixir/test/symphony_elixir/orchestrator_liveness_test.exs):
an over-age blocked issue re-enters retry, and the breaker parks an issue after
consecutive failures while leaving the rest of the lane dispatchable.

## 7. Watchdog, Credential Probe, and Upkeep Loop

The durable lane stack is installed by `scripts/install-lane.sh`. It renders
launchd jobs for:

- [scripts/lane-daemon.sh](../scripts/lane-daemon.sh), which runs the promoted
  release and resolves the Linear key by name at the edge.
- `scripts/lane-watchdog.sh`, which restarts HTTP-dead lane daemons and files
  an issue for the restart.
- `scripts/credential-probe.sh`, which finds expiring or invalid named
  credentials before they break the lane.
- `scripts/auto-promote.sh`, which closes the land-to-live gap.

The upkeep issue flow is part of `elixir/WORKFLOW.md`. It runs the full gate
and `mix docs.check`, inspects metrics/log patterns, reports stale local
artifacts without deleting them, reopens Deferred issues whose decision packet
conditions now hold, files dispatchable follow-up issues for recurring
friction, optionally writes a daily digest, and then completes the upkeep issue.

That loop is the self-improvement path: production incidents and lane friction
become queued work, the same implementation/review/merge rules apply, and the
promotion path decides when the fix becomes live.
