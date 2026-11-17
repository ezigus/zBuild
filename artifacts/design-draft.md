# Design — GitHub label claim (#1764)

## Goal

Prevent two concurrent zBuild runs on the same issue from overlapping across machines using a
GitHub label (`zbuild:claimed`) as a soft cross-machine claim. The existing local flock
(`core/state/issue-lock.sh`) remains for intra-machine serialisation; this change adds the
inter-machine layer on top of it.

## Context

`core/state/issue-lock.sh` is a filesystem flock: effective on one host, invisible from another.
Issue #1764 asks for a GitHub label that any run can see before it starts. The run-status sidecar
already posts a progress comment on the issue (ADR-064, `scripts/lib/run-status-comment.sh`);
the holder string goes into that comment, satisfying RQADR-2 without a separate claim comment.

## Decision

**Run-status comment as the progress comment.** `rsc_render_header` (in `scripts/lib/run-status-render.sh`)
adds a machine-readable `<!-- zbuild-holder: ... -->` HTML comment immediately after the
`<!-- zbuild-run-status run_id=... -->` marker line. Format:
- CI (`GITHUB_ACTIONS=true`): `<!-- zbuild-holder: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID} -->`
- Local: `<!-- zbuild-holder: run_id=<run_id> machine=<hostname> -->`

**Amend `plugins/claim-coordinator/github-labels/plugin.sh`** (the existing plugin owns this job):
- Change `claim_coordinator_claim` to use the single shared label `zbuild:claimed` instead of
  `claimed:<machine>`. The simplified check: if `zbuild:claimed` is absent, add it; if present,
  search the issue's comments for the most recent run-status comment and extract the
  `<!-- zbuild-holder: -->` line into a returned holder string.
- Change `claim_coordinator_release` to remove `zbuild:claimed` (no machine suffix).
- The `_ccgl_*` backend helpers remain and are used by the amended public functions.
- `plugin.sh` must not source `core/claim/claim.sh` — that would create a circular dependency
  and add a startup `$(cd ...)` subshell in plugin.sh's load path.

**New `core/claim/claim.sh`** (thin wiring bridge — no reimplemented logic):
- Sources `plugins/claim-coordinator/github-labels/plugin.sh` using `$_ZBUILD_ROOT` (already
  set by runner.sh before claim.sh is sourced) — not via a `$(cd ...)` subshell. Tests that
  source claim.sh must set `_ZBUILD_ROOT` before sourcing it.
- `zbuild_claim_build_holder`: builds and exports `_ZBUILD_CLAIM_HOLDER`; uses `${HOSTNAME}`
  (bash built-in variable) for the machine name — never calls the external `hostname` command,
  which would fork an extra process during startup.
- `zbuild_claim_acquire <issue>`: skip if issue is empty; calls `_ccgl_read_labels` / `_ccgl_add_label`
  / `_ccgl_read_holder` from the loaded plugin; on conflict, sets `_ZBUILD_CLAIM_HOLDER` from
  the extracted holder string and returns 1; on success, sets `_ZBUILD_CLAIM_ACQUIRED` and
  returns 0. Backend errors return 0 (graceful).
- `zbuild_claim_release <issue>`: skip if issue is empty or `_ZBUILD_CLAIM_ACQUIRED` is unset;
  calls `_ccgl_remove_label` (advisory).

**Wire into `core/pipeline/runner.sh`**: source `core/claim/claim.sh` at top (alongside
`core/state/issue-lock.sh`); call `zbuild_claim_build_holder` before the sidecar spawn so the
sidecar inherits `_ZBUILD_CLAIM_HOLDER`; call `zbuild_claim_acquire` right after
`zbuild_issue_lock_acquire` succeeds; on return 1, emit `pipeline.refused.claimed`, print holder,
return 1 (same shape as issue-lock refusal); call `zbuild_claim_release` in `_runner_abort_trap`
after `zbuild_issue_lock_release`, using `declare -F` guard.

