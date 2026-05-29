#!/usr/bin/env bash
# Tests: ADR-017 (#455) — per-stage router.timeout_s precedence across the
# subprocess boundary. Locks the export of _TPL_STAGE_ROUTER_TIMEOUT_* so a
# #448-class bug (forgotten export, plugin subshells see empty) cannot return.
#
# Strategy: fork a real bash -c child subprocess. In the child, source helpers
# + template.sh + route.sh, load a fixture template with build router.timeout_s
# = 900, set ZBUILD_CURRENT_STAGE=build AND ZBUILD_ROUTER_TIMEOUT=600 (env that
# would win if the per-stage export regressed), mock claude via PATH shim,
# call route_to_model. Outside the child, assert events.jsonl shows the
# resolved per-stage value (900). If export regressed → child sees empty stage
# var → falls back to env (600) → assertion fails loudly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "router-timeout-precedence e2e — subprocess boundary (#455, #448 lesson)"
setup_test_env "router-timeout-e2e"

# Fixtures + mocks
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$TEST_TEMP_DIR/events"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
echo -n "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# Mock claude — succeeds, writes its model arg to disk for verification.
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
echo "OK-RESPONSE"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

# Fixture template with build router.timeout_s=900.
FIXTURE="$TEST_TEMP_DIR/fixture.yaml"
cat > "$FIXTURE" <<'EOF'
id: rt-e2e
name: RT E2E
defaults:
  strategy: fanout

stages:
  - id: build
    gate: auto
    roles: [builder]
    router:
      timeout_s: 900
EOF

: > "$ZBUILD_EVENTS_JSONL"

# Fork a real subprocess. Inside: source the libs, load template, set BOTH
# ZBUILD_CURRENT_STAGE=build and ZBUILD_ROUTER_TIMEOUT=600 (different from
# per-stage). If exports work, per-stage 900 wins. If export regressed, env
# 600 wins.
bash -c "
set -euo pipefail
export PATH='$TEST_TEMP_DIR/bin:$PATH'
export HOME='$HOME'
export ZBUILD_SCOPE_OVERRIDE='$ZBUILD_SCOPE_OVERRIDE'
export ZBUILD_MODELS_FILE='$ZBUILD_MODELS_FILE'
export ZBUILD_EVENTS_DIR='$ZBUILD_EVENTS_DIR'
export ZBUILD_EVENTS_JSONL='$ZBUILD_EVENTS_JSONL'
export ZBUILD_EVENTS_DB='$ZBUILD_EVENTS_DB'
export ZBUILD_EVENT_SCHEMA='$ZBUILD_EVENT_SCHEMA'
source '$REPO_ROOT/scripts/lib/helpers.sh'
source '$REPO_ROOT/core/pipeline/template.sh'
source '$REPO_ROOT/core/router/route.sh'
load_template '$FIXTURE'
export ZBUILD_CURRENT_STAGE=build
export ZBUILD_ROUTER_TIMEOUT=600
route_to_model T2 'ping' --skip-precondition >/dev/null 2>&1
" || true

# Outside the child: read events.jsonl and check timeout_s on model.route.
applied_timeout="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.route") | .data.timeout_s // empty' 2>/dev/null | tail -1 || true)"
assert_eq "subprocess-boundary: per-stage 900 wins over env 600 (export regression catcher)" \
    "900" "$applied_timeout"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
