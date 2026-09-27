#!/usr/bin/env bash
# Tests: provider modules — the router resolves a tier to the LATEST model of its
# family through the tier's provider, and every call's cost comes from the
# provider, never a price table in the engine (ADR-003 amendment).
#
#   SPEC-1 [change]: a tier naming {provider, family} is resolved by that
#                    provider's module — anthropic passes the family alias, which
#                    the CLI resolves to the newest model of that family
#   SPEC-2 [change]: a tier that pins an `id` still uses exactly that id
#   SPEC-3 [change]: a tier naming a provider with no module fails loudly (rc=2)
#   SPEC-4 [change]: the ledger records the cost the provider reported for the
#                    call (total_cost_usd), cache tokens included
#   SPEC-5 [change]: model.outcome records the concrete model that ran
#   SPEC-6 [guard] : a caller that did not ask for JSON still gets plain text back
#   SPEC-7 [change]: a call whose cost the provider cannot report is evented, and
#                    under a spending cap the next call is refused
#   SPEC-8 [change]: route_to_model_loop records each iteration's cost too
#   SPEC-9 [change]: config/models.json carries no prices; every LLM tier names a
#                    provider and a family
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "router provider modules: latest model per family, provider-reported cost"
setup_test_env "router-provider-modules"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STAGE_SCRATCH="$TEST_TEMP_DIR/scratch"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_REPO_ROOT="$REPO_ROOT"
export ZBUILD_COST_LEDGER="$TEST_TEMP_DIR/ledger.jsonl"
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$TEST_TEMP_DIR/events" "$TEST_TEMP_DIR/scratch" "$TEST_TEMP_DIR/state" "$HOME/.zbuild"
echo -n "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# The mock records its argv; MOCK_MODE picks what it answers with:
#   json   — a result envelope with total_cost_usd and modelUsage
#   nocost — an envelope with no cost field
#   plain  — bare text (an older CLI, or a stub)
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TEMP_DIR/argv"
cat > /dev/null
case "\${MOCK_MODE:-json}" in
    json)   jq -n '{type:"result",subtype:"success",result:"hello LOOP_COMPLETE",total_cost_usd:0.123,
                    modelUsage:{"claude-sonnet-9-9":{outputTokens:3}},
                    usage:{input_tokens:5,output_tokens:3,cache_read_input_tokens:900}}' ;;
    nocost) jq -n '{type:"result",subtype:"success",result:"hello LOOP_COMPLETE",usage:{input_tokens:5,output_tokens:3}}' ;;
    plain)  echo "hello LOOP_COMPLETE" ;;
esac
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

