#!/usr/bin/env bash
# tests/unit/design-status-check-test.sh — design's check judges every
# requirement's status from three facts it quotes, and the stage derives the
# status the facts give (ADR-072, ADR-069, amended 2026-11-14, #2543).
#
# Why: on #1700 run 43617030653 DSPRB-2 was marked [code] though the old code
# already met it, and DSBUD-1 [no-code] though it needed no work: test-author
# lost all three rounds on them. The check asked about a status only for a
# [done] requirement (done_wrong); a wrong [code], [no-code] or [doc] went by.
#
# S1 [change] the check is told the three facts and the status each gives, and
#             answers in one form: status | DOC | BEFORE | WORK | WHY  | ACCEPTED IF: it is accepted| QUOTE;
#             done_wrong is gone
# S2 [change] it is told where the code from before the change is, with no
#             [done] requirement in the design
# S3 [change] [code] that the old code already does, with no work left → a
#             finding that says it is [done]
# S4 [change] [no-code] that the old code does not do → [code]
# S5 [change] [code] that is a document only → [doc]
# S6 [change] [no-code] the old code already does, with no work left → [done]
# S7 [change] [done] the old code does not do → [code]
# S8 [change] [code] with facts that give [no-code] (already, work left) → [no-code]
# S9 [change] facts that give the SPEC's own status make the answer unusable
# S10 [change] a fact that is not yes or no makes the answer unusable
# S11 [guard]  a quote that is not in the code makes the answer unusable
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "design's check judges each requirement's status from three facts (#2543)"
setup_test_env "design-status-check"

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

_P_FILE="$TEST_TEMP_DIR/prompt.txt"
route_to_model() { printf '%s' "$2" > "$_P_FILE"; printf '%s' "$_REPLY"; return 0; }

# The repository as it is now, and the copy of it from before the change.
XR="$TEST_TEMP_DIR/repo"; BASE="$TEST_TEMP_DIR/base"
mkdir -p "$XR/scripts" "$XR/docs" "$BASE/scripts" "$BASE/docs"
printf 'mode_of() { stat -f %%Lp "$1" 2>/dev/null || stat -c %%a "$1"; }\n' > "$BASE/scripts/x.sh"
cp "$BASE/scripts/x.sh" "$XR/scripts/x.sh"
printf '# Guide\nThe probe runs once at load.\n' > "$XR/docs/guide.md"
printf '# Guide\n' > "$BASE/docs/guide.md"
export _DESIGN_BASE_DIR="$BASE"

D="$TEST_TEMP_DIR/design.md"
cat > "$D" <<'MD'
# Design
```acceptance
MODE-1[code]: the mode check returns a valid mode when the platform setting is wrong covers: RQST-1
  When: the mode check runs with the platform setting wrong for the host
  Then: it returns a valid octal mode
MODE-2[no-code]: the fork budget test still passes covers: RQST-2
MODE-3[done]: the mode check runs stat once covers: RQST-1 evidence: scripts/x.sh | mode_of()
  When: the mode check runs on an existing file
  Then: exactly one stat runs
WIRING: none
```
MD
REQS='- RQST-1: the mode check works with a wrong platform setting
- RQST-2: the fork budget test still passes'
QOLD='scripts/x.sh | mode_of() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }'
_ok='RQST-1: covered
RQST-2: covered
MODE-1: ok
MODE-2: ok
MODE-3: ok'
_reply_with() {   # <SPEC id> <its line> — every other item ok
    local id="$1" line="$2" l out=""
    while IFS= read -r l; do
        if [[ "$l" == "$id: ok" ]]; then out+="$line"$'\n'; else out+="$l"$'\n'; fi
    done <<< "$_ok"
    printf '%s' "$out"
}
_run() { _REPLY="$1"; ZBUILD_REPO_ROOT="$XR" _design_coverage "$D" "$REQS" T2; FX="$(_design_coverage_findings)"; }

