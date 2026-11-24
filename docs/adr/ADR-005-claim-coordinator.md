# ADR-005: Claim Coordinator Plugin

**Status:** Accepted
**Date:** 2026-05-24
**Amended:** 2026-11-21 (#1764: the engine claims and releases; one shared label; holder in the run-status comment)

## Context

The legacy code uses GitHub labels as the cross-machine claim mechanism: each daemon adds `claimed:<machine>` to an issue when picking it up. This is elegant (no SDK, no central coordinator, operators can pause/redirect from the web UI) but has a real TOCTOU window: between `gh issue edit --add-label` and the verification re-read (`legacy-DoNotUse/scripts/lib/daemon-state.sh:602-720`), two daemons can both add their labels and both end up "claiming" the same issue.

Backoff + re-verify mitigates but doesn't eliminate. The race gets worse as the fleet grows.

Three options for zBuild:
- **(A) Real TTL leases.** Lease file or KV with `holder`, `acquired_at`, `ttl_sec`, heartbeat thread. ~200–400 LoC. Production-grade.
- **(B) Dashboard as hard dependency.** Multi-machine mode requires the dashboard process (which already serializes). Cheap but constrains deployment.
- **(C) Document and accept.** Keep current scheme; advise single-machine for now.

The user's decision (KEEPERS §M) was a fourth option: **keep the current scheme as default, but architect it as a plugin so the better solution drops in later.**

## Decision

Cross-machine claim coordination is a `kind: claim-coordinator` plugin, so another tracker (JIRA, a lease
store) can replace GitHub by providing its own coordinator. The engine's side is `core/claim/claim.sh`; it
knows the hooks, never what a claim is made of.

### §1 — Engine claim lifecycle (amended 2026-11-21, #1764)

- A run with an issue calls the coordinator's `claim` hook **after** the one-machine admission lock
  (`core/state/issue-lock.sh`, ADR-059 §4) and **before** its tree, its branch and its first stage. The lock
  refuses first: a second run of an issue on the same machine never reaches the coordinator.
- A run with no issue (a goal run) makes no claim and calls no coordinator hook.
- **Refused** (another run holds the claim): the run exits non-zero, dispatches no stage, emits
  `pipeline.refused.claimed` with the holder, and prints the holder exactly as written (no escape in it is
  interpreted).
- **Released** through the coordinator's `release` hook on every way out of a run that holds the claim: a
  pass, a stage failure, a TERM or INT mid-run, a failure before the stages, and a TERM that lands while the
  claim itself is being taken. From the claim until the run's own EXIT trap is set, a small EXIT trap
  releases it; a signal in that span is held until the claim is recorded and then ends the run through
  that trap. A second TERM during teardown does not stop the release.
- The engine does not check, before each stage, that it still holds the claim.

### §2 — One shared label; the holder in the run-status comment

- The default coordinator's claim is one label, `zbuild:claimed`, the same for a laptop run and a CI run —
  no machine name in it.
- Who holds it is written in the holder's run-status comment (ADR-064): a run that has the claim emits
  `pipeline.claim.acquired holder=<holder>`, and the comment's header carries
  `<!-- zbuild-holder: <holder> -->` while the run is running. A run that has no claim, or has finished,
  names no holder. The holder is the CI run's
  URL in CI, and `run_id=<id> machine=<host>` elsewhere.
- A refused run reads the holder from the newest run-status comment that names one, and only from comments
  the CI bot or a repository owner, member or collaborator posted: an outside commenter cannot name the
  holder. A finished run's comment names none, so the holder named is a run still going, or one that died
  without finishing (which left the label too). A newer comment naming none — a refused or skipped run's —
  does not hide it. When no comment names one (e.g. the holder posts none: `ZBUILD_STATUS_COMMENT=0`), the
  holder is unknown.
- The coordinator's hook events (`plugin.claim.*`, `plugin.release.*`) carry no stage.

### §3 — Graceful degradation

The claim is advisory across machines; this machine's admission lock still serialises runs here.

- No coordinator installed, a coordinator that fails, or one that makes no claim (`skipped`, e.g.
  `NO_GITHUB=true`): the run goes on unclaimed and emits `pipeline.claim.skipped` with the reason.
- An answer the engine cannot read is a refusal: a claim may be there.
- A release that fails emits `pipeline.claim.release_failed` and never changes the run's exit status; the
  coordinator says on stderr how to clear the claim by hand.

### §3 (amended 2026-11-24, #2533) — Heartbeat and cross-machine staleness

- **§3a Heartbeat interval.** While a run holds the claim, the run-status sidecar flushes a fresh body
  to GitHub every `ZBUILD_CLAIM_HEARTBEAT_S` seconds (default 600) even when no new stage events have
  arrived. The first visible line of a running body is `still running — <ISO8601> — now: <stage>` (or
  without the stage suffix when no stage is active), updated on every flush.
- **§3b Staleness threshold.** A cross-machine claim is considered stale when its heartbeat timestamp
  is at least `ZBUILD_CLAIM_STALE_S` seconds old (default 1800). `ZBUILD_CLAIM_STALE_S` and
  `ZBUILD_CLAIM_HEARTBEAT_S` are set as shell defaults (`:-` expansion) in `core/claim/claim.sh`.
- **§3c Always-claimed when no heartbeat.** A claim with no heartbeat line in the run-status comment
  falls back to the `zbuild:claimed` label's `added` event timestamp (GitHub issues events API). If
  that timestamp is also unavailable (API error), the run refuses rather than taking over blindly
  (fail closed).
- **§3d Stale takeover.** When a cross-machine claim's reference timestamp (heartbeat or label-added)
  is at least `ZBUILD_CLAIM_STALE_S` old: `rsc_takeover_note_post` posts "took over a stale claim
  from <holder>" as a new issue comment, the old claim is released, and the new run acquires once.
  The takeover is attempted at most once per `zbuild_claim_acquire` call chain
  (`_ZBUILD_CLAIM_RETRIED` guard).
- **§3e Lazy source.** `zbuild_claim_acquire` sources `run-status-comment.sh` lazily when a
  cross-machine stale check is needed; it refuses if the file cannot be sourced or
  `rsc_takeover_note_post` is not defined after sourcing.

### §4 — Finding and calling the coordinator

- The coordinator is the claim-coordinator plugin found under the plugins root
  (`${ZBUILD_PLUGINS_ROOT:-<engine>/plugins}`), the one root every other plugin is found under. Choosing
  between several coordinators is not built; one is installed (`github-labels`).
- The engine calls it only through `plugin_hook_call`; nothing under `core/` calls `gh` for the claim.

### Contract

Every `claim-coordinator` plugin declares these hooks in its manifest (the default plugin's functions are
`claim_coordinator_<verb>`):

```bash
claim <issue_id>   → stdout JSON: {"acquired": true}
                                | {"acquired": false, "holder": "<who>"}
                                | {"acquired": false, "skipped": "<why no claim was attempted>"}
                     rc 0 answered, 1 backend error, 2 usage error
release <issue_id> → rc 0 released, non-zero failed
heartbeat <issue_id> → rc 0 (the default plugin's labels do not expire; staleness is #2533)
list_claims        → stdout JSON: [{"issue": N, "holder": "...", "acquired_at": ...}]
```

### Default plugin: `plugins/claim-coordinator/github-labels/`

- `claim`: read the issue's labels; `zbuild:claimed` there → refused, with the holder and, on stderr, how to
  clear a claim whose run is gone (remove the label). Otherwise add it. A repository that does not define
  the label gets it (`gh label create --force`) when the add fails with "not found", and the add is tried
  once more. An add that fails is checked by reading the labels once more: the issue was clear when read,
  so a label there now is this run's claim, and is released on exit.
- Every label call names the repository (`--repo`, the same slug the holder reader uses).
- `release`: remove the label; on failure, say on stderr to remove it by hand.
- Every `gh` call runs under the run-status comment's watchdog (`rsc_gh`,
  `ZBUILD_STATUS_COMMENT_GH_TIMEOUT`), so a hung `gh` cannot hold up a run's exit.
