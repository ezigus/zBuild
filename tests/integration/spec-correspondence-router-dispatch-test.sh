#!/usr/bin/env bash
# tests/integration/spec-correspondence-router-dispatch-test.sh — #2062 Defect A
#
# The stage calls route_to_model but never sourced the file that defines it.
# plugin-bootstrap.sh supplies helpers.sh and artifact-render.sh only (its
# line-22 comment says so explicitly: a plugin needing the router sources it
# itself, as build/plugin.sh:31 and design/plugin.sh:32 do). The engine does not
# supply it either — cycle-orchestrator.sh:50 records that the runner's main
# process does NOT source route.sh, "only plugin subshells do, via route.sh".
#
# The unit tests never saw this because they define route_to_model in their own
# shell before sourcing the plugin, so the function is always in scope. The
# defect only exists at the boundary the unit tests erase, which is why this
# test crosses a real one: a separate `bash` PROCESS, holding exactly what a
# production dispatch holds — the registry, the engine's env, and nothing the
# test author defined.
#
#   SPEC-1 [change]: dispatched across a process boundary with only what the
#                    engine supplies, the plugin is NOT starved of a router —
#                    route_to_model is defined once plugin.sh has loaded
#   SPEC-2 [change]: and the judgment therefore reaches the model: with a model
#                    replying `VERDICT: corresponds` for the one SPEC, the stage
#                    records one correspondence rather than zero
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "spec-correspondence: the dispatched plugin has a router (#2062 A)"
setup_test_env "spec-correspondence-router-dispatch"
_test_cleanup_hook() { cleanup_test_env; }

# ── The run's state directory, shaped as the engine shapes it ────────────────
_S="$TEST_TEMP_DIR/state/runs/20260907-sc-dispatch"
_A="$_S/artifacts"
_R="$TEST_TEMP_DIR/repo"
mkdir -p "$_A" "$_S/runtime" "$_R/tests"
printf '{}\n' > "$_S/pipeline-state.json"

cat > "$_R/tests/acc-test.sh" <<'FIX'
if grep -q 'data' "$OUT"; then
    assert_pass "[SPEC-1] fields are nested under data"
else
    assert_fail "[SPEC-1] fields are not nested"
fi
FIX
cat > "$_A/design.md" <<'EOF'
# Design
```acceptance
SPEC-1[change]: plugin-specific fields live under data:{} not at the top level
TESTFILES:
SPEC-1: tests/acc-test.sh
WIRING: scripts/thing.sh
```
EOF

# ── A model that answers, so "zero judged" can only mean the call never happened ──
mock_binary "claude" 'cat >/dev/null 2>&1 || true
echo "VERDICT: corresponds"
echo "REASON: the assertion checks exactly the property the requirement names"
exit 0'

_PROBE="$TEST_TEMP_DIR/router-in-scope.txt"

# ── The driver: a fresh process holding what a production dispatch holds ─────
# NOT named *-test.sh — test-helpers' re-entrancy guard (#971) refuses those.
# It sources the registry, which is what the runner has, and nothing else: no
# route_to_model stub exists anywhere in this process, so whether the plugin can
# reach a model is decided entirely by what plugin.sh itself sources.
_DRIVER="$TEST_TEMP_DIR/dispatch-driver.sh"
cat > "$_DRIVER" <<'DRIVER'
#!/usr/bin/env bash
set -uo pipefail
_ROOT="$1"; _STATE="$2"; _PROBE="$3"

# What does the dispatch subshell see once plugin.sh has loaded? This is the
# same `source plugin.sh` that plugin_hook_call's subshell performs.
(
    source "$_ROOT/plugins/agent/spec-correspondence/plugin.sh" >/dev/null 2>&1
    if declare -F route_to_model >/dev/null 2>&1; then
        printf 'defined\n' > "$_PROBE"
    else
        printf 'MISSING\n' > "$_PROBE"
    fi
)

# shellcheck source=/dev/null
source "$_ROOT/core/plugin-registry/registry.sh"
plugin_hook_call "$_ROOT/plugins/agent/spec-correspondence" run \
    spec-correspondence "$_STATE"
DRIVER
chmod +x "$_DRIVER"

export ZBUILD_REPO_ROOT="$_R"
export ZBUILD_STATE_DIR="$_S"
# ADR-055 §1: the flow the runner exports, so the declared `design` input
# resolves to the design stage's output and the dispatch is not refused
# pre-launch. Without it the stage never launches and the test would be
# measuring input resolution rather than the router.
export ZBUILD_INPUTS_FLOW="design spec-correspondence"
export ZBUILD_RUN_ID="sc-dispatch-$$"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENTS_DB="/dev/null"

set +e
_out="$(bash "$_DRIVER" "$REPO_ROOT" "$_S/pipeline-state.json" "$_PROBE" 2>&1)"
_rc=$?
set -e

_res() { jq -r "$1" "$_A/spec-correspondence-result.json" 2>/dev/null || echo MISSING; }

# ── SPEC-1: the plugin brings its own router ────────────────────────────────
assert_eq "[SPEC-1][change] route_to_model is defined after plugin.sh loads in a fresh process" \
    "defined" "$(cat "$_PROBE" 2>/dev/null || echo NO-PROBE)"

# ── SPEC-2: and the model call actually happens ─────────────────────────────
assert_eq "[SPEC-2][change] the dispatched stage judged its one SPEC" \
    "1" "$(_res '.data.corresponds')"

if [[ "$(_res '.data.corresponds')" != "1" ]]; then
    printf 'dispatch rc=%s\n--- driver output ---\n%s\n--- result ---\n%s\n' \
        "$_rc" "$_out" "$(cat "$_A/spec-correspondence-result.json" 2>/dev/null || echo NONE)" >&2
fi

print_test_results
exit $((FAIL > 0))
