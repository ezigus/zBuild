#!/usr/bin/env bash
# tests/unit/acceptance-negctl-unreached-test.sh — a [guard] whose assertion
# never ran at the merge-base is not a regressed guard.
#
# Why: #1835 run 20260929132254-2135 (and its first cycle). The gate runs the
# branch's testfile against the pre-change code. An earlier [change] step in
# the file called a function that does not exist yet, bare under `set -e`, so
# the file exited there — every assertion after that point never ran. The gate
# read "no verdict for SPEC-18" as "SPEC-18 fails at the merge-base", reported
# `guard_regressed` ("a mislabelled [change]"), and rewound design to relabel a
# guard that held (verified: at the merge-base the template still wins). Three
# rewinds, a 6h ceiling.
#
# The rule: an assertion that did not print its OWN verdict was not measured,
# and "not measured" is never "failed". The file's output says which case it is:
#   - it printed verdicts for OTHER SPECs of this contract and none for this
#     one → it stopped before this assertion ran: "unreached", the file's
#     author's to fix, never design's;
#   - it printed no verdicts at all (a bare check, or a framework that does not
#     print the contract's ✓/✗ lines) → its exit code cannot tell "checked and
#     failed" from "died first": "unverified". It goes to the stage that owns
#     the file first, and to design only when it is still so on the next round.
#
# U1 [change] a [guard] cut off by an earlier failure is `guard_unreached`
# U2 [guard]  a [guard] that printed its own ✓ before the file stopped still
#             holds; a [change] that printed ✗ is still a valid control
# U3 [change] a bare [guard] (no verdict lines) that fails at the merge-base is
#             `guard_unverified`, not `guard_regressed`
# U4 [guard]  a [guard] that prints its own ✗ at the merge-base is still
#             `guard_regressed` — a real mislabel is still caught
# U5 [change] the design-gate precheck rejects a design for neither:
#             `GUARD SKIP <spec> guard_unreached|guard_unverified`
# U6 [change] the gate: recoverable, NOT a specification fault (design is not
#             rewound), a reason that names the SPEC and the last verdict the
#             file printed, and `about` naming the testfile, so the stage that
#             wrote it is told it is its to fix
# U7 [change] guard_unverified: no fault on the first round (about names the
#             testfile); a specification fault from the second round on
# U8 [change] a [change] SPEC the file never reached at the merge-base is
#             `unreached_at_base` — its negative control is unproven, not valid
# U9 [change] a [change] SPEC the file never reached on the NEW code is
#             `unreached_at_head` — build's, and never escalated to design
# U10 [change] a command missing at the merge-base (rc 127) inside a file that
#             printed other verdicts is unreached, not "the runner could not
#             execute the file"
# U11 [guard]  _negctl_last_other_verdict reads the contract's own tag shape:
#             bare and issue-prefixed tags, another issue's tags ignored, this
#             SPEC's own lines ignored, colour codes stripped, the LAST one wins,
#             nothing found in an empty or verdict-free log (review #2235)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-negctl.sh
source "$REPO_ROOT/scripts/lib/acceptance-negctl.sh"

print_test_header "acceptance negctl — a guard that never ran is not a regressed guard"
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
    # One contract file: a guard that holds, a [change], a bare call that exits
    # the file at the baseline, and a guard after it.
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
echo "  ✓ [SPEC-10] another existing behaviour"
EOF
    # U3: a bare guard — no verdict lines at all — that fails at the baseline.
    cat > tests/bare-test.sh <<'EOF'
#!/usr/bin/env bash
# [SPEC-4] impl present
grep -q new_feature "$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
EOF
    # U4: a guard that prints its own ✗ at the baseline — a real mislabel.
    cat > tests/mislabel-test.sh <<'EOF'