- **Known, not mitigated:** GitHub's label add does not check that the label is absent, so two runs that
  read "no label" at the same moment can both add it and both start. #2534 settles that race; until then
  nothing here prevents it. (The local-fs test store checks and adds under one lock, so a race on it has
  one winner; that says nothing about GitHub.)

### Future plugin: `plugins/claim-coordinator/ttl-leases/`

Section L wishlist item. Behavior:
- Lease file at `~/.zbuild/leases/<issue>.json` (or shared KV in cluster deployments).
- `claim`: write-if-absent with `flock`; record `{holder, acquired_at, ttl_sec, generation}`.
- `heartbeat`: refresh `acquired_at` with `flock`; bump generation if needed.
- `release`: delete lease file.
- `list_claims`: read all `~/.zbuild/leases/*.json`.

No TOCTOU window — `flock` provides atomicity.

### Future plugin: `plugins/claim-coordinator/dashboard/`

Section L wishlist item. Routes all claim operations through an optional dashboard process that serializes them in-memory. Useful for teams already running the dashboard.

## Consequences

**Good:**
- One label any run on any machine can see; the run-status comment already on every issue names the holder.
- A coordinator for another tracker drops in without an engine change.
- A run is never blocked by GitHub being down: the claim degrades to "unclaimed", visibly.

