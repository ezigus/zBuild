# ADR-025: Abort Propagation Contract

**Status:** Accepted
**Date:** 2026-06-04
**Accepted:** 2026-06-04 (Wave 15-B #684 ships the helpers + dispatch-site conversion)
**Depends on:** ADR-006 (resume contract), ADR-024 (subprocess env isolation — sentinel-file precedent)
**Implemented by:** #684 (Wave 15-B impl: helper + dispatch-site conversion). Umbrella: #679.

## Context

Three consecutive discoveries of the same abort-propagation bug class —
each at a different dispatch site — have shipped tactical per-site fixes
that did not generalize:

1. **#612 (Wave 8)** — `route_to_model_loop` did not distinguish a
   SIGINT-driven child exit (rc=130) from a generic per-iteration failure
   and continued the loop, spawning another iteration after the user
   hit Ctrl-C. Tactical fix at `core/router/route.sh:527-539, 636, 841-863`
   installed an INT/TERM trap that captures the child pid, signals it,
   and surfaces rc=130 from the loop so the caller can propagate.
   The trap installer (`_route_loop_install_traps`) and signal
   handler (`_route_loop_on_signal`) are the per-site primitives.
2. **#616 (Wave 8)** — same bug class one layer up: the build plugin
   captured rc=130 from the router but then ran post-processing as if the
   call had succeeded, returning rc=0 to the runner. Tactical fix added an
   explicit `[[ $rc -eq 130 ]] && return 130` check after each router
   call. The runner's `_runner_signal_trap` at `core/pipeline/runner.sh:863-872`
   was added to convert SIGINT into a clean rc=130 exit and trigger the
   abort EXIT trap.
3. **Wave 15 dogfood `20260604061056-1003` (this ADR's motivating
   discovery)** — the cycle orchestrator (introduced by ADR-021 *after*
   Wave 8 shipped, so it never received the per-site SIGINT pattern) has
   the third instance of the same gap. `_cycle_iter_dispatch` at
   `core/pipeline/cycle-orchestrator.sh:664-681` captures `rc=$?` from
   `cycle_dispatch_stage`, increments `fail` if non-zero, and continues to
   the next stage. rc=130 looks indistinguishable from a normal stage
   failure. The cycle keeps spinning after the user hit Ctrl-C.

The pattern is now clear: every new dispatcher recreates the bug. Per-site
SIGINT handling is a treadmill — it patches the site that surfaced the
issue, not the class. The cycle orchestrator gap is the third instance;
the next dispatcher (strategy plugins, future orchestrators) is one
unchecked `rc=$?` away from re-discovery.

What's missing is a single semantic contract that tells dispatch-site
authors how to propagate abort across nested dispatch layers, plus a
cross-subshell signal channel for cases where rc propagation alone is too
slow (a child that hasn't returned yet when a sibling child sees the
abort).

## Decision

zBuild codifies a **two-layer abort propagation contract**. Every
dispatcher — runner, cycle orchestrator, future strategy plugins —
participates in both layers.

### Layer 1 — rc=130 propagation chokepoint helper

A single framework-owned helper, `_zbuild_propagate_abort`, lives in
`scripts/lib/abort-propagation.sh`. Signature:

```
_zbuild_propagate_abort <child_rc>
  returns <child_rc> if <child_rc> is an abort rc (130 today;
  130 or 143 once Wave 15-F #686 ships SIGTERM parity), else 0
```

The helper returns the abort rc it was given, not a hard-coded 130.
This means the SIGTERM widening in #686 is a one-line change to the
helper's classifier (add 143 to the recognised set) and does not change
the helper's signature or the call-site contract. Every dispatcher calls
it immediately after capturing each child rc. Greppable —
`grep -r _zbuild_propagate_abort` enumerates every dispatch site
participating in the contract. Single point to evolve when SIGTERM parity
ships.

### Layer 2 — sentinel file `${ZBUILD_STATE_DIR}/.abort.signal`

The runner's SIGINT trap (`_runner_signal_trap` at
`core/pipeline/runner.sh:863-872`) creates the sentinel file as the first
action before triggering the rc=130 exit. The sentinel is a cross-subshell
signal channel: env vars get scrubbed by ADR-024's
`_zbuild_make_fresh_shell` at fresh-shell boundaries, but the filesystem
survives. Long-running dispatch loops in subshells (cycle iteration,
strategy plugins forked under `( ... )`) check the sentinel before each
child spawn.

