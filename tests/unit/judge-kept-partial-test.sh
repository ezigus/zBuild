#!/usr/bin/env bash
# tests/unit/judge-kept-partial-test.sh — a judge's good answers are kept even
# when another SPEC changed or another line of its reply is bad (#2472, ADR-072
# §3 §4).
#
# Why: on #1805 run 41951779189 SKIP-1 and FRSH-2 were `ok` in tries 1 and 2
# and never changed, yet try 3 judged them from scratch and found new
# complaints. Each SPEC's kept answer depended on the whole draft, which the
# judge opened, so any edit made every answer stale; and try 2's reply, good
# for all 14 SPECs, was thrown away whole for two bad requirement quotes.
#
# D1 design's check: a kept answer does not depend on the draft (or design.md)
#    the judge opened; a code file it opened still counts
# D2 test-author's check: a kept answer does not depend on the design the judge
#    opened
# P1 design's check, a partly bad reply: the re-ask asks only for the items
#    whose lines are bad; the good items are kept even when the check ends
#    unusable; the next try asks only for what is missing
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a judge's good answers are kept (#2472)"
setup_test_env "judge-kept-partial"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export _RUNNER_ENGINE_SHA="engine-a"

_N="$TEST_TEMP_DIR/n"; _P="$TEST_TEMP_DIR/p"
_l() { grep "^$2|" "$1" | head -1 | cut -d'|' -f2-; }
assert_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }
# _ev <type> <check> <item> — how many such events since the log was cleared.
_ev() { jq -r --arg t "$1" --arg c "$2" --arg i "$3" 'select(.type == $t and .data.check == $c and .data.item == $i) | 1' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | grep -c .; }