**Register `pipeline.refused.claimed`** in `config/event-schema.json` (follows pattern of
`pipeline.refused.issue_locked`).

**Register `core/claim/claim.sh`** in `config/shape-change-paths.txt`. Future changes to the
claim bridge can alter what events runner.sh emits; the shape floor should detect them.

**Amend ADR-005** per RQADR-1 through RQADR-4. The working-tree ADR-005 already has §1–§3 and
a partial `## Enforced by` section. The existing §1 Enforced by bullet lists DSCLA-1,5,6,7
(acquire and release) but omits §1(c) — the refused-behavior statement (engine emits
`pipeline.refused.claimed`, prints the holder string, and returns non-zero without dispatching any
stage). The step must extend that §1 bullet to add:
- `claim-coordinator-unit-test.sh [DSCLA-3]` (non-zero exit, no stage dispatched, event emitted)
- `teardown-repeat-signal-test.sh [DSCLA-9]` (refused output names holder)

The §2 Enforced by bullet also needs `[DSCLA-12]` added alongside `[DSCLA-2]` for the CI
holder rendering case.

**Amend ADR-059 §4** noting cross-machine exclusion is the coordinator's job per RQADR-5. The
working-tree ADR-059 §4 already has the cross-machine text added. The `## Enforced by` section
must gain a new entry for this §4 cross-machine statement, naming DSCLA-3 as the enforcing test
(a run is refused when the label is already on the issue — the visible effect of cross-machine
exclusion). CLAUDE.md requires a test per new/changed statement regardless of whether a
requirement names it explicitly.

The label `zbuild:claimed` contains no hostname. Holder string contains machine name (local) or
CI URL — in the comment body, not the label (RQLAB-2). Check-then-label is not atomic at GitHub;
two racing machines may both succeed. Known limitation; a strict mutex is out of scope (RQMECH-1,
RQMECH-2).

Startup process budget: the two new source calls (plugin.sh, claim.sh) are `source` builtins
(no forks); `zbuild_claim_build_holder` uses `${HOSTNAME}` (bash built-in, no fork); no `$(cd ...)`
subshells on the load path. Net startup-process cost of this change: 0.

UNCLEAR: RQADR-2 | "the holder is in the run-status comment" — which comment is this? | Assumed:
the ADR-064 run-status comment (`scripts/lib/run-status-comment.sh`), not a new one.

```steps
- Amend plugins/claim-coordinator/github-labels/plugin.sh: change claim_coordinator_claim to use zbuild:claimed (single shared label, no machine suffix); change claim_coordinator_release to remove zbuild:claimed; add holder extraction from run-status comment on claim conflict; remove any back-reference source of core/claim/claim.sh (circular dependency; also eliminates the _ccgl_plugin_dir=$(cd ...) subshell) | areas: plugins/claim-coordinator/github-labels/plugin.sh
- Edit scripts/lib/run-status-render.sh: add <!-- zbuild-holder: CI_URL --> (CI) or <!-- zbuild-holder: run_id=X machine=H --> (local) in rsc_render_header after the run_id marker printf | areas: scripts/lib/run-status-render.sh
- Create core/claim/claim.sh: thin wiring bridge; source plugin.sh using $_ZBUILD_ROOT (not $(cd ...) subshell); zbuild_claim_build_holder uses ${HOSTNAME} bash variable (not external hostname); zbuild_claim_acquire calls _ccgl_read_labels/_ccgl_add_label/_ccgl_read_holder; zbuild_claim_release calls _ccgl_remove_label; graceful degradation (no issue, backend error) | areas: core/claim/claim.sh
- Register pipeline.refused.claimed in config/event-schema.json following the pattern of pipeline.refused.issue_locked | areas: config/event-schema.json
- Add core/claim/claim.sh to config/shape-change-paths.txt so future changes to the claim bridge trigger the shape floor | areas: config/shape-change-paths.txt
- Wire core/claim/claim.sh into runner.sh: source at top; call zbuild_claim_build_holder before sidecar spawn; call zbuild_claim_acquire after zbuild_issue_lock_acquire; emit event + print holder + return 1 on refusal; call zbuild_claim_release in _runner_abort_trap with declare -F guard | areas: core/pipeline/runner.sh
- Amend docs/adr/ADR-005-claim-coordinator.md: extend the existing ## Enforced by §1 bullet to add §1(c) enforcement: claim-coordinator-unit-test.sh [DSCLA-3] (refused: non-zero exit, no stage dispatched, event emitted) and teardown-repeat-signal-test.sh [DSCLA-9] (refused output names holder); add [DSCLA-12] to the §2 bullet alongside [DSCLA-2] for the CI holder rendering case | areas: docs/adr/ADR-005-claim-coordinator.md
- Amend docs/adr/ADR-059-issue-vs-run-keying.md: add an Enforced by entry for the §4 cross-machine exclusion statement — naming [DSCLA-3] (a run is refused when another machine holds zbuild:claimed on the issue) | areas: docs/adr/ADR-059-issue-vs-run-keying.md
```

