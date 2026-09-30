#!/usr/bin/env bash
# tests/unit/impact-v2-closeout-test.sh — #1838 close-out: what the run's SPECs
# missed, found by its review lenses, claude-review and a code read.
#
# C1 [change] a failure to pick the model tier writes a result (error /
#             misconfigured) instead of exiting with none
# C2 [change] a result that cannot be written is reported, and impact does not
#             claim to have written one
# C3 [change] the success path never writes a v1-shaped impact.json: if the v2
#             merge fails, that is reported as an error result
# C4 [change] a turn-budget hit is recoverable (verdict incomplete, disposition
#             out_of_turns) — the stage's own rule for max_turns, SPEC-10's intent
# C5 [change] a router failure the shared mapping cannot name is warned and
#             recorded as unusable — never a silent `interrupted`
# C6 [change] a real SIGTERM (the guard not stubbed) writes interrupted /
#             signal_interrupt
# C7 [change] router budgets resolve from the manifest when no template or env
#             sets one (the issue's checkbox; SPEC-13 covered only the override)
# C8 [change] a passing run's impact.json is the v1 output plus the v2 fields,
#             byte-for-byte against a golden (the issue's "before/after golden diff")
# C9 [change] plugin.sh derives no path from the state file (SPEC-8's grep missed
#             `dirname "${state_file…}"`)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "impact: v2 close-out (#1838)"
setup_test_env "impact-v2-closeout"
PLUGIN_DIR="$REPO_ROOT/plugins/agent/impact"
GOLDEN="$REPO_ROOT/tests/golden/impact-output-v1.golden"
CANNED='{"schema_version":1,"verdict":"complete","missing":[]}'

# _fixture <name> — an engine-style dispatch: inputs index + artifact dir.
_fixture() {
    local d="$TEST_TEMP_DIR/$1"
    mkdir -p "$d/state" "$d/art"
    printf 'scope: all\n' > "$d/state/scope-manifest.md"
    printf '# Design\n\n```scope\nfoo.sh\n```\n' > "$d/state/design.md"
    printf '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"s1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}\n' > "$d/state/plan.json"
    printf '{}' > "$d/state/pipeline-state.json"
    jq -n --arg s "$d/state/scope-manifest.md" --arg g "$d/state/design.md" --arg p "$d/state/plan.json" \
        '{inputs:{scope_manifest:$s, design:$g, plan:$p}}' > "$d/state/stage-inputs.json"
    printf '%s' "$d"
}
# _impact <dir> <stub-body> — impact_run in a subshell, with extra stubs. Prints
# stderr; the result is <dir>/art/impact.json.
_impact() {
    local d="$1" stubs="$2"
    (
        export ZBUILD_STAGE_INPUTS="$d/state/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$d/art"
        export ZBUILD_EVENTS_JSONL="$d/events.jsonl" ZBUILD_REPO_ROOT="$d"
        mkdir -p "$d/config"
        # shellcheck source=../../plugins/agent/impact/plugin.sh
        source "$PLUGIN_DIR/plugin.sh" >/dev/null 2>&1
        apply_scope_redaction() { cp "$1" "$2"; }
        route_to_model() { printf '%s\n' "$CANNED"; return 0; }
        eval "$stubs"
        impact_run impact "$d/state/pipeline-state.json" >/dev/null
        echo "RC=$?" >&2
    ) 2>&1
}
_res() { jq -r "$2 // empty" "$1/art/impact.json" 2>/dev/null || true; }

print_test_section "C1: no model tier"
D1="$(_fixture c1)"; _impact "$D1" 'resolve_tier() { return 1; }' >/dev/null
assert_eq "[C1] a tier failure writes a result" "2" "$(_res "$D1" .result_contract)"
assert_eq "[C1] ...error / misconfigured" "error/misconfigured" "$(_res "$D1" .verdict)/$(_res "$D1" .disposition)"

print_test_section "C2: a write that fails"
D2="$(_fixture c2)"
_e2="$(_impact "$D2" 'route_to_model() { return 124; }; atomic_write() { cat >/dev/null; return 1; }')"
assert_contains "[C2] a failed write is reported" "$_e2" "could not write"
assert_file_not_exists "[C2] ...and no result is claimed (the fallback printf is gone)" "$D2/art/impact.json"