A second helper, `_zbuild_check_abort`, also lives in
`scripts/lib/abort-propagation.sh`. Signature:

```
_zbuild_check_abort
  returns 130 if "${ZBUILD_STATE_DIR}/.abort.signal" exists, else 0
```

## Dispatch site contract

Every dispatcher MUST:

1. Call `_zbuild_check_abort` BEFORE spawning each child (pre-flight,
   sentinel-driven).
2. Call `_zbuild_propagate_abort $?` AFTER capturing each child rc
   (post-flight, rc-driven).

Both helpers return 130 on abort; the dispatcher propagates that rc
upward via `|| return $?` or equivalent. Future orchestrators inherit
correct behavior by convention — the contract is the same two helper
calls at the same two points in every loop.

## Resolver order in dispatchers

```
loop {
    _zbuild_check_abort || return $?         # pre-flight (sentinel)
    dispatch_child
    _zbuild_propagate_abort $? || return $?  # post-flight (rc)
    # per-iter bookkeeping (verdict, status, events)
}
```

Pre-flight catches the case where a sibling child or a parent caught the
signal and the sentinel was written between this iteration's previous
post-flight and the next child spawn. Post-flight catches the case where
the child itself received the signal and exited 130. Both layers are
needed: rc propagation is fast within-process, sentinel is
belt-and-suspenders for cross-subshell.

## Cleanup contract

The runner's existing `_runner_abort_trap` (EXIT-bound) already emits
`pipeline.aborted reason=sigint status=interrupted`. ADR-025 adds the
sentinel-file cleanup: the EXIT trap removes
`${ZBUILD_STATE_DIR}/.abort.signal` after emitting the event, so a
subsequent `zbuild` invocation in the same state dir does not see a stale
sentinel.

Trap composition is **additive**, not clobbering. The Wave 15-B impl
must compose the sentinel-creation step onto the existing
`_runner_signal_trap` body (which already calls `exit 130`) and the
sentinel-removal step onto the existing `_runner_abort_trap` EXIT body —
not replace them. This matches the ADR-024 amendment's additive-trap
discipline for the test harness.

## SIGTERM extension

ADR-025 anticipates rc=143 (128 + SIGTERM) carrying the same semantics
as rc=130. The `_zbuild_propagate_abort` helper returns the abort rc it
was given (not a hard-coded 130), so widening to rc=143 is a one-line
change to the helper's internal classifier and leaves the signature,
the call-site contract, and the sentinel-file pathway unchanged. The
sentinel file is signal-agnostic — any abort cause writes the same
sentinel. This ADR scopes the contract to SIGINT for now; #686 widens
it without changing the helper signatures or call-site contract.

## Member dispatch sites

