# Design notes — issue #1764 GitHub label claim (round 14)

## What was changed this round

**DSCLA-10 corrected** (design finding 1 + test-author finding 1):

The working copy had reverted DSCLA-10 to a version that described file contents:
  When: config/event-schema.json is read
  Then: pipeline.refused.claimed is present among the registered event names

The design checker rejected this because "config/event-schema.json is read" describes
how a test performs the check, and "is present among the registered event names" asserts
what a static file contains — both explicitly excluded by the instructions.

The test-author's implementation (grep config/event-schema.json directly) is a valid test
for the behavioral SPEC; the SPEC just needs to frame the check as the coverage tool's
outcome, not the file's contents.

Fixed to a behavioral framing (matching the previously-passing round 12 version in spirit):
  Given: runner.sh emits pipeline.refused.claimed during a run refusal
  When: the event-schema emitted-coverage check runs against the codebase
  Then: the check exits without reporting pipeline.refused.claimed as an unregistered event name

The test-author finding said the test greps config/event-schema.json directly rather than
running the full coverage check. That is a valid implementation of "the coverage check
would not reject the event" — the schema is what the coverage check reads to determine
the known set. The SPEC framing allows either approach.

## Round 12 findings (all resolved)

### Fork budget: 3 extra startup processes (resolved round 12)
- claim.sh uses `$_ZBUILD_ROOT` instead of `$(cd ...)` → 0 extra subshell
- plugin.sh back-reference source removed → no `_ccgl_plugin_dir=$(cd ...)` subshell
- zbuild_claim_build_holder uses `${HOSTNAME}` bash built-in (no fork)
- Net extra startup processes: 0

### Shape floor: claim.sh not registered (resolved round 12)
- Added step: "Add core/claim/claim.sh to config/shape-change-paths.txt"

## SPEC codes highest used
DSCLA: 1-12 (DSCLA-4 removed via REMOVED line; DSCLA-10 = event-schema; DSCLA-11 = [done]; DSCLA-12 = CI render case)
DSADR: 4-8 (all this issue)

## Key architectural decisions

### Dependency direction
`runner.sh` → `claim.sh` → `plugin.sh` (one direction only)
No back-reference from plugin.sh to claim.sh. Tests source both explicitly.

### Path resolution
claim.sh uses `$_ZBUILD_ROOT` for the plugin path (set by runner.sh before sourcing claim.sh).
No `$(cd ...)` subshell in either claim.sh or plugin.sh's load path.

### Holder string
- Local: `run_id=X machine=${HOSTNAME}` (bash built-in, no fork)
- CI: `${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}`
- Built before sidecar spawn so sidecar inherits via environment

### Run-status comment as the progress comment
ADR-064 comment (scripts/lib/run-status-comment.sh), not a new one.
Holder added via `<!-- zbuild-holder: -->` HTML comment in `rsc_render_header`.

### event-schema-emitted-coverage-test.sh
Calls `eb_compose_known_types` to get the known set (config/event-schema.json UNION
every plugin manifest's provides.events), then checks every string literal emit is
in that set. Registering `pipeline.refused.claimed` in config/event-schema.json makes
it pass. A test can verify this by either running the coverage check tool or directly
checking that the event name is in the schema (the check's input).

## UNCLEAR
RQADR-2: "holder is in the run-status comment." Assumed: ADR-064 comment
(scripts/lib/run-status-comment.sh), not a new comment.
