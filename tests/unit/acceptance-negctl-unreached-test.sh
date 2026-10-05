#!/usr/bin/env bash
# tests/unit/acceptance-negctl-unreached-test.sh — an assertion that never ran
# is "not measured", never "failed".
#
# Why: #1835 run 20260929132254-2135. The gate runs the branch's testfile
# against the pre-change code. An earlier step in the file called a function
# that does not exist yet, bare under `set -e`, so the file exited there — every
# assertion after that point never ran, and the gate read "no verdict" as "it
# fails at the merge-base". The rule: an assertion that did not print its OWN
# verdict was not measured. When the file printed verdicts for OTHER SPECs of
# this contract and none for this one, it stopped before this assertion ran.
#
# (The [guard] cases — U1, U3–U7 — went with [guard], #2304 / ADR-069: a done
# requirement is not run at all.)
#
# U2 [guard]  a [code] SPEC that printed ✗ before the file stopped is still a
#             valid control
# U8 [change] a [code] SPEC the file never reached at the merge-base is
#             `unreached_at_base` — its negative control is unproven, not valid
# U9 [change] a [code] SPEC the file never reached on the NEW code is
#             `unreached_at_head` — never a fault class
# U10 [change] a command missing at the merge-base (rc 127) inside a file that
#             printed other verdicts is unreached, not "the runner could not
#             execute the file"
# U11 [guard]  _negctl_last_other_verdict reads the contract's own tag shape:
#             bare and issue-prefixed tags, another issue's tags ignored, this
#             SPEC's own lines ignored, colour codes stripped, the LAST one wins,
#             nothing found in an empty or verdict-free log (review #2235)
# U12 [guard]  the whole gate on a contract whose ONLY finding is
#             unreached_at_base: no fault class, and the numbered finding says
#             the test never ran on the old code (review #2235 round 3)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-negctl.sh
source "$REPO_ROOT/scripts/lib/acceptance-negctl.sh"

print_test_header "acceptance negctl — an assertion that never ran is not a failure"
setup_test_env "acceptance-negctl-unreached"
unset ZBUILD_ISSUE 2>/dev/null || true

GIT="$(command -v git)"
REPO="$(setup_git_temp_repo negctl-unreached-repo)"   # main @ seed = baseline

