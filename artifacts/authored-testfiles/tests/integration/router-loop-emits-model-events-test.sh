#!/usr/bin/env bash
# Tests: route_to_model_loop emits one model.route and one model.outcome event
# per iteration — observability parity with the single-shot path (#1730).
# [#1730/SPEC-1] [#1730/SPEC-2] [#1730/SPEC-3]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "router_loop: emits model.route and model.outcome per iteration (#1730)"
setup_test_env "router-loop-emits-model-events"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="loop-model-events-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# Fixture git repo so the loop can run `git diff HEAD` between iterations.
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
(
    cd "$REPO" && git init -q \
        && git config user.email t@t && git config user.name t \
        && printf 'seed\n' > seed.txt && git add seed.txt \
        && git commit -q -m seed
) >/dev/null

# ─── TC-1: 1-iteration loop ─ model.route and model.outcome fields ─────────────
# Stub claude: writes a work file (non-empty diff in case loop needs one),
# emits a JSON result envelope with known token/cost fields, then emits
# LOOP_COMPLETE so the loop terminates after exactly one iteration.
# total_cost_usd is present so provider_anthropic_call_cost can populate
# _ROUTE_CALL_COST, which _route_emit_outcome writes as cost_usd.
MARK1="$TEST_TEMP_DIR/tc1-mark"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK1
#!/usr/bin/env bash
printf 'iter1\n' > "$REPO/tc1-work.txt" 2>/dev/null || true
printf '%s' "1" >> "$MARK1"
jq -n '{type:"result",subtype:"success",is_error:false,result:"done\nLOOP_COMPLETE",num_turns:1,total_cost_usd:0.0012,usage:{input_tokens:100,output_tokens:20,cache_read_input_tokens:50,cache_creation_input_tokens:10}}'
exit 0
MOCK1
chmod +x "$TEST_TEMP_DIR/bin/claude"
: > "$ZBUILD_EVENTS_JSONL"

PROMPT1="$TEST_TEMP_DIR/tc1-prompt.txt"
printf 'build something\n' > "$PROMPT1"
RC1_OUT="$TEST_TEMP_DIR/tc1-rc.txt"
LEDGER1="$TEST_TEMP_DIR/tc1-ledger.jsonl"
DRIVER1="$TEST_TEMP_DIR/tc1-driver.sh"
cat > "$DRIVER1" <<EOF
set -euo pipefail
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/event-bus/event-bus.sh"
source "$REPO_ROOT/core/output/stage-io.sh"
source "$REPO_ROOT/core/router/route.sh"
export ZBUILD_EVENTS_DIR="$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$ZBUILD_EVENT_SCHEMA"
export ZBUILD_STATE_DIR="$ZBUILD_STATE_DIR"
export ZBUILD_MODELS_FILE="$ZBUILD_MODELS_FILE"
export ZBUILD_RUN_ID="$ZBUILD_RUN_ID"
export ZBUILD_COST_LEDGER="$LEDGER1"
export HOME="$HOME"
export ZBUILD_SCOPE_OVERRIDE=1
export PATH="$PATH"
export ZBUILD_ROUTER_MAX_TURNS=0
set +e
route_to_model_loop T2 "$PROMPT1" "$REPO" 5
rc=\$?
set -e
printf '%s' "\$rc" > "$RC1_OUT"
EOF
bash "$DRIVER1" >/dev/null 2>/dev/null || true

rc1="$(cat "$RC1_OUT" 2>/dev/null || printf 'missing')"
assert_eq "TC-1: loop driver exits 0 (sentinel honored)" "0" "$rc1"

print_test_section "SPEC-1: model.route emitted per iteration with tier, model_id, provider"

# [#1730/SPEC-1] Count: one model.route event per iteration.
tc1_route_count="$(jq -c 'select(.type=="model.route")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[#1730/SPEC-1] one model.route event for 1-iteration loop" "1" "$tc1_route_count"

