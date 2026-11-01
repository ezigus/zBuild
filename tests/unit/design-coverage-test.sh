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
#   RA     an answer with no verdict is asked again once, told what was wrong
#          and shown the answer (ADR-060 §6); a failed call is not
#   R1     a call whose exit code cannot be kept is not read as covered
#          (review on PR #2393: mktemp failing left rc at 0)
#   X1     the check also looks the other way: what the design commits to that
#          the issue does not ask for, or gets wrong (#2445)
#   X2     each such item is one entry, and becomes a finding design must fix,
#          whatever the coverage verdict
#   X3     the check is shown the design's scope (#2445)
#   X4     for a SPEC marked [done], the check is shown the lines its evidence
#          points at, and asked whether that code does what the SPEC says (#2445)
#   X5     each [done] SPEC it says the code does not do is one entry, and a
#          finding
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

# ── RA: asked again, with what was wrong ────────────────────────────────────
_RA_N="$TEST_TEMP_DIR/ra-n"
route_to_model() {
    local n; n=$(( $(cat "$_RA_N") + 1 )); printf '%s' "$n" > "$_RA_N"
    printf '%s' "$2" > "$_P_FILE.$n"
    if [[ $n -eq 1 ]]; then printf 'I think it is mostly fine.\n'; else printf '%s' "$_RA_R2"; fi
}
printf '0' > "$_RA_N"; _RA_R2=$'VERDICT: covered\nREASON: fine\n'
_cov
assert_eq "[RA] asked twice" "2" "$(cat "$_RA_N")"
assert_contains "[RA] the second ask says what was wrong" "$(cat "$_P_FILE.2" 2>/dev/null)" "it has no VERDICT: line"
assert_contains "[RA] the second ask carries the first answer" "$(cat "$_P_FILE.2" 2>/dev/null)" "I think it is mostly fine."
assert_eq "[RA] the second answer is the judgement" "" "$_DESIGN_COV_OUTCOME"
printf '0' > "$_RA_N"; _RA_R2='still not sure'
_cov
assert_eq "[RA] asked twice, no more" "2" "$(cat "$_RA_N")"
assert_eq "[RA] still no verdict: unusable" "unusable" "$_DESIGN_COV_OUTCOME"
printf '0' > "$_RA_N"
route_to_model() { local n; n=$(( $(cat "$_RA_N") + 1 )); printf '%s' "$n" > "$_RA_N"; return 124; }
_cov
assert_eq "[RA] a failed call is not asked again" "1" "$(cat "$_RA_N")"

# ── R1 ───────────────────────────────────────────────────────────────────────
route_to_model() { printf 'VERDICT: covered\nREASON: fine\n'; return 1; }
mktemp() { [[ "${1:-}" == -d ]] && { command mktemp "$@"; return; }; return 1; }
_cov
unset -f mktemp
assert_eq "[R1] mktemp failed: the call is not read as covered" "broken" "$_DESIGN_COV_OUTCOME"

# ── X1–X5 (#2445) ────────────────────────────────────────────────────────────
route_to_model() { printf '%s' "$2" > "$_P_FILE"; printf '%s' "$_REPLY"; return 0; }
XR="$TEST_TEMP_DIR/xrepo"; mkdir -p "$XR/scripts"
printf 'line one\nline two\nrefuse_missing_config() { [[ -f "$1" ]] || return 2; }\nline four\n' > "$XR/scripts/cfg.sh"
DX="$TEST_TEMP_DIR/design-x.md"
cat > "$DX" <<'MD'
# Design
```acceptance
SPEC-1[code]: a --dry-run flag is accepted covers: R-1
SPEC-2[done]: a missing config is refused covers: R-2 evidence: scripts/cfg.sh:3
TESTFILES:
SPEC-1: tests/acc-test.sh
WIRING: scripts/thing.sh
```
```scope
scripts/thing.sh
scripts/telemetry.sh
```
MD
_REPLY='VERDICT: covered
REASON: ok'
ZBUILD_REPO_ROOT="$XR" _design_coverage "$DX" "$REQS" T2
_P="$(cat "$_P_FILE")"
assert_contains "[X1] the check looks the other way too" "$_P" "OUTSIDE:"
assert_contains "[X1] ...for what the design commits to that the issue does not ask for, or gets wrong" "$_P" \
    "that the issue does not ask for, or that contradicts it"
assert_contains "[X3] the check is shown the design's scope" "$_P" "scripts/telemetry.sh"
assert_contains "[X4] the check is shown the code a [done] SPEC's evidence points at" "$_P" "refuse_missing_config()"
assert_contains "[X4] ...and asked whether it does what the SPEC says" "$_P" "DONE_WRONG:"
_REPLY='VERDICT: covered
REASON: every requirement maps to a SPEC
OUTSIDE: scripts/telemetry.sh: the issue asks for no telemetry; SPEC-1: also renames the flag
DONE_WRONG: SPEC-2: the cited line returns 2 only when the file is absent, not when it is unreadable'
ZBUILD_REPO_ROOT="$XR" _design_coverage "$DX" "$REQS" T2
assert_eq "[X2] each item outside the issue is one entry, whatever the coverage verdict" "2" "${#_DESIGN_OUTSIDE[@]}"
assert_eq "[X5] each [done] SPEC the code does not do is one entry" "1" "${#_DESIGN_DONE_WRONG[@]}"
_fx="$(_design_coverage_findings)"
assert_contains "[X2] ...and a finding design must fix" "$_fx" "the issue does not ask for this, or the design gets it wrong: scripts/telemetry.sh"
assert_contains "[X5] ...and a finding too" "$_fx" "marked [done], but the code its evidence points at does not do it: SPEC-2"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
