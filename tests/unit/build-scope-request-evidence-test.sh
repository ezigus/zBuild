#!/usr/bin/env bash
# tests/unit/build-scope-request-evidence-test.sh — build asks for a file outside
# its scope only with evidence it needs it (#2252 B).
#
# Why: build turns every path in the test-failure text that is not in the plan
# into a scope request. #1844 run 36969128968 asked for three test files it had
# already fixed; #2032 run 36969130031 asked for a test that failed for an
# environment reason (#1910). Every entry carried `"evidence": ""`, the request
# was denied, and the denial routed the run back to design. Meanwhile the prompt
# tells build to say `BLOCKED: <gate> requires <file> (out of scope)` when it
# truly needs a file — and nothing read that line.
#
# E1 [change] a path named in failure text, with nothing from the text found in
#             the file, is not requested
# E2 [guard]  a path named in failure text WITH a quote found in the file still is
# E3 [change] build's own `BLOCKED: … requires <file> (out of scope)` line is a
#             request for that file, with the line as its evidence
# E4 [change] a file build reported NOT_REPRODUCED is never requested
# E7 [change] the same holds for the one answer vocabulary build is now asked
#             for: `ANSWER … : nothing to do — not reproduced: <path>` (#2322)
# E5 [guard]  a file build actually edited out of scope is still requested
# E6 [change] a BLOCKED file already in scope is not requested
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "build asks for out-of-scope files only with evidence (#2252 B)"
setup_test_env "build-scope-request-evidence"
# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

mkdir -p "$TEST_TEMP_DIR/repo/tests/unit" "$TEST_TEMP_DIR/repo/core"
printf 'assert_eq "lint names the verdict" "x" "$y"\n' > "$TEST_TEMP_DIR/repo/tests/unit/lint-test.sh"
printf 'assert_eq "order is impact" "impact" "$z"\n' > "$TEST_TEMP_DIR/repo/tests/unit/order-test.sh"
printf 'echo core\n' > "$TEST_TEMP_DIR/repo/core/x.sh"
cd "$TEST_TEMP_DIR/repo" || exit 1
PLAN="core/x.sh"
_paths() { jq -r '[.files[].path] | join(",")' <<< "${1:-{\}}" 2>/dev/null; }

print_test_section "E1/E2: failure text alone is not evidence"
FB1="FAIL tests/unit/lint-test.sh (see the earlier run)"
assert_eq "[E1] a named path with no quote found in it → no request" "" \
    "$(_build_scope_expansion_request "tests/unit/lint-test.sh" "$FB1")"
FB2="FAIL tests/unit/order-test.sh asserts 'order is impact' — update it"
assert_eq "[E2] a quote found in the file → requested" "tests/unit/order-test.sh" \
    "$(_paths "$(_build_scope_expansion_request "tests/unit/order-test.sh" "$FB2")")"

print_test_section "E3/E4/E6: build's own words"
RESP="$(printf 'Done what I can.\nBLOCKED: lint requires tests/unit/lint-test.sh (out of scope)\nBLOCKED: gate requires core/x.sh (out of scope)\nNOT_REPRODUCED: tests/unit/order-test.sh\nLOOP_COMPLETE\n')"
R3="$(_build_blocked_request "$RESP" "$PLAN")"
assert_eq "[E3] the BLOCKED file is requested" "tests/unit/lint-test.sh" "$(_paths "$R3")"
assert_contains "[E3] ...with build's line as evidence" \
    "$(jq -r '.files[0].evidence' <<< "$R3" 2>/dev/null)" "BLOCKED: lint requires tests/unit/lint-test.sh"
assert_eq "[E6] a BLOCKED file already in scope is not requested" "" \
    "$(jq -r '.files[] | select(.path=="core/x.sh") | .path' <<< "$R3" 2>/dev/null)"
RESP4="$(printf 'BLOCKED: x requires tests/unit/order-test.sh (out of scope)\nNOT_REPRODUCED: tests/unit/order-test.sh\n')"
assert_eq "[E4] a file build reported NOT_REPRODUCED is not requested" "" \
    "$(_build_blocked_request "$RESP4" "$PLAN")"
RESP7="$(printf 'BLOCKED: x requires tests/unit/order-test.sh (out of scope)\n**ANSWER test finding 1:** nothing to do — not reproduced: tests/unit/order-test.sh\n')"
assert_eq "[E7] a not-reproduced answer names the path build ran" "tests/unit/order-test.sh" \
    "$(_build_not_reproduced "$RESP7")"
assert_eq "[E7] ...and that file is not requested" "" "$(_build_blocked_request "$RESP7" "$PLAN")"

print_test_section "E5: an actual out-of-scope edit"
R5="$(_build_edited_collateral_request "" "" "tests/unit/lint-test.sh")"
assert_eq "[E5] an edited out-of-scope file is requested without a quote" "tests/unit/lint-test.sh" "$(_paths "$R5")"

cd "$REPO_ROOT" || exit 1
cleanup_test_env
print_test_results
exit $((FAIL > 0))
