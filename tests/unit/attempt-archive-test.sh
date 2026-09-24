#!/usr/bin/env bash
# Tests (#2183): an attempt's record survives the next attempt, and the errors a
# stage hit reach the stages that read its summary.
#
# SPEC-1 [change]: every dispatch of a stage archives its DECLARED outputs under
#   its own attempt identity — stage + cycle iteration + attempt number — so a
#   second dispatch cannot erase the first's record. #1841 run 35802918016:
#   build attempt 1 committed 66259d79 (1 file, +21 lines), was redispatched on
#   `disposition: interrupted`, and attempt 2's `changed 0 file(s)` overwrote it.
# SPEC-2 [change]: the archive is keyed by CYCLE ITERATION too, so iteration 2's
#   passing suite log cannot replace iteration 1's failing one inside one run.
# SPEC-3 [guard] : the LIVE paths are untouched — every consumer still reads the
#   same filename, and the newest attempt is what it sees.
# SPEC-4 [change]: a stage may declare ONE output as its error channel
#   (`errors: true`); when that stage's verdict is a failure, a bounded tail of
#   it is published into the summaries every other stage reads.
# SPEC-5 [guard] : a passing stage's error channel is NOT published, and a stage
#   that declares none behaves exactly as before.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "attempt archive + stage error channel (#2183)"
setup_test_env "attempt-archive"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/ev"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

PROOT="$TEST_TEMP_DIR/plugins"; STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"
mkdir -p "$PROOT/tool/aa-stage" "$ART"
cat > "$PROOT/tool/aa-stage/manifest.yaml" <<'EOF'
id: aa-stage
name: aa-stage
kind: tool
version: 0.0.1
convergence: gate
hooks:
  run: aa_stage_run
inputs: []
outputs:
  - id: aa_result
    path: ${artifact_dir}/aa-result.json
    type: json
    required: true
    primary: true
  - id: aa_summary
    path: ${artifact_dir}/aa-summary.md
    type: markdown
    required: false
    summary: true
  - id: aa_errors
    path: ${artifact_dir}/aa-errors.log
    type: text
    required: false
    errors: true
EOF
printf 'aa_stage_run() { return 0; }\n' > "$PROOT/tool/aa-stage/plugin.sh"
printf '{"schema_version":1,"stage_statuses":{"aa-stage":"failed"},"stage_verdicts":{"aa-stage":"fail"}}\n' > "$STATE/pipeline-state.json"

# shellcheck source=../../core/plugin-registry/attempt-archive.sh
source "$REPO_ROOT/core/plugin-registry/attempt-archive.sh" 2>/dev/null || true

if ! declare -F attempt_archive_outputs >/dev/null 2>&1; then
    assert_fail "[SPEC-1] attempt_archive_outputs is defined" "core/plugin-registry/attempt-archive.sh missing or defines nothing"
    cleanup_test_env; print_test_results; exit 1
fi

# ─── SPEC-1: two dispatches in one iteration keep two records ────────────────
print_test_section "SPEC-1: a second dispatch cannot erase the first's record"

printf '{"verdict":"pass","files_changed_count":1,"lines_added":21}\n' > "$ART/aa-result.json"
printf 'changed 1 file(s)\n' > "$ART/aa-summary.md"
ZBUILD_CYCLE_ITER=2 attempt_archive_outputs "$PROOT/tool/aa-stage" "$STATE/pipeline-state.json" "aa-stage" >/dev/null 2>&1

# attempt 2 overwrites the LIVE paths, exactly as today
printf '{"verdict":"pass","files_changed_count":0,"lines_added":0}\n' > "$ART/aa-result.json"
printf 'changed 0 file(s)\n' > "$ART/aa-summary.md"
ZBUILD_CYCLE_ITER=2 attempt_archive_outputs "$PROOT/tool/aa-stage" "$STATE/pipeline-state.json" "aa-stage" >/dev/null 2>&1

_a1="$(find "$ART/attempts" -name 'aa-result.json' 2>/dev/null | sort | head -1)"
_a2="$(find "$ART/attempts" -name 'aa-result.json' 2>/dev/null | sort | tail -1)"
assert_eq "[SPEC-1] two dispatches leave two archived copies" "2" \
    "$(find "$ART/attempts" -name 'aa-result.json' 2>/dev/null | grep -c . || true)"
assert_eq "[SPEC-1] the FIRST attempt's file count survives" "1" \
    "$(jq -r '.files_changed_count' "$_a1" 2>/dev/null)"
assert_eq "[SPEC-1] …and the second's is recorded separately" "0" \
    "$(jq -r '.files_changed_count' "$_a2" 2>/dev/null)"
assert_eq "[SPEC-1] the declared summary is archived too" "2" \
    "$(find "$ART/attempts" -name 'aa-summary.md' 2>/dev/null | grep -c . || true)"

# ─── SPEC-2: the key includes the cycle iteration ───────────────────────────
print_test_section "SPEC-2: iteration 2 cannot overwrite iteration 1"

