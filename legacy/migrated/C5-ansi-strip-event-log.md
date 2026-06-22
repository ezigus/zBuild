# Tombstone: C.5 — ANSI Stripping in Event Log Emission

| Field | Value |
|---|---|
| **Keeper ID** | C.5 |
| **Legacy source** | `legacy/scripts/lib/helpers.sh:431-437`, function `strip_ansi` |
| **Migration date** | 2026-06-21 |
| **Issue** | #c-9 |
| **Status** | Migrated |

## New canonical location

- `core/event-bus/event-bus.sh` — `_eb_strip_ansi` (private function), called by `eb_emit_event`

The implementation follows the two-pass pattern from `_stage_io_strip_ansi`
(`core/output/stage-io.sh:717`): first strip CSI sequences
(`ESC [ params final`), then strip bare-ESC sequences (`ESC <char>`).
`LC_ALL=C` guards against non-UTF-8 byte sequences aborting BSD `sed`
(issue #830 fix, same as stage-io precedent).

Stripping is applied to:
- Every payload **value** (the `val` side of each `key=val` arg)
- Three string envelope fields read from environment: `run_id`, `plugin`, `kind`

Payload keys, `type`, `ts`, and `issue` are excluded — keys are structural
identifiers, `type` is an internal literal, `ts` is date-generated output, and
`issue` is cast to a non-negative integer.

## What is NOT tombstoned here

`legacy/scripts/lib/helpers.sh` contains additional unmigrated keepers
(`emit_event`, `check_disk_space`, `rotate_jsonl`, atomic-append,
bookkeeping lists, `safe_git_stage`). Do NOT `git rm` the file — only the
ANSI-strip behavior is migrated by this tombstone.