_models() {   # _models <T2 candidate json> — a models.json with one LLM tier
    jq -n --argjson c "$1" '{schema_version:1, tiers:{T0:{class:"wasm",candidates:[]}, T2:{class:"llm",candidates:[$c]}}}' \
        > "$TEST_TEMP_DIR/models.json"
    export ZBUILD_MODELS_FILE="$TEST_TEMP_DIR/models.json"
}
_arg_after() { awk -v f="$1" 'p{print; exit} $0==f{p=1}' "$TEST_TEMP_DIR/argv" 2>/dev/null; }
_last_event() { grep "\"$1\"" "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1; }

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"
set +e

print_test_section "SPEC-1: a family resolves through its provider module"
_models '{"provider":"anthropic","family":"sonnet"}'
MOCK_MODE=json route_to_model T2 "ping" --skip-precondition >/dev/null 2>&1
assert_eq "[SPEC-1] rc=0" "0" "$?"
assert_eq "[SPEC-1] the CLI is asked for the family alias (it resolves to the newest)" "sonnet" "$(_arg_after --model)"

print_test_section "SPEC-2: a pinned id wins"
_models '{"provider":"anthropic","family":"sonnet","id":"claude-sonnet-4-6"}'
MOCK_MODE=json route_to_model T2 "ping" --skip-precondition >/dev/null 2>&1
assert_eq "[SPEC-2] the pinned id is used" "claude-sonnet-4-6" "$(_arg_after --model)"

print_test_section "SPEC-3: a provider with no module fails loudly"
_models '{"provider":"nosuchprovider","family":"sonnet"}'
MOCK_MODE=json route_to_model T2 "ping" --skip-precondition >/dev/null 2>"$TEST_TEMP_DIR/s3.err"
assert_eq "[SPEC-3] rc=2 (misconfigured)" "2" "$?"
assert_contains "[SPEC-3] the error names the provider" "$(cat "$TEST_TEMP_DIR/s3.err")" "nosuchprovider"

print_test_section "SPEC-4/5/6: cost from the provider, the model that ran, plain text back"
_models '{"provider":"anthropic","family":"sonnet"}'
: > "$ZBUILD_COST_LEDGER"; : > "$ZBUILD_EVENTS_JSONL"
_out="$(MOCK_MODE=json route_to_model T2 "ping" --skip-precondition 2>/dev/null)"
assert_eq "[SPEC-4] the ledger records the provider-reported cost" "0.123000" "$(tail -1 "$ZBUILD_COST_LEDGER" 2>/dev/null)"
assert_contains "[SPEC-5] model.outcome names the concrete model" "$(_last_event model.outcome)" "claude-sonnet-9-9"
assert_eq "[SPEC-6] the caller gets the text, not the envelope" "hello LOOP_COMPLETE" "$_out"
assert_contains "[SPEC-6] …because the provider asked the CLI for JSON" "$(cat "$TEST_TEMP_DIR/argv")" "--output-format"

print_test_section "SPEC-7: an unreported cost is evented; under a cap it blocks the next call"
: > "$ZBUILD_COST_LEDGER"; : > "$ZBUILD_EVENTS_JSONL"; rm -f "$ZBUILD_STATE_DIR/runtime/cost-unknown"
_out7="$(MOCK_MODE=nocost route_to_model T2 "ping" --skip-precondition 2>/dev/null)"
assert_eq "[SPEC-7] the call itself still succeeds" "hello LOOP_COMPLETE" "$_out7"
assert_contains "[SPEC-7] router.cost.unknown is emitted" "$(_last_event router.cost.unknown)" "router.cost.unknown"
ZBUILD_BUDGET_USD=100 MOCK_MODE=json route_to_model T2 "ping" --skip-precondition >/dev/null 2>&1
assert_eq "[SPEC-7] with a spending cap, the next call is refused (rc=1)" "1" "$?"
MOCK_MODE=json route_to_model T2 "ping" --skip-precondition >/dev/null 2>&1
assert_eq "[SPEC-7] without a cap, calls continue" "0" "$?"
rm -f "$ZBUILD_STATE_DIR/runtime/cost-unknown"
_out7p="$(MOCK_MODE=plain route_to_model T2 "ping" --skip-precondition 2>/dev/null)"
assert_eq "[SPEC-7] a plain-text answer is returned as-is (cost unknown)" "hello LOOP_COMPLETE" "$_out7p"

print_test_section "SPEC-8: the loop path records each iteration's cost"
: > "$ZBUILD_COST_LEDGER"; rm -f "$ZBUILD_STATE_DIR/runtime/cost-unknown"
printf 'do the thing\n' > "$TEST_TEMP_DIR/loop-prompt.txt"
mkdir -p "$TEST_TEMP_DIR/cwd"
( MOCK_MODE=json route_to_model_loop T2 "$TEST_TEMP_DIR/loop-prompt.txt" "$TEST_TEMP_DIR/cwd" 1 >/dev/null 2>&1 )
assert_eq "[SPEC-8] the loop iteration's cost is in the ledger" "0.123000" "$(tail -1 "$ZBUILD_COST_LEDGER" 2>/dev/null)"

print_test_section "SPEC-9: models.json names providers and families, no prices"
_real="$REPO_ROOT/config/models.json"
assert_eq "[SPEC-9] no price fields remain" "0" \
    "$(jq '[.. | objects | keys[] | select(test("cost_per|_mtok"))] | length' "$_real")"
assert_eq "[SPEC-9] every LLM candidate names provider + family" "0" \
    "$(jq '[.tiers[] | select(.class=="llm") | .candidates[] | select((.provider // "") == "" or (.family // "") == "")] | length' "$_real")"
assert_eq "[SPEC-9] T1/T2/T3 are haiku/sonnet/opus" "haiku sonnet opus" \
    "$(jq -r '[.tiers.T1, .tiers.T2, .tiers.T3 | .candidates[0].family] | join(" ")' "$_real")"

print_test_results
exit $((FAIL > 0))
