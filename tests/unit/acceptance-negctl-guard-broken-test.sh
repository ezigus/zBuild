#!/usr/bin/env bash
# tests/unit/acceptance-negctl-guard-broken-test.sh — a [guard] whose own check
# fails on the NEW code too is a broken test, not a mislabelled guard (#2244).
#
# Why: #1838, round 1 of its second build loop. SPEC-14/17's tests used
# `grep -qF "- x"` — grep reads `- x` as an option — so they failed on the old
# code AND the new. The gate ran the guard only against the merge-base (since
# #1670), saw its own ✗, and reported guard_regressed: "a mislabelled [change]",
# a specification fault. The fault was the test's.
#
# G1 [change] own ✗ at the merge-base AND at HEAD → guard_test_broken
# G2 [guard]  own ✗ at the merge-base only (holds at HEAD) → guard_regressed, as today
# G3 [change] the gate: guard_test_broken is recoverable, not a specification
#             fault, and its finding is about the testfile
# G4 [change] the design-gate precheck does not reject a design for it
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-negctl.sh
source "$REPO_ROOT/scripts/lib/acceptance-negctl.sh"

print_test_header "a guard failing on the new code too is a broken test (#2244)"
setup_test_env "acceptance-negctl-guard-broken"
unset ZBUILD_ISSUE 2>/dev/null || true

GIT="$(command -v git)"
REPO="$(setup_git_temp_repo negctl-guard-broken)"
(
    cd "$REPO" || exit 1
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '#!/usr/bin/env bash\nnew_feature() { return 0; }\n' > impl.sh
    # SPEC-1: a guard whose check is broken — fails on the old AND the new code.
    printf '%s\n' '#!/usr/bin/env bash' 'if grep -qF "- nothing matches" /dev/null; then echo "  ✓ [SPEC-1] events declared"; else echo "  ✗ [SPEC-1] events declared"; exit 1; fi' > tests/broken-test.sh
    # SPEC-2: a real mislabel — fails on the old code, holds on the new.
    printf '%s\n' '#!/usr/bin/env bash' 'impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"' 'if [[ -f "$impl" ]]; then echo "  ✓ [SPEC-2] impl present"; else echo "  ✗ [SPEC-2] impl present"; exit 1; fi' > tests/mislabel-test.sh
    chmod +x tests/*.sh impl.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat + tests"
)
printf '```acceptance\nSPEC-1[guard]: events declared\nSPEC-2[guard]: impl present\nTESTFILES:\nSPEC-1: tests/broken-test.sh\nSPEC-2: tests/mislabel-test.sh\n```\n' > "$REPO/design.md"
_sel() { grep -E "^[A-Z]+ [A-Z]+ $2( |\$)" <<< "$1" || true; }

print_test_section "G1/G2: the negative control"
OUT="$(ZBUILD_NEGCTL_TIMEOUT=60 acceptance_negctl_check "$REPO/design.md" "$REPO" 2>/dev/null || true)"
assert_eq "[G1] own ✗ on the old AND new code → guard_test_broken" \
    "NEGCTL FAIL SPEC-1 guard_test_broken" "$(_sel "$OUT" SPEC-1)"
assert_eq "[G2] own ✗ only on the old code → guard_regressed (a real mislabel)" \
    "NEGCTL FAIL SPEC-2 guard_regressed" "$(_sel "$OUT" SPEC-2)"

print_test_section "G4: the design-gate precheck"
OUT4="$(ZBUILD_NEGCTL_TIMEOUT=60 acceptance_negctl_guard_precheck "$REPO/design.md" "$REPO" 2>/dev/null || true)"
assert_eq "[G4] a broken guard test does not reject the design" \
    "GUARD SKIP SPEC-1 guard_test_broken" "$(_sel "$OUT4" SPEC-1)"
assert_eq "[G4] ...while a real mislabel still does" \
    "GUARD FAIL SPEC-2 guard_regressed" "$(_sel "$OUT4" SPEC-2)"

print_test_section "G3: the gate"
# shellcheck source=../../scripts/lib/acceptance-disposition.sh
source "$REPO_ROOT/scripts/lib/acceptance-disposition.sh"
assert_eq "[G3] guard_test_broken is recoverable" "recoverable" "$(_ag_failure_class_disposition guard_test_broken)"
REPO3="$(setup_git_temp_repo negctl-guard-broken-3)"
( cd "$REPO3" || exit 1; "$GIT" checkout -q -b feature; mkdir -p tests
  printf '#!/usr/bin/env bash\nnew_feature() { return 0; }\n' > impl.sh
  printf '%s\n' '#!/usr/bin/env bash' 'if grep -qF "- nothing matches" /dev/null; then echo "  ✓ [SPEC-1] events declared"; else echo "  ✗ [SPEC-1] events declared"; exit 1; fi' > tests/broken-test.sh
  chmod +x tests/broken-test.sh impl.sh; "$GIT" add -A; "$GIT" commit -q -m t )
printf '```acceptance\nSPEC-1[guard]: events declared\nTESTFILES:\nSPEC-1: tests/broken-test.sh\n```\n' > "$REPO3/design.md"
st="$REPO3/.zbuild-state"; mkdir -p "$st/artifacts" "$st/events"
cp "$REPO3/design.md" "$st/artifacts/design.md"
printf '{"inputs":{"design":"%s"}}\n' "$st/artifacts/design.md" > "$st/stage-inputs.json"
: > "$st/events/events.jsonl"
( cd "$REPO3" || exit 1
  export ZBUILD_EVENTS_DIR="$st/events" ZBUILD_EVENTS_JSONL="$st/events/events.jsonl"
  export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
  export ZBUILD_STAGE_INPUTS="$st/stage-inputs.json" ZBUILD_NEGCTL_TIMEOUT=60 ZBUILD_CYCLE_ITER=2
  unset _ZBUILD_ACCEPTANCE_GATE_LOADED
  source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" \
      && acceptance_gate_run "acceptance-gate" "$st/pipeline-state.json" ) >/dev/null 2>&1 || true
R="$st/artifacts/acceptance-gate-result.json"
assert_eq "[G3] the gate fails" "fail" "$(jq -r '.verdict // empty' "$R" 2>/dev/null)"
assert_eq "[G3] ...without blaming the specification" "" "$(jq -r '.fault // empty' "$R" 2>/dev/null)"
assert_eq "[G3] ...about the testfile" "tests/broken-test.sh" "$(jq -r '.about // empty' "$R" 2>/dev/null)"
assert_contains "[G3] the reason says the test itself fails on the new code" "$(jq -r '.reason // empty' "$R" 2>/dev/null)" "fails on the new code too"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