#!/usr/bin/env bash
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
if [[ -f "$impl" ]]; then echo "  ✓ [SPEC-5] impl present"; else echo "  ✗ [SPEC-5] impl present"; exit 1; fi
EOF
    chmod +x tests/*.sh impl.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: new_feature + contract tests"
)
DM="$REPO/design.md"
cat > "$DM" <<'EOF'
```acceptance
SPEC-1[guard]: an existing behaviour still holds
SPEC-2[change]: the new feature exists
SPEC-3[guard]: precedence still holds
SPEC-4[guard]: impl present
SPEC-5[guard]: impl present
SPEC-6[change]: a second new thing
SPEC-7[change]: impl exists
SPEC-8[change]: feature works
SPEC-9[guard]: an existing behaviour
SPEC-10[guard]: another existing behaviour
TESTFILES:
SPEC-1: tests/contract-test.sh
SPEC-2: tests/contract-test.sh
SPEC-3: tests/contract-test.sh
SPEC-4: tests/bare-test.sh
SPEC-5: tests/mislabel-test.sh
SPEC-6: tests/contract-test.sh
SPEC-7: tests/head-test.sh
SPEC-8: tests/head-test.sh
SPEC-9: tests/missing-cmd-test.sh
SPEC-10: tests/missing-cmd-test.sh
```
EOF

print_test_section "U1–U4: the gate's negative control"
OUT="$(ZBUILD_NEGCTL_TIMEOUT=60 acceptance_negctl_check "$DM" "$REPO" 2>/dev/null || true)"
assert_eq "[U1] a guard cut off by an earlier failure → guard_unreached" \
    "NEGCTL FAIL SPEC-3 guard_unreached after=SPEC-2" "$(grep -E '^[A-Z]+ [A-Z]+ SPEC-3( |$)' <<< "$OUT" || true)"
assert_eq "[U2] a guard that printed its ✓ before the file stopped still holds" \
    "NEGCTL PASS SPEC-1 guard_spec" "$(grep -E '^[A-Z]+ [A-Z]+ SPEC-1( |$)' <<< "$OUT" || true)"
assert_eq "[U2] a [change] that printed ✗ is still a valid control" \
    "NEGCTL PASS SPEC-2" "$(grep -E '^[A-Z]+ [A-Z]+ SPEC-2( |$)' <<< "$OUT" || true)"
assert_eq "[U3] a bare guard that fails at the merge-base is unverified, not regressed" \
    "NEGCTL FAIL SPEC-4 guard_unverified" "$(grep -E '^[A-Z]+ [A-Z]+ SPEC-4( |$)' <<< "$OUT" || true)"
assert_eq "[U4] a guard that prints its own ✗ is still regressed" \
    "NEGCTL FAIL SPEC-5 guard_regressed" "$(grep -E '^[A-Z]+ [A-Z]+ SPEC-5( |$)' <<< "$OUT" || true)"

print_test_section "U8–U10: [change] SPECs and missing commands"
_sel() { grep -E "^[A-Z]+ [A-Z]+ $1( |\$)" <<< "$OUT" || true; }
assert_eq "[U8] a [change] never reached at the merge-base → unreached_at_base, not a valid control" \
    "NEGCTL FAIL SPEC-6 unreached_at_base after=SPEC-2" "$(_sel SPEC-6)"
assert_eq "[U9] a [change] never reached on the new code → unreached_at_head" \
    "NEGCTL FAIL SPEC-8 unreached_at_head after=SPEC-7" "$(_sel SPEC-8)"
assert_eq "[U9] ...while its sibling that printed is still judged normally" \
    "NEGCTL PASS SPEC-7" "$(_sel SPEC-7)"
assert_eq "[U10] rc 127 inside a file that printed other verdicts → unreached, not harness" \
    "NEGCTL FAIL SPEC-10 guard_unreached after=SPEC-9" "$(_sel SPEC-10)"

print_test_section "U5: the design-gate precheck"
OUT5="$(ZBUILD_NEGCTL_TIMEOUT=60 acceptance_negctl_guard_precheck "$DM" "$REPO" 2>/dev/null || true)"
assert_eq "[U5] an unreached guard does not reject the design" \
    "GUARD SKIP SPEC-3 guard_unreached" "$(grep -E '^[A-Z]+ [A-Z]+ SPEC-3( |$)' <<< "$OUT5" || true)"
assert_eq "[U5] ...nor for an unverified one" \
    "GUARD SKIP SPEC-4 guard_unverified" "$(grep -E '^[A-Z]+ [A-Z]+ SPEC-4( |$)' <<< "$OUT5" || true)"
assert_eq "[U5] ...while a real mislabel still does" \
    "GUARD FAIL SPEC-5 guard_regressed" "$(grep -E '^[A-Z]+ [A-Z]+ SPEC-5( |$)' <<< "$OUT5" || true)"

print_test_section "U6: the gate's class, fault, reason and about"
# shellcheck source=../../scripts/lib/acceptance-disposition.sh
source "$REPO_ROOT/scripts/lib/acceptance-disposition.sh"
assert_eq "[U6] guard_unreached is recoverable" \
    "recoverable" "$(_ag_failure_class_disposition guard_unreached)"
assert_contains "[U6] the gate declares the class" \
    "$(cat "$REPO_ROOT/plugins/agent/spec-acceptance/manifest.yaml")" "- guard_unreached"

# The real gate, on a contract whose only finding is the unreached guard.
REPO6="$(setup_git_temp_repo negctl-unreached-repo6)"
( cd "$REPO6" || exit 1; "$GIT" checkout -q -b feature; mkdir -p tests
  printf '#!/usr/bin/env bash\nnew_feature() { return 0; }\n' > impl.sh
  cat > tests/c-test.sh <<'EOF2'
#!/usr/bin/env bash
set -euo pipefail
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
# shellcheck disable=SC1090
[[ -f "$impl" ]] && source "$impl"
if declare -F new_feature >/dev/null; then echo "  ✓ [SPEC-1] the new feature exists"; else echo "  ✗ [SPEC-1] the new feature exists"; fi
# The #1835 shape: a call that exists at the baseline but returns 1 there,
# bare under set -e (a missing command would be rc 127 — the runner's own code).
declare -F new_feature >/dev/null
echo "  ✓ [SPEC-2] precedence still holds"
EOF2
  chmod +x tests/c-test.sh impl.sh; "$GIT" add -A; "$GIT" commit -q -m c )
printf '```acceptance\nSPEC-1[change]: the new feature exists\nSPEC-2[guard]: precedence still holds\nTESTFILES:\nSPEC-1: tests/c-test.sh\nSPEC-2: tests/c-test.sh\n```\n' > "$REPO6/design.md"
_st6="$REPO6/.zbuild-state"; mkdir -p "$_st6/artifacts" "$_st6/events"
cp "$REPO6/design.md" "$_st6/artifacts/design.md"
printf '{"inputs":{"design":"%s"}}\n' "$_st6/artifacts/design.md" > "$_st6/stage-inputs.json"
: > "$_st6/events/events.jsonl"
( cd "$REPO6" || exit 1
  export ZBUILD_EVENTS_DIR="$_st6/events" ZBUILD_EVENTS_JSONL="$_st6/events/events.jsonl"
  export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
  export ZBUILD_STAGE_INPUTS="$_st6/stage-inputs.json" ZBUILD_NEGCTL_TIMEOUT=60 ZBUILD_CYCLE_ITER=2
  unset _ZBUILD_ACCEPTANCE_GATE_LOADED
  source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" \
      && acceptance_gate_run "acceptance-gate" "$_st6/pipeline-state.json" ) >/dev/null 2>&1 || true
_res6="$_st6/artifacts/acceptance-gate-result.json"
assert_eq "[U6] the gate fails the SPEC" "fail" "$(jq -r '.verdict // empty' "$_res6" 2>/dev/null)"
assert_eq "[U6] ...and does NOT blame the specification (design is not rewound)" "" \
    "$(jq -r '.fault // empty' "$_res6" 2>/dev/null)"
assert_eq "[U6] ...its finding is about the testfile that stopped" "tests/c-test.sh" \
    "$(jq -r '.about // empty' "$_res6" 2>/dev/null)"
_reason6="$(jq -r '.reason // empty' "$_res6" 2>/dev/null)"
assert_contains "[U6] the reason names the SPEC" "$_reason6" "SPEC-2"
assert_contains "[U6] ...says its assertion never ran at the merge-base" "$_reason6" "never ran"
assert_contains "[U6] ...and where the file stopped (after the last verdict it printed)" "$_reason6" "after SPEC-1"

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

print_test_section "U7: an unverified guard — its owner first, design on the next round"
REPO7="$(setup_git_temp_repo negctl-unreached-repo7)"
( cd "$REPO7" || exit 1; "$GIT" checkout -q -b feature; mkdir -p tests
  printf '#!/usr/bin/env bash\nnew_feature() { return 0; }\n' > impl.sh
  printf '#!/usr/bin/env bash\n# [SPEC-1] impl present\ngrep -q new_feature "$(cd "$(dirname "$0")/.." && pwd)/impl.sh"\n' > tests/b-test.sh
  chmod +x tests/b-test.sh impl.sh; "$GIT" add -A; "$GIT" commit -q -m b )
printf '```acceptance\nSPEC-1[guard]: impl present\nTESTFILES:\nSPEC-1: tests/b-test.sh\n```\n' > "$REPO7/design.md"
_r7a="$(_gate_run "$REPO7" 1)"
assert_eq "[U7] round 1: not a specification fault" "" "$(jq -r '.fault // empty' "$_r7a" 2>/dev/null)"
assert_eq "[U7] round 1: about the testfile" "tests/b-test.sh" "$(jq -r '.about // empty' "$_r7a" 2>/dev/null)"
assert_contains "[U7] round 1: the reason says it could not tell" "$(jq -r '.reason // empty' "$_r7a" 2>/dev/null)" "not verified"
_r7b="$(_gate_run "$REPO7" 2)"
assert_eq "[U7] round 2: still unverified → a specification fault" "specification" "$(jq -r '.fault // empty' "$_r7b" 2>/dev/null)"

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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
