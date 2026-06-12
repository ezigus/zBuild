#!/usr/bin/env bash
# Tests: test_assessment cumulative branch_numstat against intake-captured
# baseline sha (#824). The dogfood failure mode: build's per-iter
# diff.patch gets zeroed on scope_violation, but worktree has real
# implementation files from mid-LLM Edit/Write calls. Old `branch_numstat`
# helper used `git diff <range>..HEAD` which misses uncommitted changes
# entirely. The new path uses `git diff <baseline_sha>` (no `..HEAD`) so
# uncommitted worktree changes count.
#
# Covers:
#   T1 baseline missing → rc=2 + test_assessment.missing_baseline event
#   T2 baseline present + UNCOMMITTED worktree changes → numstat reports them
#   T3 baseline present + COMMITTED changes → numstat reports them
#   T4 prompt heredoc contains the "Verification discipline" section
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "test_assessment cumulative branch_numstat (#824)"
setup_test_env "ta-branch-numstat-824"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/test_assessment"

# Fresh git fixture per-test (initialized inside each test's setup).
_init_git_fixture() {
    local dir="$1"
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$dir" init --quiet >/dev/null 2>&1
    git -C "$dir" config user.email 'test@example.com' >/dev/null
    git -C "$dir" config user.name  'test' >/dev/null
    printf 'seed\n' > "$dir/SEED"
    git -C "$dir" add SEED >/dev/null
    git -C "$dir" commit -m 'baseline' --quiet >/dev/null
    git -C "$dir" rev-parse HEAD
}

_seed_state_dir() {
    local repo="$1" state_dir="$2" baseline_sha="$3"
    rm -rf "$state_dir"
    mkdir -p "$state_dir/artifacts"
    printf '{"schema_version":1,"run_id":"824","issue":"824","stage_statuses":{}}' > "$state_dir/pipeline-state.json"
    cat > "$state_dir/scope-manifest.md" <<'SCOPE'
+ core/
+ plugins/
SCOPE
    cat > "$state_dir/artifacts/test-results.json" <<'TR'
{"schema_version":1,"verdict":"pass","exit_code":0,"passed":10,"failed":0,"test_output":"","diff_applied":true,"test_cmd":"npm test"}
TR
    cat > "$state_dir/artifacts/plan.json" <<'PJ'
{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}
PJ
    cat > "$state_dir/artifacts/build-summary.json" <<'BS'
{"schema_version":1,"verdict":"pass","iterations":1,"terminated_reason":"complete"}
BS
    [[ -n "$baseline_sha" ]] && printf '%s\n' "$baseline_sha" > "$state_dir/intake-baseline-ref.txt"
}

# Source plugin FIRST so its own `source core/router/route.sh` loads, THEN
# override the public functions with mocks. If mocks come first, the plugin's
# sourcing replaces them (same trap as the design-stray test fix).
# shellcheck source=../../plugins/agent/test_assessment/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

apply_scope_redaction() { cp "$1" "$2"; return 0; }
_CAPTURED_PROMPT="$TEST_TEMP_DIR/captured.txt"
route_to_model() {
    printf '%s' "${2:-}" > "$_CAPTURED_PROMPT"
    printf '%s\n' '{"schema_version":1,"verdict":"pass","summary":"ok","diagnosis":"","required_changes":[],"agrees_with_build_complete":true,"branch_numstat":"unknown","failure_summary_md":"ok","iter":1}'
    return 0
}

# ─── T1: baseline missing → rc=2 + missing_baseline event ────────────────────
T1_REPO="$TEST_TEMP_DIR/t1-repo"
T1_STATE="$TEST_TEMP_DIR/t1-state"
_init_git_fixture "$T1_REPO" >/dev/null
_seed_state_dir "$T1_REPO" "$T1_STATE" ""   # NO baseline file written
cd "$T1_REPO"
: > "$ZBUILD_EVENTS_JSONL"
set +e
test_assessment_run "test_assessment" "$T1_STATE/pipeline-state.json" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T1: missing intake-baseline-ref.txt → rc=2" "2" "$rc"
if grep -q '"test_assessment.missing_baseline"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "T1: test_assessment.missing_baseline event emitted"
else
    assert_fail "T1: missing_baseline event NOT emitted" \
        "events: $(head -c 200 "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo none)"
