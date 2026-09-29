#!/usr/bin/env bash
# tests/unit/input-resolve-external-test.sh — a REQUIRED `source: external`
# input must actually be supplied before the stage is dispatched (ADR-055 §3).
#
# _inputs_declared drops every external input, so `required: true` on one was
# never checked. #1835's run relied on exactly that: plan declared goal_string
# external/required, the design read it as "the engine guarantees ZBUILD_GOAL",
# and every --issue run of the changed plugin failed 50 minutes later instead of
# being refused at dispatch.
#
#   1 [change] required goal_string with ZBUILD_GOAL empty -> refused, named
#   2 [guard]  required goal_string with ZBUILD_GOAL set    -> dispatched
#   3 [guard]  optional external with no supplier           -> dispatched
#   4 [change] every allowlisted id has a supplier (one table, ADR-055 §3)
#   5 [change] required gh_issue_body needs ZBUILD_ISSUE > 0
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"

print_test_header "a required external input must be supplied (ADR-055 §3)"
setup_test_env "input-resolve-external"

unset ZBUILD_INPUTS_FLOW ZBUILD_GOAL ZBUILD_ISSUE ZBUILD_SCOPE_PATHS 2>/dev/null || true

STATE="$TEST_TEMP_DIR/state"
PROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$STATE/artifacts"

_consumer() {  # <id> <external_id> <required>
    mkdir -p "$PROOT/tool/$1"
    cat > "$PROOT/tool/$1/manifest.yaml" <<EOF
id: $1
name: External Consumer
kind: tool
version: 0.0.1
hooks:
  run: x_run
inputs:
  - id: $2
    source: external
    required: $3
outputs: []
EOF
    printf '%s\n' "$PROOT/tool/$1/manifest.yaml"
}

_check() {  # <stage> <manifest> → prints rc, stderr to $TEST_TEMP_DIR/err
    _IR_INDEX_KEY=""
    _inputs_check_required "$1" "$PROOT" "$STATE" "$2" 2>"$TEST_TEMP_DIR/err"
    printf '%s' "$?"
}

# ── SPEC-1 [change] ───────────────────────────────────────────────────────────
M1="$(_consumer ext-goal goal_string true)"
rc="$(ZBUILD_GOAL="" _check ext-goal "$M1")"
assert_eq "[SPEC-1] required goal_string with ZBUILD_GOAL empty is refused" "1" "$rc"
assert_contains "[SPEC-1] the refusal names the unsupplied external input" \
    "$(cat "$TEST_TEMP_DIR/err")" "EXTERNAL_UNSUPPLIED"
assert_contains "[SPEC-1] the refusal names the id" "$(cat "$TEST_TEMP_DIR/err")" "goal_string"

# ── SPEC-2 [guard] ────────────────────────────────────────────────────────────
rc="$(ZBUILD_GOAL="build the thing" _check ext-goal "$M1")"
assert_eq "[SPEC-2] required goal_string with ZBUILD_GOAL set is dispatched" "0" "$rc"
rc="$(ZBUILD_GOAL="   " _check ext-goal "$M1")"
assert_eq "[SPEC-2] a blank ZBUILD_GOAL does not count as supplied" "1" "$rc"

# ── SPEC-3 [guard] ────────────────────────────────────────────────────────────
M3="$(_consumer ext-opt goal_string false)"
rc="$(ZBUILD_GOAL="" _check ext-opt "$M3")"
assert_eq "[SPEC-3] an optional external input with no supplier is dispatched" "0" "$rc"

# ── SPEC-4 [change] ───────────────────────────────────────────────────────────
_unsupplied=""
for _id in $(manifest_graph_external_allowlist); do
    _k="$(manifest_graph_external_supplier "$_id")"
    [[ -n "$_k" ]] || _unsupplied+="$_id "
done
assert_eq "[SPEC-4] every allowlisted external id names its supplier" "" "$_unsupplied"
assert_eq "[SPEC-4] an id outside the allowlist has no supplier" "" \
    "$(manifest_graph_external_supplier not_a_real_id)"

# ── SPEC-5 [change] ───────────────────────────────────────────────────────────
M5="$(_consumer ext-issue gh_issue_body true)"
rc="$(ZBUILD_ISSUE="" _check ext-issue "$M5")"
assert_eq "[SPEC-5] required gh_issue_body with no issue is refused" "1" "$rc"
rc="$(ZBUILD_ISSUE="0" _check ext-issue "$M5")"
assert_eq "[SPEC-5] issue 0 (a --goal run) does not supply gh_issue_body" "1" "$rc"
rc="$(ZBUILD_ISSUE="$(zb_test_issue)" _check ext-issue "$M5")"
assert_eq "[SPEC-5] a real issue number supplies gh_issue_body" "0" "$rc"

print_test_results
