# Tombstone: C — JSON Corruption Recovery

| Field | Value |
|---|---|
| **Keeper ID** | C.2 |
| **Legacy source** | `legacy/scripts/lib/helpers.sh:179`, function `validate_json` |
| **Migration date** | 2026-06-18 |
| **Issue** | #38 |
| **Status** | Migrated |

## New canonical locations

- `scripts/lib/helpers.sh` — `validate_json` primitive (atomic `.bak` restore via `atomic_replace`)
- `core/state/atomic.sh` — `read_state` (validate before read) and `_zbuild_lsu_validate_and_copy` (validate before locked update)
- `core/state/resume.sh` — `get_state_field` (validate before field read; added issue #38)

All state read paths now call `validate_json` before accessing file contents. A corrupt main file triggers atomic `.bak` restoration; both-corrupt returns the caller-supplied default and exits 0.

## What is NOT tombstoned here

`legacy/scripts/lib/helpers.sh` contains additional unmigrated keepers (`emit_event`, `check_disk_space`, `rotate_jsonl`, atomic-append, ANSI strip, bookkeeping lists, `safe_git_stage`). Do NOT `git rm` the file — only the `validate_json` function is migrated by this tombstone.
