# Red-team checkpoint — issue #1799

## Files read
- plugins/tool/pr-open/plugin.sh (full) — state-aware draft forcing in _pr_open_run_inner (lines 133-147); draft flag only in _gh_args, used only by gh pr create
- plugins/tool/pr-open/lib/advisory-section.sh (full) — new render functions; gate/convergence content rendered without esc sanitizer used elsewhere in same file
- plugins/tool/pr-open/manifest.yaml — new optional gate_aggregator_result input declared (not read yet but consistent with design)
- plugins/tool/pr-open/tests/pr-open-test.sh (diff only) — tests 10-13 all mock gh pr list to return empty, forcing the gh pr create path

## Conclusions reached

### Finding 1 (HIGH, introduced): Existing non-draft PR not promoted to draft on failed re-run
plugin.sh:376 sets `_gh_args+=("--draft")` when `_draft_bool="true"`.
But `_gh_args` is only passed to `gh pr create` (line 407).
When `existing_pr_number` is set, the code calls `gh pr edit "$existing_pr_number" --title ... --body ...` (lines 388, 414) — `_gh_args` is never consulted. `gh pr edit` has no `--draft` flag. A non-draft PR opened by a prior passing run remains non-draft after a failed re-run, directly violating SPEC-1 and SPEC-2 for the re-run scenario.
Tests 10-13 mock `gh pr list` to return empty (no existing PR), so they exercise only the create path and do not detect this gap.

### Finding 2 (LOW, introduced): Gate reason / failed_gates unescaped in PR body
advisory-section.sh:143-146: `failed_gates` and `reason` from gate_aggregator_result are rendered via bare `printf`. The file's existing `_PR_OPEN_FINDING_JQ_DEFS` defines `esc` which strips ANSI, flattens control chars, and escapes `\`,`[`,`]`,`<`,`>`. The new gate-section renderer skips it. Content is from a trusted engine-resolved path, so exploitability is low, but it is inconsistent with the defensive posture established in this file.

### Finding 3 (LOW, introduced): Convergence cycle_id / iterations unescaped
advisory-section.sh:129: jq string interpolation of `cycle_id`, `iterations_used`, `max_iterations` without `esc`. Same class as finding 2.

## What's still unresolved
- manifest.yaml was not read in full; not expected to contain new findings
- pr-delivery plugin.sh not read; described as passing gate_aggregator_result via ZBUILD_STAGE_INPUTS which is the engine-trusted path

## Next step if stopped now
Emit JSON with 3 findings above. Score 6.