_spec_design() {  # <file> [WORK-2's Then words]
    cat > "$1" <<MD
# Design
\`\`\`acceptance
FRSH-1[code]: a new run starts from the first stage covers: RQST-1
  Given: a run whose stages all completed
  When: it is started again
  Then: every stage is dispatched
  And: no stage is skipped
WORK-2[code]: the flag is read covers: RQST-2
  When: the flag is given
  Then: ${2:-the run uses it}
WIRING: none
\`\`\`
MD
}
REQS='- RQST-1: start from the *first* stage
- RQST-2: read the flag'

# The judge stub: counts calls, keeps each prompt, and, as the router does,
# lists the files the call opened (ZBUILD_ROUTER_OPENED_FILE).
_stub() {
    route_to_model() {
        local n f; n=$(( $(cat "$_N") + 1 )); printf '%s' "$n" > "$_N"; printf '%s' "$2" > "$_P.$n"
        for f in ${_OPENS:-}; do [[ -n "${ZBUILD_ROUTER_OPENED_FILE:-}" ]] && printf '%s\n' "$f" >> "$ZBUILD_ROUTER_OPENED_FILE"; done
        if [[ $n -eq 1 ]]; then printf '%s' "$_R1"; else printf '%s' "${_R2:-$_R1}"; fi
    }
}

print_test_section "D1 + P1: design's check"
(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh"
    _stub
    export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"
    export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo"; mkdir -p "$ZBUILD_REPO_ROOT/core"
    printf 'run() { :; }\n' > "$ZBUILD_REPO_ROOT/core/run.sh"
    artifact_dir="$TEST_TEMP_DIR/d-art"; mkdir -p "$artifact_dir"
    D="$artifact_dir/design-draft.md"; _spec_design "$D"
    printf 'an earlier design\n' > "$artifact_dir/design.md"
    _OPENS="$D $artifact_dir/design.md $ZBUILD_REPO_ROOT/core/run.sh"
    _cov() { printf 0 > "$_N"; : > "$ZBUILD_EVENTS_JSONL"; _design_coverage "$D" "$REQS" T2 >/dev/null 2>&1; }
    _fresh() { rm -f "$artifact_dir/design-judged.json"; }
    OK=$'RQST-1: covered\nRQST-2: covered\nFRSH-1: ok\nWORK-2: ok\n'

    # D1: WORK-2 changes; FRSH-1's answer still holds though the draft it was read in changed.
    _fresh; _R1="$OK"; _R2=""; _cov
    _spec_design "$D" "the run uses the flag"
    _R1=$'RQST-1: covered\nRQST-2: covered\nWORK-2: ok\n'; _cov
    _p1="$(cat "$_P.1" 2>/dev/null)"
    echo "D1a|$(cat "$_N")|$_DESIGN_COV_OUTCOME|$(_ev judge.kept.used design FRSH-1)|$(_ev judge.kept.stale design FRSH-1)|$([[ "$_p1" == *"  Then: every stage is dispatched"* ]] && echo frsh-inline)"
    # D1: a code file the judge opened still counts.
    _R1=$'RQST-1: covered\nRQST-2: covered\nFRSH-1: ok\nWORK-2: ok\n'; _cov
    printf 'run() { return 1; }\n' > "$ZBUILD_REPO_ROOT/core/run.sh"
    _cov
    echo "D1b|$(cat "$_N")|$(jq -r 'select(.type == "judge.kept.stale" and .data.item == "FRSH-1") | .data.why' "$ZBUILD_EVENTS_JSONL" 2>/dev/null)"

    # P1: requirement lines bad twice, both SPECs good: SPECs kept, check unusable.
    _spec_design "$D"
    _BADQ=$'RQST-1: covered\nRQST-2: uncovered | WHY: nothing reads it | QUOTE: "reads the flag"\nFRSH-1: ok\nWORK-2: ok\n'
    _fresh; _R1="$_BADQ"; _R2="$_BADQ"; _cov
    echo "P1a|$(cat "$_N")|$_DESIGN_COV_OUTCOME|$(_ev judge.kept.saved design FRSH-1)|$(_ev judge.kept.saved design WORK-2)|$(_ev judge.kept.saved design requirements)"
    echo "P1b|$(grep -F 'Answer again only for:' "$_P.2" 2>/dev/null)"
    # ...the next try asks only for requirements: no SPEC inline, one call.
    _R1=$'RQST-1: covered\nRQST-2: covered\n'; _R2=""; _cov
    _p1="$(cat "$_P.1" 2>/dev/null)"
    echo "P1c|$(cat "$_N")|$_DESIGN_COV_OUTCOME|$([[ "$_p1" == *"  Then: every stage is dispatched"* || "$_p1" == *"  Then: the run uses it"* ]] && echo spec-inline)|$([[ "$_p1" == *"<requirement id>: covered"* ]] && echo reqs-asked)"

    # P1: one SPEC's line bad, then fixed: the re-ask asks for it alone, and the
    # second reply's lines for the items already answered do not count.
    _BADP=$'RQST-1: covered\nRQST-2: covered\nFRSH-1: ok\nWORK-2 Then: how | WHY: x | QUOTE: "not its words"\n'
    _fresh; _R1="$_BADP"; _R2=$'WORK-2: ok\nFRSH-1 Then: how | WHY: names a loop | QUOTE: "every stage is dispatched"\nRQST-1: uncovered | WHY: y | QUOTE: "first stage"\n'; _cov
    echo "P1d|$(cat "$_N")|$_DESIGN_COV_OUTCOME|$(_design_coverage_findings | grep -c .)|$(grep -F 'Answer again only for:' "$_P.2" 2>/dev/null)"
) > "$TEST_TEMP_DIR/d.out" 2>/dev/null
F="$TEST_TEMP_DIR/d.out"
assert_eq "[D1] one SPEC changed: one call, the other SPEC's answer used, not stale, not shown" "1||1|0|" "$(_l "$F" D1a)"
assert_eq "[D1] a code file the judge opened changed: judged again, why=file" "1|file" "$(_l "$F" D1b)"
assert_eq "[P1] requirements bad twice: unusable, and both SPECs kept, requirements not" "2|unusable|1|1|0" "$(_l "$F" P1a)"
assert_eq "[P1] ...the re-ask asks only for the requirements" "Answer again only for: every requirement" "$(_l "$F" P1b)"
assert_eq "[P1] ...the next try asks only for them, no SPEC inline" "1|||reqs-asked" "$(_l "$F" P1c)"
assert_contains "[P1] one SPEC's line bad, then fixed: judged in two calls, nothing found" "$(_l "$F" P1d)" "2||0|"
assert_contains "[P1] ...the re-ask asks for that SPEC alone" "$(_l "$F" P1d)" "|Answer again only for: WORK-2"

print_test_section "D2: test-author's check"
(
    # shellcheck source=../../plugins/agent/test-author/plugin.sh
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
    _stub
    R="$TEST_TEMP_DIR/t-repo"; mkdir -p "$R/tests"; git -C "$R" init -q
    A="$TEST_TEMP_DIR/t-art"; mkdir -p "$A"; D="$A/design.md"; _spec_design "$D"
    printf '# Given\nrun=done\n# When\nstart\n# Then\nassert_eq "[FRSH-1] first" "1" "$s"\nassert_eq "[WORK-2] flag" "1" "$f"\n' > "$R/tests/a-test.sh"
    _OPENS="$D"
    _j() { printf 0 > "$_N"; : > "$ZBUILD_EVENTS_JSONL"; _ta_correspondence "$D" "$R" T2 "$A" >/dev/null 2>&1; }
    _R1=$'FRSH-1: ok\nWORK-2: ok\n'; _R2=""; _j
    _spec_design "$D" "the run uses the flag"
    _R1=$'WORK-2: ok\n'; _j
    echo "D2a|$(cat "$_N")|$_TA_CORR_OUTCOME|$(_ev judge.kept.used test-author FRSH-1)|$(_ev judge.kept.stale test-author FRSH-1)"
) > "$TEST_TEMP_DIR/t.out" 2>/dev/null
T="$TEST_TEMP_DIR/t.out"
assert_eq "[D2] one SPEC changed in the design: the other SPEC's answer used, not stale" "1||1|0" "$(_l "$T" D2a)"

cleanup_test_env
print_test_results
