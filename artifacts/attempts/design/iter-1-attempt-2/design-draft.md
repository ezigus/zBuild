# Design: serialize the release CHANGELOG write with flock (#1608)

## Decision summary
- Goal: two concurrent `_release_prepend_changelog` calls in one checkout must not lose or duplicate a section; a lock that cannot be had fails the release.
- Context: `scripts/release.sh` `_release_prepend_changelog` does check-then-write (idempotency grep, then build a temp file, then `mv`) with no lock, so two callers both pass the grep and the second `mv` overwrites the first (lost section, or duplicate). ADR-041 makes `flock` (guarded by `zbuild_has_flock`) the chokepoint for shared writes, and says an authoritative writer "must fail soft on timeout".
- Decision: take an exclusive `flock -w N` on a lock file around the WHOLE read-check-write (the idempotency grep must be inside the lock, otherwise the same-version case still races). This follows the existing pattern in `core/state/atomic.sh` (`zbuild_has_flock`, `flock -w 30`, `error ...; exit 1`) and the helper `zbuild_has_flock` in `scripts/lib/compat.sh` (already sourced by `scripts/lib/helpers.sh`, which release.sh sources). No new lib or mechanism.
- Differences from `atomic.sh`: the lock is held via `exec {fd}>file` in the function itself, not a `( ... ) 9>file` subshell, because `_RELEASE_CHANGELOG_SKIPPED` must be set in the caller's shell. The fd is closed on every return path.
- Lock file: `zbuild-changelog.lock` in the checkout's git dir (`git -C <changelog dir> rev-parse --git-dir`), falling back to a dotfile beside the CHANGELOG only when git gives no dir. A lock file beside CHANGELOG.md would dirty the tree, which `--ship` flow checks (#1601). Chosen over a per-version lock: different versions must also serialize (RQLOCK-2), because both rewrite the one file.
- Timeout: 30s by default (same as `atomic.sh`), overridable by `ZBUILD_CHANGELOG_LOCK_TIMEOUT` (trusted engine/operator env, validated as digits, else default) so a test can hold the lock and observe a timeout without waiting 30s.
- Timeout behaviour: `error "release: could not acquire CHANGELOG lock <path> within Ns"`, `exit 1`, before any temp file or write, so CHANGELOG is byte-identical. This is deliberately fail closed, an exception to ADR-041's "fail soft" for authoritative writers: a silently skipped changelog would ship a release without notes.
- No-flock fallback: `warn` and proceed unserialized, as ADR-041 already says for non-flock environments.
- ADR-041 amendment: add an "Amended" block (same style as the existing 2026-10-24 one) stating the release CHANGELOG writer fails closed on lock timeout as an exception to the fail-soft rule, and naming the enforcing tests inline (the new release-changelog-lock test file, by SPEC tag). ADR-041 is in `config/adr-enforcement-baseline.txt` (no `## Enforced by` section), so inline naming is what is asked; the baseline is not touched.
- Outside assumptions: `flock` binary (checked by `zbuild_has_flock`; fallback warns); git dir writable (if the lock file cannot be opened, error and exit 1, fail closed); `ZBUILD_CHANGELOG_LOCK_TIMEOUT` is a trusted env value, validated.
- Not touched (LMSCOP-1): `--ship` preflight, branch/tag collision handling, `release.yml` `concurrency:` group.
- ABS check: no closed set (stages, plugins, events) grows; no enumeration/count sites. No new plugin dir, so no wiki page.
- `scripts/release.sh` is already over 500 lines (793); the change adds a few lines to the one function and does not add a file.

```steps
- 1.1 Wrap the idempotency check, temp-file build and mv in `_release_prepend_changelog` in an exclusive `flock -w` on a lock file in the git dir, failing closed (error naming the lock, exit 1, CHANGELOG untouched) on timeout and warning when flock is absent | areas: scripts/release.sh | serves: DSCLG-1, DSCLG-2, DSCLG-3, DSCLG-4
- 2.1 Add an amendment to ADR-041 recording the fail-closed exception for the release CHANGELOG writer and naming its enforcing tests inline | areas: docs/adr/ADR-041-flock-serialization-chokepoint.md | serves: DSCLG-5, DSCLG-6
```

```acceptance
DSCLG-1[code]: Two concurrent prepends of the same version leave exactly one section covers: RQLOCK-1, RQLOCK-5
  Given: a CHANGELOG with a header and one release section
  When: two `_release_prepend_changelog` calls for the same version run concurrently in one checkout
  Then: the CHANGELOG holds exactly one section for that version
  And: the earlier release section is still present
DSCLG-2[code]: Two concurrent prepends of different versions keep both sections in order covers: RQLOCK-2, RQLOCK-5
  Given: a CHANGELOG with a header and one release section
  When: two `_release_prepend_changelog` calls for different versions run concurrently in one checkout
  Then: the CHANGELOG holds both new sections and the earlier one
  And: each new section sits above the earlier existing section, with the header intact and no section duplicated, whichever call finishes first
DSCLG-3[code]: A lock timeout fails the release covers: RQLOCK-3, RQLOCK-4, RQLOCK-5
  Given: another process holds the CHANGELOG lock for longer than the timeout
  When: `_release_prepend_changelog` is called
  Then: it exits non-zero
  And: its output names the lock
DSCLG-4[code]: A lock timeout leaves the CHANGELOG unchanged covers: RQLOCK-3, RQLOCK-4
  Given: another process holds the CHANGELOG lock for longer than the timeout
  When: `_release_prepend_changelog` is called
  Then: the CHANGELOG is byte-identical to before
  And: no temp file is left in its directory
DSCLG-5[doc]: ADR-041 records that the release CHANGELOG writer fails closed on a lock timeout, as an exception to its "fail soft" rule for authoritative writers covers: RQADR-1
DSCLG-6[doc]: ADR-041's amendment names its enforcing tests inline, by test file and SPEC tag covers: RQADR-2
WIRING:
scripts/release.sh
```

Note on WIRING: `_release_prepend_changelog` is called from `main()` in `scripts/release.sh`; restoring that file removes the lock, so DSCLG-1..4 fail.

## Findings
- DSFND-1: DSCLG-6 already covers RQADR-2 only (not scripts/release.sh); left unchanged.
- DSFND-2: DSCLG-2 no longer asserts write order; it asserts both sections above the earlier one, header intact, none lost or duplicated.
