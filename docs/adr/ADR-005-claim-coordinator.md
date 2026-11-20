# ADR-005: Claim Coordinator Plugin

**Status:** Accepted
**Date:** 2026-05-24

## Context

The legacy code uses GitHub labels as the cross-machine claim mechanism: each daemon adds `claimed:<machine>` to an issue when picking it up. This is elegant (no SDK, no central coordinator, operators can pause/redirect from the web UI) but has a real TOCTOU window: between `gh issue edit --add-label` and the verification re-read (`legacy-DoNotUse/scripts/lib/daemon-state.sh:602-720`), two daemons can both add their labels and both end up "claiming" the same issue.

Backoff + re-verify mitigates but doesn't eliminate. The race gets worse as the fleet grows.

Three options for zBuild:
- **(A) Real TTL leases.** Lease file or KV with `holder`, `acquired_at`, `ttl_sec`, heartbeat thread. ~200–400 LoC. Production-grade.
- **(B) Dashboard as hard dependency.** Multi-machine mode requires the dashboard process (which already serializes). Cheap but constrains deployment.
- **(C) Document and accept.** Keep current scheme; advise single-machine for now.

The user's decision (KEEPERS §M) was a fourth option: **keep the current scheme as default, but architect it as a plugin so the better solution drops in later.**

## Decision

Cross-machine claim coordination is a `kind: claim-coordinator` plugin. Multiple implementations can coexist. The engine has a built-in wiring layer (`core/claim/claim.sh`) that calls the default plugin's hooks.

### §1 — Engine claim lifecycle

The engine calls the claim coordinator's `claim` hook after the admission lock (`core/state/issue-lock.sh`) and before the first stage dispatches. If the claim is refused (another run holds `zbuild:claimed`), the engine emits `pipeline.refused.claimed`, prints the holder string, and returns non-zero without dispatching any stage. The engine calls the coordinator's `release` hook in the EXIT path (`_runner_abort_trap`), on every exit path: normal completion, stage failure, and TERM signal.

### §2 — Single shared label; holder in the run-status comment

The shared claim label is `zbuild:claimed` — no hostname suffix. Any run on any machine can see it and interpret it without knowing which machine added it. The holder is identified in the run-status comment: `<!-- zbuild-holder: <string> -->` immediately after the `<!-- zbuild-run-status run_id=... -->` marker line. For CI runs the holder is the Actions run URL; for local runs it is `run_id=<id> machine=<hostname>`.

### §3 — Stale content corrected

