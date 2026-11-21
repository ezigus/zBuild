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
replaces that with the single shared label `zbuild:claimed`. RQARC-3 and RQCLA-14 require the
engine to call the coordinator's hooks through the plugin registry (via `plugin_hook_call`), so
that a test can substitute a stub coordinator through the discovery mechanism.

## Decision

**`plugins/claim-coordinator/github-labels/plugin.sh`**: replace `claimed:<machine>` with the
shared label `zbuild:claimed` in both `claim_coordinator_claim` and `claim_coordinator_release`;
add `_ccgl_read_holder` to read the holder from the issue's run-status comment; on conflict,
`claim_coordinator_claim` returns `{"acquired": false, "holder": "<extracted_holder>"}`;
remove any `source` of `core/claim/claim.sh` from `plugin.sh` — the dependency arrow is
one-way (`claim.sh` → (registry) → `plugin.sh`).

**`scripts/lib/run-status-render.sh`**: add `<!-- zbuild-holder: ... -->` in `rsc_render_header`
immediately after the run-id marker: CI path uses `<!-- zbuild-holder: <CI_URL> -->`; local
path uses `<!-- zbuild-holder: run_id=<id> machine=<host> -->`.

**`core/claim/claim.sh`** (new wiring bridge via plugin registry): sources
`core/plugin-registry/registry.sh` via `$_ZBUILD_ROOT` at top (idempotent — `runner.sh`
sources `claim.sh` at line 33, before `registry.sh` at line 46, so `claim.sh` must load it);
`zbuild_claim_build_holder` builds and exports `_ZBUILD_CLAIM_HOLDER` using `${HOSTNAME}` bash
variable (no fork); `zbuild_claim_acquire <issue>`: skip if issue is empty — returns 0
immediately without calling `discover_plugins` or any coordinator hook; calls
`discover_plugins "${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_ROOT/plugins}"` and filters for the first
plugin with `kind: claim-coordinator` to obtain `coordinator_dir`, stored in
`_ZBUILD_COORDINATOR_DIR`; calls `plugin_hook_call "$coordinator_dir" claim "$issue"` with
stdout captured; parses the JSON for `acquired`/`holder`; on `acquired: false` sanitizes the
holder string (strip ANSI escape codes via `sed`) and stores in `_ZBUILD_CLAIM_HOLDER`, returns
1; on backend error (no coordinator found, or non-zero hook exit) returns 0 with a stderr
warning (graceful degradation — the intra-machine flock still serialises); on success sets
`_ZBUILD_CLAIM_ACQUIRED`; `zbuild_claim_release <issue>`: skip if `_ZBUILD_CLAIM_ACQUIRED` is
unset — returns 0 immediately without calling any coordinator hook; MUST call
`unset _ZBUILD_CLAIM_ACQUIRED` BEFORE calling
`plugin_hook_call "$_ZBUILD_COORDINATOR_DIR" release "$issue"` (makes second call a no-op —
this is the idempotency RQCLA-11 relies on); no direct `gh` calls anywhere in
`core/claim/claim.sh`.

For non-`run` hooks `plugin_hook_call` goes straight to `_plugin_hook_call_once` (no retry
loop, no output scan). The hook runs in a background subshell that is immediately waited on;
its JSON stdout flows through to `plugin_hook_call`'s stdout and is captured by the outer
`$( )`.

**`core/pipeline/runner.sh`**: source `core/claim/claim.sh` at top (already in place); call
`zbuild_claim_build_holder` before sidecar spawn; call `zbuild_claim_acquire` after
`zbuild_issue_lock_acquire`; on refusal emit `pipeline.refused.claimed`, print holder via
`printf '%s\n'` (not `error()` which uses `echo -e` and would interpret backslash sequences in
an attacker-controlled holder string), return 1; call `zbuild_claim_release` in
`_runner_abort_trap` after the `trap '' INT TERM` guard, with a `declare -F` guard; add
`zbuild_claim_release || true` to both early-failure return paths that currently have only
`zbuild_run_cap_release || true`.

**`config/event-schema.json`**: register `pipeline.refused.claimed` following the pattern of
`pipeline.refused.issue_locked`.

**ADR-005**: amend for RQADR-1 through RQADR-4; extend the `## Enforced by` section.

**ADR-059 §4**: note that cross-machine exclusion is the coordinator's job; add `[DSCLA-3]` to
the `## Enforced by` entry for the §4 cross-machine statement.

The label `zbuild:claimed` contains no hostname (RQLAB-2). Check-then-label is not atomic at
GitHub; two racing machines may both succeed. Known limitation; strict mutex is out of scope
(RQMECH-1, RQMECH-2).

