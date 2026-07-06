#!/usr/bin/env bash
# Integration (#1214): cost-ledger and cache isolation via ZBUILD_COST_LEDGER /
# ZBUILD_CACHE_DIR. Mirrors state-root-isolation-test.sh for the spend/cache fence.
#
# Contract:
#   SPEC-1 (change): ZBUILD_COST_LEDGER set → router writes to it, not HOME
#   SPEC-2 (change): parent ledger byte-identical after ZBUILD_COST_LEDGER-fenced call
#   SPEC-3 (guard):  ZBUILD_COST_LEDGER unset → router defaults to $HOME/.zbuild/cost-ledger.jsonl
#   SPEC-4 (change): _route_check_budget reads from ZBUILD_COST_LEDGER (not HOME)
#   SPEC-5 (change): test plugin exports ZBUILD_COST_LEDGER under fence in _test_run_inner
#   SPEC-6 (change): test plugin exports ZBUILD_CACHE_DIR under fence in _test_run_inner
#   SPEC-7 (change): E2E: suite that writes via env-var-resolved paths leaves parent
#                    ledger + cache untouched after test-stage fence
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
set +e

print_test_header "cost-ledger + cache isolation (#1214)"
setup_test_env "cost-ledger-cache-isolation-1214"
export ZBUILD_CONTRACT_VALIDATOR=warn

# ─── Common env shared by router direct tests ────────────────────────────────
HOME_DIR="$TEST_TEMP_DIR/home"; mkdir -p "$HOME_DIR/.zbuild"
PARENT_LEDGER="$HOME_DIR/.zbuild/cost-ledger.jsonl"
FENCE_DIR="$TEST_TEMP_DIR/fence"; mkdir -p "$FENCE_DIR"
FENCE_LEDGER="$FENCE_DIR/cost-ledger.jsonl"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"
export HOME="$HOME_DIR"
echo -n "bootstrap" > "$HOME_DIR/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# Seed parent ledger with known content.
printf '0.001000\n' > "$PARENT_LEDGER"
PARENT_LEDGER_GOLD="$TEST_TEMP_DIR/parent-ledger.gold"
cp "$PARENT_LEDGER" "$PARENT_LEDGER_GOLD"

# Source router; set token-cost variables so _route_update_ledger writes something.
source "$REPO_ROOT/core/router/route.sh"

_prime_router_cost() {
    _ROUTE_INPUT_TOKENS=1000
    _ROUTE_OUTPUT_TOKENS=1000
    _ROUTE_COST_IN=1.0
    _ROUTE_COST_OUT=1.0
}

# ─── SPEC-1: ZBUILD_COST_LEDGER set → router writes to fence, not HOME ───────
_prime_router_cost
export ZBUILD_COST_LEDGER="$FENCE_LEDGER"
_route_update_ledger 2>/dev/null
if [[ -s "$FENCE_LEDGER" ]]; then
    assert_pass "[SPEC-1] ZBUILD_COST_LEDGER set: route writes to fence ledger"
else
    assert_fail "[SPEC-1] ZBUILD_COST_LEDGER set: route writes to fence ledger" \
        "fence ledger is empty"
fi

# ─── SPEC-2: parent ledger byte-identical after fenced call ──────────────────
if cmp -s "$PARENT_LEDGER" "$PARENT_LEDGER_GOLD"; then
    assert_pass "[SPEC-2] parent ledger byte-identical after ZBUILD_COST_LEDGER-fenced call"
else
    assert_fail "[SPEC-2] parent ledger byte-identical after ZBUILD_COST_LEDGER-fenced call" \
        "parent ledger was modified"
fi

# ─── SPEC-3 (guard): ZBUILD_COST_LEDGER unset → writes to HOME default ───────
unset ZBUILD_COST_LEDGER
parent_lines_before=$(wc -l < "$PARENT_LEDGER" 2>/dev/null || echo 0)
_prime_router_cost
_route_update_ledger 2>/dev/null
parent_lines_after=$(wc -l < "$PARENT_LEDGER" 2>/dev/null || echo 0)
if [[ "$parent_lines_after" -gt "$parent_lines_before" ]]; then
    assert_pass "[SPEC-3] ZBUILD_COST_LEDGER unset: router defaults to HOME ledger"
