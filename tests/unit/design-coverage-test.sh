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
#   SPEC-4 the prompt carries the requirements and the SPECs, and does not read
#          the issue from a file by name
#   I1     the prompt carries the issue's own words, found among the stage's
#          inputs by what they are (ADR-070 §4); with no issue it claims none
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
#   X3     the check is not shown the design's scope to judge: a design that goes
#          beyond the issue shows as an outside SPEC (ADR-070 §4, #2495)
#   X4     for a SPEC marked [done], the check is pointed at the file its
#          evidence names, and asked whether that code does what the SPEC says
#          (#2445; #2464: it opens the file itself — no window of lines)
#   X5     each [done] SPEC it says the code does not do is one entry, and a
#          finding
#   NS1    the check is asked for no verdict on a scope entry (#2495): on #1805
#          run 42439063480 a scope line whose own reason said "raises no concern"
#          failed design
#   NS2    a reply with no scope lines is complete: judged in one call
#   NS3    a scope line in a reply is no finding
#
# #2464 (ADR-072 §3): the check answers one line per requirement and per SPEC,
# each complaint quoted; tests/unit/judge-quotes-test.sh covers the form.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "design's coverage call: does the design cover the ISSUE? (#1683, #2369)"
setup_test_env "design-coverage"

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

assert_not_contains() {
    if grep -qF -- "$3" <<< "$2" 2>/dev/null; then assert_fail "$1" "output unexpectedly has: $3"; else assert_pass "$1"; fi
}

# Mocks AFTER the source: the plugin sources core/router/route.sh at file scope.
_P_FILE="$TEST_TEMP_DIR/prompt.txt"
_REPLY='RQST-1: covered
RQST-2: covered
WORK-1: ok'
route_to_model() { printf '%s' "$2" > "$_P_FILE"; printf '%s' "$_REPLY"; return 0; }

D="$TEST_TEMP_DIR/design.md"
cat > "$D" <<'MD'
# Design
```acceptance
WORK-1[code]: a --dry-run flag is accepted covers: RQST-1
TESTFILES:
WORK-1: tests/acc-test.sh
WIRING: scripts/thing.sh
```
MD
REQS='- RQST-1: add a --dry-run flag
- RQST-2: refuse a missing config'
_cov() { _design_coverage "$D" "$REQS" T2; }

# ── SPEC-2 / SPEC-4 ──────────────────────────────────────────────────────────
_cov
assert_eq "[SPEC-2] a covering design has nothing uncovered" "0" "${#_DESIGN_UNCOVERED[@]}"
assert_eq "[SPEC-2] ...and the call judged it" "" "$_DESIGN_COV_OUTCOME"
_P="$(cat "$_P_FILE")"
assert_contains "[SPEC-4] the prompt carries the requirements" "$_P" "RQST-2: refuse a missing config"
assert_contains "[SPEC-4] ...and the SPECs" "$_P" "a --dry-run flag is accepted"
_i1_none=1; [[ "$_P" == *"The issue itself"* ]] && _i1_none=0
assert_eq "[I1] with no issue among the inputs, the prompt claims none" "1" "$_i1_none"
assert_eq "[SPEC-4] the coverage call reads no other stage's output by name" "0" \
    "$(grep -c 'intake' "$REPO_ROOT/plugins/agent/design/lib/coverage.sh" || true)"

# ── I1 ───────────────────────────────────────────────────────────────────────
# ADR-070 §4: the check judges the list beside the issue's own words. On #1805
# run 42340358110 its prompt said the issue was "under Previous work", where it
# was not; the judge read "Tests for R1–R5" without the issue, took R1–R5 for
# the ids that looked like it, and refused a SPEC that covered R3 and R4.
_I1="$TEST_TEMP_DIR/i1"; mkdir -p "$_I1"
zb_test_issue_output "$_I1" $'## Required behavior\n- **R3.** `--from-stage <s>` dispatches `<s>` first.' >/dev/null
jq -n --arg i "$_I1/intake-result.json" '{inputs: {a: $i}}' > "$_I1/stage-inputs.json"
ZBUILD_STAGE_INPUTS="$_I1/stage-inputs.json" _cov
_P="$(cat "$_P_FILE")"
assert_contains "[I1] the prompt carries the issue's own words" "$_P" "- **R3.** \`--from-stage <s>\` dispatches \`<s>\` first."
assert_contains "[I1] ...and says that is the issue" "$_P" "ISSUE — the issue itself, in the requester's own words:"

