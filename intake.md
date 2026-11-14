[bug] host decisions come from a probe of the tools, never from ZBUILD_PLATFORM (ADR-009, part 1 of 2 — then #2532)

## Goal

Host decisions — which `sed -i` or `stat` form to use — come from a probe of the tools, made once when the library loads, never from a platform name. Part 1 of 2: this must land before #2532, which stops `compat.sh` writing `ZBUILD_PLATFORM`; until then the host checks below still depend on that value.

## What is wrong today

- `zbuild_sed_inplace` in `scripts/lib/compat.sh` picks its `sed -i` form from `ZBUILD_PLATFORM == macos`. It is used by `scripts/deferred-backfill.sh` and `scripts/lib/gh-automation.sh`.
- `_zb_target_mode_v` in `scripts/lib/helpers.sh` is the mode check inside `atomic_write` and `replace_keep_mode`. It picks its `stat` form from `ZBUILD_PLATFORM`, and runs `stat` a second time when the first form's answer is not a mode.
- `zbuild_stat_size` in `compat.sh` reads `ZBUILD_PLATFORM` and has no callers.

## ADR

- **Amend ADR-009** so it says: host decisions (which `sed -i` or `stat` form to use) come from a probe of the tools themselves, made once when the library loads, never from a platform name.
- ADR-009 is in `config/adr-enforcement-baseline.txt`, so the amendment names its enforcing tests inline.
- **Amend ADR-020** if `zbuild_sed_inplace` is renamed: it names that function as the deferred tracker's log-update helper.

## Required behavior

Write each as a test first and watch it fail.

- **R1.** `zbuild_sed_inplace` and `_zb_target_mode_v` pick their `sed -i` / `stat` form from a probe run **once when the file loads**, not from a platform name. With `ZBUILD_PLATFORM` set to a wrong value (e.g. `ios`), both still work on the host.
  - No extra process per `atomic_write`: the ADR-065 process budget (`tests/e2e/fork-budget-test.sh`) must still pass.
  - Use the GNU form first (`stat -c` before `stat -f`).
- **R2.** The probe replaces `_zb_target_mode_v`'s second `stat` call: each mode check runs one `stat`.
- **R3.** `zbuild_stat_size` is deleted.

## Scope

- **Code:** `scripts/lib/compat.sh`, `scripts/lib/helpers.sh`, `scripts/deferred-backfill.sh`, `scripts/lib/gh-automation.sh`.
- **ADR:** `docs/adr/ADR-009-platform-aware-modularity.md`; `docs/adr/ADR-020-deferred-tracker.md` only if `zbuild_sed_inplace` is renamed.
- **Tests:**
  - `tests/e2e/fork-budget-test.sh`
  - `tests/unit/event-bus-emit-cost-test.sh`
  - the existing tests of `atomic_write`, `replace_keep_mode` and `zbuild_sed_inplace` (`grep -rlE 'atomic_write|replace_keep_mode|zbuild_sed_inplace' tests/`)
- **Out of scope:** what writes `ZBUILD_PLATFORM` — that is #2532.
