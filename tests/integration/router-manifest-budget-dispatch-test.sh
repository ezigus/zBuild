#!/usr/bin/env bash
# tests/integration/router-manifest-budget-dispatch-test.sh — #1816
#
# The unit test pins the resolution RULE with ZBUILD_PLUGIN_DIR set by hand.
# That is exactly the shape of test that let #1862 hide for the life of the
# project: three tests exported the value they then asserted, so a production
# read that always resolved to "" reddened nothing.
#
# So this file never sets it. It dispatches a fixture plugin through the real
# plugin_hook_call and asserts that the budget the PLUGIN declared is what the
# ROUTER resolved, inside the plugin's own process. Everything between —
# engine-exported identity (ADR-054 §3), route.sh's manifest layer (ADR-017
# §11), the manifest reader — is exercised, not stubbed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

print_test_header "router manifest budget — resolved across a real dispatch (#1816)"

setup_test_env "router-manifest-budget-dispatch"

# The values under test must come from the dispatch, never from this shell.
unset ZBUILD_PLUGIN ZBUILD_PLUGIN_KIND ZBUILD_PLUGIN_DIR ZBUILD_CURRENT_STAGE 2>/dev/null || true
unset ZBUILD_ROUTER_TIMEOUT ZBUILD_ROUTER_MAX_TURNS ZBUILD_ROUTER_RETRIES 2>/dev/null || true
unset ZBUILD_ROUTER_MAX_TURNS_OVERRIDE 2>/dev/null || true

# ─── Fixtures: one plugin that declares a budget, one that declares none ─────
_mk_fixture() {  # <name> <router-block-or-empty> → plugin dir
    local name="$1" router_block="$2"
    local dir="$TEST_TEMP_DIR/$name"
    mkdir -p "$dir"
    {
        printf 'id: %s\nname: %s\nkind: agent\nversion: 0.0.1\n' "$name" "$name"
        printf 'summary: budget dispatch fixture\n'
        printf 'requires:\n  core: [redaction]\n'
        printf 'hooks:\n  run: rmb_run\n'
        printf 'config:\n  tier_default: T1\n'
        [[ -n "$router_block" ]] && printf '%s' "$router_block"
    } > "$dir/manifest.yaml"

    # The hook asks the ROUTER what budget it has, exactly as a stage does.
    # $_RMB_ROOT / $_RMB_OUT are baked in at construction: they are not ZBUILD_*
    # and so say nothing about the identity under test.
    {
        printf '_RMB_ROOT=%q\n' "$REPO_ROOT"
        printf '_RMB_OUT=%q\n'  "$TEST_TEMP_DIR/$name-seen.txt"
        cat <<'FIXTURE'
rmb_run() {
    source "$_RMB_ROOT/core/router/route.sh"
    {
        printf 'timeout=%s\n'   "$(_route_resolve_timeout)"
        printf 'max_turns=%s\n' "$(_route_resolve_max_turns)"
        printf 'retries=%s\n'   "$(_route_resolve_retries)"
        printf 'dir=%s\n'       "${ZBUILD_PLUGIN_DIR-<unset>}"
    } > "$_RMB_OUT"
    return 0
}
FIXTURE
    } > "$dir/plugin.sh"
    printf '%s' "$dir"
}

_DECLARES="$(_mk_fixture rmb-declares '  router:
    timeout_s: 777
    max_turns: 3
    retries: 2
')"
_SILENT="$(_mk_fixture rmb-silent '')"

_dispatch() {  # <plugin dir> <stage name>
    local _rc=0
    local _old_dir="${ZBUILD_EVENTS_DIR:-}" _old_jsonl="${ZBUILD_EVENTS_JSONL:-}" _old_db="${ZBUILD_EVENTS_DB:-}"
    ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR"
    ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events.jsonl"
    ZBUILD_EVENTS_DB="/dev/null"
    set +e
    plugin_hook_call "$1" run "$2" "$TEST_TEMP_DIR/pipeline-state.json" >/dev/null 2>&1
    _rc=$?
    set -e
    ZBUILD_EVENTS_DIR="$_old_dir"; ZBUILD_EVENTS_JSONL="$_old_jsonl"; ZBUILD_EVENTS_DB="$_old_db"
    return $_rc
}

_seen() { grep "^$2=" "$TEST_TEMP_DIR/$1-seen.txt" 2>/dev/null | head -1 | cut -d= -f2-; }

# ─── SPEC-1: a declared budget reaches the router inside the dispatch ────────
print_test_section "[SPEC-1] the plugin's declared budget is what the router resolves"

_dispatch "$_DECLARES" budget_fixture_stage
assert_eq "[SETUP] declaring fixture dispatched cleanly" "0" "$?"
assert_eq "[SETUP] the engine — not this test — supplied ZBUILD_PLUGIN_DIR" \
    "$_DECLARES" "$(_seen rmb-declares dir)"

assert_eq "[SPEC-1] router.timeout_s comes from the manifest, not the 300s constant" \
    "777" "$(_seen rmb-declares timeout)"
assert_eq "[SPEC-1] router.max_turns comes from the manifest, not the 25 constant" \
    "3" "$(_seen rmb-declares max_turns)"
assert_eq "[SPEC-1] router.retries comes from the manifest, not the 0 constant" \
    "2" "$(_seen rmb-declares retries)"

# ─── SPEC-2: a plugin that declares nothing is unchanged ────────────────────
print_test_section "[SPEC-2] a plugin declaring no budget resolves exactly as before"

_dispatch "$_SILENT" budget_fixture_stage
assert_eq "[SETUP] silent fixture dispatched cleanly" "0" "$?"
assert_eq "[SPEC-2] timeout_s is the 300s constant" "300" "$(_seen rmb-silent timeout)"
assert_eq "[SPEC-2] max_turns is the 25 constant" "25" "$(_seen rmb-silent max_turns)"
assert_eq "[SPEC-2] retries is the 0 constant" "0" "$(_seen rmb-silent retries)"

# ─── SPEC-3: identity does not leak into the NEXT dispatch ──────────────────
# plugin_hook_call uses `local -x`, so stage N's manifest cannot be read by
# stage N+1. SPEC-2 running after SPEC-1 already proves it (the silent fixture
# would otherwise report 777); assert it as a named contract so a future change
# to `export` reddens here with the reason attached.
print_test_section "[SPEC-3] one plugin's declared budget does not bleed into the next"

if [[ "$(_seen rmb-silent timeout)" == "$(_seen rmb-declares timeout)" ]]; then
    assert_fail "[SPEC-3] the declaring plugin's budget did not survive its own dispatch" \
        "both dispatches resolved $(_seen rmb-silent timeout)"
else
    assert_pass "[SPEC-3] the declaring plugin's budget did not survive its own dispatch"
fi

# ─── SPEC-4: the operator escape hatch still beats a declaration ─────────────
print_test_section "[SPEC-4] ZBUILD_ROUTER_TIMEOUT still overrides a declared budget"

ZBUILD_ROUTER_TIMEOUT=61 _dispatch "$_DECLARES" budget_fixture_stage
assert_eq "[SPEC-4] env wins over the manifest across the dispatch boundary" \
    "61" "$(_seen rmb-declares timeout)"

print_test_results
exit $((FAIL > 0))