# ── SPEC-1 / E3 ──────────────────────────────────────────────────────────────
REQS3="$REQS"'
- RQST-3: B
- RQST-4: C'
_REPLY='RQST-1: covered
RQST-2: uncovered | WHY: no SPEC refuses it | QUOTE: "refuse a missing config"
RQST-3: uncovered | WHY: nothing covers B | QUOTE: "B"
RQST-4: uncovered | WHY: nothing covers C | QUOTE: "C"
WORK-1: ok'
_design_coverage "$D" "$REQS3" T2
assert_eq "[SPEC-1][E3] each uncovered requirement is one entry" "3" "${#_DESIGN_UNCOVERED[@]}"
assert_contains "[SPEC-1] the entry names the requirement and its words" "${_DESIGN_UNCOVERED[0]:-}" 'RQST-2: no SPEC refuses it — "refuse a missing config"'

# ── SPEC-7 / SPEC-8 / SPEC-9 / E1 / E2: the prompt ───────────────────────────
_PS="$(tr -s '[:space:]' ' ' <<< "$_P")"
assert_contains "[SPEC-7] behaviour, not how the change is verified" "$_PS" \
    "your part of each requirement is the BEHAVIOUR it asks of the software"
assert_contains "[SPEC-7] ...such a requirement is not uncovered" "$_PS" \
    "the check that compares the finished change with the issue judges it there. It is not uncovered"
assert_contains "[SPEC-8] a narrower SPEC leaves the requirement uncovered" "$_P" "demands less than the requirement"
assert_contains "[SPEC-8] ...naming the ways a SPEC narrows" "$_P" "a subset of the cases"
assert_contains "[SPEC-9] an already-done SPEC covers its requirement" "$_PS" \
    "A SPEC tagged [done] says the code already does it. A requirement it covers counts as covered"
assert_contains "[J1] several SPECs may cover one requirement together" "$_PS" \
    "Several SPECs may cover one requirement together"
assert_contains "[J1] ...judged together" "$_PS" "judge every SPEC that names it, together"
assert_contains "[E1] it asks for EVERY uncovered requirement" "$_P" "EVERY requirement"
assert_contains "[E1] ...not only the first found" "$_PS" "not only the first"
assert_contains "[E1] ...because the next round fixes only what is listed" "$_PS" "only what you list"
assert_eq "[E2] the answer is not capped at three lines" "0" "$(grep -c 'at most three lines' <<< "$_P" || true)"

# ── #2032: a failed call is classified ───────────────────────────────────────
route_to_model() { return 124; }
_cov
assert_eq "[#2032] rc=124 → timed_out" "timed_out" "$_DESIGN_COV_OUTCOME"
route_to_model() { return 1; }
_cov
assert_eq "[#2032] any other non-zero rc → unavailable" "unavailable" "$_DESIGN_COV_OUTCOME"
route_to_model() { printf '%s' "$_REPLY"; return 124; }
_cov
assert_eq "[#2032] a verdict printed and then a timeout is still a timeout" "timed_out" "$_DESIGN_COV_OUTCOME"

# ── #2366 ───────────────────────────────────────────────────────────────────
route_to_model() { printf 'I think it is mostly fine.\n'; return 0; }
_cov
assert_eq "[#2366] an answer with no line for any item is unusable" "unusable" "$_DESIGN_COV_OUTCOME"

