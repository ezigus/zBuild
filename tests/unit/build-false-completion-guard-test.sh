#!/usr/bin/env bash
# Unit: _build_guard_false_completion (#1532) — 0-diff + red acceptance testfile
# overrides verdict to inert_build before downstream test+gate run.
#
# Case A: LOOP_COMPLETE with 0-file diff + failing acceptance testfile
#         → helper returns failing path (non-zero exit)
# Case B: LOOP_COMPLETE with 0-file diff + passing acceptance testfile
#         → helper returns empty (zero exit)
# Case C: LOOP_COMPLETE with 0-file diff + no acceptance block
#         → helper returns empty (zero exit, empty testfiles input)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build _build_guard_false_completion — false-completion guard (#1532)"
setup_test_env "build-false-completion-guard"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-false-completion-guard-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts"

# Minimal mocks for plugin bootstrap dependencies.
# shellcheck disable=SC2317
route_to_model_loop() {
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    _ROUTE_LOOP_LAST_RESPONSE="LOOP_COMPLETE"
    return 0
}
# shellcheck disable=SC2317
_route_resolve_max_iterations() { echo 3; }
# shellcheck disable=SC2317
_route_loop_close_final_banner() { return 0; }
# shellcheck disable=SC2317
apply_scope_redaction() { local in="$1" out="$2"; [[ -f "$in" ]] && cp "$in" "$out"; return 0; }

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# ── Fixture repo ──────────────────────────────────────────────────────────────
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
(
    cd "$REPO"
    git init -q
    git config user.email t@t
    git config user.name t
    printf 'seed\n' > seed.txt
    git add seed.txt
    git commit -q -m seed
) >/dev/null

# ── Acceptance testfiles ──────────────────────────────────────────────────────
mkdir -p "$REPO/tests/unit"

# Failing testfile: always exits 1.
cat > "$REPO/tests/unit/failing-test.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$REPO/tests/unit/failing-test.sh"

# Passing testfile: always exits 0.
cat > "$REPO/tests/unit/passing-test.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$REPO/tests/unit/passing-test.sh"

# ── Case A: failing testfile → helper returns path + exits 1 ─────────────────
print_test_section "A: failing acceptance testfile → returns failing path"

TESTFILES_A="tests/unit/failing-test.sh"
failing_out=""
if ! failing_out="$(_build_guard_false_completion "$TESTFILES_A" "$REPO" 2>/dev/null)"; then
    assert_eq "A: failing testfile → helper exits 1" "1" "1"
else
    assert_eq "A: failing testfile → helper exits 1" "0" "1"
fi
assert_eq "A: failing_out is the failing testfile path" \
    "tests/unit/failing-test.sh" "$failing_out"

# ── Case B: passing testfile → helper returns empty + exits 0 ────────────────
print_test_section "B: passing acceptance testfile → no override"

TESTFILES_B="tests/unit/passing-test.sh"
passing_out=""
if passing_out="$(_build_guard_false_completion "$TESTFILES_B" "$REPO" 2>/dev/null)"; then
    assert_eq "B: passing testfile → helper exits 0" "0" "0"
else
    assert_eq "B: passing testfile → helper exits 0" "1" "0"
fi
assert_eq "B: passing_out is empty (no failing testfile)" "" "$passing_out"

# ── Case C: empty testfiles list → helper returns empty + exits 0 ────────────
print_test_section "C: no acceptance block (empty testfiles) → no override"

empty_out=""
if empty_out="$(_build_guard_false_completion "" "$REPO" 2>/dev/null)"; then
    assert_eq "C: empty testfiles → helper exits 0" "0" "0"
else
    assert_eq "C: empty testfiles → helper exits 0" "1" "0"
fi
assert_eq "C: empty_out is empty (no testfiles)" "" "$empty_out"

# ── SPEC-7 [change]: inert_build writes verdict=fail + data.build_kind (#1832) ─
# Previously wrote verdict="inert_build"; now writes verdict="fail" +
# data: {build_kind: "inert_build"} + disposition="broken" (ADR-054 §6).
print_test_section "SPEC-7 [change]: inert_build → verdict=fail + data.build_kind=inert_build (#1832)"

_spec7_summary="$TEST_TEMP_DIR/spec7-build-summary.json"
# Set up the caller-scope variables that _build_write_build_summary reads.
scope_violation="false"
terminated_reason="done_sentinel"
files_changed_count=0
files_changed_json='[]'
lines_added=0
lines_removed=0
iterations=1
loop_input_tokens=0
loop_output_tokens=0
output_diff_patch=""
output_summary_json="$_spec7_summary"
_acceptance_testfiles="tests/unit/failing-test.sh"
repo_root="$REPO"
scope_violations=()
scope_violations_created=()
_feedback_body=""
plan_files_csv=""
issue=0
router_rc=0
build_verdict=""

_build_write_build_summary 2>/dev/null

_s7_verdict="$(jq -r '.verdict' "$_spec7_summary" 2>/dev/null)"
_s7_kind="$(jq -r '.data.build_kind // ""' "$_spec7_summary" 2>/dev/null)"
_s7_disp="$(jq -r '.disposition // ""' "$_spec7_summary" 2>/dev/null)"
assert_eq "[SPEC-7] inert_build summary: verdict=fail (#1832)" "fail" "$_s7_verdict"
assert_eq "[SPEC-7] inert_build summary: data.build_kind=inert_build (#1832)" "inert_build" "$_s7_kind"
assert_eq "[SPEC-7] inert_build summary: disposition=broken (#1832)" "broken" "$_s7_disp"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
