# Design — Fix event-bus per-emit forks, malformed timestamps, and run-status self-trigger loop

**Issue:** #1806  
**ADR refs:** ADR-065 §1-§2-§5 (fork budget), ADR-064 §2-§6 (sidecar reader/redaction), ADR-009 §ZBUILD_PLATFORM env contract

## Architectural Decision Summary

**Goal:** Reduce O(N) jq forks per event emission to O(1), fix ISO 8601 timestamp malformation on macOS hosts running `type: map` work units, and break the run-status sidecar's self-trigger loop and redundant PATCH cycle.

**Context:** `eb_emit_event` forks jq once per key=val payload argument (typically 3–8) rather than once total; the envelope jq call is already one call and is unchanged. The timestamp format branch reads `ZBUILD_PLATFORM` (the build target) rather than the host OS (`$OSTYPE`), so a macOS host dispatching a linux-target map unit calls BSD `date +%3N` which emits the literal string `%3N`. The run-status sidecar calls `apply_scope_redaction` during each render, which emits `redaction.applied` to events.jsonl; the tail loop sees a new byte count, sets `dirty=1`, and triggers another render. Each render also issues a redundant PATCH when the body is unchanged.

**Decision:**
1. **Payload accumulation:** replace the per-argument `jq . + {($k): $v}` loop with a two-phase approach — accumulate `--arg key val` pairs in a bash array, then call `jq -n '$ARGS.named'` once after the loop. ANSI stripping and plugin/kind extraction remain in the loop (both are bash-native; no fork).
2. **SQL escape:** replace `printf '%s' "$1" | sed "s/'/''/g"` with bash parameter expansion `${1//\'/\'\'}` to eliminate one fork per SQLite-enabled field (six calls per emit when the mirror is active).
3. **Host-OS timestamp:** add a `_eb_host_is_mac` helper that tests `[[ "$OSTYPE" == darwin* ]]` (bash builtin, zero forks). Use it instead of `ZBUILD_PLATFORM == "macos"`. ADR-009's ZBUILD_PLATFORM contract for plugins is preserved; the host clock format is now a separate concern.
4. **Self-trigger fix:** after `rsc_flush` returns in `rsc_tail_loop`, re-read the file byte count and set `last_size` to it, absorbing any `redaction.applied` bytes written during the flush. Set `ZBUILD_CURRENT_STAGE="run-status-comment"` (and export it) at the top of `rsc_main`, before any `rsc_flush` call, so every event the sidecar emits carries stage attribution.
5. **Unchanged-body skip:** in `rsc_flush`, after rendering to `body_file`, compare it against `$state_dir/status-comment-body-prev.txt` with `cmp -s`. If identical, remove `body_file` and return 0. After a successful `rsc_upsert`, copy `body_file` to the prev file atomically.
6. **ADR-065 amendment + enforcement:** lower `FORK_BUDGET` in `fork-budget-test.sh` to just above the new measured value; amend ADR-065 §5 to name the removed processes; add `## Enforced by` section; remove ADR-065 from `config/adr-enforcement-baseline.txt`.

```scope
core/event-bus/event-bus.sh
scripts/lib/run-status-comment.sh
tests/unit/event-bus-timestamp-test.sh
tests/unit/run-status-comment-loop-test.sh
tests/e2e/fork-budget-test.sh
docs/adr/ADR-065-process-budget.md
config/adr-enforcement-baseline.txt
docs/adr/ADR-064-run-status-comment.md
docs/adr/ADR-009-platform-aware-modularity.md
tests/unit/core-event-bus-test.sh
tests/unit/engine-event-shape-test.sh
tests/unit/event-bus-seq-envelope-test.sh
tests/unit/event-bus-concurrency-test.sh
tests/unit/event-bus-ansi-strip-test.sh
tests/unit/run-status-comment-gh-test.sh
tests/mutation/event-bus.md
tests/mutation/event-bus-ansi-strip.md
tests/integration/strategy-platform-env-test.sh
tests/golden/parity/run-fixture.sh
```

```acceptance
SPEC-1[code]: eb_emit_event produces a well-formed ISO 8601 timestamp (no literal `%3N`, format `YYYY-MM-DDTHH:MM:SS.000Z` or `.NNNz`) when ZBUILD_PLATFORM is set to "linux" and the host OS is macOS (OSTYPE=darwin*) covers: R-2
SPEC-2[code]: eb_emit_event accumulates all key=val arguments into a single jq invocation for payload construction; the emitted event JSON is byte-for-byte identical to the current output for the same inputs covers: R-1 R-6
SPEC-3[code]: after rsc_flush returns, the tail loop's file-size cursor (`last_size`) is updated to the current byte count of events.jsonl so that redaction.applied events written during the flush do not set dirty=1 and cause a second render covers: R-3 R-4
SPEC-4[code]: rsc_flush makes no gh PATCH request (does not call rsc_upsert) when the rendered body is byte-for-byte identical to the body sent in the previous flush covers: R-4
SPEC-5[code]: every event emitted by the sidecar process (including redaction.applied) carries `stage="run-status-comment"` in the event envelope covers: R-3
SPEC-6[code]: FORK_BUDGET in fork-budget-test.sh is lowered to a value smaller than the current merge-base measurement; the test fails on the unpatched event-bus.sh and passes after the payload-accumulation and sql-escape fixes covers: R-1 R-5
SPEC-7[no-code]: ADR-065-process-budget.md gains an `## Enforced by` section naming fork-budget-test.sh (§1) and the amendment text naming the removed per-emit processes (§5); ADR-065-process-budget.md is removed from config/adr-enforcement-baseline.txt covers: R-5
WIRING:
core/event-bus/event-bus.sh
scripts/lib/run-status-comment.sh
TESTFILES:
SPEC-1: tests/unit/event-bus-timestamp-test.sh
SPEC-2: tests/unit/event-bus-timestamp-test.sh
SPEC-3: tests/unit/run-status-comment-loop-test.sh
SPEC-4: tests/unit/run-status-comment-loop-test.sh
SPEC-5: tests/unit/run-status-comment-loop-test.sh
SPEC-6: tests/e2e/fork-budget-test.sh
```

## Notes

- The new `FORK_BUDGET` constant must be measured after steps 3–4 (payload + sql-escape fixes) land, then set to just above the Linux CI value per ADR-065 §2. Until measured, the design cannot name the exact number.
- `$ARGS.named` in jq preserves all key/value pairs; key order in the output JSON may differ from the iterative approach but downstream consumers (including `jq -Sc` golden comparisons) sort keys, so the change is invisible to all existing tests.
- The `_eb_host_is_mac` helper reads `$OSTYPE`, a bash builtin set at shell startup — no fork, and immune to ZBUILD_PLATFORM overrides that map work units inject for plugin dispatch.
- The unchanged-body prev file grows to ~60 KB; it lives in the run's state dir and is cleaned up with it.
- `cmp -s` adds one fork per potential PATCH, negligible against the `gh` network call it prevents.
- The self-trigger fix (cursor reset) and the stage attribution (ZBUILD_CURRENT_STAGE) address R-3 jointly: the event is still emitted once per genuine render and carries attribution, but it no longer re-arms the dirty flag for a second render.
- ADR-064 §2 states the sidecar "reads events.jsonl (never writes it)"; in practice `apply_scope_redaction` (called from the render path) does write a `redaction.applied` event. The stage attribution amendment note in ADR-064 acknowledges this and records that the sidecar's own events are now attributed.
```

EMIT_LOOP_COMPLETE
