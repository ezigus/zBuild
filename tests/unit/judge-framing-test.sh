#!/usr/bin/env bash
# tests/unit/judge-framing-test.sh — a stage that only reads and reports is told
# so, never sees its own earlier verdict, and is never ordered to fix anything.
#
# Why: two #1845 runs.
#   36274909946 — issue-acceptance made a claim, and from then on its own
#     summary came back into its next prompt under "RESOLVE these findings
#     before completing". It repeated the claim every iteration, even at 741/741.
#   36332698182 — spec-correspondence, a judge, got three findings stamped
#     RESOLVE, spent 19 minutes editing a failing e2e test instead of judging
#     (9 SPECs unjudged), and the write boundary halted the run.
#
# J1 [change] a stage's own summary is not injected into its own prompt
# J2 [change] a reader that does not declare capabilities.writes_repository sees
#             an unowned failure as context, never as RESOLVE
# J3 [guard]  a declared repository writer still gets RESOLVE for it
# J4 [guard]  a reader still sees every OTHER stage's summary
# J5 [change] the router opens a non-writer's prompt with its scope — read and
#             report, change nothing in the repository — once, first
# J6 [guard]  a declared writer's prompt gets no such line
# J7 [change] the cycle's RESOLVE count follows the same two rules
# J8 [guard]  the count leaks no working variable into its caller (review #2212)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh" 2>/dev/null || true
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"

print_test_header "judges read and report: no self-echo, no orders, a stated scope"
setup_test_env "judge-framing"
unset ZBUILD_STAGE_INPUTS ZBUILD_INPUTS_FLOW 2>/dev/null || true

STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"; PROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$ART"

# _mf <kind/id> <writes_repository:true|false>
_mf() {
    local d="$PROOT/$1" id="${1#*/}"
    mkdir -p "$d"
    {
        printf 'id: %s\nname: %s\nkind: %s\nversion: 0.0.1\nhooks:\n  run: run_it\ninputs: []\n' "$id" "$id" "${1%%/*}"
        [[ "$2" == "true" ]] && printf 'capabilities:\n  writes_repository: true\n'
        printf 'outputs:\n  - id: %s_result\n    path: ${artifact_dir}/%s-result.json\n    type: json\n    required: true\n    primary: true\n' "${id//-/_}" "$id"
        printf '  - id: %s_summary\n    path: ${artifact_dir}/%s-summary.md\n    type: text\n    format: text\n    required: false\n    summary: true\n' "${id//-/_}" "$id"
    } > "$d/manifest.yaml"
    printf 'run_it() { return 0; }\n' > "$d/plugin.sh"
    printf '%s-SUMMARY-BODY\n' "$id" > "$ART/$id-summary.md"
    printf '{"result_contract":2,"verdict":"fail","disposition":"complete","reason":"x"}\n' > "$ART/$id-result.json"
}
_mf tool/jf-gate false
_mf agent/jf-judge false
_mf agent/jf-builder true

cat > "$STATE/pipeline-state.json" <<'EOF'
{"schema_version":1,"run_id":"jf","stage_statuses":{"jf-gate":"failed","jf-judge":"failed","jf-builder":"complete"},
 "stage_verdicts":{"jf-gate":"fail","jf-judge":"fail","jf-builder":"pass"}}
EOF
SF="$STATE/pipeline-state.json"

print_test_section "J1–J4: what a judge is shown"
_judge="$(ZBUILD_CURRENT_STAGE=jf-judge ZBUILD_PLUGIN_DIR="$PROOT/agent/jf-judge" \
    stage_summaries_prompt_block "$SF" "$PROOT" 2>/dev/null || true)"
if grep -qF "jf-judge-SUMMARY-BODY" <<< "$_judge"; then
    assert_fail "[J1] the judge is not shown its own earlier summary" "its own body was injected"
else
    assert_pass "[J1] the judge is not shown its own earlier summary"
fi
assert_contains "[J4] it still sees the gate's summary" "$_judge" "jf-gate-SUMMARY-BODY"
if grep -qF "RESOLVE" <<< "$_judge"; then
    assert_fail "[J2] a non-writer is never told to RESOLVE" "$(grep -F RESOLVE <<< "$_judge")"
else
    assert_pass "[J2] a non-writer is never told to RESOLVE"