# [#1730/SPEC-1] Field: tier.
tc1_route_tier="$(jq -r 'select(.type=="model.route") | .data.tier // empty' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1 || true)"
assert_eq "[#1730/SPEC-1] model.route.tier is T2" "T2" "$tc1_route_tier"

# [#1730/SPEC-1] Field: model_id non-empty.
tc1_route_model_id="$(jq -r 'select(.type=="model.route") | .data.model_id // empty' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1 || true)"
if [[ -n "$tc1_route_model_id" ]]; then
    assert_pass "[#1730/SPEC-1] model.route.model_id is non-empty"
else
    assert_fail "[#1730/SPEC-1] model.route.model_id is non-empty" "model_id was empty — model.route not emitted"
fi

# [#1730/SPEC-1] Field: provider non-empty.
tc1_route_provider="$(jq -r 'select(.type=="model.route") | .data.provider // empty' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1 || true)"
if [[ -n "$tc1_route_provider" ]]; then
    assert_pass "[#1730/SPEC-1] model.route.provider is non-empty"
else
    assert_fail "[#1730/SPEC-1] model.route.provider is non-empty" "provider was empty — model.route not emitted"
fi

print_test_section "SPEC-2: model.outcome emitted per iteration with token and cost fields"

# [#1730/SPEC-2] Count: one model.outcome event per iteration.
tc1_outcome_count="$(jq -c 'select(.type=="model.outcome")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[#1730/SPEC-2] one model.outcome event for 1-iteration loop" "1" "$tc1_outcome_count"

# [#1730/SPEC-2] Field: input_tokens matches mock value.
tc1_in_tok="$(jq -r 'select(.type=="model.outcome") | .data.input_tokens // empty' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1 || true)"
assert_eq "[#1730/SPEC-2] model.outcome.input_tokens=100" "100" "$tc1_in_tok"

# [#1730/SPEC-2] Field: output_tokens matches mock value.
tc1_out_tok="$(jq -r 'select(.type=="model.outcome") | .data.output_tokens // empty' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1 || true)"
assert_eq "[#1730/SPEC-2] model.outcome.output_tokens=20" "20" "$tc1_out_tok"

# [#1730/SPEC-2] Field: cache_read_input_tokens matches mock value.
tc1_cache_read="$(jq -r 'select(.type=="model.outcome") | .data.cache_read_input_tokens // empty' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1 || true)"
assert_eq "[#1730/SPEC-2] model.outcome.cache_read_input_tokens=50" "50" "$tc1_cache_read"

# [#1730/SPEC-2] Field: cache_creation_input_tokens matches mock value.
tc1_cache_creation="$(jq -r 'select(.type=="model.outcome") | .data.cache_creation_input_tokens // empty' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1 || true)"
assert_eq "[#1730/SPEC-2] model.outcome.cache_creation_input_tokens=10" "10" "$tc1_cache_creation"

# [#1730/SPEC-2] Field: cost_usd is present and non-"unknown" (total_cost_usd in mock JSON).
tc1_cost="$(jq -r 'select(.type=="model.outcome") | .data.cost_usd // empty' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1 || true)"
if [[ -n "$tc1_cost" && "$tc1_cost" != "unknown" ]]; then
    assert_pass "[#1730/SPEC-2] model.outcome.cost_usd is present and not 'unknown'"
else
    assert_fail "[#1730/SPEC-2] model.outcome.cost_usd is present and not 'unknown'" \
        "cost_usd='${tc1_cost}' — model.outcome not emitted or total_cost_usd not extracted"
fi