(
    cd "$REPO" || exit 1
    "$GIT" checkout -q -b feature
    mkdir -p tests
    # HEAD's implementation adds the function the baseline lacks.
    printf '#!/usr/bin/env bash\nnew_feature() { return 0; }\nhalf_done() { return 1; }\n' > impl.sh
    # One contract file: an already-done line, a [code] check, a bare call that
    # exits the file at the baseline, and a second [code] check after it.
    cat > tests/contract-test.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
# shellcheck disable=SC1090
[[ -f "$impl" ]] && source "$impl"
echo "  ✓ [SPEC-1] an existing behaviour still holds"
if declare -F new_feature >/dev/null; then echo "  ✓ [SPEC-2] the new feature exists"; else echo "  ✗ [SPEC-2] the new feature exists"; fi
# The #1835 shape: a call that exists at the baseline but returns 1 there,
# bare under set -e (a missing command would be rc 127 — the runner's own code).
declare -F new_feature >/dev/null
echo "  ✓ [SPEC-3] precedence still holds"
if declare -F new_feature >/dev/null; then echo "  ✓ [SPEC-6] a second new thing"; else echo "  ✗ [SPEC-6] a second new thing"; fi
EOF
    # U9: on the NEW code a step fails before SPEC-8's assertion.
    cat > tests/head-test.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
# shellcheck disable=SC1090
[[ -f "$impl" ]] && source "$impl"
if [[ -f "$impl" ]]; then echo "  ✓ [SPEC-7] impl exists"; else echo "  ✗ [SPEC-7] impl exists"; fi
if [[ -f "$impl" ]]; then half_done; fi
if declare -F new_feature >/dev/null; then echo "  ✓ [SPEC-8] feature works"; else echo "  ✗ [SPEC-8] feature works"; fi
EOF
    # U10: a command that does not exist yet at the merge-base (rc 127).
    cat > tests/missing-cmd-test.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
# shellcheck disable=SC1090
[[ -f "$impl" ]] && source "$impl"
echo "  ✓ [SPEC-9] an existing behaviour"
new_feature
echo "  ✓ [SPEC-10] the new feature runs"
EOF
    chmod +x tests/*.sh impl.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: new_feature + contract tests"
)
DM="$REPO/design.md"
cat > "$DM" <<'EOF'
```acceptance
SPEC-1[done]: an existing behaviour still holds evidence: impl.sh
SPEC-2[code]: the new feature exists
SPEC-3[done]: precedence still holds evidence: impl.sh
SPEC-6[code]: a second new thing
SPEC-7[code]: impl exists
SPEC-8[code]: feature works
SPEC-9[done]: an existing behaviour evidence: impl.sh
SPEC-10[code]: the new feature runs
TESTFILES:
SPEC-1: tests/contract-test.sh
SPEC-2: tests/contract-test.sh
SPEC-3: tests/contract-test.sh
SPEC-6: tests/contract-test.sh
SPEC-7: tests/head-test.sh
SPEC-8: tests/head-test.sh
SPEC-9: tests/missing-cmd-test.sh
SPEC-10: tests/missing-cmd-test.sh
```
EOF

print_test_section "U2: a [code] SPEC with its own verdict"
OUT="$(ZBUILD_NEGCTL_TIMEOUT=60 acceptance_negctl_check "$DM" "$REPO" 2>/dev/null || true)"
assert_eq "[U2] a [code] SPEC that printed ✗ is still a valid control" \
    "NEGCTL PASS SPEC-2" "$(grep -E '^[A-Z]+ [A-Z]+ SPEC-2( |$)' <<< "$OUT" || true)"

print_test_section "U8–U10: [change] SPECs and missing commands"
_sel() { grep -E "^[A-Z]+ [A-Z]+ $1( |\$)" <<< "$OUT" || true; }
assert_eq "[U8] a [change] never reached at the merge-base → unreached_at_base, not a valid control" \
    "NEGCTL FAIL SPEC-6 unreached_at_base after=SPEC-2" "$(_sel SPEC-6)"
assert_eq "[U9] a [change] never reached on the new code → unreached_at_head" \
    "NEGCTL FAIL SPEC-8 unreached_at_head after=SPEC-7" "$(_sel SPEC-8)"
assert_eq "[U9] ...while its sibling that printed is still judged normally" \
    "NEGCTL PASS SPEC-7" "$(_sel SPEC-7)"
assert_eq "[U10] rc 127 inside a file that printed other verdicts → unreached, not harness" \
    "NEGCTL FAIL SPEC-10 unreached_at_base after=SPEC-9" "$(_sel SPEC-10)"

# _gate_run <repo> <iter> — the real gate in <repo>; prints the result file path.
_gate_run() {
    local repo="$1" iter="$2" st="$1/.zbuild-state-$2"
    mkdir -p "$st/artifacts" "$st/events"
    cp "$repo/design.md" "$st/artifacts/design.md"
    printf '{"inputs":{"design":"%s"}}\n' "$st/artifacts/design.md" > "$st/stage-inputs.json"
    : > "$st/events/events.jsonl"
    ( cd "$repo" || exit 1
      export ZBUILD_EVENTS_DIR="$st/events" ZBUILD_EVENTS_JSONL="$st/events/events.jsonl"
      export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
      export ZBUILD_STAGE_INPUTS="$st/stage-inputs.json" ZBUILD_NEGCTL_TIMEOUT=60 ZBUILD_CYCLE_ITER="$iter"
      unset _ZBUILD_ACCEPTANCE_GATE_LOADED
      source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" \
          && acceptance_gate_run "acceptance-gate" "$st/pipeline-state.json" ) >/dev/null 2>&1 || true
    printf '%s' "$st/artifacts/acceptance-gate-result.json"
}

print_test_section "U9: unreached on the new code is never escalated to design"
_r9="$(_gate_run "$REPO" 2)"
assert_contains "[U9] the gate reports it" "$(jq -r '.failures[]?' "$_r9" 2>/dev/null)" "unreached_at_head:SPEC-8"
assert_contains "[U9] ...and says where the file stopped" "$(jq -r '.reason // empty' "$_r9" 2>/dev/null)" "SPEC-8 (the file stopped after SPEC-7)"

print_test_section "U11: reading where the file stopped"
_L11="$TEST_TEMP_DIR/u11.log"
_lov() { _negctl_last_other_verdict "$_L11" "$1"; printf ' rc=%s' "$?"; }
printf '  \033[32m✓\033[0m [SPEC-1] a\n  ✗ [SPEC-2] b\n  some noise [SPEC-4] without a verdict\n  ✓ [SPEC-3] c (own line)\n' > "$_L11"
assert_eq "[U11] bare tags: the last OTHER SPEC with a verdict, colour codes stripped" "SPEC-2 rc=0" "$(unset ZBUILD_ISSUE; _lov SPEC-3)"
_ID11="$(zb_test_issue)"
printf '  ✓ [#%s/SPEC-1] a\n  ✓ [#%s/SPEC-7] another issue\n  ✗ [SPEC-8] bare, not this contract\n' "$_ID11" "$((_ID11 + 1))" > "$_L11"
assert_eq "[U11] issue-prefixed tags: only this issue's contract counts" "SPEC-1 rc=0" "$(ZBUILD_ISSUE="$_ID11" _lov SPEC-18)"
printf '  ✓ [#%s/SPEC-18] its own line\n' "$_ID11" > "$_L11"
assert_eq "[U11] its own line is not another SPEC's" " rc=1" "$(ZBUILD_ISSUE="$_ID11" _lov SPEC-18)"
printf 'no verdicts here\n' > "$_L11"
assert_eq "[U11] a log with no verdict lines finds nothing" " rc=1" "$(unset ZBUILD_ISSUE; _lov SPEC-3)"
: > "$_L11"
assert_eq "[U11] an empty log finds nothing" " rc=1" "$(unset ZBUILD_ISSUE; _lov SPEC-3)"

print_test_section "U12: the gate, when unreached_at_base is the only finding"
REPO12="$(setup_git_temp_repo negctl-unreached-repo12)"
( cd "$REPO12" || exit 1; "$GIT" checkout -q -b feature; mkdir -p tests
  printf '#!/usr/bin/env bash\nnew_feature() { return 0; }\n' > impl.sh
  cat > tests/u-test.sh <<'EOF12'
#!/usr/bin/env bash
set -euo pipefail
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
# shellcheck disable=SC1090
[[ -f "$impl" ]] && source "$impl"
if declare -F new_feature >/dev/null; then echo "  ✓ [SPEC-1] the feature"; else echo "  ✗ [SPEC-1] the feature"; fi
declare -F new_feature >/dev/null
if declare -F new_feature >/dev/null; then echo "  ✓ [SPEC-2] a second feature"; else echo "  ✗ [SPEC-2] a second feature"; fi
EOF12
  chmod +x tests/u-test.sh impl.sh; "$GIT" add -A; "$GIT" commit -q -m u )
printf '```acceptance\nSPEC-1[code]: the feature\nSPEC-2[code]: a second feature\nTESTFILES:\nSPEC-1: tests/u-test.sh\nSPEC-2: tests/u-test.sh\n```\n' > "$REPO12/design.md"
_r12="$(_gate_run "$REPO12" 2)"
assert_eq "[U12] the only failure is unreached_at_base" "unreached_at_base:SPEC-2" \
    "$(jq -r '.failures | join(",")' "$_r12" 2>/dev/null)"
assert_eq "[U12] not a specification fault, even on round 2" "" "$(jq -r '.fault // empty' "$_r12" 2>/dev/null)"
assert_contains "[U12] the numbered finding says the test never ran on the old code" "$(jq -r '.data.findings[]?.text' "$_r12" 2>/dev/null)" "never ran on the code from before this change"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
