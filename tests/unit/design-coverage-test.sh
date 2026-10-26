#!/usr/bin/env bash
# tests/unit/design-coverage-test.sh — design's second model call: do the SPECs
# cover what the ISSUE asked for? (#1683; #2369 moved it from the spec-coverage
# stage into design, ADR-040 §5.)
#
# Design is the single reader of the issue, so a design that under-scopes it
# produces a contract everything downstream satisfies perfectly. Its standard is
# the issue, which design cannot re-author, so the only way to pass is to cover
# it. The issue reaches the call under Previous work; the call reads no other
# stage's output.
#
#   SPEC-1 an uncovered requirement is named, one entry per requirement
#   SPEC-2 a covering design has nothing uncovered
#   SPEC-4 the prompt carries the requirements and the SPECs, says the issue is
#          under Previous work, and does not read the issue from a file
#   SPEC-7 how-the-change-is-verified requirements are not gaps (#2176)
#   SPEC-8 a SPEC that demands less than its requirement does not cover it (#1849)
#   SPEC-9 an already-done SPEC covers its requirement (#2304, ADR-069 §7)
#   J1     several SPECs that name one requirement are judged together (#1801
#          run 40351795413: one SPEC per requirement pushed design to join
#          several claims into one SPEC, which test-author's check then called
#          partial)
#   E1/E2  every gap in one answer, not capped (#2245); E3 three gaps travel
#   #2032  a failed call is classified, even after a verdict was printed
#   #2366  an answer with no verdict is unusable
#   R1     a call whose exit code cannot be kept is not read as covered
#          (review on PR #2393: mktemp failing left rc at 0)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "design's coverage call: does the design cover the ISSUE? (#1683, #2369)"
setup_test_env "design-coverage"

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

# Mocks AFTER the source: the plugin sources core/router/route.sh at file scope.
_P_FILE="$TEST_TEMP_DIR/prompt.txt"
_REPLY='VERDICT: covered
REASON: every requirement maps to a SPEC'
route_to_model() { printf '%s' "$2" > "$_P_FILE"; printf '%s' "$_REPLY"; return 0; }

D="$TEST_TEMP_DIR/design.md"
cat > "$D" <<'MD'
# Design
```acceptance
SPEC-1[code]: a --dry-run flag is accepted covers: R-1
TESTFILES:
SPEC-1: tests/acc-test.sh
WIRING: scripts/thing.sh
```
MD
REQS='- R-1: add a --dry-run flag
- R-2: refuse a missing config'
_cov() { _design_coverage "$D" "$REQS" T2; }

# ── SPEC-2 / SPEC-4 ──────────────────────────────────────────────────────────
_cov
assert_eq "[SPEC-2] a covering design has nothing uncovered" "0" "${#_DESIGN_UNCOVERED[@]}"
assert_eq "[SPEC-2] ...and the call judged it" "" "$_DESIGN_COV_OUTCOME"
_P="$(cat "$_P_FILE")"
assert_contains "[SPEC-4] the prompt carries the requirements" "$_P" "R-2: refuse a missing config"
assert_contains "[SPEC-4] ...and the SPECs" "$_P" "a --dry-run flag is accepted"
assert_contains "[SPEC-4] ...and says where the issue is" "$_P" "The issue itself, in the requester's own words, is under Previous work."
assert_eq "[SPEC-4] the coverage call reads no other stage's output by name" "0" \
    "$(grep -c 'intake' "$REPO_ROOT/plugins/agent/design/lib/coverage.sh" || true)"

# ── SPEC-1 / E3 ──────────────────────────────────────────────────────────────
_REPLY='VERDICT: uncovered
REASON: three requirements have no SPEC
UNCOVERED: R-2: refuse a missing config; R-3: B; R-4: C'
_cov
assert_eq "[SPEC-1][E3] each uncovered requirement is one entry" "3" "${#_DESIGN_UNCOVERED[@]}"
assert_eq "[SPEC-1] the entry names the requirement" "R-2: refuse a missing config" "${_DESIGN_UNCOVERED[0]:-}"

# ── SPEC-7 / SPEC-8 / SPEC-9 / E1 / E2: the prompt ───────────────────────────
_PS="$(tr -s '[:space:]' ' ' <<< "$_P")"
assert_contains "[SPEC-7] behaviour, not how the change is verified" "$_PS" \
    "your part of each requirement is the BEHAVIOUR it asks of the software"
assert_contains "[SPEC-7] ...such a requirement does not go in UNCOVERED" "$_PS" \
    "the check that compares the finished change with the issue judges it there. It does not go in UNCOVERED"
assert_contains "[SPEC-8] a narrower SPEC leaves the requirement uncovered" "$_P" "demands less than the requirement"
assert_contains "[SPEC-8] ...naming the ways a SPEC narrows" "$_P" "a subset of the cases"
assert_contains "[SPEC-9] an already-done SPEC covers its requirement" "$_PS" \
    "A SPEC tagged [done] says the code already does it. A requirement it covers counts as covered"
assert_contains "[J1] several SPECs may cover one requirement together" "$_PS" \
    "Several SPECs may cover one requirement together"
assert_contains "[J1] ...judged together" "$_PS" "judge every SPEC that names it, together"
assert_contains "[E1] it asks for EVERY uncovered requirement" "$_P" "EVERY requirement"
assert_contains "[E1] ...not only the first found" "$_P" "not only the first"
assert_contains "[E1] ...because the next round fixes only what is listed" "$_P" "only what you list"
assert_eq "[E2] the answer is not capped at three lines" "0" "$(grep -c 'at most three lines' <<< "$_P" || true)"

# ── #2032: a failed call is classified ───────────────────────────────────────
route_to_model() { return 124; }
_cov
assert_eq "[#2032] rc=124 → timed_out" "timed_out" "$_DESIGN_COV_OUTCOME"
route_to_model() { return 1; }
_cov
assert_eq "[#2032] any other non-zero rc → unavailable" "unavailable" "$_DESIGN_COV_OUTCOME"
route_to_model() { printf 'VERDICT: covered\nREASON: fine\n'; return 124; }
_cov
assert_eq "[#2032] a verdict printed and then a timeout is still a timeout" "timed_out" "$_DESIGN_COV_OUTCOME"

# ── #2366 ───────────────────────────────────────────────────────────────────
route_to_model() { printf 'I think it is mostly fine.\n'; return 0; }
_cov
assert_eq "[#2366] an answer with no verdict is unusable" "unusable" "$_DESIGN_COV_OUTCOME"

# ── R1 ───────────────────────────────────────────────────────────────────────
route_to_model() { printf 'VERDICT: covered\nREASON: fine\n'; return 1; }
mktemp() { [[ "${1:-}" == -d ]] && { command mktemp "$@"; return; }; return 1; }
_cov
unset -f mktemp
assert_eq "[R1] mktemp failed: the call is not read as covered" "broken" "$_DESIGN_COV_OUTCOME"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