else
    assert_fail "[SPEC-3] ZBUILD_COST_LEDGER unset: router defaults to HOME ledger" \
        "before=$parent_lines_before after=$parent_lines_after"
fi
# Restore parent ledger to gold.
cp "$PARENT_LEDGER_GOLD" "$PARENT_LEDGER"

# ─── SPEC-4: _route_check_budget reads from ZBUILD_COST_LEDGER ───────────────
# Small amount in fence ledger; large amount in HOME ledger.
# With budget=$0.50 and HOME over-budget, the check should still PASS when
# ZBUILD_COST_LEDGER points at the small-amount fence. Fails at baseline (reads HOME).
FENCE_LEDGER4="$TEST_TEMP_DIR/fence4/cost-ledger.jsonl"
mkdir -p "$(dirname "$FENCE_LEDGER4")"
printf '0.001000\n' > "$FENCE_LEDGER4"
printf '10.000000\n' > "$PARENT_LEDGER"
export ZBUILD_COST_LEDGER="$FENCE_LEDGER4"
export ZBUILD_BUDGET_USD="0.50"
_route_check_budget "T2" 2>/dev/null
spec4_rc=$?
unset ZBUILD_BUDGET_USD
unset ZBUILD_COST_LEDGER
if [[ $spec4_rc -eq 0 ]]; then
    assert_pass "[SPEC-4] _route_check_budget reads from ZBUILD_COST_LEDGER (not HOME)"
else
    assert_fail "[SPEC-4] _route_check_budget reads from ZBUILD_COST_LEDGER (not HOME)" \
        "returned rc=$spec4_rc (read HOME over-budget ledger instead of fence)"
fi
# Restore parent ledger.
cp "$PARENT_LEDGER_GOLD" "$PARENT_LEDGER"

# ─── SPEC-5/6/7: test-stage plugin fence via _test_run_inner ─────────────────
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"

MINIMAL_TEMPLATE_SRC="$REPO_ROOT/tests/fixtures/templates/runner-state-dir-minimal.yaml"
MINIMAL_TEMPLATE_INSTALLED="$REPO_ROOT/config/templates/runner-state-dir-minimal.yaml"
cp "$MINIMAL_TEMPLATE_SRC" "$MINIMAL_TEMPLATE_INSTALLED" 2>/dev/null || true
_test_cleanup_hook() {
    rm -f "$MINIMAL_TEMPLATE_INSTALLED" 2>/dev/null || true
}
mock_plugin_factory "intake" "agent" 0 "" "" >/dev/null
mock_plugin_factory "build"  "agent" 0 "" "" >/dev/null

# Source test plugin to get _test_run_inner.
# shellcheck source=../../plugins/tool/test/plugin.sh
source "$REPO_ROOT/plugins/tool/test/plugin.sh"

STAGE_ARTIFACTS="$TEST_TEMP_DIR/stage-artifacts"; mkdir -p "$STAGE_ARTIFACTS"
export ZBUILD_ARTIFACT_DIR="$STAGE_ARTIFACTS"
export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/stage-state"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/stage-events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
mkdir -p "$ZBUILD_EVENTS_DIR"

F_FIXTURE="$TEST_TEMP_DIR/f-repo"; mkdir -p "$F_FIXTURE"
git -C "$F_FIXTURE" init -q
git -C "$F_FIXTURE" config user.name t
git -C "$F_FIXTURE" config user.email t@t
printf 'hi\n' > "$F_FIXTURE/tracked.txt"
git -C "$F_FIXTURE" add tracked.txt
git -C "$F_FIXTURE" commit -q -m init
F_PATCH="$STAGE_ARTIFACTS/diff.patch"; : > "$F_PATCH"
F_OUT="$STAGE_ARTIFACTS/test-results.json"

