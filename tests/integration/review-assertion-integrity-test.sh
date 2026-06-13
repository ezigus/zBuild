#!/usr/bin/env bash
# Integration: review's prompt carries the assertion-integrity charter (#840 /
# ADR-030 R3). Governed scope expansion lets build edit test files; review must
# guard against a build that passes a red test by WEAKENING its assertions.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "integration: review assertion-integrity charter (#840 R3)"
setup_test_env "review-assertion-integrity-840"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
: > "$ZBUILD_EVENTS_JSONL"

ARTIFACTS="$TEST_TEMP_DIR/state/artifacts"; STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ARTIFACTS"
SCOPE_MANIFEST="$STATE_DIR/scope-manifest.md"; printf '+ ./\n' > "$SCOPE_MANIFEST"
PLAN_JSON="$ARTIFACTS/plan.json"
printf '{"schema_version":1,"title":"X","goal":"x","steps":[{"id":"step-1","description":"d","files":["src/foo.sh"],"estimated_lines":10}],"estimated_total_lines":10,"notes":""}\n' > "$PLAN_JSON"
DIFF_PATCH="$ARTIFACTS/diff.patch"; printf '' > "$DIFF_PATCH"
TEST_RESULTS="$ARTIFACTS/test-results.json"
printf '{"schema_version":1,"verdict":"pass","passed":10,"failed":0,"exit_code":0}\n' > "$TEST_RESULTS"
REVIEW_OUT="$ARTIFACTS/review.json"

zbuild_plugin_bootstrap() { _ZBUILD_PLUGIN_DIR="$REPO_ROOT/plugins/agent/review"; _ZBUILD_PLUGIN_ROOT="$REPO_ROOT"; }
emit_event() { return 0; }
warn() { return 0; }
error() { echo "ERROR: $*" >&2; }

# shellcheck source=../../plugins/agent/review/plugin.sh
source "$REPO_ROOT/plugins/agent/review/plugin.sh"

CAPTURED="$TEST_TEMP_DIR/captured-prompt.txt"
route_to_model() {
    printf '%s' "$2" > "$CAPTURED"
    printf '{"verdict":"approve","confidence":0.9,"issues":[],"summary":"ok"}'
    return 0
}
apply_scope_redaction() { cp "$1" "$2"; return 0; }
atomic_write() { cat > "$1"; }
extract_first_json_object() { cat; }
render_artifact() { printf '%s' "$2"; }
_zbuild_sanitize_for_llm() { cat; }
_zbuild_diff_stat() { printf '## Changed files (0 total)\n'; }

set +e
_review_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$DIFF_PATCH" "$TEST_RESULTS" "$REVIEW_OUT" "$ARTIFACTS" "" >/dev/null 2>&1
rc=$?
set -e
assert_eq "review inner rc=0" "0" "$rc"
assert_file_exists "prompt captured" "$CAPTURED"

# T1: charter heading present.
if grep -qi 'Assertion integrity' "$CAPTURED"; then
    assert_pass "T1: prompt has the Assertion integrity section"
else
    assert_fail "T1: prompt missing Assertion integrity section"
fi
# T2: forbids weakening/deleting assertions to pass.
if grep -qiE 'weaken|deleted|loosen|gaming the gate' "$CAPTURED"; then
    assert_pass "T2: prompt forbids weakened/deleted assertions"
else
    assert_fail "T2: prompt must forbid weakened/deleted assertions"
fi
# T3: distinguishes a legitimate updated expected value from gaming.
if grep -qiE 'UPDATED to a new correct|genuinely added|is fine' "$CAPTURED"; then
    assert_pass "T3: prompt allows legitimate expected-value updates"
else
    assert_fail "T3: prompt must distinguish legit updates from gaming"
fi
# T4: ties it to scope expansion (#840 context).
if grep -qiE 'scope expansion|ADR-030|#840' "$CAPTURED"; then
    assert_pass "T4: charter references governed scope expansion"
else
    assert_fail "T4: charter should reference scope expansion context"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