Current call sites being modified by Wave 15-B (#684):

- `core/pipeline/cycle-orchestrator.sh` — `_cycle_iter_dispatch` at
  `:664-681` (the dogfood bug). Adds pre-flight `_zbuild_check_abort`
  before `cycle_dispatch_stage`, post-flight `_zbuild_propagate_abort`
  after capturing `rc=$?`.
- `core/pipeline/runner.sh` — linear stage loop already honors rc=130
  via the existing #612/#616 pattern. Adds the sentinel pre-flight
  `_zbuild_check_abort` before each stage dispatch for parity with the
  cycle orchestrator, plus the sentinel-write step in
  `_runner_signal_trap` and sentinel-remove step in `_runner_abort_trap`.
- `core/router/route.sh` — `route_to_model_loop`'s per-iter body at
  `:527-539, 636, 841-863` already returns 130 on signal. Converts the
  ad-hoc trap-and-kill primitives to call the new helpers on the
  post-spawn rc path. Pre-flight sentinel check before each
  `claude` exec spawn.

Future candidates:

- Strategy plugins that fan out child dispatches (e.g., parallel-
  candidate strategies).
- Future orchestrators (compound-quality loop, retry orchestrator).
- Any plugin whose body contains a `for stage in ...; do dispatch; done`
  shape.

## Alternatives considered

- **(a) Per-site SIGINT unsets and rc=130 checks** (Wave 8 status quo) —
  rejected: does not generalize. The cycle orchestrator gap is the third
  discovery of the same class. Every future dispatcher is one missed
  rc=130 check away from re-discovery. The fix scales with the number of
  dispatch sites, not with the cause.

- **(b) Process-group signal forwarding (`set -m` + job control)** — a
  more aggressive isolation that puts each child in its own process
  group and forwards SIGINT to the whole group, letting the kernel do
  propagation. Rejected for this ADR: `set -m` interacts badly with
  bash's existing trap handling in subshells, and even within zBuild's
  supported Bash 5+ baseline the job-control semantics are subtle —
  failure modes differ across Bash 5 minor versions and across platforms
  (macOS Homebrew Bash 5.x vs Linux CI Bash 5.x), and the failures are
  hard to reproduce without live SIGINT timing. A
  flag-gated reconsider ships as Wave 15-H (#688). If/when that lands,
  the helpers become no-ops in process-group mode; the call-site
  contract is unchanged.

- **(c) Single sentinel-file-only contract (drop Layer 1)** — rejected:
  rc propagation is faster within-process and catches the common case
  where the child itself received the signal. Sentinel is the
  belt-and-suspenders layer for the cross-subshell case where rc alone
  is insufficient (e.g., a sibling child sees the abort first and writes
  the sentinel before the current child returns). Both layers serve
  distinct cases.

- **(d) Single rc-propagation-only contract (drop Layer 2)** — rejected:
  ADR-024's `_zbuild_make_fresh_shell` scrubs `ZBUILD_*` at fresh-shell
  boundaries, so an env-var-based signal channel does not survive the
  scrub. The filesystem is the only channel guaranteed to survive both
  the scrub and the subshell boundary.

## Consequences

**Good:**

- The next dispatcher added to zBuild does not recreate the bug class.
  The contract is two helper calls; the helpers are greppable; the
  reviewer checklist is "does this dispatch loop call both helpers?".
- Per-site trap-and-rc-check primitives at runner/router/build collapse
  into one helper file. SIGTERM parity (Wave 15-F #686) is a one-file
  edit, not a per-site sweep.
- The cycle orchestrator gap surfaced by Wave 15 dogfood is killed at
  the architectural boundary, not patched per-site.

**Bad:**

- One more piece of framework vocabulary (`_zbuild_propagate_abort`,
  `_zbuild_check_abort`) that dispatch-site authors must learn.
  Mitigated by the helpers living in one file with the contract
  colocated.
- Additive trap composition needs care: the Wave 15-B impl must compose
  onto existing `_runner_signal_trap` / `_runner_abort_trap` bodies,
  not replace them. A reviewer checklist item.
- Sentinel file is filesystem state; a crashed runner that did not run
  its EXIT trap leaves a stale sentinel. Mitigated by the next runner
  invocation observing rc=130 immediately and surfacing a clear error
  (or, with a pre-flight clean step at runner entry, removing the
  stale file).

**Open follow-ups:**

- **Wave 15-B (#684)** — ship `_zbuild_propagate_abort` +
  `_zbuild_check_abort` in `scripts/lib/abort-propagation.sh`, convert
  the three dispatch sites (cycle orchestrator, runner, router), add
  the runner's sentinel-write/remove steps. ADR-025 flips from
  Proposed to Accepted on that merge.
- **Wave 15-E (#685)** — resume contract integration: a run aborted via
  SIGINT writes resume metadata before the EXIT trap exits, so the user
  can `zbuild resume` from the aborted stage. Builds on ADR-006.
- **Wave 15-F (#686)** — SIGTERM parity. Widens the helpers to accept
  rc=143 and routes SIGTERM through the same trap composition.
- **Wave 15-G (#687)** — faster pre-abort: poll the sentinel from
  long-running stages (not just at dispatch boundaries) so SIGINT is
  honored mid-stage rather than at the next stage boundary.
- **Wave 15-H (#688)** — reconsider process-group signal forwarding
  (alternative b) once helper baseline is in place.

## Implementation Notes (Proposed — 2026-06-04)

This ADR ships in **Proposed** status. No code, no test, no event-schema
changes in this PR. The status flips to **Accepted** when Wave 15-B
(#684) lands the helpers and converts the three dispatch sites.

The impl sequence (Wave 15-B):

- Ship `_zbuild_propagate_abort` and `_zbuild_check_abort` in
  `scripts/lib/abort-propagation.sh`. The first returns its argument rc when the argument is an abort rc
  (130 today; widened in #686), else 0. The second returns 130 when
  `${ZBUILD_STATE_DIR}/.abort.signal` exists, else 0. Both signatures
  are stable across the SIGTERM widening — only the abort-rc classifier
  inside `_zbuild_propagate_abort` changes.
- Wire the sentinel-write step into `_runner_signal_trap`
  (`core/pipeline/runner.sh:863-872`) as the first action, composed
  additively onto the existing `exit 130` body. Wire the sentinel-
  remove step into `_runner_abort_trap` after the
  `pipeline.aborted` event emission, also composed additively.
- Convert `_cycle_iter_dispatch` at
  `core/pipeline/cycle-orchestrator.sh:664-681` to call
  `_zbuild_check_abort` before `cycle_dispatch_stage` and
  `_zbuild_propagate_abort` after capturing `rc=$?`. Both calls use
  `|| return $?` to propagate rc=130 upward.
- Convert the runner's linear stage loop to the same two-helper-call
  shape for parity.
- Convert `route_to_model_loop`'s body (`core/router/route.sh:527-539, 636, 841-863`)
  to call the helpers around its `claude` spawn.
- Add subprocess-boundary integration tests that assert:
  (a) rc=130 from a child propagates up through cycle orchestrator;
  (b) a sentinel written by a sibling dispatcher aborts the next
  iteration's pre-flight check;
  (c) the sentinel is removed by `_runner_abort_trap` on clean exit.
- ADR-025 status flips from Proposed to Accepted in the Wave 15-B PR.

This PR (closing #679) lands only the ADR text.

## Status flip

ADR-025 ships in **Proposed** status. The status flips from Proposed to
**Accepted** when Wave 15-B (#684) merges — the same pattern used by
ADR-015 (flipped on #438) and ADR-024 (flipped on #673). No code, no
test, no event-schema changes in this PR. Only the ADR text.

## References

- [ADR-006](ADR-006-resume-contract.md) — resume contract; aborted runs
  MAY be resumable, integrated by Wave 15-E (#685).
- [ADR-024](ADR-024-subprocess-env-isolation.md) — subprocess env
  isolation; the sentinel-file pattern is the cross-subshell signal
  channel because env vars do not survive `_zbuild_make_fresh_shell`.
- Issue #612 (Wave 8) — first discovery: SIGINT through router
  (`route_to_model_loop` rc=130). Tactical fix at
  `core/router/route.sh:527-539, 636, 841-863`.
- Issue #616 (Wave 8) — second discovery: SIGINT through build plugin
  (rc=130 → terminal). Added `_runner_signal_trap` at
  `core/pipeline/runner.sh:863-872`.
- Wave 15 dogfood `20260604061056-1003` — third discovery: cycle
  orchestrator gap at `core/pipeline/cycle-orchestrator.sh:664-681`.
- Issue #679 (this ADR) — Wave 15-A umbrella.
- Issue #684 (Wave 15-B) — helper impl + dispatch-site conversion; the
  PR that flips ADR-025 to Accepted.
- Issue #685 (Wave 15-E) — resume contract integration.
- Issue #686 (Wave 15-F) — SIGTERM parity.
- Issue #687 (Wave 15-G) — faster pre-abort polling.
- Issue #688 (Wave 15-H) — process-group signal forwarding reconsider.
- `scripts/lib/abort-propagation.sh` — forthcoming home of
  `_zbuild_propagate_abort` and `_zbuild_check_abort` (lands in
  Wave 15-B).
