#!/usr/bin/env bash
# Tests: ADR-018 (#466) — router claude flag-set adoption across the
# subprocess boundary. Forks a real bash -c child that sources the libs
# from scratch (no in-memory state from the parent). Mocks claude via PATH
# shim that records argv NUL-delimited to disk; parent asserts the four
# new flags are present and that the per-stage template knob propagates
# end-to-end.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "router-claude-flags e2e — subprocess boundary (#466, ADR-018)"
setup_test_env "router-claude-flags-e2e"

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

# Argv-recording claude mock — writes NUL-delimited argv tokens so commas in
# --disallowed-tools "EnterPlanMode,ExitPlanMode" survive verbatim.
ARGV_FILE="$TEST_TEMP_DIR/last_args"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
: > "$ARGV_FILE"
for a in "\$@"; do printf '%s\0' "\$a"; done > "$ARGV_FILE"
echo "OK-RESPONSE"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

# Per-stage fixture: build with max_turns=42 (distinct from default 25 and env 10).
FIXTURE="$TEST_TEMP_DIR/fixture.yaml"
cat > "$FIXTURE" <<'EOF'
id: cf-e2e
name: CF E2E
defaults:
  strategy: fanout

stages:
  - id: build
    gate: auto
    roles: [builder]
    router:
      max_turns: 42
EOF

# Pre-seed events.jsonl with a redaction.applied event so that the child
# subprocess can satisfy the C6 precondition WITHOUT --skip-precondition.
# This exercises the realistic path where redaction.applied gates the call.
# The event carries the envelope `stage` field that eb_emit_event stamps from
# ZBUILD_CURRENT_STAGE (ADR-039 §3): the child runs the `build` stage below, and
# C6 is now scoped per-stage, so the seeded redaction must be tagged `build` —
# exactly as a real in-stage redaction.applied would be.
export ZBUILD_RUN_ID="cf-e2e-run-id"
: > "$ZBUILD_EVENTS_JSONL"
jq -cn --arg rid "$ZBUILD_RUN_ID" \
    '{ts:"2026-01-01T00:00:00Z", run_id:$rid, issue:0, type:"redaction.applied",
      plugin:"", kind:"", stage:"build", data:{}, schema_version:1}' \
    >> "$ZBUILD_EVENTS_JSONL"

# Fork a real subprocess. Inside: source libs from scratch, load template,
# set ZBUILD_CURRENT_STAGE=build + ZBUILD_ROUTER_MAX_TURNS=10 (env that would
# win if the per-stage export regressed), call route_to_model.
# A SPACE in the scratch path, deliberately. --add-dir is the grant (#1919 P4),
# and route.sh used to assemble it with `_claude_args+=($(_zbuild_permission_args))`
# — an unquoted command substitution, which splits "e2e scratch dir" into three
# argv tokens and silently grants a directory nobody named. This path is the only
# place that regression is observable, because it is real recorded argv.
_e2e_scratch="$TEST_TEMP_DIR/e2e scratch dir"
# #1961: artifacts/ is a SIBLING of scratch/, never a child — that is precisely
# why granting scratch did not reach it and every design stage died on a refused
# write. Laid out as siblings here so the assertion below is not accidentally
# satisfied by containment.
_e2e_artifacts="$TEST_TEMP_DIR/e2e-run-state/artifacts"
mkdir -p "$_e2e_scratch" "$_e2e_artifacts"
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
export ZBUILD_RUN_ID='$ZBUILD_RUN_ID'
export ZBUILD_STAGE_SCRATCH='$_e2e_scratch'
export ZBUILD_REPO_ROOT='$REPO_ROOT'
export ZBUILD_ARTIFACT_DIR='$_e2e_artifacts'
source '$REPO_ROOT/scripts/lib/helpers.sh'
source '$REPO_ROOT/core/pipeline/template.sh'
source '$REPO_ROOT/core/router/route.sh'
load_template '$FIXTURE'
export ZBUILD_CURRENT_STAGE=build
export ZBUILD_ROUTER_MAX_TURNS=10
route_to_model T2 'ping' >/dev/null 2>&1
" || true

