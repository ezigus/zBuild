#!/usr/bin/env bash
# Integration: spec-coverage reaches the router when DISPATCHED (#2061).
#
# plugins/agent/spec-coverage/plugin.sh guards its model call on
# `declare -f route_to_model`, but never sourced core/router/route.sh — the only
# file that defines it. plugin-bootstrap.sh supplies helpers.sh and
# artifact-render.sh, and says so at line 22: a plugin needing the router sources
# it itself. So in production `_raw` was always empty, no VERDICT line ever
# parsed, and the stage took its unreadable path on every run — observed in run
# 33944161764, spec-coverage-result.json verdict "unreadable", reason "no
# parseable verdict from the model — the design was not judged".
#
# tests/unit/spec-coverage-test.sh defines its own `route_to_model` in the test
# shell, so the guard always passed there and the router-absent path — the only
# one production takes — was never exercised. That is why the suite stayed green
# across every run in which the stage did nothing.
#
# This drives the REAL plugin through the REAL dispatch seam (plugin_hook_call,
# which sources plugin.sh into a subshell of a runner shell that has never
# sourced route.sh — runner.sh does not) with a stubbed `claude` on PATH, so the
# only way a verdict can appear in the artifact is an actual router round trip.
#
#   SPEC-1 [guard] : the dispatching shell defines no route_to_model. Without
#                    this the test is blind exactly the way the unit test is.
#   SPEC-2 [change]: a dispatched spec-coverage does NOT report verdict
#                    "unreadable" with reason "no parseable verdict from the
#                    model" — the design was actually judged.
#   SPEC-3 [change]: the model's verdict reaches the artifact. The stub answers
#                    `uncovered` and names a requirement; only a completed
#                    router call can put either in spec-coverage-result.json.
#   SPEC-4 [guard] : the `claude` stub was actually spawned. SPEC-2 and SPEC-3
#                    read the artifact, and an artifact can be right for reasons
#                    that are not a model call; this records the spawn itself.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# The engine's dispatch seam. Deliberately the ONLY engine library loaded here:
# it is what the runner loads, and — like the runner — it does not pull in
# core/router/route.sh.
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

print_test_header "spec-coverage reaches the router when dispatched (#2061)"
setup_test_env "spec-coverage-router-reachable"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_CONTRACT_VALIDATOR=warn
export ZBUILD_RUN_ID="scv-router-2061-$$"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
# ADR-055 §1.5: the dispatch refuses a stage whose required inputs no stage in
# the resolved flow produces. The runner publishes the flow as the _TPL_STAGES
# array; ZBUILD_INPUTS_FLOW is the scalar equivalent for callers that have no
# template loaded. Both templates put intake and design upstream of
# spec-coverage, which is what makes intake_goal and design resolvable.
export ZBUILD_INPUTS_FLOW="intake design spec-coverage"

# ─── SPEC-1: the dispatching shell has no router ────────────────────────────
# The blindness guard. If some library ever starts sourcing route.sh into the
# runner shell, this test would silently stop testing anything, so it must fail
# loudly instead — the failure mode #2061 itself is made of.
if declare -f route_to_model >/dev/null 2>&1; then
    assert_fail "[SPEC-1][guard] the dispatching shell defines no route_to_model" \
        "route_to_model IS defined before dispatch — this test can no longer see the defect"
else
    assert_pass "[SPEC-1][guard] the dispatching shell defines no route_to_model"
fi

# ─── The model stub ─────────────────────────────────────────────────────────
# Answers `uncovered` and names a requirement. Neither string exists anywhere in
# the plugin, so neither can reach the artifact except through the router.
_SCV_UNCOVERED_REQ="refusing a missing config"
# The spawn marker. ADR-024 scrubs the whole ZBUILD_* namespace before the
# claude exec, so the stub cannot be told where to write through a ZBUILD_ var —
# the path is baked into the script at write time.
_SCV_SPAWN_MARK="$TEST_TEMP_DIR/claude-was-spawned"
: > "$_SCV_SPAWN_MARK"
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
printf 'spawned\n' >> "$_SCV_SPAWN_MARK"
cat <<'REPLY'
VERDICT: uncovered
REASON: the refusal path is not covered by any SPEC
UNCOVERED: $_SCV_UNCOVERED_REQ
REPLY
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

# ─── Stage inputs, as the manifest declares them ────────────────────────────
STATE_DIR="$TEST_TEMP_DIR/state"
ART_DIR="$STATE_DIR/artifacts"
mkdir -p "$ART_DIR"
export ZBUILD_STATE_DIR="$STATE_DIR"
STATE_FILE="$STATE_DIR/pipeline-state.json"
printf '{}' > "$STATE_FILE"

# intake_goal — real issue prose, NOT the "GitHub issue #<N>" placeholder, so
# the stage cannot take its other unreadable branch.
cat > "$STATE_DIR/intake.md" <<'EOF'
Add a --dry-run flag to the CLI, and make it refuse to start when the config
file is missing rather than falling back to defaults.
EOF

# design — needs a parseable acceptance block, else the stage short-circuits
# before it ever reaches the router.
cat > "$ART_DIR/design.md" <<'EOF'
# Design

```acceptance
SPEC-1[change]: a --dry-run flag is accepted and prints the plan without acting
TESTFILES:
SPEC-1: tests/unit/dry-run-test.sh
WIRING: scripts/cli.sh
```
EOF

_res() { jq -r "$1" "$ART_DIR/spec-coverage-result.json" 2>/dev/null || echo MISSING; }

# ─── Dispatch exactly as the engine does ────────────────────────────────────
set +e
plugin_hook_call "$REPO_ROOT/plugins/agent/spec-coverage" run "spec-coverage" "$STATE_FILE" \
    >"$TEST_TEMP_DIR/dispatch.out" 2>"$TEST_TEMP_DIR/dispatch.err"
_dispatch_rc=$?
set -e

_verdict="$(_res '.verdict')"
_reason="$(_res '.reason')"

# ─── SPEC-2: the design was actually judged ─────────────────────────────────
if [[ "$_verdict" == "unreadable" && "$_reason" == *"no parseable verdict from the model"* ]]; then
    assert_fail "[SPEC-2][change] a dispatched spec-coverage does not fall to the no-verdict path" \
        "verdict=$_verdict reason=$_reason (dispatch rc=$_dispatch_rc) — route_to_model was undefined at dispatch, so the model was never called"
else
    assert_pass "[SPEC-2][change] a dispatched spec-coverage does not fall to the no-verdict path"
fi

# ─── SPEC-3: the model's own answer reached the artifact ────────────────────
assert_eq "[SPEC-3][change] the model's verdict is what the artifact records" \
    "uncovered" "$_verdict"
assert_eq "[SPEC-3][change] and the requirement it named is in data.uncovered[]" \
    "$_SCV_UNCOVERED_REQ" "$(_res '.data.uncovered[0]')"

# ─── SPEC-4: the model was really spawned ───────────────────────────────────
assert_eq "[SPEC-4][guard] the claude stub was spawned exactly once" \
    "1" "$(wc -l < "$_SCV_SPAWN_MARK" | tr -d '[:space:]')"

print_test_results
exit $((FAIL > 0))
