# Design notes — issue #1764 GitHub label claim (round 12)

## What was read this round

- `issue-acceptance-result.json` (iter-3) — 2 unasked-change findings
- `tests/e2e/fork-budget-test.sh` — STARTUP_PROCS_BUDGET=465
- `scripts/lib/shape-floor.sh` — shape floor logic; _sf_floor_verified passes unedited files when _SF_VERIFY_OK=1
- `config/shape-change-paths.txt` — shape-change triggers (runner.sh is there, claim.sh is not)
- Worktree `core/claim/claim.sh` — sources plugin.sh via $(cd ...) subshell; zbuild_claim_build_holder calls _ccgl_machine_id which calls hostname
- Worktree `plugins/claim-coordinator/github-labels/plugin.sh` — has back-reference source of claim.sh at bottom; uses $(cd ...) subshell for _ccgl_plugin_dir
- Worktree `core/pipeline/runner.sh` — sources claim.sh; calls zbuild_claim_build_holder before sidecar spawn

## Issue-acceptance findings (iter-3)

### Finding 1 (fork budget): 3 extra startup processes
Evidence: `core/claim/claim.sh | source "$_claim_sh_own_dir/../../plugins/claim-coordinator/github-labels/plugin.sh"`

Root cause of 3 processes:
1. `claim.sh` line 12: `$(cd "${BASH_SOURCE[0]%/*}" ...)` = 1 subshell
2. `plugin.sh` line 254 (back-reference load): `$(cd "${BASH_SOURCE[0]%/*}" ...)` = 1 subshell
3. `zbuild_claim_build_holder` → `_ccgl_machine_id` → `hostname` external command = 1 process

Design fix applied:
- `claim.sh` uses `$_ZBUILD_ROOT` (set by runner.sh) instead of `$(cd ...)` → 0 extra subshell
- plugin.sh back-reference source removed → no `_ccgl_plugin_dir=$(cd ...)` subshell
- `zbuild_claim_build_holder` uses `${HOSTNAME}` bash built-in (no fork)
- Net extra startup processes: 0

### Finding 2 (shape floor): claim.sh not registered
Evidence: `core/claim/claim.sh | _ZBUILD_CLAIM_SH_LOADED=1`

Root cause: `config/shape-change-paths.txt` has `core/pipeline/runner.sh`; modifying it triggers
shape floor. `_TPL_STAGES[N]`-indexed tests not in diff and no test results for `_sf_floor_verified`.
Finding says claim.sh "is not registered in the shape floor."

Design fix applied:
- Add `core/claim/claim.sh` to `config/shape-change-paths.txt` as a new step

Note: in actual CI, `_sf_floor_verified` handles unedited `_TPL_STAGES[N]` tests when full test
suite passes (`_SF_VERIFY_OK=1`). Stage order/count unchanged by this PR; those tests are still correct.

## Changes this round (round 12)

1. Decision section: added startup process analysis and fix explanation; noted ${HOSTNAME} usage; noted $_ZBUILD_ROOT for path resolution; noted removal of circular back-reference
2. plugin.sh step: added "remove any back-reference source of core/claim/claim.sh; also eliminates _ccgl_plugin_dir=$(cd ...) subshell"
3. claim.sh step: added "source plugin.sh using $_ZBUILD_ROOT (not $(cd ...) subshell); zbuild_claim_build_holder uses ${HOSTNAME} bash variable (not external hostname)"
4. New step: "Add core/claim/claim.sh to config/shape-change-paths.txt"
5. runner.sh step: added explicit mention of zbuild_claim_build_holder before sidecar spawn

## SPEC codes highest used
DSCLA: 1-12 (DSCLA-4 removed via REMOVED line; DSCLA-10 = event-schema; DSCLA-11 = [done]; DSCLA-12 = CI render case)
DSADR: 4-8 (all this issue)

## Key architectural decisions

### Dependency direction (corrected from coder's implementation)
`runner.sh` → `claim.sh` → `plugin.sh` (one direction only)
No back-reference from plugin.sh to claim.sh. Tests source both explicitly.

### Path resolution (new constraint)
claim.sh uses `$_ZBUILD_ROOT` for the plugin path (set by runner.sh before sourcing claim.sh).
No `$(cd ...)` subshell in either claim.sh or plugin.sh's load path.

### Holder string
- Local: `run_id=X machine=${HOSTNAME}` (bash built-in, no fork)
- CI: `${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}`
- Built before sidecar spawn so sidecar inherits via environment

### Run-status comment as the progress comment
ADR-064 comment (scripts/lib/run-status-comment.sh), not a new one.
Holder added via `<!-- zbuild-holder: -->` HTML comment in `rsc_render_header`.

## UNCLEAR
RQADR-2: "holder is in the run-status comment." Assumed: ADR-064 comment
(scripts/lib/run-status-comment.sh), not a new comment.
