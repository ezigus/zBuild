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

The base code's `claim_coordinator_claim` uses `claimed:<machine>` as the label. This change
replaces that with the single shared label `zbuild:claimed`. The engine calls the coordinator's
public hooks (`claim_coordinator_claim`, `claim_coordinator_release`) through a thin bridge
(`core/claim/claim.sh`). The bridge sources `plugin.sh`; `plugin.sh` must NOT source `claim.sh`
— the dependency arrow is one-way: `runner.sh` → `claim.sh` → `plugin.sh`.

## Decision

**`plugins/claim-coordinator/github-labels/plugin.sh`**: replace `claimed:<machine>` with the
shared label `zbuild:claimed` in both `claim_coordinator_claim` and `claim_coordinator_release`;
add `_ccgl_read_holder` to read the holder from the issue's run-status comment; on conflict,
`claim_coordinator_claim` returns `{"acquired": false, "holder": "<extracted_holder>"}`;
remove the `source` of `core/claim/claim.sh` currently at the bottom of `plugin.sh`.

**`scripts/lib/run-status-render.sh`**: add `<!-- zbuild-holder: ... -->` in `rsc_render_header`
immediately after the run-id marker: CI path uses `<!-- zbuild-holder: <CI_URL> -->`; local
path uses `<!-- zbuild-holder: run_id=<id> machine=<host> -->`.

**`core/claim/claim.sh`** (new thin bridge): sources `plugin.sh` via `$_ZBUILD_ROOT`; exports
`_ZBUILD_CLAIM_HOLDER` via `zbuild_claim_build_holder` (uses `${HOSTNAME}` bash variable, no fork);
`zbuild_claim_acquire` calls `claim_coordinator_claim` and parses its JSON output; on
`acquired: false` sanitizes and stores the holder string, returns 1; on backend error returns 0
with a stderr warning; `zbuild_claim_release` unsets `_ZBUILD_CLAIM_ACQUIRED` before calling
`claim_coordinator_release` (makes second call a no-op); no direct `gh` calls anywhere in
`core/claim/claim.sh`.

**`core/pipeline/runner.sh`**: source `core/claim/claim.sh` at top; call `zbuild_claim_build_holder`
before sidecar spawn; call `zbuild_claim_acquire` after `zbuild_issue_lock_acquire`; on refusal
emit `pipeline.refused.claimed`, print holder via `printf '%s\n'` (not `error()` to avoid
interpreting backslash sequences), return 1; call `zbuild_claim_release` in `_runner_abort_trap`
after the `trap '' INT TERM` guard; add `zbuild_claim_release || true` to both early-failure
return paths that currently have only `zbuild_run_cap_release || true`.

**`config/event-schema.json`**: register `pipeline.refused.claimed` following the pattern of
`pipeline.refused.issue_locked`.

**ADR-005**: amend for RQADR-1 through RQADR-4; extend the `## Enforced by` section.

**ADR-059 §4**: note that cross-machine exclusion is the coordinator's job; add `[DSCLA-3]` to
the `## Enforced by` entry for the §4 cross-machine statement.

The label `zbuild:claimed` contains no hostname (RQLAB-2). Check-then-label is not atomic at
GitHub; two racing machines may both succeed. Known limitation; strict mutex is out of scope
(RQMECH-1, RQMECH-2).

UNCLEAR: RQADR-2 | "the holder is in the run-status comment" — which comment is this? | Assumed:
the ADR-064 run-status comment (`scripts/lib/run-status-comment.sh`), not a new one.

```steps
- Amend plugins/claim-coordinator/github-labels/plugin.sh: replace `claimed:<machine>` with `zbuild:claimed` in claim_coordinator_claim (remove local our_label and machine logic) and in claim_coordinator_release; add _ccgl_read_holder to extract the holder from the issue's run-status comment; claim_coordinator_claim returns {"acquired": false, "holder": "<holder>"} on conflict; remove the source of core/claim/claim.sh from plugin.sh (the dependency arrow is claim.sh→plugin.sh, not the reverse) | areas: plugins/claim-coordinator/github-labels/plugin.sh
- Update plugins/claim-coordinator/github-labels/README.md: remove all references to claimed:<machine>; describe the single shared label zbuild:claimed; update ZBUILD_CLAIM_MACHINE_ID row to note it now affects only the holder string in the run-status comment, not the label name | areas: plugins/claim-coordinator/github-labels/README.md
- Edit scripts/lib/run-status-render.sh: add <!-- zbuild-holder: CI_URL --> (CI) or <!-- zbuild-holder: run_id=X machine=H --> (local) in rsc_render_header after the run_id marker | areas: scripts/lib/run-status-render.sh
- Create core/claim/claim.sh: thin wiring bridge; source plugin.sh via $_ZBUILD_ROOT (not $(cd ...) subshell); zbuild_claim_build_holder uses ${HOSTNAME} bash variable (no fork); zbuild_claim_acquire calls claim_coordinator_claim and parses its JSON output; on acquired:false sanitizes the holder field (strip ANSI codes and backslash sequences) and stores in _ZBUILD_CLAIM_HOLDER, returns 1; on backend error returns 0 with stderr warning; zbuild_claim_release unsets _ZBUILD_CLAIM_ACQUIRED before calling claim_coordinator_release (makes second call a no-op); core/claim/claim.sh must contain no direct gh calls | areas: core/claim/claim.sh
- Register pipeline.refused.claimed in config/event-schema.json following the pattern of pipeline.refused.issue_locked | areas: config/event-schema.json
- Wire core/claim/claim.sh into runner.sh: source at top; call zbuild_claim_build_holder before sidecar spawn; call zbuild_claim_acquire after zbuild_issue_lock_acquire; on refusal emit event + print holder via printf '%s\n' (not error() which uses echo -e) + return 1; call zbuild_claim_release in _runner_abort_trap with declare -F guard after the trap '' INT TERM guard; add zbuild_claim_release || true to both early-failure return paths that currently have only zbuild_run_cap_release || true | areas: core/pipeline/runner.sh
- Amend docs/adr/ADR-005-claim-coordinator.md: add §1(c) enforcement to Enforced by: claim-coordinator-unit-test.sh [DSCLA-3] (refused — non-zero exit, no stage, event emitted) and teardown-repeat-signal-test.sh [DSCLA-9] (refused output names holder); add [DSCLA-12] to the §2 bullet for CI holder rendering | areas: docs/adr/ADR-005-claim-coordinator.md
- Amend docs/adr/ADR-059-issue-vs-run-keying.md: add Enforced by entry for the §4 cross-machine exclusion statement naming [DSCLA-3] | areas: docs/adr/ADR-059-issue-vs-run-keying.md
```