# ─── TC-2: 3-iteration loop ─ exactly 3 model.route and 3 model.outcome events ─
# Stub claude: counts calls via a shared file. Writes a distinct file each
# iteration (non-empty git diff). Emits LOOP_COMPLETE only on the third call.
COUNT2="$TEST_TEMP_DIR/tc2-count"
: > "$COUNT2"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK2
#!/usr/bin/env bash
printf '1\n' >> "$COUNT2"
n=\$(wc -l < "$COUNT2" | tr -d ' ')
printf 'iter%s\n' "\$n" > "$REPO/tc2-work-\${n}.txt" 2>/dev/null || true
if [[ "\$n" -ge 3 ]]; then
    jq -n '{type:"result",subtype:"success",is_error:false,result:"all done\nLOOP_COMPLETE",num_turns:1,total_cost_usd:0.0005,usage:{input_tokens:80,output_tokens:15,cache_read_input_tokens:0,cache_creation_input_tokens:0}}'
else
    jq -n '{type:"result",subtype:"success",is_error:false,result:"still working",num_turns:1,total_cost_usd:0.0005,usage:{input_tokens:80,output_tokens:15,cache_read_input_tokens:0,cache_creation_input_tokens:0}}'
fi
exit 0
MOCK2
chmod +x "$TEST_TEMP_DIR/bin/claude"
: > "$ZBUILD_EVENTS_JSONL"

PROMPT2="$TEST_TEMP_DIR/tc2-prompt.txt"
printf 'build it in three steps\n' > "$PROMPT2"
RC2_OUT="$TEST_TEMP_DIR/tc2-rc.txt"
LEDGER2="$TEST_TEMP_DIR/tc2-ledger.jsonl"
DRIVER2="$TEST_TEMP_DIR/tc2-driver.sh"
cat > "$DRIVER2" <<EOF
set -euo pipefail
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/event-bus/event-bus.sh"
source "$REPO_ROOT/core/output/stage-io.sh"
source "$REPO_ROOT/core/router/route.sh"
export ZBUILD_EVENTS_DIR="$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$ZBUILD_EVENT_SCHEMA"
export ZBUILD_STATE_DIR="$ZBUILD_STATE_DIR"
export ZBUILD_MODELS_FILE="$ZBUILD_MODELS_FILE"
export ZBUILD_RUN_ID="$ZBUILD_RUN_ID"
export ZBUILD_COST_LEDGER="$LEDGER2"
export HOME="$HOME"
export ZBUILD_SCOPE_OVERRIDE=1
export PATH="$PATH"
export ZBUILD_ROUTER_MAX_TURNS=0
set +e
route_to_model_loop T2 "$PROMPT2" "$REPO" 10
rc=\$?
set -e
printf '%s' "\$rc" > "$RC2_OUT"
EOF
bash "$DRIVER2" >/dev/null 2>/dev/null || true

rc2="$(cat "$RC2_OUT" 2>/dev/null || printf 'missing')"
assert_eq "TC-2: 3-iter loop driver exits 0 (sentinel on iter 3)" "0" "$rc2"

iter_count="$(wc -l < "$COUNT2" 2>/dev/null | tr -d ' ' || printf '0')"
assert_eq "TC-2: stub invoked exactly 3 times" "3" "$iter_count"

print_test_section "SPEC-3: 3-iteration loop emits exactly 3 model.route and 3 model.outcome events"

# [#1730/SPEC-3] Exactly 3 model.route events.
tc2_route_count="$(jq -c 'select(.type=="model.route")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[#1730/SPEC-3] exactly 3 model.route events for 3-iteration loop" "3" "$tc2_route_count"

# [#1730/SPEC-3] Exactly 3 model.outcome events.
tc2_outcome_count="$(jq -c 'select(.type=="model.outcome")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[#1730/SPEC-3] exactly 3 model.outcome events for 3-iteration loop" "3" "$tc2_outcome_count"

# [#1730/SPEC-3] model.outcome count matches cost-ledger row count (3 rows from 3 iterations).
tc2_ledger_rows="$(wc -l < "$LEDGER2" 2>/dev/null | tr -d ' ' || printf '0')"
assert_eq "[#1730/SPEC-3] model.outcome count matches cost-ledger rows" "$tc2_ledger_rows" "$tc2_outcome_count"

# ─── Teardown ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
