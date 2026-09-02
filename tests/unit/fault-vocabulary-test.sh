#!/usr/bin/env bash
# tests/unit/fault-vocabulary-test.sh — a gate declares the KIND of fault it
# hit; the template maps that to a destination (#1987).
#
# A gate that found an unfixable problem wrote `route_target: design` into its
# result — a stage naming another stage, which is exactly what ADR-055
# eliminated for data (a consumer names the ARTIFACT it needs, never the
# producer). It is also wrong in general: drop that gate into a flow with no
# design stage and it names a destination that does not exist.
#
# ADR-054 §6 already solved this shape for `disposition`: "a closed set, owned
# by the engine. Each word exists only because the engine acts differently on
# it." This mirrors that file deliberately, down to the case-statement
# validator — a second shape would be a second contract.
#
#   SPEC-1 [change]: the vocabulary is a closed set of exactly the three words
#   SPEC-2 [change]: membership validates; an unknown word and the empty string
#                    are both non-members
#   SPEC-3 [change]: fault_routes distinguishes a fault that rewinds from one
#                    fixed in place — `implementation` is an explicit answer,
#                    not an absent field
#   SPEC-4 [guard] : the helper refuses to answer for a non-member rather than
#                    returning a plausible default, as disposition_response does
#   SPEC-5 [guard] : no plugin names a stage as a routing destination any more
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "fault vocabulary — stages stop naming stages (#1987)"
setup_test_env "fault-vocabulary"

# shellcheck source=../../core/pipeline/fault.sh
source "$REPO_ROOT/core/pipeline/fault.sh" 2>/dev/null || true

# ─── SPEC-1: the closed set ──────────────────────────────────────────────────
print_test_section "1. the vocabulary is a closed set"

if declare -F fault_vocabulary >/dev/null 2>&1; then
    assert_eq "[SPEC-1] exactly the three declared words, in table order" \
        "specification scope implementation" "$(fault_vocabulary)"
else
    assert_fail "[SPEC-1] fault_vocabulary exists" "function not defined"
fi

# ─── SPEC-2: membership ──────────────────────────────────────────────────────
print_test_section "2. membership validates, and absence is not a member"

if declare -F fault_is_valid >/dev/null 2>&1; then
    for _w in specification scope implementation; do
        if fault_is_valid "$_w"; then
            assert_pass "[SPEC-2] '$_w' is a member"
        else
            assert_fail "[SPEC-2] '$_w' is a member" "rejected"
        fi
    done
    # `environment` is deliberately NOT a fault: disposition already owns "was
    # this the work's fault?" via interrupted/throttled/unavailable/broken, and
    # negctl_error/reachability_error already map to disposition: advisory. Two
    # vocabularies answering one question is how #1767 happened.
    for _w in environment input design route_design ""; do
        if fault_is_valid "$_w"; then
            assert_fail "[SPEC-2] '${_w:-<empty>}' is NOT a member" "accepted"
        else
            assert_pass "[SPEC-2] '${_w:-<empty>}' is NOT a member"
        fi
    done
else
    assert_fail "[SPEC-2] fault_is_valid exists" "function not defined"
fi

# ─── SPEC-3: rewind vs fix-in-place ──────────────────────────────────────────
# "I decided this is local" and "I never thought about it" must be
# distinguishable — that ambiguity is what #1767 is filed about.
print_test_section "3. a fault says whether the work rewinds or is fixed here"

if declare -F fault_routes >/dev/null 2>&1; then
    for _w in specification scope; do
        if fault_routes "$_w"; then
            assert_pass "[SPEC-3] '$_w' rewinds"
        else
            assert_fail "[SPEC-3] '$_w' rewinds" "reported as fixed in place"
        fi
    done
    if fault_routes implementation; then
        assert_fail "[SPEC-3] 'implementation' is fixed in place" "reported as rewinding"
    else
        assert_pass "[SPEC-3] 'implementation' is fixed in place"
    fi
else
    assert_fail "[SPEC-3] fault_routes exists" "function not defined"
fi

# ─── SPEC-4: refuse, do not guess ────────────────────────────────────────────
# disposition_halts returns rc 2 for a non-member because "I cannot answer" is
# not "it does not halt". Same discipline here: a caller asking about `wedged`
# has already failed structurally, and a plausible default would bury that.
print_test_section "4. a non-member is refused, not defaulted"

if declare -F fault_routes >/dev/null 2>&1; then
    fault_routes wedged; _rc=$?
    assert_eq "[SPEC-4] an unknown word returns 'cannot answer' (rc 2)" "2" "$_rc"
    fault_routes ""; _rc2=$?
    assert_eq "[SPEC-4] the empty string likewise" "2" "$_rc2"
fi

# ─── SPEC-5: no plugin names a stage ─────────────────────────────────────────
print_test_section "5. no plugin names a routing destination"

_offenders="$(grep -rlE '^[[:space:]]*(local[[:space:]]+)?route_target=' \
    "$REPO_ROOT/plugins" 2>/dev/null || true)"
assert_eq "[SPEC-5] no plugin still writes route_target" "" "$_offenders"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
