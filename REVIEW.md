# REVIEW.md — Encoded Review Rules

Canonical review rulebook for the Symphony harness. Reviewer agents judge every
PR against these rules. A rejection MUST cite a rule id from this file; if no
rule covers the reason, the rejection MUST ship a proposed new rule alongside
it (the no-rejection-without-a-rule policy). Rules carry telemetry: a rule that
repeatedly causes deadlocks, exemptions, or arbiter overturns gets flagged for
revision by the maintenance lane and amended through a normal PR.

Machine-checkable rules name their enforcing check; reviewers verify the rest.

## Boundaries

- **RV-B1 — The harness stays generic.** No product-specific policy, names,
  paths, ports, Linear slugs, or URLs in `elixir/lib/` (Alpine Reach,
  dr-thomas, content-pipeline, natuvera, or future products). Product policy
  belongs in the target repository's `WORKFLOW.md` and repo-owned scripts.
  Enforced by: `mix harness.check`. Source: `AGENTS.md` Core Boundaries.
- **RV-B2 — Primitives here, decisions there.** The harness may expose
  scheduling, workspace isolation, sessions, observability, retries, hooks,
  budgets, and breakers. Target repos decide states, prompts, branch policy,
  release gates, and product validation rules.
- **RV-B3 — Never push to `upstream`.** `origin` (the fork) is the only push
  remote. Source: `docs/fork-operations.md`.

## Compatibility

- **RV-C1 — Preserved surfaces.** Direct `./bin/symphony <WORKFLOW.md>`
  startup, `/api/v1/state` response fields consumed by existing callers,
  `hooks.before_run` exit code `75` skip semantics, and file-mode operation
  without a database must keep working. Breaking one requires an explicit,
  documented migration in the same change.
- **RV-C2 — Spec alignment.** The implementation may be a superset of
  `SPEC.md` but must not conflict with it; behavior-changing PRs update the
  spec in the same change where practical. Source: `elixir/AGENTS.md`.
- **RV-C3 — Docs move with behavior.** Config/behavior changes update
  `README.md`, `elixir/README.md`, and workflow contract docs in the same PR.
  Enforced in part by: `mix docs.check`.

## Safety

- **RV-S1 — Secret hygiene.** Credentials are referenced by name only
  (`$LINEAR_API_KEY`), never inlined, logged, committed, or written into
  reports/workflow files. Reviewers reject any diff that prints or persists a
  secret value.
- **RV-S2 — Workspace safety.** Agent turns never run in a source repo; all
  workspaces stay under the configured workspace root. Cleanup semantics
  (retry, reconciliation, terminal sweep) must be preserved.
- **RV-S3 — Environment scrubbing at process boundaries.** Long-lived or
  spawned processes (hooks, daemons, codex subprocesses) must not inherit
  session-scoped environment (GIT_DIR family, NODE_OPTIONS preloads). New
  spawn sites scrub or allowlist their env. Precedents: pre-push GIT_DIR
  corruption incident; NODE_OPTIONS killing codex turns.
- **RV-S4 — Tests own only their sandbox.** Test cleanup deletes only paths
  the test created (scoped `on_exit`); no `rm_rf` of shared directories; test
  git commands must not be able to reach the real repository. Precedent: the
  tmp-dir deletion and Test-User-commits incidents.
- **RV-S5 — State changes are read back.** A step that mutates external state
  (symlink flip, daemon restart, tracker write) verifies the observed result
  before reporting success. Precedent: the silent `mv -f` no-flip bug.

## Autonomy invariants

- **RV-A1 — Gates block artifacts, not flow.** New checks must give agents a
  deterministic, local, re-runnable failure signal. No check may require a
  human to interpret it.
- **RV-A2 — Every FAIL becomes an issue.** Failure paths in automation must
  end in a deduplicated Linear issue (via `SymphonyElixir.OpsIssue`), never in
  a log line only.
- **RV-A3 — Cleanup is validated, not assumed.** Teardown paths report
  per-resource results and fail the run on leaks (daemons, tracker artifacts,
  filesystems).
- **RV-A4 — No exit-code masking.** Gate and promotion commands must not be
  piped through consumers that swallow exit codes (`| tee`, `| tail`); capture
  to files instead. Precedent: three masked-failure incidents in one day.
- **RV-A5 — Liveness.** New orchestration states declare a timeout and a
  default action. Nothing waits indefinitely.

## Quality

- **RV-Q1 — Gate green before handoff.** `mix format --check-formatted`,
  `mix lint` (specs.check + credo --strict + docs/harness checks), full
  `mix test`, and `make all` (coverage 100% with explicit `ignore_modules`,
  dialyzer clean) on the final tip. Real-IO adapters may be coverage-ignored
  following the `Linear.Client` / `OpsTransport` precedent; journey/decision
  logic may not.
- **RV-Q2 — @spec on public functions** in `lib/` (adjacent; `@impl`
  callbacks exempt). Enforced by: `mix specs.check`.
- **RV-Q3 — Narrow scope.** No unrelated refactors in the same change; follow
  existing module and style patterns.
- **RV-Q4 — Root cause over masking.** Retries/backoff are flow control, not
  error hiding; the underlying failure class must surface in metrics or
  issues. A fix that only silences a symptom is rejected.
- **RV-Q5 — Real proof for runtime behavior.** Changes to orchestration,
  agent launch, prompt delivery, or runtime adapters include at least one real
  run (Codex turn or live E2E) unless provably doc/UI-only. Cost is not a
  skip reason. Source: runtime spec Required Validation Gate.

## Review process

- **RV-P1 — Bounded rounds.** Implementer↔reviewer exchanges are capped at 3
  rounds per PR; an unresolved disagreement then goes to the arbiter, whose
  decision is final (a Deferred decision packet is a valid outcome).
- **RV-P2 — Verdicts carry evidence.** Reviewer verdicts cite the rule id and
  the observed violation (file/line or command output), not taste. Refuting a
  finding requires evidence (a failing repro or a passing runtime proof).
- **RV-P3 — Findings tracked as CR-ids.** Material findings keep stable ids
  across rounds with explicit statuses (fixed-and-verified, still-open,
  refuted-with-evidence, deferred-with-rationale).