fi
assert_contains "[J2] it is told the finding is context" "$_judge" "### jf-gate (verdict: fail) — context only"

_builder="$(ZBUILD_CURRENT_STAGE=jf-builder ZBUILD_PLUGIN_DIR="$PROOT/agent/jf-builder" \
    stage_summaries_prompt_block "$SF" "$PROOT" 2>/dev/null || true)"
assert_contains "[J3] a declared writer is still told to RESOLVE an unowned failure" \
    "$_builder" "### jf-gate (verdict: fail) — RESOLVE these findings before completing"
assert_contains "[J4] a writer still sees the judge's summary" "$_builder" "jf-judge-SUMMARY-BODY"

print_test_section "J7: the RESOLVE count follows the same rules"
assert_eq "[J7] a judge has nothing to resolve" "0" \
    "$(ZBUILD_CURRENT_STAGE=jf-judge ZBUILD_PLUGIN_DIR="$PROOT/agent/jf-judge" stage_summaries_count "$SF" "$PROOT" 2>/dev/null | cut -d' ' -f2)"
assert_eq "[J7] the judge's own summary is not counted" "2" \
    "$(ZBUILD_CURRENT_STAGE=jf-judge ZBUILD_PLUGIN_DIR="$PROOT/agent/jf-judge" stage_summaries_count "$SF" "$PROOT" 2>/dev/null | cut -d' ' -f1)"

unset _cstage
stage_summaries_count "$SF" "$PROOT" >/dev/null 2>&1 || true
assert_eq "[J8] stage_summaries_count leaks no working variable" "unset" "${_cstage-unset}"

print_test_section "J5/J6: the router states a non-writer's scope"
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh" 2>/dev/null || true
if declare -F _route_redact_prompt >/dev/null 2>&1; then
    IN="$TEST_TEMP_DIR/p.in"; OUT="$TEST_TEMP_DIR/p.out"
    printf 'Judge each SPEC.\n' > "$IN"
    ZBUILD_PLUGIN_DIR="$PROOT/agent/jf-judge" ZBUILD_SCOPE_MANIFEST="" _route_redact_prompt "$IN" "$OUT" 0 "" >/dev/null 2>&1 || true
    ZBUILD_PLUGIN_DIR="$PROOT/agent/jf-judge" ZBUILD_SCOPE_MANIFEST="" _route_redact_prompt "$IN" "$OUT" 1 "" >/dev/null 2>&1 || true
    _o="$(cat "$OUT" 2>/dev/null || true)"
    assert_contains "[J5] the scope says read and report" "$_o" "Your job is to read and report."
    assert_contains "[J5] ...and to change nothing in the repository" "$_o" \
        "Do not create, modify or delete any file in the repository"
    assert_eq "[J5] stated once, however often the prompt is redacted" "1" \
        "$(grep -c 'Your job is to read and report.' "$OUT" 2>/dev/null || true)"
    _scope_line="$(grep -n 'Your job is to read and report.' "$OUT" | cut -d: -f1 || true)"
    _task_line="$(grep -n 'Judge each SPEC.' "$OUT" | cut -d: -f1 || true)"
    if [[ -n "$_scope_line" && -n "$_task_line" && "$_scope_line" -lt "$_task_line" ]]; then
        assert_pass "[J5] it comes before the stage's own instructions"
    else
        assert_fail "[J5] it comes before the stage's own instructions" "scope@${_scope_line:-none} task@${_task_line:-none}"
    fi

    IN2="$TEST_TEMP_DIR/p2.in"; OUT2="$TEST_TEMP_DIR/p2.out"
    printf 'Build it.\n' > "$IN2"
    ZBUILD_PLUGIN_DIR="$PROOT/agent/jf-builder" ZBUILD_SCOPE_MANIFEST="" _route_redact_prompt "$IN2" "$OUT2" 0 "" >/dev/null 2>&1 || true
    if grep -qF "Your job is to read and report." "$OUT2" 2>/dev/null; then
        assert_fail "[J6] a declared writer gets no read-only scope" "scope line injected"
    else
        assert_contains "[J6] a declared writer gets no read-only scope" "$(cat "$OUT2" 2>/dev/null)" "Build it."
    fi
else
    assert_fail "[J5] _route_redact_prompt is available" "not defined after sourcing route.sh"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
