#!/usr/bin/env bash
# tests/integration/template-tier-override-test.sh — #1252
#
# End-to-end: a per-stage `router.tier` in the loaded template reaches the model
# router. A plugin resolves its tier via resolve_tier (the #1231 accessor), which
# now consults the template's router.tier BETWEEN the env override and the
# manifest config.tier_default. The resolved tier is handed to route_to_model,
# and the emitted `model.route` event's model_id proves which tier won.
#
# Precedence proven here (env ZBUILD_<ID>_TIER > template router.tier > manifest):
#   • template-only (env unset)  → template tier's model routes
#   • operator env override       → env tier's model routes (template ignored)
#   • no template tier + no env    → manifest tier_default routes (unchanged, #1231)
#
# Harness: mirrors router-retries-test.sh — a mock `claude` on PATH that just
# succeeds; we read the resolved model_id from the model.route event, so no real
# model call happens.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "template router.tier reaches route_to_model (#1252)"
setup_test_env "template-tier-override"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild" "$TEST_TEMP_DIR/bin"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# Model ids per tier (from config/models.json) — the assertion targets.
T1_MODEL="$(jq -r '.tiers.T1.candidates[0].id' "$ZBUILD_MODELS_FILE")"
T2_MODEL="$(jq -r '.tiers.T2.candidates[0].id' "$ZBUILD_MODELS_FILE")"
T3_MODEL="$(jq -r '.tiers.T3.candidates[0].id' "$ZBUILD_MODELS_FILE")"

# Mock claude: always succeeds; argv doesn't matter (we read model.route events).
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "OK-RESPONSE"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

# A fake "plan" plugin whose manifest declares tier_default T2 (the baseline).
PLUGIN_DIR="$TEST_TEMP_DIR/plugin/plan"
mkdir -p "$PLUGIN_DIR"
printf 'config:\n  tier_default: T2\n' > "$PLUGIN_DIR/manifest.yaml"

# Template fixture: `plan` stage with an optional router.tier (param).
_write_fixture() {
    local tpl_tier="$1" fixture="$2"
    {
        printf 'id: tt\nname: TT\ndefaults:\n  strategy: fanout\nstages:\n  - id: plan\n'
        printf 'plan:\n  gate: auto\n  roles: [planner]\n  router:\n    timeout_s: 300\n'
        [[ -n "$tpl_tier" ]] && printf '    tier: %s\n' "$tpl_tier"
        true
    } > "$fixture"
}

# Resolve the tier as a plugin would (resolve_tier), then route with it. Emits
# the resolved model_id to stdout via the model.route event.
# Args: <template_tier|""> <events_out> [env_tier]
_run_case() {
    local tpl_tier="$1" events_out="$2" env_tier="${3:-}"
    : > "$events_out"
    local fixture="$TEST_TEMP_DIR/fx.yaml"
    _write_fixture "$tpl_tier" "$fixture"
    local driver="$TEST_TEMP_DIR/driver.sh"
    cat > "$driver" <<EOF
set -uo pipefail
export PATH="$TEST_TEMP_DIR/bin:\$PATH"
export HOME="$HOME"
export ZBUILD_SCOPE_OVERRIDE=1
export ZBUILD_MODELS_FILE="$ZBUILD_MODELS_FILE"
export ZBUILD_EVENT_SCHEMA="$ZBUILD_EVENT_SCHEMA"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/ev"
export ZBUILD_EVENTS_JSONL="$events_out"
${env_tier:+export ZBUILD_PLAN_TIER="$env_tier"}
mkdir -p "$TEST_TEMP_DIR/ev"
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/pipeline/template.sh"
source "$REPO_ROOT/scripts/lib/tier-resolve.sh"
source "$REPO_ROOT/core/router/route.sh"
load_template "$fixture"
export ZBUILD_CURRENT_STAGE=plan
# The plugin resolves its tier the canonical way, then routes with it.
tier="\$(resolve_tier plan "$PLUGIN_DIR")" || { echo "RESOLVE_FAILED"; exit 3; }
route_to_model "\$tier" 'ping' --skip-precondition >/dev/null 2>&1 || true
EOF
    bash "$driver" >/dev/null 2>&1 || true
    return 0
}

_routed_model() {
    grep '"model.route"' "$1" 2>/dev/null | jq -r '.data.model_id // .model_id' 2>/dev/null | head -1
}

# ── S1: template-only (env unset) → template tier T3 routes (beats manifest T2) ─
EV="$TEST_TEMP_DIR/ev-s1.jsonl"
_run_case T3 "$EV"
assert_eq "[S1] template router.tier=T3 reaches route_to_model (opus model routed)" \
    "$T3_MODEL" "$(_routed_model "$EV")"

# ── S2: operator env override beats the template tier ─────────────────────────
EV="$TEST_TEMP_DIR/ev-s2.jsonl"
_run_case T3 "$EV" T1
assert_eq "[S2] env ZBUILD_PLAN_TIER=T1 overrides template router.tier=T3 (haiku model routed)" \
    "$T1_MODEL" "$(_routed_model "$EV")"

# ── S3: CRITICAL INVARIANT — no template tier → manifest default (unchanged) ──
EV="$TEST_TEMP_DIR/ev-s3.jsonl"
_run_case "" "$EV"
assert_eq "[S3] no router.tier → manifest tier_default T2 routes unchanged (#1231 invariant, sonnet model)" \
    "$T2_MODEL" "$(_routed_model "$EV")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
