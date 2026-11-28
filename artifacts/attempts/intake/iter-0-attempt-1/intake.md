[bug] release: _release_prepend_changelog check-then-write race can duplicate (or drop) a CHANGELOG section

## Goal

Two releases can never add the same CHANGELOG section twice, or lose one.

## What is wrong today

- `_release_prepend_changelog` (`scripts/release.sh`) checks for the section with `grep` and then writes it with `mv`, without a lock. Two processes in one checkout can both pass the check.
- Most of the real exposure is elsewhere:
  - the `--ship` preflight already refuses a dirty tree;
  - a second run collides on the branch and tag first;
  - in CI each runner has its own checkout; overlapping release runs are prevented by a `concurrency:` group on `release.yml` (#1602).

## Decision

**A CHANGELOG write that cannot get its lock fails the release** (fail closed): non-zero exit, and a message naming the lock. This is an exception to ADR-041's "fail soft" rule, recorded as an ADR-041 amendment.

## ADR

**Amend ADR-041** (flock serialization chokepoint): the release CHANGELOG writer fails closed on a lock timeout. ADR-041 is in `config/adr-enforcement-baseline.txt`, so the amendment names its enforcing tests inline.

## Required behavior

Write each as a test first and watch it fail.

- **R1.** Two concurrent `_release_prepend_changelog` calls for the same version in one checkout produce exactly one section.
- **R2.** Two concurrent calls for different versions produce both sections, in order.
- **R3.** A lock timeout fails the release: non-zero exit, a message naming the lock, and the CHANGELOG unchanged.

## Scope

- **Code:** `scripts/release.sh` (`_release_prepend_changelog`, using `zbuild_has_flock` from `scripts/lib/compat.sh`).
- **ADR:** `docs/adr/ADR-041-flock-serialization-chokepoint.md`.
- **Tests:**
  - `tests/integration/release-sh-ship-idempotent-test.sh`
  - `tests/integration/release-sh-test.sh`
  - `tests/integration/release-sh-apply-test.sh`
