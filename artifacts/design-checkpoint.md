# Design Checkpoint — Issue #1806

## Files Read and What They Told Me

- **core/event-bus/event-bus.sh** (full): The payload loop (lines 148-156) forks jq once per key=val arg (`. + {($k): $v}`). The envelope call (lines 206-220) is already one jq -cn call — unchanged. Timestamp at lines 159-164 uses `ZBUILD_PLATFORM == "macos"` which is wrong for map work units where ZBUILD_PLATFORM=linux on a macOS host. `_eb_sql_escape` at lines 291-293 uses `printf | sed` — one fork per SQLite field.

- **scripts/lib/run-status-comment.sh** (full): `rsc_tail_loop` (lines 255-296) marks dirty when file size changes (line 277) but does NOT re-read size after `rsc_flush` (line 290). So redaction.applied events emitted by apply_scope_redaction during the flush increment the file and trigger another dirty=1 cycle. `rsc_flush` (lines 231-242) calls `rsc_upsert` unconditionally without body comparison. `rsc_main` (lines 325-371) does not set ZBUILD_CURRENT_STAGE before calling rsc_flush.

- **tests/e2e/fork-budget-test.sh** (full): FORK_BUDGET=5480. Must be lowered to reflect per-emit savings.

- **tests/unit/run-status-comment-loop-test.sh** (full): Has SPEC-1 through SPEC-8. New SPEC-9 and SPEC-10 to be added.

- **tests/unit/event-bus-timestamp-test.sh**: Does NOT exist yet. Must be created.

- **docs/adr/ADR-065-process-budget.md** (full): In config/adr-enforcement-baseline.txt (line 62) so currently no Enforced by section required. Must gain Enforced by section and be removed from baseline.

- **config/adr-enforcement-baseline.txt** (full): ADR-065-process-budget.md is line 62. Must be removed.

- **docs/adr/ADR-064-run-status-comment.md** (full): Describes the sidecar model. Self-trigger fix and stage attribution are behavioral changes; may need amendment note.

- **docs/adr/ADR-009-platform-aware-modularity.md** (full): Defines ZBUILD_PLATFORM for plugin dispatch. Fix decouples host clock from ZBUILD_PLATFORM using OSTYPE. ADR doesn't need change; in scope as reference.

- **tests/unit/core-event-bus-test.sh**, **engine-event-shape-test.sh**, **event-bus-seq-envelope-test.sh**: All call eb_emit_event; validate R-6 (contents unchanged).

## Conclusions

- The payload accumulation change (N→1 jq forks) + _eb_sql_escape bash expansion are the main fork reducers for R-1/R-5.
- The OSTYPE-based timestamp fix decouples host OS from ZBUILD_PLATFORM (target platform).
- rsc_tail_loop self-trigger fix: re-read size after rsc_flush. Stage attribution: set ZBUILD_CURRENT_STAGE before rsc_main emits.
- rsc_flush unchanged-body skip: cmp -s against a state-dir prev file.
- New FORK_BUDGET value unknown until implementation runs; design pins the method.

## What Would Come Next

Write design.md with scope and acceptance criteria as instructed.
