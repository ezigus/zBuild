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
  `claimed:<machine>`. Delete the `local our_label="claimed:${machine}"` line and all per-machine
  label logic from both `claim_coordinator_claim` and `claim_coordinator_release`; replace with
  `local label="zbuild:claimed"`. The simplified check: if `zbuild:claimed` is absent, add it;
  if present, search the issue's comments for the most recent run-status comment and extract the
  `<!-- zbuild-holder: -->` line into a returned holder string.
- Change `claim_coordinator_release` to remove `zbuild:claimed` (no machine suffix).
- The `_ccgl_*` backend helpers remain and are used by the amended public functions.
- `plugin.sh` MUST NOT contain any `source` of `core/claim/claim.sh` — that creates a circular
  dependency (`claim.sh` sources `plugin.sh`; a reverse source closes the loop) and adds a
  startup `$(cd ...)` subshell on plugin.sh's load path. The dependency arrow is one-way:
  `claim.sh` sources `plugin.sh`.

**Update `plugins/claim-coordinator/github-labels/README.md`**: remove all references to
`claimed:<machine>` labels; describe the single shared label `zbuild:claimed`; update the
`ZBUILD_CLAIM_MACHINE_ID` env-var row to note it is now used only for the holder string in the
run-status comment, not in the label name.

**New `core/claim/claim.sh`** (thin wiring bridge — no reimplemented logic):
- Sources `plugins/claim-coordinator/github-labels/plugin.sh` using `$_ZBUILD_ROOT` (already
  set by runner.sh before claim.sh is sourced) — not via a `$(cd ...)` subshell.
- `zbuild_claim_build_holder`: builds and exports `_ZBUILD_CLAIM_HOLDER`; uses `${HOSTNAME}`
  (bash built-in variable) for the machine name — never calls the external `hostname` command.
- `zbuild_claim_acquire <issue>`: skip if issue is empty; calls `_ccgl_read_labels` / `_ccgl_add_label`
  / `_ccgl_read_holder` from the loaded plugin; on conflict, sanitizes the extracted holder string
  (strip ANSI escape codes and literal backslash sequences via `printf '%s'` or `sed`) before
  storing in `_ZBUILD_CLAIM_HOLDER`, then returns 1; on success, sets `_ZBUILD_CLAIM_ACQUIRED`
  and returns 0. Backend errors (read or add failures) return 0 (graceful) and log a warning to
  stderr so the skip is visible in the run's output.
- `zbuild_claim_release <issue>`: skip if issue is empty or `_ZBUILD_CLAIM_ACQUIRED` is unset;
  MUST call `unset _ZBUILD_CLAIM_ACQUIRED` BEFORE calling `_ccgl_remove_label` (advisory).
  Unsetting first makes a second call a no-op — this is the idempotency guarantee DSCLA-13
  relies on.

**Wire into `core/pipeline/runner.sh`**: source `core/claim/claim.sh` at top (alongside
`core/state/issue-lock.sh`); call `zbuild_claim_build_holder` before the sidecar spawn so the
sidecar inherits `_ZBUILD_CLAIM_HOLDER`; call `zbuild_claim_acquire` right after
`zbuild_issue_lock_acquire` succeeds; on return 1, emit `pipeline.refused.claimed`, print holder
using `printf '%s\n'` (not `error()`, which uses `echo -e` and would interpret escape sequences
in an attacker-controlled holder string), then return 1 (same shape as issue-lock refusal); call
`zbuild_claim_release` in `_runner_abort_trap` after `zbuild_issue_lock_release`, using `declare
-F` guard. The call is placed AFTER the `trap '' INT TERM` guard already at the top of
`_runner_abort_trap`, which blocks SIGTERM re-entry for the duration of cleanup — this is what
RQCLA-11 relies on. `zbuild_claim_release` also unsets `_ZBUILD_CLAIM_ACQUIRED` on first call,
so a second invocation from any path is a no-op.

The EXIT trap is installed well after `zbuild_claim_acquire` succeeds; two early-failure return
paths between them (`_runner_enter_worktree` failure and `zbuild_run_branch_setup` failure)
currently call only `zbuild_run_cap_release || true` before returning. Both paths MUST also call
`zbuild_claim_release || true` and `zbuild_issue_lock_release || true`, mirroring the
`zbuild_run_cap_release || true` pattern already in those paths.

**Register `pipeline.refused.claimed`** in `config/event-schema.json` (follows pattern of
`pipeline.refused.issue_locked`).

**Register `core/claim/claim.sh`** in `config/shape-change-paths.txt`.

