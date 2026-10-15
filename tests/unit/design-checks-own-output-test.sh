#!/usr/bin/env bash
# tests/unit/design-checks-own-output-test.sh — design checks its own design.md
# and goes back to its model with what failed (#2369, ADR-040, ADR-068).
#
# Why: a check that reads one stage's output belongs to that stage. design does
# its model work, then checks design.md by script (its structure, and that every
# numbered requirement is covered), then asks a second model call whether the
# SPECs cover what the issue asks. Anything that fails goes back to its model,
# until the checks pass or its rounds (its manifest's config.check_rounds) run out.
#
# C1 [change] a structural failure in round 1 goes back to the model with the
#             finding; a fixed design in round 2 passes
# C2 [change] the checks still fail when the rounds run out: outcome fail, and
#             the result carries every finding
# C3 [change] the coverage call says a requirement is uncovered: it goes back
#             to the model, naming the requirement
# C4 [change] the coverage call is rate-limited: that is design's outcome
# C5 [change] the rounds come from design's own manifest
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

# The design call: round n writes ${DESIGNS[n-1]} and keeps its prompt.
DESIGNS=()
route_to_model_loop() {
    local prompt_file="$2" n
    n=$(( $(cat "$TEST_TEMP_DIR/design-calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/design-calls"
    cp "$prompt_file" "$TEST_TEMP_DIR/design-prompt-$n"
    printf '%s' "${DESIGNS[$((n - 1))]:-${DESIGNS[${#DESIGNS[@]}-1]}}" > "$_F_DESIGN"
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    return 0
}
# The coverage call: answer n is ${JUDGE[n-1]}; JUDGE_RC is its rc.
JUDGE=(); JUDGE_RC=0
route_to_model() {
    local n
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
    _design_stage_run_inner "$d/state/scope-manifest.md" "$_F_ART/plan.json" "$_F_DESIGN" "$_F_ART" >/dev/null 2>&1
    RC=$?
    OUTCOME="$(jq -r '.outcome // "MISSING"' "$_F_ART/design-verdict.json" 2>/dev/null || echo MISSING)"
    FINDINGS="$(jq -r '.data.findings[]?.text // empty' "$_F_ART/design-verdict.json" 2>/dev/null || true)"
    CALLS="$(cat "$TEST_TEMP_DIR/design-calls" 2>/dev/null || echo 0)"
}

# ── C1 ───────────────────────────────────────────────────────────────────────
DESIGNS=("$NO_WIRING" "$GOOD"); JUDGE=("VERDICT: covered"); JUDGE_RC=0
_run
assert_eq "[C1] the model is called again after a failed check" "2" "$CALLS"
assert_contains "[C1] round 2's prompt names what failed" \
    "$(cat "$TEST_TEMP_DIR/design-prompt-2" 2>/dev/null)" "WIRING"
assert_eq "[C1] the fixed design passes" "pass" "$OUTCOME"

# ── C2 ───────────────────────────────────────────────────────────────────────
DESIGNS=("$NO_WIRING"); JUDGE=("VERDICT: covered"); JUDGE_RC=0
_run
assert_eq "[C2] the model is called once per round, no more" "2" "$CALLS"
assert_eq "[C2] still failing when the rounds run out: outcome fail" "fail" "$OUTCOME"
assert_contains "[C2] the result carries the finding" "$FINDINGS" "WIRING"

# ── C3 ───────────────────────────────────────────────────────────────────────
DESIGNS=("$GOOD"); JUDGE=("VERDICT: uncovered
REASON: R-1 is only half covered
UNCOVERED: R-1: the docs say so" "VERDICT: covered"); JUDGE_RC=0
_run
assert_eq "[C3] an uncovered requirement goes back to the model" "2" "$CALLS"
assert_contains "[C3] round 2's prompt names the uncovered requirement" \
    "$(cat "$TEST_TEMP_DIR/design-prompt-2" 2>/dev/null)" "R-1: the docs say so"
assert_contains "[C3] the coverage call is shown the SPECs" \
    "$(cat "$TEST_TEMP_DIR/judge-prompt-1" 2>/dev/null)" "SPEC-1[no-code]: the docs say so"
assert_eq "[C3] covered in round 2: pass" "pass" "$OUTCOME"

# ── C4 ───────────────────────────────────────────────────────────────────────
DESIGNS=("$GOOD"); JUDGE=("rate limited"); JUDGE_RC=1
_router_rc_classify() { printf -v "$2" '%s' error; printf -v "$3" '%s' router_rate_limited; }
_run
assert_eq "[C4] a rate-limited coverage call is design's outcome" "rate_limited" "$OUTCOME"
unset -f _router_rc_classify

# ── C5 ───────────────────────────────────────────────────────────────────────
assert_eq "[C5] design's manifest sets its rounds" "2" \
    "$(yaml_get "$REPO_ROOT/plugins/agent/design/manifest.yaml" config.check_rounds 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
