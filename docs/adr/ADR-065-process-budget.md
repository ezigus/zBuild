# ADR-065 — Process budget: the engine's fork count is a tested contract

**Status:** Accepted (2026-09-19)
**Issue:** #2151
**Related:** ADR-001 (Discovery + lockfile), ADR-012 (test tiering), ADR-053 (test flake policy — the serial-pin cap that also needs an amendment to raise), ADR-041 (the fd-9 lock discipline the trace harness must respect)

## Context

zBuild is bash. Every `$(jq …)`, `$(dirname …)`, `$(awk …)` is a fork and an exec, and the
engine does them by the thousand: on 2026-09-19 `source core/pipeline/runner.sh` execs 1,375
processes before any stage runs (1,050 of them `awk`), and a mocked seven-stage pipeline run
(`tests/golden/parity/run-fixture.sh`) execs about 7,100. The suite is therefore fork-bound, not
compute-bound: #1840 run 1 (35184719395) spent 4,910 of its 6,989 CPU-seconds in the kernel
creating processes. Fork throughput scales with cores, so the same suite takes ~15 minutes on a
10-core Mac and ~58 minutes inside the daemon's `test` stage on a 4-vCPU GitHub runner — the
single largest cost in every long run. Buying larger runners was considered and rejected: it
hides the cost rather than removing it.

A census by call site (bash xtrace with `PS4='+@${BASH_SOURCE[0]-}:${LINENO}@ '`) put a third
of the mocked run's execs on one line — `core/pipeline/input-resolve.sh:113`, an awk per manifest
inside `_inputs_scan_manifests`, whose memo is never filled in the parent shell and whose every
caller runs it inside `$( )`: 41 calls × 55 manifests. The next third is `yaml_cache_prewarm`
(one awk per manifest per key, 55 × 12) and the event bus (a `sed` per key and value, a `jq` per
key, a `date` and a `mkdir` per event). None of this is inherent; all of it was invisible because
nothing measured it.

## Decision

### §1 — The number is a contract

The engine's external process count on the mocked full run is a tested quantity, held by
`tests/e2e/fork-budget-test.sh` as `FORK_BUDGET`. The test runs the parity fixture under bash
xtrace (`BASH_ENV` injecting `set -x`, `PS4` stamping `source:line`, `BASH_XTRACEFD=7` — fd 3 is
stage-io, 8 is coverage, 9 is flock), classifies each traced command word as external when the
test shell resolves it to a file on `PATH` (or it is one of the fixture's mocks), and asserts the
total is within budget. Its failure output is the diagnosis: the top call sites and per-file
totals, so the next reader starts where the forks are.

### §2 — The budget only ratchets down

A PR that removes forks lowers `FORK_BUDGET` to just above its new measurement. A PR that must
raise it says why in an amendment to this ADR (the ADR-053 §5 precedent for the serial-pin cap).
"It is only a few hundred more" is not a reason; the run-4 postmortem of #1840 is what a few
hundred per stage per iteration adds up to.

### §3 — A memo is only as good as its fill in the parent shell

`$( … )` and `< <( … )` fork: the child inherits every associative array the parent has filled
and can never write back. A memo that is consulted from a subshell but filled only inside one is
not a memo — `_inputs_scan_manifests` ran 2,255 awks with its `_IR_SCAN_KEY` guard "in place".
The rule: every per-run memo is filled once, in the parent, at a prewarm seam that runs before
anything reads it from a subshell (`core/pipeline/runner.sh` warms the yaml cache and discovery
at file scope before `core/orch/contract.sh` is sourced — #2105 — and again in `main()`). A memo
that cannot be filled in the parent, because the reader is a separately spawned plugin process,
may instead be file-backed under `$ZBUILD_STATE_DIR/runtime/` with an explicit flush and the
shared `ZBUILD_YAML_CACHE=0` kill switch — the `known-event-types.cache` (ADR-001 §Declared
events) and `mgraph-memo` (#2129) precedents.

### §4 — One pass, not one per key

A reader over N manifests forks once — `awk` with an `FNR == 1` reset over the whole file list —
never N times and never N × K for K keys. `eb_manifest_events`
(`core/event-bus/known-types.sh`) is the existing example. The manifest index (#2152) applies
this to the yaml prewarm and `_inputs_scan_manifests`.

### §5 — Named, not planned

The census also names the event bus's per-event processes, the `$(dirname` / `$(basename` /
`$(cat` idioms (363 / 59 / 235 sites in the engine; `${p%/*}`, `${p##*/}`, `$(<f)` are free),
`manifest_graph_collect`'s per-hit awk and `cksum`, and `validate_manifest`'s three direct awks
per manifest per walk. Each is a later ratchet; this ADR does not schedule them.

## Consequences

- A fork regression fails CI with its call site named, instead of surfacing months later as a
  slower daemon.
- Test authors get the harness for free: `_fb_traced` + `_fb_count` in the budget test are the
  census tool. Run them by hand on any script to see where its forks are.
- The number is platform-sensitive at the margin (`gtimeout` vs `timeout`, `stat` flavours);
  the budget carries a small headroom and CI's e2e job is Linux-only, so the ratchet is set from
  the Linux number.

## Verification

`bash tests/e2e/fork-budget-test.sh` — SPEC-1 a canary script with one external exec counts
exactly 1 (the detector cannot go inert); SPEC-2 the mocked run still exits 0 under tracing;
SPEC-3 the trace names ≥ 20 source files and ≥ 1,000 execs (an fd-7-closed child traces to
stderr and must not pass as "under budget"); SPEC-4 total ≤ `FORK_BUDGET`. Red step: with the
counter stubbed, SPEC-1 fails `expected: 1, got: 0`.