**Amend ADR-005** per RQADR-1 through RQADR-4. The existing §1 Enforced by bullet lists
DSCLA-1,5,6,7 but omits §1(c) — refused behavior. Extend it to add:
- `claim-coordinator-unit-test.sh [DSCLA-3]` (non-zero exit, no stage dispatched, event emitted)
- `teardown-repeat-signal-test.sh [DSCLA-9]` (refused output names holder)

The §2 Enforced by bullet also needs `[DSCLA-12]` added alongside `[DSCLA-2]` for the CI
holder rendering case.

**Amend ADR-059 §4** noting cross-machine exclusion is the coordinator's job per RQADR-5. The
`## Enforced by` section must gain a new entry for the §4 cross-machine statement, naming
DSCLA-3 as the enforcing test. CLAUDE.md requires a test per new/changed statement.

The label `zbuild:claimed` contains no hostname. Holder string contains machine name (local) or
CI URL — in the comment body, not the label (RQLAB-2). Check-then-label is not atomic at GitHub;
two racing machines may both succeed. Known limitation; a strict mutex is out of scope (RQMECH-1,
RQMECH-2).

Startup process budget: `source` builtins (no forks); `${HOSTNAME}` bash built-in (no fork);
no `$(cd ...)` subshells on the load path. Net startup-process cost: 0.

UNCLEAR: RQADR-2 | "the holder is in the run-status comment" — which comment is this? | Assumed:
the ADR-064 run-status comment (`scripts/lib/run-status-comment.sh`), not a new one.