print_test_section "C3: the success-path merge"
D3="$(_fixture c3)"
_e3="$(_impact "$D3" 'jq() { if [[ "$*" == *result_contract:2,disposition:* ]]; then return 1; fi; command jq "$@"; }')"
assert_eq "[C3] a failed merge is an error result, not a v1-shaped impact.json" "2" "$(_res "$D3" .result_contract)"
assert_eq "[C3] ...verdict error" "error" "$(_res "$D3" .verdict)"

print_test_section "C4/C5: router failures"
D4="$(_fixture c4)"
_impact "$D4" '_router_rc_classify() { printf -v "$2" error; printf -v "$3" router_out_of_turns; }; route_to_model() { return 1; }' >/dev/null
assert_eq "[C4] a turn-budget hit is recoverable (incomplete)" "incomplete" "$(_res "$D4" .verdict)"
assert_eq "[C4] ...disposition out_of_turns" "out_of_turns" "$(_res "$D4" .disposition)"
D5="$(_fixture c5)"
_e5="$(_impact "$D5" 'router_reason_disposition() { printf ""; }; route_to_model() { return 1; }')"
assert_eq "[C5] an unnamed failure is unusable, not interrupted" "unusable" "$(_res "$D5" .disposition)"
assert_contains "[C5] ...and says the mapping named nothing" "$_e5" "router_reason_disposition returned nothing"

print_test_section "C6: a real SIGTERM"
D6="$(_fixture c6)"; READY="$TEST_TEMP_DIR/c6-ready"
bash -c "
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    export ZBUILD_STAGE_INPUTS='$D6/state/stage-inputs.json' ZBUILD_ARTIFACT_DIR='$D6/art'
    export ZBUILD_EVENTS_JSONL='$D6/events.jsonl' ZBUILD_REPO_ROOT='$D6'
    mkdir -p '$D6/config'
    source '$PLUGIN_DIR/plugin.sh' >/dev/null 2>&1
    apply_scope_redaction() { cp \"\$1\" \"\$2\"; }
    route_to_model() { sleep 30 >/dev/null 2>&1 & printf '%s' \$! > '$READY'; wait \$!; }
    impact_run impact '$D6/state/pipeline-state.json' &
    p=\$!
    for _i in \$(seq 1 200); do [[ -s '$READY' ]] && break; sleep 0.05; done
    kill -TERM \"\$p\" 2>/dev/null; wait \"\$p\" 2>/dev/null
    kill \"\$(cat '$READY' 2>/dev/null)\" 2>/dev/null
" >/dev/null 2>&1
assert_file_exists "[C6] fixture: the model call was reached" "$READY"
assert_eq "[C6] a real SIGTERM writes interrupted / signal_interrupt" "interrupted/signal_interrupt" \
    "$(_res "$D6" .disposition)/$(_res "$D6" .reason)"

print_test_section "C7: router budgets from the manifest"
_t7="$(
    source "$PLUGIN_DIR/plugin.sh" >/dev/null 2>&1
    unset ZBUILD_ROUTER_TIMEOUT ZBUILD_ROUTER_MAX_TURNS
    unset -f template_stage_router_timeout template_stage_router_max_turns 2>/dev/null
    export ZBUILD_PLUGIN_DIR="$PLUGIN_DIR" ZBUILD_CURRENT_STAGE=impact
    printf '%s/%s' "$(_route_resolve_timeout)" "$(_route_resolve_max_turns)"
)"
assert_eq "[C7] with no template or env, the manifest's budgets are used (600s / 45 turns)" "600/45" "$_t7"

print_test_section "C8: the passing run against its v1 golden"
D8="$(_fixture c8)"; _impact "$D8" '' >/dev/null
_v1="$(jq -S 'del(.result_contract, .disposition, .reason)' "$D8/art/impact.json" 2>/dev/null)"
assert_eq "[C8] impact.json minus the v2 fields is byte-identical to the v1 golden" \
    "$(cat "$GOLDEN" 2>/dev/null)" "$_v1"
assert_eq "[C8] ...and carries result_contract 2" "2" "$(_res "$D8" .result_contract)"

print_test_section "C9: no path from the state file"
_hits="$(grep -nE 'dirname "\$\{?state_file|\$\{?state_dir\}?/' "$PLUGIN_DIR/plugin.sh" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
assert_eq "[C9] plugin.sh derives no path from the state file" "" "$_hits"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
