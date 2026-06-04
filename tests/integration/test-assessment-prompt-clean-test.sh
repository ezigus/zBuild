#!/usr/bin/env bash
# Integration: test_assessment LLM prompt is clean (Wave 15-C, #681)
#
# Drives test_assessment with a fake test-results.json whose .test_output
# field is heavy with framework decoration (banner pairs, redaction-tag
# wrappers, ANSI, decorative separator, truncation footer). Asserts the
# composed prompt that gets written to test-assessment-prompt.txt:
#   - contains the genuine test-runner signal
#   - does NOT contain any of the 5 decoration classes that #681 strips
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "integration: test_assessment prompt clean (#681)"
setup_test_env "test-assessment-prompt-clean"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

STATE_DIR="$TEST_TEMP_DIR/state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"
echo '{"schema_version":1,"run_id":"clean","issue":"681","stage_statuses":{}}' > "$STATE_FILE"
cat > "$STATE_DIR/scope-manifest.md" <<'SCOPE'
+ core/
+ plugins/
SCOPE

# Build a heavily-decorated test_output: every #681 transform must trigger.
# Use printf to keep control bytes literal in the JSON value.
NOISY_OUTPUT="$(printf '%s\n' \
    '══ test [command] seq=1 input ══' \
    'npm test' \
    '── end stage-io: test ✓ ──' \
    '══════════════════════════════════════════════════' \
    'FAIL UserTest (assertion)' \
    '  expected: 42' \
    '  got: <out-of-scope-context>/var/folders/x/user.js</out-of-scope-context>:99' \
    $'\x1b[38;2;74;222;128m✓\x1b[0m other test passed' \
    '──────────────────────────────────────────────────' \
    '↪ [56 more lines · full at /Users/x/test-results.json]')"

# Embed into test-results.json via jq for proper JSON escaping.
jq -n --arg out "$NOISY_OUTPUT" \
    '{schema_version:1,verdict:"fail",exit_code:1,passed:1,failed:1,test_output:$out,diff_applied:true,test_cmd:"npm test"}' \
    > "$ARTIFACTS_DIR/test-results.json"

cat > "$ARTIFACTS_DIR/plan.json" <<'PJ'
{"schema_version":1,"title":"clean","goal":"clean","steps":[{"id":"s1","description":"x","files":["src/x.js"],"estimated_lines":1}],"estimated_total_lines":1,"notes":""}
PJ
cat > "$ARTIFACTS_DIR/build-summary.json" <<'BS'
{"schema_version":1,"verdict":"pass","iterations":1,"terminated_reason":"complete"}
BS

# shellcheck source=../../plugins/agent/test_assessment/plugin.sh
source "$REPO_ROOT/plugins/agent/test_assessment/plugin.sh"

# Stubs — pass-through redaction so the assembled prompt is the artifact we
# inspect; canned LLM response so the run completes.
apply_scope_redaction() { cat "$1" > "$2"; return 0; }
route_to_model() {
    printf '%s\n' '{"schema_version":1,"verdict":"fail","summary":"x","diagnosis":"y","required_changes":["z"],"agrees_with_build_complete":false,"branch_numstat":"unused","failure_summary_md":"## x","iter":1}'
    return 0
}

set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "run rc=0" "0" "$rc"

PROMPT_FILE="$ARTIFACTS_DIR/test-assessment-prompt.txt"
assert_file_exists "prompt file written" "$PROMPT_FILE"

prompt="$(cat "$PROMPT_FILE")"

print_test_section "1. signal preserved"

assert_contains "FAIL line present" "$prompt" "FAIL UserTest (assertion)"
assert_contains "expected line present" "$prompt" "expected: 42"
assert_contains "✓ mark preserved (post-ANSI-strip)" "$prompt" "✓ other test passed"
# Wrapper stripped — bare path remains in the assertion line
assert_contains "bare path preserved after wrapper strip" "$prompt" "/var/folders/x/user.js:99"

print_test_section "2. decoration stripped"

if grep -qF '<out-of-scope-context>' <<< "$prompt"; then
    assert_fail "no redaction-tag wrappers" "still present"
else
    assert_pass "no redaction-tag wrappers"
fi

if grep -qF '══' <<< "$prompt"; then
    assert_fail "no heavy banner / separator chars" "still present"
else
    assert_pass "no heavy banner / separator chars"
fi

if grep -qF '──' <<< "$prompt"; then
    assert_fail "no light banner / separator chars" "still present"
else
    assert_pass "no light banner / separator chars"
fi

# ANSI CSI sequence detection — ESC followed by [
if printf '%s' "$prompt" | grep -qE $'\x1b\\['; then
    assert_fail "no ANSI CSI sequences" "still present"
else
    assert_pass "no ANSI CSI sequences"
fi

if grep -qF 'more lines · full at' <<< "$prompt"; then
    assert_fail "no truncation footer" "still present"
else
    assert_pass "no truncation footer"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
