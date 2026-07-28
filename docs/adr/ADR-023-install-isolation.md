# ADR-023: Install isolation — copy pipeline runtime into `$ZBUILD_HOME`

**Status:** Accepted (issue #595)
**Date:** 2026-05-31

## Context

Before this ADR, `install.sh` created a symlink from `~/.local/bin/zbuild`
into the source clone: `ln -sf "$SCRIPT_DIR/scripts/zbuild"
"$TARGET_DIR/zbuild"`. The `scripts/zbuild` shell entrypoint resolves
`SCRIPT_DIR` through that symlink and computes `REPO_ROOT="$SCRIPT_DIR/.."` —
landing inside the source clone. Every plugin, template, and `core/` helper
loaded by `core/pipeline/runner.sh` therefore came from whatever the source
clone's working tree looked like at the instant of the read.

The intake stage runs `git checkout` inside that same clone. The 2026-06-01
dogfood reflog captured the failure mode:

    06:03:18 HEAD@{...}: checkout: moving from main to zbuild/issue-294-...

Subsequent stages then loaded plugin code that had not existed when the run
started. Build artifacts were attributed to a code version that, on disk, was
already gone.

This is the same self-modifying-binary class of bug that shipwright hit in its
early releases (precedent referenced in PR description).

## Decision

`install.sh` **copies** the pipeline runtime into `$ZBUILD_HOME` (default
`~/.local/share/zbuild`) and writes a thin shim at `~/.local/bin/zbuild`.

Pinned design (#595 implementation):

1. **`$ZBUILD_HOME`** is the single source of truth env var.
   Default: `~/.local/share/zbuild`. Settable to override location.
2. **rsync** copies `scripts/`, `core/`, `plugins/`, `config/`. `tests/`,
   `docs/`, `legacy/`, `.git/` are excluded — they are not runtime deps.
   `--delete` makes re-installs idempotent.
3. **Shim** at `$TARGET_DIR/zbuild` is a 5-line regular file (never a
   symlink). It exports `ZBUILD_HOME` and `ZBUILD_FROM_INSTALL=1`, then
   `exec`s `$ZBUILD_HOME/scripts/zbuild`.
4. **Version file** at `$ZBUILD_HOME/version` records `sha=`, `branch=`,
   `installed_at=` (ISO-8601 UTC), and `source=` captured from the source
   clone at install time.
5. **`zbuild version`** prints the contents of the version file; falls back
   to `git rev-parse` from the source clone when invoked directly via `bash
   scripts/zbuild` (CI / dev mode).
6. **`zbuild upgrade --from <dir>`** runs `git pull --ff-only` in the source
   clone, then `exec`s its `install.sh`. The `--from` flag is required —
   `$ZBUILD_HOME` itself has no `.git`.
7. **Migration**: if `$TARGET_DIR/zbuild` is currently a symlink, install
   removes it and writes the shim, printing a "migrating" notice.
8. **CI** continues to invoke `bash scripts/zbuild` directly from the source
   clone. No CI changes are required.

## Consequences

**Positive:**
- Pipeline runtime is immune to intake's branch switches and to any mid-run
  edit of the source clone.
- Upgrades become explicit and observable (`zbuild version` shows what's
  actually running).
- `--delete` rsync makes re-installs fully reproducible.

**Negative / accepted:**
- ~30 MB extra disk usage in `~/.local/share/zbuild` (small relative to a
  modern dev workstation).
- Users must remember `--from` when upgrading. Mitigated by the `--help`
  message and the install completion banner.
- `bash scripts/zbuild` from the source clone is still self-mutable; this is
  intentional for dev workflows and CI.

## Alternatives considered

- **In-place lock**: have intake refuse to `git checkout` while a pipeline is
  running. Rejected — too easy to bypass, and worktrees already do this
  better for parallel use.
- **Worktree-by-default**: have intake always checkout into a worktree.
  Rejected at the time this ADR was written (issue tracked separately). Even
  with worktrees, the *binary* needs to be stable across the run; that's what
  this ADR provides.

  **AMENDED (#888, 2026-07-27): worktree-by-default is now ACCEPTED.** Every
  pipeline run works in a per-run worktree; `--no-worktree` opts out. The
  original rejection assumed the two mechanisms were alternatives — they are
  orthogonal, and the sentence above says why: engine stability and target
  isolation solve different halves. This ADR keeps the engine stable; #888 keeps
  one run's work out of another's.

  The rejection also predated the discovery that the engine, the pipeline state
  and the work were *all* living inside the target repository (#1629). One
  principle covers all three: **nothing the pipeline owns lives inside the repo
  it is working on.** Worktrees are how that applies to the work itself.

  Layout: `<base>/runs/<run_id>/worktree`, co-located with the per-run state dir
  (#887) so resume has one place to look and cleanup one place to delete.
  Overridable via `ZBUILD_RUN_ROOT`, `ZBUILD_WORKTREE_ROOT`, or template
  `config.worktree_root`. The default deliberately avoids `$TMPDIR`: on macOS
  that resolves into `/var/folders/...`, where entries can vanish mid-run
  (#1571, #1609/#1611), and a worktree holds in-flight work.

  A branch already checked out elsewhere is **refused**, not forced: two trees on
  one branch leaves a silently stale HEAD in the other, which is a worse failure
  than stopping.
- **Symlink with `realpath` capture**: pin `REPO_ROOT` to the symlink target
  *as resolved at process start*. Rejected — still mutable mid-run; doesn't
  fix the underlying class of bug.

## Implementation Notes (issue #595)

- `install.sh` was rewritten in #595 to use `rsync -a --delete` for the four
  runtime directories. The smoke test at the end of install execs the copied
  `scripts/zbuild --version` (not the source-clone copy) to verify the
  installed tree is functional.
- The shim is generated by a heredoc inside `install.sh`'s `write_shim()`
  helper. The literal `\${ZBUILD_HOME:-...}` keeps the default
  expansion-at-runtime so users can still override per-invocation.
- `scripts/zbuild`'s `version` case prefers `$ZBUILD_HOME/version` when
  present, then falls back to `git rev-parse` against `$REPO_ROOT` for users
  who run zbuild directly from the source clone (CI / dev mode).
- `scripts/zbuild upgrade` requires `--from <dir>`; the helper performs a
  best-effort `git pull --ff-only` then `exec`s `install.sh`.
- Tests live under `tests/integration/install-copy-flow-test.sh`,
  `zbuild-version-subcommand-test.sh`, `zbuild-upgrade-subcommand-test.sh`.

## References

- Issue #595
- Reflog evidence: 2026-06-01 dogfood run, intake checkout at 06:03:18.
- Tests: `tests/integration/install-copy-flow-test.sh`,
  `tests/integration/zbuild-version-subcommand-test.sh`,
  `tests/integration/zbuild-upgrade-subcommand-test.sh`.
- Docs: `docs/INSTALL.md`.
