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
# The evidence that separates the two, in any language: the file printed
# verdicts for OTHER SPECs of this contract and none for this one. A bare guard
# test (`grep -q …`, no verdict lines, #1658) prints nothing, so it keeps the
# file's exit code as its verdict, as before.
#
# U1 [change] a [guard] cut off by an earlier failure is `guard_unreached`
# U2 [guard]  a [guard] that printed its own ✓ before the file stopped still
#             holds; a [change] that printed ✗ is still a valid control
# U3 [guard]  a bare [guard] file with no verdict lines that fails at the
#             merge-base is still `guard_regressed` (#1658)
# U4 [guard]  a [guard] that prints its own ✗ at the merge-base is still
#             `guard_regressed` — a real mislabel is still caught
# U5 [change] the design-gate precheck does not reject a design for it:
#             `GUARD SKIP <spec> guard_unreached`
# U6 [change] the gate: recoverable, NOT a specification fault (design is not
#             rewound), a reason that names the SPEC and the last verdict the
#             file printed, and `about` naming the testfile, so the stage that
#             wrote it is told it is its to fix
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
    printf '#!/usr/bin/env bash\nnew_feature() { return 0; }\n' > impl.sh
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
TESTFILES:
SPEC-1: tests/contract-test.sh
SPEC-2: tests/contract-test.sh
SPEC-3: tests/contract-test.sh
SPEC-4: tests/bare-test.sh
SPEC-5: tests/mislabel-test.sh
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
assert_eq "[U3] a bare guard with no verdict lines keeps the file's verdict" \
    "NEGCTL FAIL SPEC-4 guard_regressed" "$(grep -E '^[A-Z]+ [A-Z]+ SPEC-4( |$)' <<< "$OUT" || true)"
assert_eq "[U4] a guard that prints its own ✗ is still regressed" \
    "NEGCTL FAIL SPEC-5 guard_regressed" "$(grep -E '^[A-Z]+ [A-Z]+ SPEC-5( |$)' <<< "$OUT" || true)"

print_test_section "U5: the design-gate precheck"
OUT5="$(ZBUILD_NEGCTL_TIMEOUT=60 acceptance_negctl_guard_precheck "$DM" "$REPO" 2>/dev/null || true)"
assert_eq "[U5] an unreached guard does not reject the design" \
    "GUARD SKIP SPEC-3 guard_unreached" "$(grep -E '^[A-Z]+ [A-Z]+ SPEC-3( |$)' <<< "$OUT5" || true)"
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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