UNCLEAR RQADR-2 | "the holder is in the run-status comment" | (1) the existing ADR-064 run-status comment (scripts/lib/run-status-comment.sh); (2) a new comment created specifically for the claim | ASSUMED: the ADR-064 run-status comment (scripts/lib/run-status-comment.sh), not a new one

```steps
- Amend plugins/claim-coordinator/github-labels/plugin.sh: replace `claimed:<machine>` with `zbuild:claimed` in claim_coordinator_claim (remove local our_label and machine logic) and in claim_coordinator_release; add _ccgl_read_holder to extract the holder from the issue's run-status comment; claim_coordinator_claim returns {"acquired": false, "holder": "<holder>"} on conflict; remove any source of core/claim/claim.sh from plugin.sh (the dependency arrow is claim.sh→registry→plugin.sh, not the reverse) | areas: plugins/claim-coordinator/github-labels/plugin.sh
- Update plugins/claim-coordinator/github-labels/README.md: remove all references to claimed:<machine>; describe the single shared label zbuild:claimed; update ZBUILD_CLAIM_MACHINE_ID row to note it now affects only the holder string in the run-status comment, not the label name | areas: plugins/claim-coordinator/github-labels/README.md
- Edit scripts/lib/run-status-render.sh: add <!-- zbuild-holder: CI_URL --> (CI) or <!-- zbuild-holder: run_id=X machine=H --> (local) in rsc_render_header after the run_id marker | areas: scripts/lib/run-status-render.sh
- Create core/claim/claim.sh: wiring bridge that calls claim-coordinator hooks through the plugin registry; sources core/plugin-registry/registry.sh via $_ZBUILD_ROOT at top (idempotent — registry.sh has a guard; needed because runner.sh sources claim.sh before registry.sh); zbuild_claim_build_holder uses ${HOSTNAME} bash variable (no fork); zbuild_claim_acquire returns 0 immediately without calling discover_plugins or any coordinator hook when issue is empty; zbuild_claim_acquire uses discover_plugins filtered by kind claim-coordinator to find coordinator_dir, stores it in _ZBUILD_COORDINATOR_DIR; calls plugin_hook_call "$coordinator_dir" claim "$issue" with stdout captured to get JSON; on acquired:false sanitizes holder string (strip ANSI codes via sed) and stores in _ZBUILD_CLAIM_HOLDER, returns 1; on backend error (no coordinator found or non-zero hook exit) warns stderr and returns 0 (graceful degradation); on success sets _ZBUILD_CLAIM_ACQUIRED; zbuild_claim_release returns 0 immediately without calling any coordinator hook when _ZBUILD_CLAIM_ACQUIRED is unset; zbuild_claim_release MUST unset _ZBUILD_CLAIM_ACQUIRED BEFORE calling plugin_hook_call "$_ZBUILD_COORDINATOR_DIR" release "$issue" (makes second call a no-op for DSCLA-13); no direct source of plugin.sh, no _ccgl_* calls, no direct gh calls | areas: core/claim/claim.sh
- Register pipeline.refused.claimed in config/event-schema.json following the pattern of pipeline.refused.issue_locked | areas: config/event-schema.json
- Wire core/claim/claim.sh into runner.sh: source at top (already in working copy); call zbuild_claim_build_holder before sidecar spawn; call zbuild_claim_acquire after zbuild_issue_lock_acquire; on refusal emit event + print holder via printf '%s\n' (not error() which uses echo -e) + return 1; call zbuild_claim_release in _runner_abort_trap with declare -F guard, placed AFTER the trap '' INT TERM guard; in both early-failure return paths after zbuild_claim_acquire succeeds but before the EXIT trap is installed, add zbuild_claim_release || true alongside the existing zbuild_run_cap_release || true | areas: core/pipeline/runner.sh
- Amend docs/adr/ADR-005-claim-coordinator.md: in the ## Enforced by section, extend the §1 bullet to add: §1(a) enforcement claim-coordinator-unit-test.sh [DSCLA-22] (claim hook called after admission lock and before first stage; release hook called in EXIT path); §1(c) enforcement claim-coordinator-unit-test.sh [DSCLA-3] (refused: non-zero exit, no stage dispatched, event emitted) and claim-coordinator-unit-test.sh [DSCLA-9] (refused output names holder); add [DSCLA-12] to the §2 bullet alongside [DSCLA-2] for the CI holder rendering case | areas: docs/adr/ADR-005-claim-coordinator.md
- Amend docs/adr/ADR-059-issue-vs-run-keying.md: add an Enforced by entry for the §4 cross-machine exclusion statement — naming [DSCLA-3] (a run is refused when another machine holds zbuild:claimed on the issue) | areas: docs/adr/ADR-059-issue-vs-run-keying.md
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
DSCLA-8[code]: When zbuild_claim_acquire is called with an empty issue argument, it returns 0 without calling the coordinator's claim hook covers: RQCLA-8
  Given: core/claim/claim.sh is loaded
  When: zbuild_claim_acquire is called with an empty string as the issue argument
  Then: the function returns 0
  And: the coordinator's claim hook is not called
DSCLA-17[code]: When zbuild_claim_release is called without a prior successful acquire, it returns 0 without calling the coordinator's release hook covers: RQCLA-8
  Given: core/claim/claim.sh is loaded; _ZBUILD_CLAIM_ACQUIRED is not set
  When: zbuild_claim_release is called
  Then: the coordinator's release hook is not called
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
DSCLA-19[code]: When zbuild_claim_acquire is called with an issue number, it delegates to the claim-coordinator plugin's claim hook and contains no direct gh calls covers: RQARC-2
  Given: core/claim/claim.sh is loaded; a claim-coordinator plugin is registered in the discovery tree; that plugin's claim hook returns {"acquired": true} on stdout
  When: zbuild_claim_acquire is called with an issue number
  Then: the claim-coordinator plugin's claim hook function is called with the issue number
  And: gh is not invoked directly within zbuild_claim_acquire
DSCLA-21[code]: When zbuild_claim_release is called after a prior successful acquire, it delegates to the claim-coordinator plugin's release hook and contains no direct gh calls covers: RQARC-2
  Given: core/claim/claim.sh is loaded; _ZBUILD_CLAIM_ACQUIRED is set
  When: zbuild_claim_release is called with the issue number
  Then: the claim-coordinator plugin's release hook function is called with the issue number
  And: gh is not invoked directly within zbuild_claim_release
DSCLA-22[code]: When a stub claim coordinator is registered in the plugin discovery tree and an issue-bound run executes, the stub's claim hook is called before the first stage and its release hook is called on exit covers: RQCLA-14, RQARC-3
  Given: a stub claim-coordinator plugin is present in the ZBUILD_PLUGINS_ROOT discovery tree; a run starts with an issue number
  When: the run executes and exits normally
  Then: the stub's claim hook is called before the first stage is dispatched
  And: the stub's release hook is called on exit
DSADR-4[doc]: ADR-005 tells the reader that the engine calls the claim coordinator's claim hook after the admission lock and before the first stage, and release in the EXIT path covers: RQADR-1
DSADR-5[doc]: ADR-005 tells the reader that the shared claim label is zbuild:claimed (no hostname) and that the holder is identified in the run-status comment covers: RQADR-2
DSADR-6[doc]: ADR-005 corrects stale content: coordinator selection is not from config/zbuild.yaml, and the engine now has a built-in claim mechanism covers: RQADR-3
DSADR-7[doc]: ADR-005 has an ## Enforced by section with the §1 bullet naming a test for each §1 statement: §1(a) claim hook called after admission lock and before first stage — claim-coordinator-unit-test.sh [DSCLA-22]; §1(b) release hook called in the EXIT path — claim-coordinator-unit-test.sh [DSCLA-22]; §1(c) refused run exits non-zero with no stage and event emitted — claim-coordinator-unit-test.sh [DSCLA-3]; §1(c) refused output names holder — claim-coordinator-unit-test.sh [DSCLA-9]; and the §2 bullet naming [DSCLA-2] and [DSCLA-12] for the holder rendering cases covers: RQADR-4
DSADR-8[doc]: ADR-059 §4 tells the reader that cross-machine exclusion is the claim coordinator's job and the admission lock (flock) handles intra-machine serialisation; the amendment's Enforced by entry names DSCLA-3 as the test that enforces the cross-machine exclusion statement covers: RQADR-5
DSCLA-14[doc]: README.md in plugins/claim-coordinator/github-labels/ tells the reader the shared claim label is zbuild:claimed (not claimed:<machine>) and does not reference machine-suffixed labels covers: RQDOC-1
REMOVED: DSCLA-4 — RQCLA-4 is fully covered by DSCLA-9, which tests the observable runner output; keeping a separate assertion that _ZBUILD_CLAIM_HOLDER is internally set tests the same interaction path with no additional observable coverage
WIRING: core/pipeline/runner.sh
```