# ── RA: asked again, with what was wrong ────────────────────────────────────
_RA_N="$TEST_TEMP_DIR/ra-n"
route_to_model() {
    local n; n=$(( $(cat "$_RA_N") + 1 )); printf '%s' "$n" > "$_RA_N"
    printf '%s' "$2" > "$_P_FILE.$n"
    if [[ $n -eq 1 ]]; then printf 'I think it is mostly fine.\n'; else printf '%s' "$_RA_R2"; fi
}
printf '0' > "$_RA_N"; _RA_R2=$'RQST-1: covered\nRQST-2: covered\nWORK-1: ok\n'
_cov
assert_eq "[RA] asked twice" "2" "$(cat "$_RA_N")"
assert_contains "[RA] the second ask says what was wrong" "$(cat "$_P_FILE.2" 2>/dev/null)" "it has no line for RQST-1 RQST-2 WORK-1"
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
route_to_model() { printf '%s' "$_REPLY"; return 1; }
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
WORK-1[code]: a --dry-run flag is accepted covers: RQST-1
CNFG-1[done]: a missing config is refused covers: RQST-2 evidence: scripts/cfg.sh:"refuse_missing_config()"
TESTFILES:
WORK-1: tests/acc-test.sh
WIRING: scripts/thing.sh
```
```scope
scripts/thing.sh
scripts/telemetry.sh
```
MD
_REPLY='RQST-1: covered
RQST-2: covered
WORK-1: ok
CNFG-1: ok'
ZBUILD_REPO_ROOT="$XR" _design_coverage "$DX" "$REQS" T2
_P="$(tr -s '[:space:]' ' ' < "$_P_FILE")"
assert_contains "[X1] the check looks the other way too" "$_P" "<SPEC id>: outside"
assert_contains "[X1] ...for what the design commits to that the issue does not ask for, or gets wrong" "$_P" \
    "that the issue does not ask for, or that contradicts it"
assert_not_contains "[X3] the check is not shown the design's scope" "$_P" "scripts/telemetry.sh"
assert_contains "[X4] the check is pointed at the file a [done] SPEC's evidence names" "$_P" 'CNFG-1: scripts/cfg.sh:"refuse_missing_config()" — open'
assert_contains "[X4] ...and asked whether it does what the SPEC says" "$_P" "<SPEC id>: done_wrong"
_REPLY='RQST-1: covered
RQST-2: covered
WORK-1: outside | WHY: also renames the flag | QUOTE: "a --dry-run flag is accepted"
CNFG-1: done_wrong | WHY: it returns 2 only when the file is absent, not when it is unreadable | QUOTE: scripts/cfg.sh:"[[ -f "$1" ]] || return 2"'
ZBUILD_REPO_ROOT="$XR" _design_coverage "$DX" "$REQS" T2
assert_eq "[X2] each item outside the issue is one entry, whatever the coverage verdict" "1" "${#_DESIGN_OUTSIDE[@]}"
assert_eq "[X5] each [done] SPEC the code does not do is one entry" "1" "${#_DESIGN_DONE_WRONG[@]}"
_fx="$(_design_coverage_findings)"
# #2470 (ADR-073 §5): the line to fix is marked with what to do.
assert_contains "[X2] ...the SPEC's own line marked" "$_fx" "WORK-1[code]: a --dry-run flag is accepted covers: RQST-1 [FIX IN DESIGN: also renames the flag — the issue does not ask for this"
assert_contains "[X5] ...and a finding too" "$_fx" "CNFG-1: 1 part to fix"
assert_contains "[X5] ...its line marked with what the code does" "$_fx" "[FIX IN DESIGN: it returns 2 only when the file is absent, not when it is unreadable: scripts/cfg.sh:"

# ── NS1–NS3 (#2495, ADR-070 §4) ─────────────────────────────────────────────
printf '0' > "$_RA_N"
route_to_model() { local n; n=$(( $(cat "$_RA_N") + 1 )); printf '%s' "$n" > "$_RA_N"; printf '%s' "$2" > "$_P_FILE.$n"; printf '%s' "$_REPLY"; }
_REPLY='RQST-1: covered
RQST-2: covered
WORK-1: ok
CNFG-1: ok'
ZBUILD_REPO_ROOT="$XR" _design_coverage "$DX" "$REQS" T2
_P="$(tr -s '[:space:]' ' ' < "$_P_FILE.1")"
assert_not_contains "[NS1] the check is asked for no verdict on a scope entry" "$_P" "scope entry"
assert_not_contains "[NS1] ...and no SCOPE line" "$_P" "SCOPE:"
assert_eq "[NS2] a reply with no scope lines is complete, judged in one call" "|1|0" \
    "$_DESIGN_COV_OUTCOME|$(cat "$_RA_N")|${#_DESIGN_OUTSIDE[@]}"
printf '0' > "$_RA_N"
_REPLY='RQST-1: covered
RQST-2: covered
WORK-1: ok
CNFG-1: ok
SCOPE: scripts/telemetry.sh | WHY: this entry is consistent with the issue and raises no concern
SCOPE: scripts/telemetry.sh: outside | WHY: the issue asks for no telemetry'
ZBUILD_REPO_ROOT="$XR" _design_coverage "$DX" "$REQS" T2
assert_eq "[NS3] a scope line in a reply is no finding" "|0|" \
    "$_DESIGN_COV_OUTCOME|${#_DESIGN_OUTSIDE[@]}|$(_design_coverage_findings)"
route_to_model() { printf '%s' "$2" > "$_P_FILE"; printf '%s' "$_REPLY"; return 0; }

cleanup_test_env
print_test_results
exit $((FAIL > 0))