```acceptance
DSCLA-1[code]: When an issue-bound run starts and zbuild:claimed is absent, the label is added before the first stage dispatches covers: RQCLA-1, RQLAB-1, RQLAB-2
  Given: a run is started with an issue number; zbuild:claimed is not on the issue
  When: the run starts
  Then: gh is called to add exactly the label zbuild:claimed to the issue (no hostname component in the label name)
  And: no stage has yet been dispatched
DSCLA-2[code]: When a local run starts with an issue, rsc_render_header embeds the holder in the run-status comment header covers: RQCLA-2
  Given: a local run (GITHUB_ACTIONS not true) starts with an issue number; the holder string is run_id=X machine=H
  When: rsc_render_header is called with the run id and holder string
  Then: the rendered header contains <!-- zbuild-holder: run_id=<id> machine=<hostname> -->
DSCLA-12[code]: When a CI run starts with an issue, the rendered run-status comment header contains the CI run URL as the holder covers: RQCLA-2
  Given: a CI run (GITHUB_ACTIONS=true) starts with an issue number
  When: rsc_render_header is called with the run id and the CI holder string
  Then: the rendered header contains <!-- zbuild-holder: <GITHUB_SERVER_URL>/<GITHUB_REPOSITORY>/actions/runs/<GITHUB_RUN_ID> -->
DSCLA-3[code]: When a run starts on a claimed issue, it refuses with non-zero exit before any stage covers: RQCLA-3, RQCLA-9
  Given: zbuild:claimed is already on the issue
  When: a run is started on that issue
  Then: the run exits non-zero
  And: no stage is dispatched
  And: pipeline.refused.claimed is emitted to the event bus
DSCLA-9[code]: When a run is refused because zbuild:claimed is on the issue, the run's output names the holder covers: RQCLA-4
  Given: zbuild:claimed is on the issue; the existing run-status comment contains a <!-- zbuild-holder: --> field with the holder string
  When: the run exits after finding zbuild:claimed on the issue
  Then: the run's stdout or stderr output contains the holder string from the <!-- zbuild-holder: --> field
DSCLA-5[code]: On normal pipeline completion, zbuild:claimed is removed from the issue covers: RQCLA-5
  Given: the claim was acquired at run start
  When: the pipeline completes normally
  Then: zbuild:claimed is absent from the issue
DSCLA-6[code]: On pipeline failure, zbuild:claimed is removed from the issue covers: RQCLA-6
  Given: the claim was acquired at run start
  When: the pipeline exits due to a stage failure
  Then: zbuild:claimed is absent from the issue
DSCLA-7[code]: On TERM signal, zbuild:claimed is removed from the issue covers: RQCLA-7
  Given: the claim was acquired at run start
  When: the runner process receives SIGTERM
  Then: zbuild:claimed is absent from the issue
DSCLA-8[code]: A run with no issue number makes no claim and calls no coordinator hook covers: RQCLA-8
  Given: the run is started with --goal and no --issue
  When: the run starts
  Then: zbuild_claim_acquire returns 0
  And: no gh label command is invoked
DSCLA-10[code]: pipeline.refused.claimed is an accepted event name that passes the schema coverage check covers: RQCLA-10
  Given: zbuild:claimed is on the issue
  When: the run is refused and emits pipeline.refused.claimed
  Then: the event-schema emitted-coverage check does not fail on pipeline.refused.claimed as an unregistered event
DSCLA-11[done]: The run-status comment shows terminal status when the runner exits on any path covers: RQCLA-5, RQCLA-6, RQCLA-7 evidence: scripts/lib/run-status-render.sh | rsc_finalize_body() {
  When: the runner exits on any path (normal, failure, or signal)
  Then: the run-status comment's status header is not "running"
REMOVED: DSCLA-4 — RQCLA-4 is fully covered by DSCLA-9, which tests the observable runner output; keeping a separate assertion that _ZBUILD_CLAIM_HOLDER is internally set tests the same interaction path with no additional observable coverage
DSADR-4[doc]: ADR-005 tells the reader that the engine calls the claim coordinator's claim hook after the admission lock and before the first stage, and release in the EXIT path covers: RQADR-1
DSADR-5[doc]: ADR-005 tells the reader that the shared claim label is zbuild:claimed (no hostname) and that the holder is identified in the run-status comment covers: RQADR-2
DSADR-6[doc]: ADR-005 corrects stale content: coordinator selection is not from config/zbuild.yaml, and the engine now has a built-in claim mechanism covers: RQADR-3
DSADR-7[doc]: ADR-005 has an ## Enforced by section with the §1 bullet extended to include §1(c)'s tests (claim-coordinator-unit-test.sh [DSCLA-3]: refused — non-zero exit, no stage, event emitted; teardown-repeat-signal-test.sh [DSCLA-9]: refused output names holder), and the §2 bullet extended to include [DSCLA-12] for the CI holder rendering case covers: RQADR-4
DSADR-8[doc]: ADR-059 §4 tells the reader that cross-machine exclusion is the claim coordinator's job and the admission lock (flock) handles intra-machine serialisation; the amendment's Enforced by entry names DSCLA-3 as the test that enforces the cross-machine exclusion statement covers: RQADR-5
WIRING: core/pipeline/runner.sh
```

