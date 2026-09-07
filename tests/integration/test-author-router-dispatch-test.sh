#!/usr/bin/env bash
# tests/integration/test-author-router-dispatch-test.sh — the test-author stage
# reaches a router when the engine dispatches it (#2060).
#
#   SPEC-1 [guard] : dispatched across a real process boundary, with NO
#                    route_to_model pre-defined by the caller, test-author does
#                    not report disposition=unavailable / "no router available"
#   SPEC-2 [change]: it reaches the model — the claude spawn actually happens —
#                    and the pass completes
#
# Integration, and a SUBPROCESS, because that is the only shape that can see the
# defect. tests/unit/test-author-test.sh defines its own `route_to_model` stub at
# file scope, so the guard inside the plugin has always passed under test while
# always firing in production: plugin-bootstrap.sh supplies helpers.sh and
# artifact-render.sh only, and its own comment says a plugin needing the router
# must source it. plugin_hook_call sources plugin.sh in a SUBSHELL, so a stub
# defined by a test file would be inherited there too — only a fresh process
# reproduces the dispatch the engine actually performs.
#
# Observed at baseline in run 33944161764 (#1848): five cycle iterations, each
# opening with `cycle.member.disposition.halt member=test-author
# disposition=unavailable rc=1`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "test-author: the dispatched stage has a router (#2060)"
setup_test_env "test-author-router-dispatch"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_RUN_ID="20260907-ta-router"
# No scope manifest → _route_redact_prompt takes its documented passthrough arm;
# the router still emits redaction.applied, so the ADR-004 chokepoint holds.
unset ZBUILD_SCOPE_MANIFEST 2>/dev/null || true

# ─── The job folder the engine would hand the stage ──────────────────────────
JOB_DIR="$TEST_TEMP_DIR/state/runs/20260907-ta-router"
STATE_FILE="$JOB_DIR/pipeline-state.json"
ART="$JOB_DIR/artifacts"
mkdir -p "$ART" "$JOB_DIR/runtime"
echo '{}' > "$STATE_FILE"
export ZBUILD_STATE_DIR="$JOB_DIR"
# The resolved flow, exactly as runner.sh:1435 exports it — test-author declares
# `design` a required input, and the producer index is built from the flow.
export ZBUILD_INPUTS_FLOW="design test-author"

REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO/tests"
printf '%s\n' 'assert_eq "[SPEC-1] placeholder" "1" "$got"' > "$REPO/tests/acc-test.sh"
export ZBUILD_REPO_ROOT="$REPO"

cat > "$ART/design.md" <<'EOF'
# Design
```acceptance
SPEC-1[change]: plugin-specific fields live under data:{} not at the top level
TESTFILES:
SPEC-1: tests/acc-test.sh
WIRING: scripts/thing.sh
```
EOF

# ─── Mock claude: records that the spawn happened, answers like the CLI ──────
CLAUDE_CALLED="$TEST_TEMP_DIR/claude-called.txt"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
printf 'called\n' >> "$CLAUDE_CALLED"
printf 'authored the assertions\n'
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

# ─── The driver: a FRESH process that knows only what the engine knows ──────
# It sources the plugin registry and nothing else. It never sources route.sh and
# never defines route_to_model — supplying either would rebuild the blind spot
# this test exists to remove.
DRIVER="$TEST_TEMP_DIR/dispatch-test-author.sh"
PROBE="$TEST_TEMP_DIR/router-probe.txt"
cat > "$DRIVER" <<'DRV'
#!/usr/bin/env bash
set -uo pipefail
_repo="$1" _state="$2" _plugin_dir="$3" _probe="$4"
# shellcheck disable=SC1090
source "$_repo/scripts/lib/helpers.sh"
# shellcheck disable=SC1090
source "$_repo/core/event-bus/event-bus.sh"
# shellcheck disable=SC1090
source "$_repo/core/plugin-registry/registry.sh"

# NON-VACUITY: prove the dispatch shell really is router-free before the plugin
# is sourced. If some include chain started supplying route_to_model, this test
# would pass while saying nothing about the plugin's own sourcing.
if declare -F route_to_model >/dev/null 2>&1; then
    printf 'pre-defined\n' > "$_probe"
else
    printf 'absent\n' > "$_probe"
fi

plugin_hook_call "$_plugin_dir" "run" "test-author" "$_state"
printf 'hook_rc=%s\n' "$?"
DRV
chmod +x "$DRIVER"

DISPATCH_LOG="$TEST_TEMP_DIR/dispatch.log"
bash "$DRIVER" "$REPO_ROOT" "$STATE_FILE" \
    "$REPO_ROOT/plugins/agent/test-author" "$PROBE" >"$DISPATCH_LOG" 2>&1
_res() { jq -r "$1" "$ART/test-author-result.json" 2>/dev/null || echo MISSING; }

# ─── SPEC-1: the router is present where production dispatches the stage ────
print_test_section "SPEC-1: the dispatched stage does not report 'no router available'"

assert_eq "[SPEC-1][guard] the dispatch shell had no route_to_model of its own" \
    "absent" "$(cat "$PROBE" 2>/dev/null || echo MISSING)"

assert_file_exists "[SPEC-1][guard] the dispatch wrote a result at all" \
    "$ART/test-author-result.json"

if [[ "$(_res '.reason')" == *"no router available"* ]]; then
    assert_fail "[SPEC-1][guard] the dispatched stage does not report 'no router available'" \
        "reason: $(_res '.reason')
  disposition: $(_res '.disposition')  verdict: $(_res '.verdict')
  dispatch log: $(tr '\n' '|' < "$DISPATCH_LOG")"
else
    assert_pass "[SPEC-1][guard] the dispatched stage does not report 'no router available'"
fi

assert_eq "[SPEC-1][guard] nor disposition=unavailable" \
    "1" "$([[ "$(_res '.disposition')" != "unavailable" ]] && echo 1 || echo 0)"

# ─── SPEC-2: it actually reached the model, and the pass completed ──────────
print_test_section "SPEC-2: the stage reaches the model and completes"

# The paired non-vacuity check for SPEC-1: "not unavailable" is also what an
# early return gives (no design.md, no SPECs), and that reads as a pass.
assert_file_exists "[SPEC-2][change] the router actually spawned the model" \
    "$CLAUDE_CALLED"

assert_eq "[SPEC-2][change] the authoring pass completed" \
    "complete" "$(_res '.disposition')"
assert_eq "[SPEC-2][change] and it authored against the design's one SPEC" \
    "1" "$(_res '.data.specs_covered')"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
