# Promotion Failure Drill

This file is committed by the full-autonomy program's failure-injection drill
(SPEC task 1.6/6.2). A promotion carrying this commit is intentionally run with
an invalid smoke target so the pipeline must: fail the smoke, flip the release
pin back to the previous release, and auto-file the FAIL issue in Linear —
with zero human action. The commit itself is harmless; only the smoke target
is poisoned, which keeps the drill fully reversible.