```supersedes
plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh [DSCLA-2]: assertion "gh issue comment was called" and "comment contains run_id/machine name" — holder is now in the run-status comment via <!-- zbuild-holder: -->, not a separate claim comment posted by zbuild_claim_acquire
plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh [DSCLA-4]: assertion "_ZBUILD_CLAIM_HOLDER contains holder string from claim comment" — holder is now extracted from the run-status comment's <!-- zbuild-holder: --> field, not a separate claim comment
tests/integration/teardown-repeat-signal-test.sh [DSCLA-5]: assertion "claim comment body shows finished status after normal exit" checks comment.txt — no separate claim comment in the new design; the progress comment is the run-status comment, finalized by the existing sidecar (DSCLA-11)
tests/integration/teardown-repeat-signal-test.sh [DSCLA-6]: assertion "claim comment body shows finished status after failure exit" is obsolete for the same reason
tests/integration/teardown-repeat-signal-test.sh [DSCLA-7]: assertion "claim comment body shows finished status after TERM signal" is obsolete for the same reason
tests/integration/teardown-repeat-signal-test.sh [DSCLA-9]: pre-seeds ZBUILD_CLAIM_STORE/$issue/holder.txt with the holder string — now the holder must be in a mock run-status comment with <!-- zbuild-holder: --> field for the claim function to read
```
