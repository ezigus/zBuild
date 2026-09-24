#!/usr/bin/env bash
# Unit: PREV-1 (#881) — impact-prefilter deterministic stage-ORDER assertion
# detector. A reorder of pipeline stages (e.g. design before impact) breaks every
# test pinning a stage by index (`_TPL_STAGES[2]`), but those are neither numeric
# shape-counts nor goldens — the existing prefilter floor misses them. This adds
# `_impact_list_order_assertions` + a `shape-change-order` candidate class,
# anchored strictly to the indexed form so it never over-matches bare names.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: impact-prefilter order-assertion detector (PREV-1 #881)"
setup_test_env "impact-prefilter-order-881"

# shellcheck source=../../scripts/lib/impact-prefilter.sh
source "$REPO_ROOT/scripts/lib/impact-prefilter.sh"

# ─── Controlled fixture repo ────────────────────────────────────────────────
FIX="$TEST_TEMP_DIR/repo"
mkdir -p "$FIX/config/templates" "$FIX/tests/unit" "$FIX/tests/golden"
# Shape-change path list so _impact_detect_shape_change fires on template.sh.
printf 'core/pipeline/template.sh\nconfig/templates/*.yaml\n' > "$FIX/config/shape-change-paths.txt"
printf 'flow:\n  - intake\nstages:\n  intake: {}\n' > "$FIX/config/templates/simple.yaml"
# Order-pinning test (indexed) — MUST be detected.
printf 'assert_eq "[2] is design" "design" "${_TPL_STAGES[2]}"\n' > "$FIX/tests/unit/order-fixture-test.sh"
# Bare names without an index — MUST NOT be detected (over-match guard).
printf 'echo "impact runs and design runs"\n' > "$FIX/tests/unit/bare-fixture-test.sh"

PLAN='{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"s1","description":"reorder","files":["core/pipeline/template.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'

# ─── T1: detector lists only the indexed order assertion ────────────────────
ORDER_FILES="$(_impact_list_order_assertions "$FIX/tests")"
case "$ORDER_FILES" in
    *"tests/unit/order-fixture-test.sh"*) assert_pass "T1: indexed order test detected" ;;
    *) assert_fail "T1: order test not detected: $ORDER_FILES" ;;
esac
case "$ORDER_FILES" in
    *"bare-fixture-test.sh"*) assert_fail "T1: bare-names test must NOT match (over-match): $ORDER_FILES" ;;
    *) assert_pass "T1: bare-names test correctly excluded" ;;
esac

# ─── T2: prefilter injects a shape-change-order candidate for the order test ──
RESULT="$(_impact_scope_prefilter "$PLAN" "$FIX")"
order_src="$(jq -r '[.[] | select(.source=="shape-change-order")] | length' <<<"$RESULT" 2>/dev/null)"
assert_eq "T2: a shape-change-order candidate is present" "1" "$order_src"
order_has_file="$(jq -r '[.[] | select(.source=="shape-change-order") | .files_to_add[]] | index("tests/unit/order-fixture-test.sh") != null' <<<"$RESULT" 2>/dev/null)"
assert_eq "T2: candidate includes the order-fixture test" "true" "$order_has_file"

# ─── T3: non-shape plan → no order candidate ────────────────────────────────
NONSHAPE='{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"s1","description":"x","files":["plugins/agent/foo/plugin.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'
RESULT3="$(_impact_scope_prefilter "$NONSHAPE" "$FIX")"
assert_eq "T3: non-shape plan → empty prefilter" "[]" "$(printf '%s' "$RESULT3" | tr -d '[:space:]')"

# ─── T4: order test already in plan scope → not re-injected ─────────────────
PLAN_SCOPED='{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"s1","description":"reorder","files":["core/pipeline/template.sh","tests/unit/order-fixture-test.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'
RESULT4="$(_impact_scope_prefilter "$PLAN_SCOPED" "$FIX")"
in_scope_excluded="$(jq -r '[.[] | select(.source=="shape-change-order") | .files_to_add[]] | index("tests/unit/order-fixture-test.sh") == null' <<<"$RESULT4" 2>/dev/null)"
assert_eq "T4: already-scoped order test excluded from candidates" "true" "$in_scope_excluded"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
