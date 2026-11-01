#!/usr/bin/env bash
# tests/unit/design-checks-own-output-test.sh — design checks its own design
# (#2369, ADR-040, ADR-068 §8).
#
# Why: a check that reads one stage's output belongs to that stage. design does
# its one model call, then checks the design by script (its structure, and that
# every numbered requirement is covered), then asks a second model call whether
# the SPECs cover what the issue asks. A design that fails cannot be used: the
# engine runs design again, handed what failed. Nothing goes back to the model
# inside the stage (ADR-068 §8 amended: a repeat there learns nothing).
#
# C1 [change] a structural failure: one design call, outcome unusable, and the
#             result carries the finding
# C2 [change] the coverage call says a requirement is uncovered: unusable, and
#             the finding names the requirement
# C3 [change] the coverage call is rate-limited: that is design's outcome
# C4 [guard]  a design that passes both checks: pass, one call of each
# C5 [change] a design that already fails a scripted check is not sent to the
#             coverage call, so a coverage call that cannot run never hides the
#             findings the next run needs (review on PR #2399)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "design checks its own design.md and goes back to its model (#2369)"
setup_test_env "design-checks-own-output"

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"
apply_scope_redaction() { cp "$1" "$2"; return 0; }

BT='```'
GOOD="# Design

${BT}scope
foo.sh
${BT}

${BT}acceptance
SPEC-1[no-code]: the docs say so covers: R-1
WIRING: none
TESTFILES:
${BT}
"
NO_WIRING="# Design

${BT}scope
foo.sh
${BT}

${BT}acceptance
SPEC-1[no-code]: the docs say so covers: R-1
TESTFILES:
${BT}
"

# Two model calls share route_to_model. The design call — its prompt names a
# file to write — writes ${DESIGNS[n-1]} there; the coverage call answers
# ${JUDGE[n-1]}, with JUDGE_RC as its rc.
DESIGNS=(); JUDGE=(); JUDGE_RC=0
route_to_model() {
    local n _t; _t="$(zb_test_prompt_write_path "$2")"
    if [[ -n "$_t" ]]; then
        n=$(( $(cat "$TEST_TEMP_DIR/design-calls" 2>/dev/null || echo 0) + 1 ))
        printf '%s' "$n" > "$TEST_TEMP_DIR/design-calls"
        printf '%s\n' "$2" > "$TEST_TEMP_DIR/design-prompt-$n"
        printf '%s' "${DESIGNS[$((n - 1))]:-${DESIGNS[${#DESIGNS[@]}-1]}}" > "$_t"
        return 0
    fi
    n=$(( $(cat "$TEST_TEMP_DIR/judge-calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/judge-calls"
    printf '%s\n' "$2" > "$TEST_TEMP_DIR/judge-prompt-$n"
    printf '%s\n' "${JUDGE[$((n - 1))]:-${JUDGE[${#JUDGE[@]}-1]}}"
    return "$JUDGE_RC"
}

_run() {
    local d="$TEST_TEMP_DIR/run"
    rm -rf "$d" "$TEST_TEMP_DIR"/design-calls "$TEST_TEMP_DIR"/judge-calls \
        "$TEST_TEMP_DIR"/design-prompt-* "$TEST_TEMP_DIR"/judge-prompt-*
    mkdir -p "$d/state/artifacts"
    git -C "$d" init -q >/dev/null 2>&1
    export ZBUILD_REPO_ROOT="$d"
    export ZBUILD_EVENTS_JSONL="$d/state/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
    _F_ART="$d/state/artifacts"; _F_DESIGN="$_F_ART/design.md"
    printf 'scope: all\n' > "$d/state/scope-manifest.md"
    printf '{"title":"t","goal":"g","steps":[{"id":"s1","description":"d","files":["foo.sh"]}]}\n' > "$_F_ART/plan.json"
    printf '{"requirements":[{"id":"R-1","text":"the docs say so"}]}\n' > "$_F_ART/requirements.json"
    _design_stage_run_inner "$d/state/scope-manifest.md" "$_F_DESIGN" "$_F_ART" >/dev/null 2>&1
    RC=$?
    OUTCOME="$(jq -r '.outcome // "MISSING"' "$_F_ART/design-verdict.json" 2>/dev/null || echo MISSING)"
    FINDINGS="$(jq -r '.data.findings[]?.text // empty' "$_F_ART/design-verdict.json" 2>/dev/null || true)"
    CALLS="$(cat "$TEST_TEMP_DIR/design-calls" 2>/dev/null || echo 0)"
    JCALLS="$(cat "$TEST_TEMP_DIR/judge-calls" 2>/dev/null || echo 0)"
}

# ── C1 ───────────────────────────────────────────────────────────────────────
DESIGNS=("$NO_WIRING" "$GOOD"); JUDGE=("VERDICT: covered"); JUDGE_RC=0
_run
assert_eq "[C1] one design call: a failed check is not sent back to the model" "1" "$CALLS"
assert_eq "[C1] a design that fails a check is unusable" "unusable" "$OUTCOME"
assert_contains "[C1] the result carries the finding" "$FINDINGS" "WIRING"

# ── C2 ───────────────────────────────────────────────────────────────────────
DESIGNS=("$GOOD"); JUDGE=("VERDICT: uncovered
REASON: R-1 is only half covered
UNCOVERED: R-1: the docs say so" "VERDICT: covered"); JUDGE_RC=0
_run
assert_eq "[C2] an uncovered requirement: unusable" "unusable" "$OUTCOME"
assert_contains "[C2] the finding names the uncovered requirement" "$FINDINGS" "R-1: the docs say so"
assert_contains "[C2] the coverage call is shown the SPECs" \
    "$(cat "$TEST_TEMP_DIR/judge-prompt-1" 2>/dev/null)" "SPEC-1[no-code]: the docs say so"
assert_eq "[C2] still one design call" "1" "$CALLS"

# ── C3 ───────────────────────────────────────────────────────────────────────
DESIGNS=("$GOOD"); JUDGE=("rate limited"); JUDGE_RC=1
_router_rc_classify() { printf -v "$2" '%s' error; printf -v "$3" '%s' router_rate_limited; }
_run
assert_eq "[C3] a rate-limited coverage call is design's outcome" "rate_limited" "$OUTCOME"
unset -f _router_rc_classify

# ── C4 ───────────────────────────────────────────────────────────────────────
DESIGNS=("$GOOD"); JUDGE=("VERDICT: covered"); JUDGE_RC=0
_run
assert_eq "[C4] a design that passes both checks: pass" "pass" "$OUTCOME"
assert_eq "[C4] one design call" "1" "$CALLS"
assert_eq "[C4] one coverage call" "1" "$JCALLS"

# ── C5 ───────────────────────────────────────────────────────────────────────
DESIGNS=("$NO_WIRING"); JUDGE=("rate limited"); JUDGE_RC=1
_router_rc_classify() { printf -v "$2" '%s' error; printf -v "$3" '%s' router_rate_limited; }
_run
assert_eq "[C5] a failed scripted check: no coverage call" "0" "$JCALLS"
assert_eq "[C5] ...the outcome is unusable" "unusable" "$OUTCOME"
assert_contains "[C5] ...and the result keeps the scripted finding" "$FINDINGS" "WIRING"
unset -f _router_rc_classify

cleanup_test_env
print_test_results
exit $((FAIL > 0))
