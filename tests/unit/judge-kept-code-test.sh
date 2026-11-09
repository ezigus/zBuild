#!/usr/bin/env bash
# tests/unit/judge-kept-code-test.sh — a kept answer depends on the code its
# SPEC's test exercises, whether or not the judge opened it (#2477, ADR-072 §4).
#
# Why: a kept answer's files were only those the judging call chose to open,
# the files its quotes name, and test-author's test files. A judge that never
# opened the code under test kept its verdict through any change to that code.
#
# C1 [change] test-author's check: a change to a file the design wires to its
#             SPECs (WIRING), never opened by the judge, makes the kept answer
#             stale and the SPEC is judged again
# C3 [guard]  nothing changed: the kept answer is used, no call
# C4 [guard]  a change to a file the design does not name: still kept
# C5 [guard]  issue-acceptance: a change to the change's code, never opened,
#             changes the diff it judged, so it is judged again
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "a kept answer depends on the code its test exercises (#2477)"
setup_test_env "judge-kept-code"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export _RUNNER_ENGINE_SHA="engine-a"
_N="$TEST_TEMP_DIR/n"
_l() { /usr/bin/grep "^$2|" "$1" | while IFS= read -r _x; do printf '%s\n' "${_x#*|}"; break; done; }

print_test_section "C1-C4: test-author's check"
(
    # shellcheck source=../../plugins/agent/test-author/plugin.sh
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
    # The judge answers and opens nothing: ZBUILD_ROUTER_OPENED_FILE stays empty.
    route_to_model() { printf '%s' "$(( $(cat "$_N") + 1 ))" > "$_N"; printf 'RUNS-1: ok\nDONE-1: ok\n'; }
    R="$TEST_TEMP_DIR/repo"; mkdir -p "$R/tests" "$R/src"; git -C "$R" init -q
    printf 'run() { echo ran; }\n' > "$R/src/run.sh"
    printf 'refuse() { return 2; }\n' > "$R/src/refuse.sh"
    printf 'unrelated\n' > "$R/src/other.sh"
    printf '# Given\nsource src/run.sh\n# When\nout="$(run)"\n# Then\nassert_eq "[RUNS-1] runs" "ran" "$out"\nassert_eq "[DONE-1] refuses" "2" "$rc"\n' > "$R/tests/a-test.sh"
    D="$TEST_TEMP_DIR/design.md"
    cat > "$D" <<'MD'
# Design
```acceptance
RUNS-1[code]: the tool runs covers: RQST-1
  When: it is run
  Then: it prints ran
DONE-1[done]: a bad flag is refused evidence: src/refuse.sh:"return 2" covers: RQST-2
  When: a bad flag is given
  Then: it exits 2
WIRING:
src/run.sh
```
MD
    A="$TEST_TEMP_DIR/art"; mkdir -p "$A"
    _j() { printf 0 > "$_N"; _ta_correspondence "$D" "$R" T2 "$A" >/dev/null 2>&1; cat "$_N"; }
    echo "C0|$(_j)"
    echo "C3|$(_j)"
    printf 'unrelated, changed\n' > "$R/src/other.sh"
    echo "C4|$(_j)"
    printf 'run() { echo ran twice; }\n' > "$R/src/run.sh"
    echo "C1|$(_j)"
    echo "C1b|$(_j)"
) > "$TEST_TEMP_DIR/c.out" 2>/dev/null
C="$TEST_TEMP_DIR/c.out"
assert_eq "[C0] setup: the first check judges, in one call" "1" "$(_l "$C" C0)"
assert_eq "[C3] nothing changed: the kept answer is used, no call" "0" "$(_l "$C" C3)"
assert_eq "[C4] a file the design does not name changed: still kept" "0" "$(_l "$C" C4)"
assert_eq "[C1] a WIRING file the judge never opened changed: judged again" "1" "$(_l "$C" C1)"
assert_eq "[C1] ...and that answer is kept in turn" "0" "$(_l "$C" C1b)"

print_test_section "C5: issue-acceptance"
(
    # shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
    source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh" 2>/dev/null
    # shellcheck source=../../scripts/lib/stage-result.sh
    source "$REPO_ROOT/scripts/lib/stage-result.sh"
    route_to_model() { printf '%s' "$(( $(cat "$_N") + 1 ))" > "$_N"; printf 'MET: FLAG-1\n'; }
    resolve_tier() { printf 'T2'; }
    G="$(setup_git_temp_repo kept-ia)"; export ZBUILD_REPO_ROOT="$G"
    printf 'flag=0\n' > "$G/p.sh"; git -C "$G" add p.sh >/dev/null 2>&1; git -C "$G" commit -qm base >/dev/null 2>&1
    S="$TEST_TEMP_DIR/ia"; A="$S/artifacts"; in="$S/inputs"; mkdir -p "$A" "$in"; printf '{}' > "$S/pipeline-state.json"
    zb_test_issue_output "$in" "Add a flag." >/dev/null
    (
        # shellcheck source=../../plugins/agent/intake/plugin.sh
        source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
        route_to_model() {
            if [[ "$2" == *"check a list of requirements"* ]]; then printf 'MISSING: none\n'
            else printf 'REQUIREMENT: FLAG-1 add a flag\n'; fi
        }
        _intake_write_requirements "$in" '{"title":"Add a flag","body":"Add a flag."}'
    ) >/dev/null 2>&1
    printf '%s\n' '# Design' '```acceptance' 'FLAG-1[code]: a flag is accepted covers: FLAG-1' 'WIRING: none' '```' > "$in/design.md"
    zb_test_test_run_output "$in" pass 1 0 >/dev/null
    jq -n --arg i "$in/intake-result.json" --arg r "$in/requirements.json" --arg d "$in/design.md" \
        --arg p "$in/diff.patch" --arg t "$in/test-results.json" \
        '{inputs: {a: $i, r: $r, b: $d, c: $p, d: $t}}' > "$S/stage-inputs.json"
    export ZBUILD_STAGE_INPUTS="$S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$A"
    # The diff as build derives it: git diff HEAD of the working tree.
    _ia() { git -C "$G" diff HEAD > "$in/diff.patch"; printf 0 > "$_N"
            issue_acceptance_run issue-acceptance "$S/pipeline-state.json" >/dev/null 2>&1; cat "$_N"; }
    printf 'flag=1\n' > "$G/p.sh"
    echo "C5a|$(_ia)"
    echo "C5b|$(_ia)"
    printf 'flag=2\n' > "$G/p.sh"
    echo "C5c|$(_ia)"
) > "$TEST_TEMP_DIR/i.out" 2>/dev/null
I="$TEST_TEMP_DIR/i.out"
assert_eq "[C5] setup: issue-acceptance judges, in one call" "1" "$(_l "$I" C5a)"
assert_eq "[C5] nothing changed: kept, no call" "0" "$(_l "$I" C5b)"
assert_eq "[C5] the change's code changed, never opened: judged again" "1" "$(_l "$I" C5c)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