# Suite command: dump the env vars seen inside the fresh shell, then write to
# the env-var-resolved ledger and cache paths (simulating a nested router+cache).
# Absolute path for ENV_DUMP survives the env-scrub / subshell boundary.
ENV_DUMP="$TEST_TEMP_DIR/env-dump.txt"
# Parent cache marker: written only if suite falls back to HOME/.zbuild/cache.
PARENT_CACHE="$HOME_DIR/.zbuild/cache"
SUITE_CMD="echo \"COST_LEDGER=\${ZBUILD_COST_LEDGER:-UNSET}\" >> '$ENV_DUMP'
echo \"CACHE_DIR=\${ZBUILD_CACHE_DIR:-UNSET}\" >> '$ENV_DUMP'
printf '0.005000\n' >> \"\${ZBUILD_COST_LEDGER:-$HOME_DIR/.zbuild/cost-ledger.jsonl}\"
mkdir -p \"\${ZBUILD_CACHE_DIR:-$PARENT_CACHE}\"
touch \"\${ZBUILD_CACHE_DIR:-$PARENT_CACHE}/marker\"
echo suite-ok"

set +e
_test_run_inner "$F_PATCH" "$F_FIXTURE" "$F_OUT" "$SUITE_CMD" >/dev/null 2>&1
set +e  # keep off — grep below may return 1 on no-match

# ─── SPEC-5: ZBUILD_COST_LEDGER exported under fence in suite env ─────────────
cost_ledger_seen="$(grep '^COST_LEDGER=' "$ENV_DUMP" 2>/dev/null | head -1 | cut -d= -f2- || true)"
if [[ -n "$cost_ledger_seen" && "$cost_ledger_seen" != "UNSET" ]]; then
    assert_pass "[SPEC-5] test plugin exports ZBUILD_COST_LEDGER under fence in suite env"
else
    assert_fail "[SPEC-5] test plugin exports ZBUILD_COST_LEDGER under fence in suite env" \
        "suite saw ZBUILD_COST_LEDGER=${cost_ledger_seen:-<empty>}"
fi

# ─── SPEC-6: ZBUILD_CACHE_DIR exported under fence in suite env ──────────────
cache_dir_seen="$(grep '^CACHE_DIR=' "$ENV_DUMP" 2>/dev/null | head -1 | cut -d= -f2- || true)"
if [[ -n "$cache_dir_seen" && "$cache_dir_seen" != "UNSET" ]]; then
    assert_pass "[SPEC-6] test plugin exports ZBUILD_CACHE_DIR under fence in suite env"
else
    assert_fail "[SPEC-6] test plugin exports ZBUILD_CACHE_DIR under fence in suite env" \
        "suite saw ZBUILD_CACHE_DIR=${cache_dir_seen:-<empty>}"
fi

# ─── SPEC-7: parent ledger + cache untouched after test-stage fence ──────────
# The suite wrote to ${ZBUILD_COST_LEDGER:-HOME_ledger}. With the fix, it goes to
# the fence; without the fix (baseline), it goes to HOME → parent ledger changes.
parent_ledger_changed=0
cmp -s "$PARENT_LEDGER" "$PARENT_LEDGER_GOLD" || parent_ledger_changed=1
parent_cache_touched=0
[[ -e "$PARENT_CACHE/marker" ]] && parent_cache_touched=1
if [[ $parent_ledger_changed -eq 0 && $parent_cache_touched -eq 0 ]]; then
    assert_pass "[SPEC-7] parent ledger + cache untouched after test-stage fence"
elif [[ $parent_ledger_changed -eq 1 ]]; then
    assert_fail "[SPEC-7] parent ledger + cache untouched after test-stage fence" \
        "parent cost-ledger.jsonl was modified (suite wrote to HOME ledger)"
else
    assert_fail "[SPEC-7] parent ledger + cache untouched after test-stage fence" \
        "parent cache/marker was created (suite wrote to HOME cache)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
