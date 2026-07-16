# CONSTITUTION.md — Immutable Autonomy Boundary

The small set of invariants that make full autonomy safe. Agent lanes
(implementer, reviewer, arbiter, upkeep) may amend anything in this
repository EXCEPT this file: `mix constitution.check` fails any change that
edits it outside an explicitly human-authorized session. The system must
never be able to remove its own brakes.

## C1 — Remotes

`origin` (`git@github.com:Girolino/symphony.git`) is the only push remote.
Nothing is ever pushed to `upstream` (openai/symphony), under any
circumstances.

## C2 — Write scopes

- Agent lanes write only inside their issue workspace and the branches/PRs
  they own.
- The upkeep lane additionally REPORTS on (never deletes) stale branches,
  parked worktrees, and old releases.
- No lane touches target-product repositories (dr-thomas, content-pipeline,
  workflow-alpine) except through their repo-owned control scripts.
- No lane edits this file, `.githooks/`, or `scripts/promote.sh`'s rollback
  path except through a PR that a human explicitly initiated.

## C3 — Budgets and breakers

- Per-lane budgets: at most `max_concurrent_agents` concurrent sessions and
  `max_turns` turns per session, as configured in the lane's `WORKFLOW.md`.
- Circuit breakers park a LANE, never the system: after the configured number
  of consecutive failed runs for one issue, that issue is parked (Deferred +
  ops issue); other issues keep dispatching.
- Breaker and rollback mechanisms are constitution-protected: agents may tune
  thresholds via config PRs but may not remove the mechanisms.

## C4 — Failure visibility

Every automated FAIL terminates in a deduplicated Linear issue
(`SymphonyElixir.OpsIssue`). A failure that only reaches a log file is a
constitution violation.

## C5 — Secrets

Credentials are referenced by name only, resolved at the edge
(`$LINEAR_API_KEY`, `~/.config/linear-codex/env`), never committed, logged,
printed, or persisted in reports, workflows, or issues.

## C6 — Arbiter finality

The arbiter's decision on a review deadlock is final. No lane re-litigates a
decided dispute; a Deferred decision packet is reopened only when its stated
re-open condition holds.

## C7 — Production protection

The release pin (`~/.cache/symphony-releases/current`) moves only through
`scripts/promote.sh`: gate, boot check, verified atomic flip, real smoke,
auto-rollback. No lane flips the pin by hand.

## Amendment

Changing this file requires a session the human operator started for that
purpose. `mix constitution.check` enforces the boundary mechanically by
comparing the file against the committed HEAD version during agent-lane runs
(`SYMPHONY_AGENT_LANE=1` in lane environments).