fi

# ─── T2: baseline present + UNCOMMITTED worktree changes ─────────────────────
# This is the dogfood loop scenario: build's mid-LLM Edit/Write calls left
# files on disk but no commits. branch_numstat_since must catch them.
T2_REPO="$TEST_TEMP_DIR/t2-repo"
T2_STATE="$TEST_TEMP_DIR/t2-state"
T2_BASELINE="$(_init_git_fixture "$T2_REPO")"
_seed_state_dir "$T2_REPO" "$T2_STATE" "$T2_BASELINE"
cd "$T2_REPO"
# Simulate uncommitted build work: 2 new files, 1 modification, no commits.
printf 'one\n' > "$T2_REPO/added-1.sh"
printf 'two\nthree\n' > "$T2_REPO/added-2.sh"
printf 'modified seed\n' > "$T2_REPO/SEED"
: > "$ZBUILD_EVENTS_JSONL"
set +e
test_assessment_run "test_assessment" "$T2_STATE/pipeline-state.json" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T2: baseline + uncommitted changes → rc=0 (plugin runs to completion)" \
    "0" "$rc"
# The captured prompt's BRANCH NUMSTAT line must show non-zero files.
ns_line=$(grep -A1 'BRANCH NUMSTAT:' "$_CAPTURED_PROMPT" 2>/dev/null | tail -1)
if [[ "$ns_line" =~ files=([0-9]+) ]] && [[ "${BASH_REMATCH[1]}" -ge 2 ]]; then
    assert_pass "T2: prompt BRANCH NUMSTAT reflects ≥2 uncommitted files (got: $ns_line)"
else
    assert_fail "T2: prompt BRANCH NUMSTAT did NOT count uncommitted files" \
        "got: $ns_line"
fi

# ─── T3: baseline present + COMMITTED changes ────────────────────────────────
T3_REPO="$TEST_TEMP_DIR/t3-repo"
T3_STATE="$TEST_TEMP_DIR/t3-state"
T3_BASELINE="$(_init_git_fixture "$T3_REPO")"
_seed_state_dir "$T3_REPO" "$T3_STATE" "$T3_BASELINE"
cd "$T3_REPO"
# Simulate a successful build that committed: 3 new files, all committed.
for n in 1 2 3; do printf 'committed-%d\n' $n > "$T3_REPO/committed-$n.sh"; done
git -C "$T3_REPO" add . >/dev/null
git -C "$T3_REPO" commit -m 'build commit' --quiet >/dev/null
: > "$ZBUILD_EVENTS_JSONL"
set +e
test_assessment_run "test_assessment" "$T3_STATE/pipeline-state.json" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T3: baseline + committed changes → rc=0" "0" "$rc"
ns_line=$(grep -A1 'BRANCH NUMSTAT:' "$_CAPTURED_PROMPT" 2>/dev/null | tail -1)
if [[ "$ns_line" =~ files=([0-9]+) ]] && [[ "${BASH_REMATCH[1]}" -ge 3 ]]; then
    assert_pass "T3: prompt BRANCH NUMSTAT reflects ≥3 committed files (got: $ns_line)"
else
    assert_fail "T3: prompt BRANCH NUMSTAT did NOT count committed files" \
        "got: $ns_line"
fi

# ─── T4: prompt contains the Verification discipline section ─────────────────
# T3's captured prompt is still in $_CAPTURED_PROMPT — reuse for T4.
if grep -q 'Verification discipline' "$_CAPTURED_PROMPT" 2>/dev/null; then
    assert_pass "T4: prompt contains 'Verification discipline' header"
else
    assert_fail "T4: prompt MISSING 'Verification discipline' section"
fi
if grep -q 'spot-check' "$_CAPTURED_PROMPT" 2>/dev/null; then
    assert_pass "T4: prompt instructs LLM to spot-check via Read tool"
else
    assert_fail "T4: prompt missing spot-check instruction"
fi
if grep -q 'EVEN IF the per-iter diff is 0/0/0' "$_CAPTURED_PROMPT" 2>/dev/null; then
    assert_pass "T4: prompt explicitly handles the per-iter-empty case"
else
    assert_fail "T4: prompt missing 'EVEN IF the per-iter diff is 0/0/0' guard"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