**Bad:**
- Two runs claiming at the same moment can both win (#2534).
- A run that dies without reaching an exit path leaves the label; until #2533 a person removes it.
- A cancelled GitHub Actions job leaves the label too: the runner sends INT, then TERM, then KILL a few
  seconds later, and the KILL can land while the always-run stages and persist are still running in the exit
  trap — before the release, which comes after them so that persist keeps the run's work. Clear it as after a
  crash: remove the `zbuild:claimed` label from the issue (until #2533).
- Plugin contract for `claim-coordinator` is wider than other kinds (4 hooks). Accepted.

## Implementation Notes (Phase 0.5 — issue #291)

| Item | Status | PR / Notes |
|------|--------|------------|
| `kind: claim-coordinator` plugin kind in registry | Implemented | #320 (feat #308, 2026-05-26) |
| `plugins/claim-coordinator/github-labels/` default coordinator | Implemented | #320; all 4 entry points (`claim`, `release`, `heartbeat`, `list_claims`) |
| `flock` timeout + exclusivity self-test in `init` | Implemented | PR #320 review commit (`862bfc0`) |
| `tests/e2e/claim-race-test.sh` race coverage | Implemented | #320; rewritten in #1764 for the shared label (the local-fs store only) |
| The engine claims before the first stage and releases on exit | Implemented | #1764 (`core/claim/claim.sh`, `core/pipeline/runner.sh`) |
| Heartbeat and stale takeover | Deferred | #2533 |
| Two runs claiming at the same moment | Deferred | #2534 |
| TOCTOU window documented in plugin README | Implemented | `plugins/claim-coordinator/github-labels/README.md` |
| `plugins/claim-coordinator/ttl-leases/` (no TOCTOU) | Deferred → Phase 1 | KEEPERS.md §L item 10 |
| `plugins/claim-coordinator/dashboard/` variant | Deferred → Phase 1 | KEEPERS.md §L item 11 |

## Amendment 2026-11-23 (#2586) — §3: a reply that says acquired is believed

A claim hook whose reply says `"acquired": true` holds the claim, whatever the hook's exit status. An interrupt can cut the engine's wait for the hook short after the label went on, so the status reads non-zero while the reply is right; before this, the run counted the claim as skipped and never released it (C7 in `tests/integration/claim-release-on-exit-test.sh`, failing in CI and in #2532 run 45017980554). A non-zero status with any other reply is still a skipped claim.

## Amendment 2026-11-23 (#2589) — §1 §3: the claim label is always cleared; a rejected login stops the run

- **The claim label is cleared in three layers.**
  1. **The run releases it on every way out,** as before.
  2. **CI's clean-up job removes it when the run did not.** It runs whatever the pipeline's result, with its own token, and removes `zbuild:claimed` when the run's events say it took the claim and never released it (`rsc_claim_left`: acquired, and no completed release hook), or when the issue's newest run-status comment still names this run as the holder (`rsc_claim_cleanup`). It runs before the comment is finalized, and it never touches another run's claim. #2532 run 45102665787 left the label because its own release failed after GitHub revoked its token.
  3. **The next run on the same machine clears that machine's own stale claim.** A local holder is `run_id=<id> machine=<machine> pid=<runner pid>`.
     - If the refusing holder is another run on this machine whose pid is gone (`kill -0`), the label is removed and the claim taken again, once, and it says so (`pipeline.claim.stale_cleared`).
     - If the holder is this very run (a resume after a crash keeps its run id), the claim is this run's again.
     - A claim held by another machine, by CI, by a live process, or written before holders carried a pid is never touched; that stays with #2533.
     - A refused run's message gives the command that clears a label by hand.
  - **When CI's clean-up uses which signal:** the run's own record (`claim_left`) decides. The holder in the status comment is used only when the run left no record, so a run that reported its release is trusted.
- **A run whose GitHub login is rejected stops at once and says so.** Two GitHub calls in a row refused with "Bad credentials" or HTTP 401 leave a marker (`rsc_gh`). Two, so a single short-lived 401 does not end a long run, and a call that works in between starts the count again. The marker is cleared when a run starts, so a resume, its token since fixed, is not stopped by it. The status sidecar then stops the run once. The run ends with the word `github_login_rejected`, with the plain words "GitHub no longer accepts this run's login", releasing what it holds on its way out. Before, the run went on for two more rounds with its status comment frozen. This works where the status sidecar runs (the run-status comment is on). A run with it off is not stopped by the engine's other GitHub calls, and its clean-up still covers the label.

## Enforced by

- §3 amendment 2026-11-24 (#2533: heartbeat interval, staleness threshold, stale takeover, label-added fallback):
  - §3a heartbeat interval default (600 s) → `tests/unit/claim-heartbeat-stale-test.sh` DSHBT-7
  - §3b staleness threshold default (1800 s) → `tests/unit/claim-heartbeat-stale-test.sh` DSHBT-8
  - §3b stale takeover after `ZBUILD_CLAIM_STALE_S` → `tests/unit/claim-heartbeat-stale-test.sh` DSHBT-4
  - §3b fresh claim refused → `tests/unit/claim-heartbeat-stale-test.sh` DSHBT-3
  - §3c label-added fallback → `tests/unit/claim-heartbeat-stale-test.sh` DSHBT-5
  - §3d takeover note posted → `tests/unit/claim-heartbeat-stale-test.sh` DSHBT-4
  - §3 same-machine dead-pid path runs before heartbeat check → `tests/unit/claim-heartbeat-stale-test.sh` DSHBT-6
  - §3 unclaimed issue acquired without heartbeat → `tests/unit/claim-heartbeat-stale-test.sh` DSHBT-12

- §1 §3 amendment 2026-11-23 (#2589: the label always cleared; a rejected login stops the run) → `tests/unit/claim-cleanup-test.sh` CL1–CL8; `tests/unit/claim-acquire-release-test.sh` S1–S4; `tests/integration/claim-release-on-exit-test.sh` C8, C9; `tests/integration/claim-holder-status-comment-test.sh` H1 (the holder carries the pid); `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh` (the refusal gives the command)

- §3 amendment 2026-11-23 (#2586: an acquired reply is believed) → `tests/unit/claim-acquire-release-test.sh` ("an acquired reply with a bad status → the claim is held … and released at the end")

- §1 claim after the admission lock, before the first stage →
  `tests/integration/claim-release-on-exit-test.sh` [C1] (the label is on the issue when the first stage
  runs), [C4] (the claim hook has run when the first stage starts);
  `tests/integration/claim-refusal-test.sh` [F2] (a second run on this machine is refused by the lock and
  never calls the coordinator)
- §1 no issue, no claim → `tests/integration/claim-release-on-exit-test.sh` [C5];
  `tests/unit/claim-acquire-release-test.sh` "a run with no issue makes no claim"
- §1 refused → `tests/integration/claim-refusal-test.sh` [F1] (non-zero, no stage, `pipeline.refused.claimed`
  with the holder, the holder printed as written)
- §1 released on every way out → `tests/integration/claim-release-on-exit-test.sh` [C1] pass, [C2] stage
  failure, [C3] TERM mid-stage, [C4] the release hook on exit, [C6] a failure before the stages, [C7] a TERM
  while the claim is taken; `tests/unit/plugin-hook-call-signal-rc-test.sh` (a signal held during the claim
  leaves the hook's own answer); `tests/integration/teardown-repeat-signal-test.sh` [T6] (a second TERM during
  teardown)
- §2 one shared label, no machine name → `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`
  (local-fs and gh: the issue carries exactly `zbuild:claimed`)
- §2 the holder written only by a run that has the claim →
  `plugins/claim-coordinator/github-labels/tests/claim-holder-reader-unit-test.sh` (the writer);
  `tests/integration/claim-holder-status-comment-test.sh` [H1] (the posted comment names it), [H2] (a run
  with no claim names none); `tests/unit/claim-acquire-release-test.sh` (`pipeline.claim.acquired` holder:
  run id and machine, or the CI run's URL)
- §2 the holder read from the newest trusted comment that names one →
  `plugins/claim-coordinator/github-labels/tests/claim-holder-reader-unit-test.sh` (the reader: paginated,
  the CI bot's comment, newer comments naming none do not hide the live holder, a finished run's comment →
  none, an outside commenter cannot name it; the writer: a finished run names none)
- §2 hook events carry no stage → `tests/unit/claim-acquire-release-test.sh` (plugin.claim.*, plugin.release.*)
- §3 graceful degradation → `tests/unit/claim-acquire-release-test.sh` (no coordinator, a failing or
  skipping coordinator → `pipeline.claim.skipped`; an unreadable answer is a refusal; a failed release →
  `pipeline.claim.release_failed`, the caller's status unchanged);
  `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh` (`NO_GITHUB=true` → skipped,
  no gh call)
- §4 one plugins root, through the registry → `tests/unit/claim-acquire-release-test.sh` (a coordinator
  outside the root is not used); `tests/integration/claim-release-on-exit-test.sh` [C4]
- Default plugin → `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh` (the label
  created once when missing; an add GitHub applied whose answer was lost is a claim; every gh call names the
  repository; the refusal and the failed release say how to clear the label; a hung gh is
  stopped by the watchdog); `tests/e2e/claim-race-test.sh` (the local-fs store has one winner)

## References

- [KEEPERS.md §M](../KEEPERS.md#section-m--multi-machine-claim-safety-decided-modular-swap-later) — full decision rationale.
- [KEEPERS.md §L item 10, 11](../KEEPERS.md#section-l--post-stabilization-wishlist) — wishlist for TTL-leases and dashboard variants.
- `legacy-DoNotUse/scripts/lib/daemon-state.sh:602-720` — the legacy label logic (`claimed:<machine>`, backoff, re-read) that the default plugin replaced.
- `legacy-DoNotUse/scripts/lib/fleet-failover.sh` — peer-release pattern, applies to all coordinator implementations.
- [ADR-041 — flock serialization chokepoint](ADR-041-flock-serialization-chokepoint.md) — generalizes this ADR's `flock`-for-atomicity use (and its required-tool justification) into the repo-wide serialization policy.