printf 'ITER1-FAILING-OUTPUT\n' > "$ART/aa-summary.md"
ZBUILD_CYCLE_ITER=1 attempt_archive_outputs "$PROOT/tool/aa-stage" "$STATE/pipeline-state.json" "aa-stage" >/dev/null 2>&1
printf 'ITER2-PASSING-OUTPUT\n' > "$ART/aa-summary.md"
ZBUILD_CYCLE_ITER=2 attempt_archive_outputs "$PROOT/tool/aa-stage" "$STATE/pipeline-state.json" "aa-stage" >/dev/null 2>&1
if grep -rq 'ITER1-FAILING-OUTPUT' "$ART/attempts" 2>/dev/null; then
    assert_pass "[SPEC-2] the earlier iteration's output is still on disk"
else
    assert_fail "[SPEC-2] the earlier iteration's output is still on disk" \
        "$(find "$ART/attempts" -type f 2>/dev/null | tr '\n' ' ')"
fi
assert_eq "[SPEC-2] the two iterations are stored apart" "2" \
    "$(find "$ART/attempts" -type d -name 'iter-*' 2>/dev/null \
        | sed 's|.*/iter-\([0-9]*\)-attempt-.*|\1|' | sort -u | grep -c . || true)"

# ─── SPEC-3 (guard): the live paths are untouched ───────────────────────────
print_test_section "SPEC-3 (guard): consumers still read the same filenames"
assert_file_exists "[SPEC-3] the live result is where it always was" "$ART/aa-result.json"
assert_contains "[SPEC-3] and holds the NEWEST attempt" \
    "$(cat "$ART/aa-summary.md" 2>/dev/null)" "ITER2-PASSING-OUTPUT"

# ─── SPEC-4: the error channel reaches the other stages ─────────────────────
print_test_section "SPEC-4: a failing stage's declared errors are published"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
_TPL_STAGES=(aa-stage)
printf '## aa-stage — fail\n\n- 1 of 19 tests failed\n' > "$ART/aa-summary.md"
printf 'runner.sh: line 1499: refusing the run: state file names another issue\nTHE-NESTED-STDERR\n' > "$ART/aa-errors.log"
printf '{"result_contract":2,"verdict":"fail","disposition":"complete","reason":"1 failed"}\n' > "$ART/aa-result.json"
_blk="$(stage_summaries_prompt_block "$STATE/pipeline-state.json" "$PROOT" 2>/dev/null || true)"
assert_contains "[SPEC-4] the summary still ships" "$_blk" "1 of 19 tests failed"
assert_contains "[SPEC-4] and the errors the stage hit ship with it" "$_blk" "THE-NESTED-STDERR"

# ─── SPEC-5 (guard): a passing stage publishes no errors ────────────────────
print_test_section "SPEC-5 (guard): errors ship only with a failure"
printf '{"schema_version":1,"stage_statuses":{"aa-stage":"complete"},"stage_verdicts":{"aa-stage":"pass"}}\n' > "$STATE/pipeline-state.json"
printf '{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"ok"}\n' > "$ART/aa-result.json"
_blk_ok="$(stage_summaries_prompt_block "$STATE/pipeline-state.json" "$PROOT" 2>/dev/null || true)"
if grep -q 'THE-NESTED-STDERR' <<< "$_blk_ok"; then
    assert_fail "[SPEC-5] a passing stage does not publish its error channel" "$_blk_ok"
else
    assert_pass "[SPEC-5] a passing stage does not publish its error channel"
fi

# ─── SPEC-6 (review #2184): the channel is found whatever the field order ───
# `errors: true` before `path:` is valid YAML. An order-dependent reader skips
# the channel silently — the stage looks like it published nothing.
print_test_section "SPEC-6: errors: true is found before OR after path:"
mkdir -p "$PROOT/tool/aa-rev"
cat > "$PROOT/tool/aa-rev/manifest.yaml" <<'EOF'
id: aa-rev
name: aa-rev
kind: tool
version: 0.0.1
hooks:
  run: aa_rev_run
inputs: []
outputs:
  - id: aa_rev_result
    path: ${artifact_dir}/aa-rev-result.json
    type: json
    required: true
    primary: true
  - id: aa_rev_summary
    path: ${artifact_dir}/aa-rev-summary.md
    type: markdown
    required: false
    summary: true
  - id: aa_rev_errors
    errors: true
    required: false
    type: text
    path: ${artifact_dir}/aa-rev-errors.log
EOF
printf 'aa_rev_run() { return 0; }\n' > "$PROOT/tool/aa-rev/plugin.sh"
_TPL_STAGES=(aa-rev)
printf '{"schema_version":1,"stage_statuses":{"aa-rev":"failed"},"stage_verdicts":{"aa-rev":"fail"}}\n' > "$STATE/pipeline-state.json"
printf '## aa-rev — fail\n\n- it failed\n' > "$ART/aa-rev-summary.md"
printf 'REVERSED-ORDER-STDERR\n' > "$ART/aa-rev-errors.log"
printf '{"result_contract":2,"verdict":"fail","disposition":"complete","reason":"x"}\n' > "$ART/aa-rev-result.json"
_blk_rev="$(stage_summaries_prompt_block "$STATE/pipeline-state.json" "$PROOT" 2>/dev/null || true)"
assert_contains "[SPEC-6] the error channel is found with errors: before path:" \
    "$_blk_rev" "REVERSED-ORDER-STDERR"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
