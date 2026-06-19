# Fork Operations

Last updated: 2026-06-19

This checkout is the local fork working copy for the reusable Symphony harness.

## Remotes

Use `origin` for our fork and `upstream` for the OpenAI source repository:

```text
origin   git@github.com:Girolino/symphony.git
upstream https://github.com/openai/symphony
```

Pushes to `upstream` should stay disabled locally. Fetch from `upstream` when
you need to compare or import new OpenAI changes.

## Working Model

- Keep `main` tracking `origin/main`.
- Use `codex/*` branches for local implementation work.
- Keep reusable harness behavior in this repository.
- Keep repo-specific workflow policy in the target repository `WORKFLOW.md` and
  target-owned control scripts.
- Preserve OpenAI upstream as a source of reusable patches, not as the place for
  local operational policy.

## Useful Commands

Check remotes:

```bash
git remote -v
```

Fetch the fork and upstream:

```bash
git fetch origin
git fetch upstream
```

Compare local fork main with upstream:

```bash
git log --oneline --left-right --graph origin/main...upstream/main
```

Start a scoped branch:

```bash
git switch -c codex/<topic>
```

Push a branch to the fork:

```bash
git push -u origin codex/<topic>
```