print_test_section "S1/S2: what the check is told"
_run "$_ok"
_P="$(tr -s '[:space:]' ' ' < "$_P_FILE")"
assert_contains "[S1] the facts: is it a document" "$_P" "Is it a change to a document only? Then it is [doc]."
assert_contains "[S1] ...does the old code already behave so, a fallback included" "$_P" "does the code from before this change already behave as the SPEC says — by any route, a fallback included? If not, it is [code]."
assert_contains "[S1] ...is work still needed" "$_P" "is work still needed that changes no behaviour — a test, a config, a refactor? Then it is [no-code]; if none, it is [done]."
assert_contains_lines "[S1] the answer's form" "$_P" $'<SPEC id> Title: status\ndoc: <yes or no>\nbefore: <yes or no>\nwork: <yes or no>\nwhy: <what shows it>\naccepted if: <the status the SPEC must have, and what shows it>\nquote: <file> | <one line of it>'
if [[ "$_P" == *done_wrong* ]]; then assert_fail "[S1] done_wrong is gone" "the prompt still asks for done_wrong"
else assert_pass "[S1] done_wrong is gone"; fi
D2="$TEST_TEMP_DIR/design-nodone.md"
sed '/MODE-3/,/exactly one stat/d' "$D" > "$D2"
_REPLY=$'RQST-1: covered\nRQST-2: covered\nMODE-1: ok\nMODE-2: ok'
ZBUILD_REPO_ROOT="$XR" _design_coverage "$D2" "$REQS" T2
assert_contains "[S2] told where the code from before the change is, with no [done] SPEC" \
    "$(tr -s '[:space:]' ' ' < "$_P_FILE")" "The code from before this change is a copy at $BASE"

print_test_section "S3–S8: the status the facts give"
_run "$(_reply_with MODE-1 "MODE-1 Title: status | DOC: no | BEFORE: yes | WORK: no | WHY: its fallback already returns a valid mode | ACCEPTED IF: it is accepted | QUOTE: $QOLD")"
assert_eq "[S3] [code] the old code already does: one entry" "1" "${#_DESIGN_STATUS_WRONG[@]}"
assert_contains "[S3] ...the finding says it is [done]" "$FX" "it is [done], not [code]"
assert_contains "[S3] ...with what shows it" "$FX" "its fallback already returns a valid mode"

_run "$(_reply_with MODE-2 "MODE-2 Title: status | DOC: no | BEFORE: no | WORK: yes | WHY: nothing counts stat calls yet | ACCEPTED IF: it is accepted | QUOTE: $QOLD")"
assert_contains "[S4] [no-code] the old code does not do → [code]" "$FX" "it is [code], not [no-code]"

_run "$(_reply_with MODE-1 "MODE-1 Title: status | DOC: yes | BEFORE: no | WORK: yes | WHY: it is the guide's sentence | ACCEPTED IF: it is accepted | QUOTE: docs/guide.md | The probe runs once at load.")"
assert_contains "[S5] [code] that is a document only → [doc]" "$FX" "it is [doc], not [code]"

_run "$(_reply_with MODE-2 "MODE-2 Title: status | DOC: no | BEFORE: yes | WORK: no | WHY: the budget test passes on the old code and nothing needs doing | ACCEPTED IF: it is accepted | QUOTE: $QOLD")"
assert_contains "[S6] [no-code] already true, no work → [done]" "$FX" "it is [done], not [no-code]"

_run "$(_reply_with MODE-3 "MODE-3 Title: status | DOC: no | BEFORE: no | WORK: yes | WHY: it runs stat twice when the first form fails | ACCEPTED IF: it is accepted | QUOTE: $QOLD")"
assert_contains "[S7] [done] the old code does not do → [code]" "$FX" "it is [code], not [done]"

_run "$(_reply_with MODE-1 "MODE-1 Title: status | DOC: no | BEFORE: yes | WORK: yes | WHY: it already behaves so; only a refactor is asked | ACCEPTED IF: it is accepted | QUOTE: $QOLD")"
assert_contains "[S8] [code] already behaving so, work left → [no-code]" "$FX" "it is [no-code], not [code]"

print_test_section "S9–S11: answers that cannot be used"
_run "$(_reply_with MODE-1 "MODE-1 Title: status | DOC: no | BEFORE: no | WORK: yes | WHY: it needs code | ACCEPTED IF: it is accepted | QUOTE: $QOLD")"
assert_eq "[S9] facts that give the SPEC's own status: unusable" "unusable" "$_DESIGN_COV_OUTCOME"
_run "$(_reply_with MODE-1 "MODE-1 Title: status | DOC: no | BEFORE: maybe | WORK: no | WHY: unsure | ACCEPTED IF: it is accepted | QUOTE: $QOLD")"
assert_eq "[S10] a fact that is not yes or no: unusable" "unusable" "$_DESIGN_COV_OUTCOME"
_run "$(_reply_with MODE-1 "MODE-1 Title: status | DOC: no | BEFORE: yes | WORK: no | WHY: it does | ACCEPTED IF: it is accepted | QUOTE: scripts/x.sh | no such line here")"
assert_eq "[S11] a quote not in the code: unusable" "unusable" "$_DESIGN_COV_OUTCOME"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