# Read argv tokens back from disk.
argv_nl="$(tr '\0' '\n' < "$ARGV_FILE" 2>/dev/null || true)"

assert_contains "e2e: argv has --max-turns" "$argv_nl" "--max-turns"
if grep -qx -- "42" <<< "$argv_nl"; then
    assert_pass "e2e: per-stage max_turns=42 propagates through subprocess (export not regressed)"
else
    assert_fail "e2e: per-stage max_turns=42 propagates through subprocess" "argv: $argv_nl"
fi

assert_contains "e2e: argv has --disallowed-tools" "$argv_nl" "--disallowed-tools"
if grep -qx -- "EnterPlanMode,ExitPlanMode" <<< "$argv_nl"; then
    assert_pass "e2e: disallowed-tools comma preserved as single argv token"
else
    assert_fail "e2e: disallowed-tools comma preserved" "argv: $argv_nl"
fi
# [SPEC-1] C10: --dangerously-skip-permissions replaced by acceptEdits + settings file.
if grep -qx -- "--permission-mode" <<< "$argv_nl"; then
    assert_pass "[SPEC-1] e2e: argv has --permission-mode"
else
    assert_fail "[SPEC-1] e2e: argv has --permission-mode" "argv: $argv_nl"
fi
if grep -qx -- "acceptEdits" <<< "$argv_nl"; then
    assert_pass "[SPEC-1] e2e: argv has acceptEdits"
else
    assert_fail "[SPEC-1] e2e: argv has acceptEdits" "argv: $argv_nl"
fi
if grep -qx -- "--settings" <<< "$argv_nl"; then
    assert_pass "[SPEC-1] e2e: argv has --settings"
else
    assert_fail "[SPEC-1] e2e: argv has --settings" "argv: $argv_nl"
fi
# --add-dir IS the grant (#1919 P4) — the settings file grants nothing (P2b).
# Without this assertion a regression dropping --add-dir leaves every stage
# unable to write its scratch dir while the three checks above stay green: the
# exact shape of the bug this issue corrected.
if grep -qx -- "--add-dir" <<< "$argv_nl"; then
    assert_pass "[SPEC-1] e2e: argv carries the --add-dir grant"
else
    assert_fail "[SPEC-1] e2e: argv carries the --add-dir grant" "argv: $argv_nl"
fi
# [SPEC-1] #1961: the ARTIFACT dir reaches real argv. The unit test proves the
# helper emits it; only this path proves it survives route.sh's assembly and the
# subprocess boundary into the argv `claude` is actually spawned with. That gap
# is where #1919 shipped green — the helper was right about two directories and
# nothing checked the one the engine tells models to write.
if grep -qxF -- "$_e2e_artifacts" <<< "$argv_nl"; then
    assert_pass "[SPEC-1] e2e: argv grants the run artifact dir (#1961)"
else
    assert_fail "[SPEC-1] e2e: argv grants the run artifact dir (#1961)" "argv: $argv_nl"
fi
# The granted path must survive assembly as ONE token, spaces and all.
if grep -qxF -- "$_e2e_scratch" <<< "$argv_nl"; then
    assert_pass "[SPEC-2] e2e: a granted path containing spaces stays one argv token"
else
    assert_fail "[SPEC-2] e2e: a granted path containing spaces stays one argv token" \
        "argv: $argv_nl"
fi

# C6 precondition precondition: the redaction.applied event we seeded must still
# be visible — the child invoked route_to_model WITHOUT --skip-precondition,
# so a successful call proves the gate passed.
if grep -q '"redaction.applied"' "$ZBUILD_EVENTS_JSONL"; then
    assert_pass "e2e: C6 redaction.applied gate respected (still in events log)"
else
    assert_fail "e2e: C6 redaction.applied event missing" ""
fi

# model.route event must have been emitted by the child after gate pass.
route_evt="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.route") | .data.tier // empty' 2>/dev/null | tail -1 || true)"
assert_eq "e2e: model.route emitted from child subprocess" "T2" "$route_evt"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