The original text below ("The engine has no built-in mechanism" and selection via `config/zbuild.yaml`) is superseded by this amendment (#1764). The engine now has a built-in wiring bridge (`core/claim/claim.sh`) that sources the plugin and delegates. Coordinator selection is not configured in `config/zbuild.yaml`; the default plugin (`plugins/claim-coordinator/github-labels/`) is sourced unconditionally by `core/claim/claim.sh`.

### Contract

Every `claim-coordinator` plugin implements:

```bash
plugin_claim <issue_id> → emits stdout JSON: {"acquired": bool, "lease_id": "..."}
plugin_release <issue_id> [lease_id]
plugin_heartbeat <lease_id> → exit 0 if still held, 1 if expired
plugin_list_claims → emits stdout JSON: [{"issue": N, "holder": "...", "acquired_at": "..."}]
```

> **Naming convention:** hook function names are
> `<plugin-id>_<verb>` (e.g. `github_labels_claim`,
> `github_labels_release`). The `plugin_*` form in the snippet above is
> illustrative.

The engine calls these and trusts the return values. Different implementations have different consistency guarantees; the engine doesn't try to reason about them.

### Default plugin: `plugins/claim-coordinator/github-labels/`

Port `daemon-state.sh:602-720` logic verbatim. Behavior:
- `claim`: `gh issue view` → check no existing `claimed:*` label → `gh issue edit --add-label "claimed:$(hostname)"` → random backoff 300–1100ms → re-read → if multiple `claimed:*` labels exist, remove ours and return `{acquired: false}`.
- `release`: `gh issue edit --remove-label "claimed:$(hostname)"`.
- `heartbeat`: no-op (return 0); labels don't expire.
- `list_claims`: `gh issue list --label claimed:*` → parse.

**Plugin README documents the TOCTOU window** so operators know what they're choosing.

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

### Selection

User config (`config/zbuild.yaml`):
```yaml
claim_coordinator: github-labels    # or ttl-leases, dashboard
```

The engine refuses to start with multiple `claim-coordinator` plugins enabled — only one can be active per run.

## Consequences

**Good:**
- Day 1 behavior matches legacy exactly. Migration risk minimized.
- The "real fix" (TTL leases) becomes a focused future PR with a clear contract to satisfy.
- Users can pick the consistency model that matches their deployment.
- The engine code never changes when a new coordinator is added.

**Bad:**
- Day 1 keeps the known TOCTOU window. Mitigated by the dashboard option (existing) and the wishlist item.
- Plugin contract for `claim-coordinator` is wider than other kinds (4 entry points vs. 1–2). Accepted; the operations are intrinsically asymmetric.
- Selecting the wrong coordinator (e.g., `ttl-leases` when fleet members can't see a shared filesystem) silently breaks claims. Mitigation: every coordinator's `init` performs a self-test and refuses to start if its consistency assumptions are violated.

## Implementation Notes (Phase 0.5 — issue #291)

| Item | Status | PR / Notes |
|------|--------|------------|
| `kind: claim-coordinator` plugin kind in registry | Implemented | #320 (feat #308, 2026-05-26) |
| `plugins/claim-coordinator/github-labels/` default coordinator | Implemented | #320; all 4 entry points (`claim`, `release`, `heartbeat`, `list_claims`) |
| `flock` timeout + exclusivity self-test in `init` | Implemented | PR #320 review commit (`862bfc0`) |
| `tests/e2e/claim-race-test.sh` race coverage | Implemented | #320; 6 assertions across concurrent-claim scenarios |
| TOCTOU window documented in plugin README | Implemented | `plugins/claim-coordinator/github-labels/README.md` |
| `plugins/claim-coordinator/ttl-leases/` (no TOCTOU) | Deferred → Phase 1 | KEEPERS.md §L item 10 |
| `plugins/claim-coordinator/dashboard/` variant | Deferred → Phase 1 | KEEPERS.md §L item 11 |

## Enforced by

- §1 (engine calls claim after admission lock, before first stage; release on every EXIT path) →
  `tests/integration/teardown-repeat-signal-test.sh` [DSCLA-1] (claim present before stage dispatches),
  [DSCLA-5] (released on normal exit), [DSCLA-6] (released on failure), [DSCLA-7] (released on TERM),
  [DSCLA-22] (stub claim hook called after admission lock and before first stage; release hook called in EXIT path);
  §1(c) (refused: non-zero exit, no stage dispatched, event emitted) →
  `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh` [DSCLA-3],
  `tests/integration/teardown-repeat-signal-test.sh` [DSCLA-9] (refused output names holder)
- §2 (single `zbuild:claimed` label, no hostname; holder in run-status comment) →
  `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh` [DSCLA-1] (label is
  exactly `zbuild:claimed`), [DSCLA-2] (`<!-- zbuild-holder: -->` in rendered run-status header),
  [DSCLA-12] (CI holder `<!-- zbuild-holder: CI_URL -->` in rendered run-status header)

## References

- [KEEPERS.md §M](../KEEPERS.md#section-m--multi-machine-claim-safety-decided-modular-swap-later) — full decision rationale.
- [KEEPERS.md §L item 10, 11](../KEEPERS.md#section-l--post-stabilization-wishlist) — wishlist for TTL-leases and dashboard variants.
- `legacy-DoNotUse/scripts/lib/daemon-state.sh:602-720` — original label-based logic, source for the default plugin.
- `legacy-DoNotUse/scripts/lib/fleet-failover.sh` — peer-release pattern, applies to all coordinator implementations.
- [ADR-041 — flock serialization chokepoint](ADR-041-flock-serialization-chokepoint.md) — generalizes this ADR's `flock`-for-atomicity use (and its required-tool justification) into the repo-wide serialization policy.
