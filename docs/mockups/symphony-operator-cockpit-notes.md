# Symphony Operator Cockpit Notes

Last updated: 2026-06-19

## Current Workflow Signals

- Live Alpine Reach daemon: `http://127.0.0.1:4765`.
- Current runtime sample: one running issue, `ALP-302`, in `Post-Merge Dev QA`.
- Linear sync dry run is clean: no missing states, labels, or views.
- Linear inventory sample: 26 states and 32 labels.
- Blocked guard dry run scanned 3 blocked issues and proposed no actions.

## Linear Writes Today

- Harness adapter can create Linear comments and update issue state.
- Codex workers receive a `linear_graphql` dynamic tool for raw GraphQL operations.
- Repo sync script creates or updates workflow states, labels, and shared views, and archives the old `Human Review` state.
- Guard script can update issue state, create blocked-triage issues, replace blocked workflow labels, update workpad comments, and upsert guardrail comments.
- Workers are expected to keep one `## Symphony Workpad` comment current instead of posting scattered status comments.

## UI Shape

The mockup treats Symphony as an operator cockpit, not a generic board:

- Top summary: daemon health, Linear sync state, guard dry-run status, and token burn.
- Execution rail: grouped workflow phases with the active phase highlighted.
- Queue table: live issue rows with state, labels, PR, review round, and next risk.
- Workpad inspector: parsed stamp fields, route, planning audit, validation ledger, and blocker fields.
- Guardrail ledger: policy checks that matter before state transitions.
- Linear surfaces: states, labels, views, and mutation classes that the automation manages.

## UX Decisions

- Do not add more workflow stages; surface transition quality and guard status instead.
- Put `Blocked` behind triage detail, because it is non-dispatchable and often external.
- Make workpad/Linear mismatches visible. The current sample includes `ALP-303` with a workpad workspace path pointing to `ALP-302`, which should be a first-class warning in a future implementation.
- Separate live runtime truth from durable Linear truth. The dashboard should show both without letting the in-memory daemon state pretend to be durable.