```acceptance
DSCLA-1[code]: When an issue-bound run starts and zbuild:claimed is absent, the label is added before the first stage dispatches covers: RQCLA-1, RQLAB-1, RQLAB-2, RQCLA-12
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
DSCLA-18[code]: When claim_coordinator_claim is called on an issue with no zbuild:claimed label, it adds the label zbuild:claimed via gh issue edit covers: RQCLA-12, RQARC-1
  Given: plugins/claim-coordinator/github-labels/plugin.sh is loaded; the issue has no zbuild:claimed label
  When: claim_coordinator_claim is called with the issue number
  Then: gh issue edit is called to add the label zbuild:claimed to the issue
  And: the label added has no hostname component
DSCLA-20[code]: When claim_coordinator_release is called on an issue, it removes the label zbuild:claimed via gh issue edit covers: RQCLA-13, RQARC-1
  Given: plugins/claim-coordinator/github-labels/plugin.sh is loaded; the issue has the zbuild:claimed label
  When: claim_coordinator_release is called with the issue number
  Then: gh issue edit is called to remove the label zbuild:claimed from the issue
DSCLA-19[code]: When zbuild_claim_acquire is called with an issue number, it delegates to claim_coordinator_claim and contains no direct gh calls covers: RQARC-2
  Given: core/claim/claim.sh is loaded; claim_coordinator_claim is stubbed to return acquired:true
  When: zbuild_claim_acquire is called with an issue number
  Then: claim_coordinator_claim is called with the issue number
  And: gh is not invoked directly within zbuild_claim_acquire
DSCLA-21[code]: When zbuild_claim_release is called after a prior successful acquire, it delegates to claim_coordinator_release and contains no direct gh calls covers: RQARC-2
  Given: core/claim/claim.sh is loaded; _ZBUILD_CLAIM_ACQUIRED is set; claim_coordinator_release is stubbed
  When: zbuild_claim_release is called with the issue number
  Then: claim_coordinator_release is called with the issue number
  And: gh is not invoked directly within zbuild_claim_release
DSADR-4[doc]: ADR-005 tells the reader that the engine calls the claim coordinator's claim hook after the admission lock and before the first stage, and release in the EXIT path covers: RQADR-1
DSADR-5[doc]: ADR-005 tells the reader that the shared claim label is zbuild:claimed (no hostname) and that the holder is identified in the run-status comment covers: RQADR-2
DSADR-6[doc]: ADR-005 corrects stale content: coordinator selection is not from config/zbuild.yaml, and the engine now has a built-in claim mechanism covers: RQADR-3
DSADR-7[doc]: ADR-005 has an ## Enforced by section with the §1 bullet extended to include §1(c)'s tests (claim-coordinator-unit-test.sh [DSCLA-3]: refused — non-zero exit, no stage, event emitted; teardown-repeat-signal-test.sh [DSCLA-9]: refused output names holder), and the §2 bullet extended to include [DSCLA-12] for the CI holder rendering case covers: RQADR-4
DSADR-8[doc]: ADR-059 §4 tells the reader that cross-machine exclusion is the claim coordinator's job and the admission lock (flock) handles intra-machine serialisation; the amendment's Enforced by entry names DSCLA-3 as the test that enforces the cross-machine exclusion statement covers: RQADR-5
DSCLA-14[doc]: README.md in plugins/claim-coordinator/github-labels/ tells the reader the shared claim label is zbuild:claimed (not claimed:<machine>) and does not reference machine-suffixed labels covers: RQDOC-1
REMOVED: DSCLA-4 — RQCLA-4 is fully covered by DSCLA-9, which tests the observable runner output; keeping a separate assertion that _ZBUILD_CLAIM_HOLDER is internally set tests the same interaction path with no additional observable coverage
WIRING: core/pipeline/runner.sh
```