```steps
- Amend plugins/claim-coordinator/github-labels/plugin.sh: in claim_coordinator_claim, delete the `local our_label="claimed:${machine}"` line and all per-machine label logic; replace with `local label="zbuild:claimed"` and use it throughout; do the same in claim_coordinator_release; add holder extraction from run-status comment on claim conflict; ensure NO `source` of core/claim/claim.sh appears anywhere in plugin.sh (the dependency arrow is claim.sh→plugin.sh, not the reverse; a reverse source creates a circular load) | areas: plugins/claim-coordinator/github-labels/plugin.sh
- Update plugins/claim-coordinator/github-labels/README.md: remove all references to claimed:<machine>; describe the single shared label zbuild:claimed; update ZBUILD_CLAIM_MACHINE_ID row to note it now affects only the holder string in the run-status comment, not the label name | areas: plugins/claim-coordinator/github-labels/README.md
- Edit scripts/lib/run-status-render.sh: add <!-- zbuild-holder: CI_URL --> (CI) or <!-- zbuild-holder: run_id=X machine=H --> (local) in rsc_render_header after the run_id marker printf | areas: scripts/lib/run-status-render.sh
- Create core/claim/claim.sh: thin wiring bridge; source plugin.sh using $_ZBUILD_ROOT (not $(cd ...) subshell); zbuild_claim_build_holder uses ${HOSTNAME} bash variable (not external hostname); zbuild_claim_acquire calls _ccgl_read_labels/_ccgl_add_label/_ccgl_read_holder; zbuild_claim_acquire sanitizes the holder string from _ccgl_read_holder (strip ANSI codes and backslash sequences via printf '%s') before storing in _ZBUILD_CLAIM_HOLDER; zbuild_claim_acquire logs a stderr warning when graceful-degrading on backend error; zbuild_claim_release MUST call `unset _ZBUILD_CLAIM_ACQUIRED` BEFORE `_ccgl_remove_label` (makes second call a no-op — required for DSCLA-13) | areas: core/claim/claim.sh
- Register pipeline.refused.claimed in config/event-schema.json following the pattern of pipeline.refused.issue_locked | areas: config/event-schema.json
- Add core/claim/claim.sh to config/shape-change-paths.txt so future changes to the claim bridge trigger the shape floor | areas: config/shape-change-paths.txt
- Wire core/claim/claim.sh into runner.sh: source at top; call zbuild_claim_build_holder before sidecar spawn; call zbuild_claim_acquire after zbuild_issue_lock_acquire; on refusal emit event + print holder via `printf '%s\n' "$holder"` (not error(), which uses echo -e and would interpret backslash sequences in an attacker-controlled holder) + return 1; call zbuild_claim_release in _runner_abort_trap with declare -F guard, placed AFTER the trap '' INT TERM guard; in both early-failure return paths after zbuild_claim_acquire succeeds but before the EXIT trap is installed (_runner_enter_worktree failure and zbuild_run_branch_setup failure), add `zbuild_claim_release || true` and `zbuild_issue_lock_release || true` before returning, alongside the existing `zbuild_run_cap_release || true` | areas: core/pipeline/runner.sh
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
DSCLA-8[code]: When zbuild_claim_acquire is called with an empty issue argument, it returns 0 and invokes no gh label command covers: RQCLA-8
  Given: core/claim/claim.sh is loaded
  When: zbuild_claim_acquire is called with an empty string as the issue argument
  Then: the function returns 0
  And: no gh label command is invoked
DSCLA-17[code]: When zbuild_claim_release is called without a prior successful acquire, it invokes no gh label command covers: RQCLA-8
  Given: core/claim/claim.sh is loaded; _ZBUILD_CLAIM_ACQUIRED is not set
  When: zbuild_claim_release is called
  Then: no gh label command is invoked
DSCLA-10[code]: When the event-schema emitted-coverage check runs, it accepts pipeline.refused.claimed as a registered event covers: RQCLA-10
  Given: config/event-schema.json includes an entry for pipeline.refused.claimed
  When: the event-schema emitted-coverage check runs against the codebase
  Then: the check exits without reporting pipeline.refused.claimed as an unregistered event name
DSCLA-11[done]: The run-status comment shows terminal status when the runner exits on any path covers: RQCLA-5, RQCLA-6, RQCLA-7 evidence: scripts/lib/run-status-render.sh | rsc_finalize_body() {
  When: the runner exits on any path (normal, failure, or signal)
  Then: the run-status comment's status header is not "running"
DSCLA-15[code]: The holder string is printed without interpreting escape sequences in the run's refusal output covers: RQCLA-4
  Given: the holder string extracted from the GitHub run-status comment contains a backslash sequence such as \n or an ANSI escape code
  When: the run prints the holder on refusal
  Then: the run's stdout or stderr output contains the literal backslash sequence, not its interpreted form
DSCLA-16[code]: When claim acquisition succeeds but runner infrastructure setup fails before the EXIT trap is installed, zbuild:claimed is removed before the runner function returns covers: RQCLA-6
  Given: zbuild_claim_acquire succeeds (zbuild:claimed is added to the issue); the subsequent _runner_enter_worktree or zbuild_run_branch_setup call fails before the EXIT trap is installed
  When: the runner returns from that failure path
  Then: zbuild_claim_release is called and zbuild:claimed is absent from the issue after the return
DSCLA-13[code]: When a second SIGTERM arrives during the runner's claim release, zbuild:claimed is still removed covers: RQCLA-11
  Given: the claim was acquired at run start; the runner has entered _runner_abort_trap and blocked SIGTERM via trap '' TERM
  When: a second SIGTERM arrives while zbuild_claim_release is executing inside _runner_abort_trap
  Then: zbuild:claimed is absent from the issue after the runner exits
DSCLA-18[code]: When ZBUILD_TEST_CHANGED_FILES contains core/claim/claim.sh, the targeted test set includes every shape test covers: RQCLA-1
  Given: config/shape-change-paths.txt lists core/claim/claim.sh
  When: _test_compute_target_files is called with ZBUILD_TEST_CHANGED_FILES set to core/claim/claim.sh
  Then: each file listed in config/shape-tests.txt appears in the targeted set
REMOVED: DSCLA-4 — RQCLA-4 is fully covered by DSCLA-9, which tests the observable runner output; keeping a separate assertion that _ZBUILD_CLAIM_HOLDER is internally set tests the same interaction path with no additional observable coverage
DSADR-4[doc]: ADR-005 tells the reader that the engine calls the claim coordinator's claim hook after the admission lock and before the first stage, and release in the EXIT path covers: RQADR-1
DSADR-5[doc]: ADR-005 tells the reader that the shared claim label is zbuild:claimed (no hostname) and that the holder is identified in the run-status comment covers: RQADR-2
DSADR-6[doc]: ADR-005 corrects stale content: coordinator selection is not from config/zbuild.yaml, and the engine now has a built-in claim mechanism covers: RQADR-3
DSADR-7[doc]: ADR-005 has an ## Enforced by section with the §1 bullet extended to include §1(c)'s tests (claim-coordinator-unit-test.sh [DSCLA-3]: refused — non-zero exit, no stage, event emitted; teardown-repeat-signal-test.sh [DSCLA-9]: refused output names holder), and the §2 bullet extended to include [DSCLA-12] for the CI holder rendering case covers: RQADR-4
DSADR-8[doc]: ADR-059 §4 tells the reader that cross-machine exclusion is the claim coordinator's job and the admission lock (flock) handles intra-machine serialisation; the amendment's Enforced by entry names DSCLA-3 as the test that enforces the cross-machine exclusion statement covers: RQADR-5
DSCLA-14[doc]: README.md in plugins/claim-coordinator/github-labels/ tells the reader the shared claim label is zbuild:claimed (not claimed:<machine>) and does not reference machine-suffixed labels covers: RQDOC-1
WIRING: core/pipeline/runner.sh
```

