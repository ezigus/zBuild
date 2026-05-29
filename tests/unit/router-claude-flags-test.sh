#!/usr/bin/env bash
# Tests: ADR-018 (#466) — router adopts shipwright's claude flag set.
# Locks the argv shape: --max-turns N --disallowed-tools "..." --dangerously-skip-permissions
# coexist with --print/--model/--output-format and resolve max_turns via
# the per-stage > env > 25 precedence rule (mirrors ADR-017's timeout_s).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "router-claude-flags — ADR-018 flag-set adoption (#466)"
setup_test_env "router-claude-flags"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$TEST_TEMP_DIR/events"

# Operator override scope token so --skip-precondition works.
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
echo -n "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# ─── Argv-recording claude mock ──────────────────────────────────────────────
# Records full argv NUL-delimited to $TEST_TEMP_DIR/last_args, plus a
# newline-joined copy to $TEST_TEMP_DIR/last_args_nl for easy grepping.
_install_recording_mock() {
    cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
: > "$TEST_TEMP_DIR/last_args"
for a in "\$@"; do printf '%s\0' "\$a"; done > "$TEST_TEMP_DIR/last_args"
printf '%s\n' "\$@" > "$TEST_TEMP_DIR/last_args_nl"
echo "OK-RESPONSE"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
}
_install_recording_mock

# Helper: read argv tokens as a newline-delimited list (one arg per line).
_read_argv() {
    # NUL-delimited file → newline list; preserves embedded commas/spaces in single tokens.
    tr '\0' '\n' < "$TEST_TEMP_DIR/last_args" 2>/dev/null || true
}

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"

# ─── T1: default flags present ───────────────────────────────────────────────
unset ZBUILD_ROUTER_MAX_TURNS ZBUILD_CURRENT_STAGE ZBUILD_ROUTER_JSON_OUTPUT
: > "$ZBUILD_EVENTS_JSONL"

set +e
route_to_model "T2" "ping" --skip-precondition >/dev/null 2>&1
rc=$?
set -e

assert_eq "T1: route returns rc=0" "0" "$rc"

argv="$(_read_argv)"
assert_contains "T1: argv contains --max-turns" "$argv" "--max-turns"
# The value 25 must appear as its own argv token (not embedded in another flag).
if grep -qx -- "25" <<< "$argv"; then
    assert_pass "T1: argv contains default max_turns=25 as its own token"
else
    assert_fail "T1: argv contains default max_turns=25 as its own token" "argv: $argv"
fi
assert_contains "T1: argv contains --disallowed-tools" "$argv" "--disallowed-tools"
# Comma must remain intact in a single argv token (no shell expansion).
if grep -qx -- "EnterPlanMode,ExitPlanMode" <<< "$argv"; then
    assert_pass "T1: disallowed-tools value is single token with comma intact"
else
    assert_fail "T1: disallowed-tools value is single token with comma intact" "argv: $argv"
fi
assert_contains "T1: argv contains --dangerously-skip-permissions" "$argv" "--dangerously-skip-permissions"
assert_contains "T1: argv preserves -p" "$argv" "-p"
assert_contains "T1: argv preserves --print" "$argv" "--print"
assert_contains "T1: argv preserves --model" "$argv" "--model"

# ─── T2: JSON mode coexists with new flags ───────────────────────────────────
export ZBUILD_ROUTER_JSON_OUTPUT=1
_install_recording_mock
# Recording mock returns plain text; ZBUILD_ROUTER_JSON_OUTPUT=1 will then
# fail JSON parse, returning rc=1 — but argv recording happens before that.
set +e
route_to_model "T2" "ping" --skip-precondition >/dev/null 2>&1
set -e

argv="$(_read_argv)"
assert_contains "T2: --output-format coexists with new flags" "$argv" "--output-format"
assert_contains "T2: json token present" "$argv" "json"
assert_contains "T2: --max-turns still present in JSON mode" "$argv" "--max-turns"
assert_contains "T2: --dangerously-skip-permissions still present in JSON mode" "$argv" "--dangerously-skip-permissions"

unset ZBUILD_ROUTER_JSON_OUTPUT

# ─── T3: env override ZBUILD_ROUTER_MAX_TURNS=10 ─────────────────────────────
_install_recording_mock
export ZBUILD_ROUTER_MAX_TURNS=10
unset ZBUILD_CURRENT_STAGE
set +e
route_to_model "T2" "ping" --skip-precondition >/dev/null 2>&1
rc=$?
set -e
assert_eq "T3: env override route returns rc=0" "0" "$rc"
argv="$(_read_argv)"
if grep -qx -- "10" <<< "$argv"; then
    assert_pass "T3: env ZBUILD_ROUTER_MAX_TURNS=10 reflected in argv"
else
    assert_fail "T3: env ZBUILD_ROUTER_MAX_TURNS=10 reflected in argv" "argv: $argv"
fi

# ─── T4: invalid env values are rejected with rc=2 ───────────────────────────
for bad in 0 "-3" abc; do
    _install_recording_mock
    export ZBUILD_ROUTER_MAX_TURNS="$bad"
    : > "$ZBUILD_EVENTS_JSONL"
    set +e
    route_to_model "T2" "ping" --skip-precondition >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "T4: invalid max_turns '$bad' → rc=2" "2" "$rc"
    reason="$(grep '"router.error"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
        jq -r 'select(.type=="router.error") | .data.reason // empty' 2>/dev/null | tail -1 || true)"
    assert_eq "T4: invalid '$bad' emits reason=invalid_max_turns" "invalid_max_turns" "$reason"
done
unset ZBUILD_ROUTER_MAX_TURNS

# ─── T5: empty env falls back to default (25) ────────────────────────────────
_install_recording_mock
export ZBUILD_ROUTER_MAX_TURNS=""
set +e
route_to_model "T2" "ping" --skip-precondition >/dev/null 2>&1
rc=$?
set -e
assert_eq "T5: empty env → rc=0 (falls through to default)" "0" "$rc"
argv="$(_read_argv)"
if grep -qx -- "25" <<< "$argv"; then
    assert_pass "T5: empty env falls back to default 25"
else
    assert_fail "T5: empty env falls back to default 25" "argv: $argv"
fi
unset ZBUILD_ROUTER_MAX_TURNS

# ─── T6: per-stage template knob wins over env ───────────────────────────────
_install_recording_mock
FIXTURE="$TEST_TEMP_DIR/max-turns-fixture.yaml"
cat > "$FIXTURE" <<'EOF'
id: mt-fixture
name: MT Fixture
defaults:
  strategy: fanout

stages:
  - id: build
    gate: auto
    roles: [builder]
    router:
      max_turns: 99
EOF
load_template "$FIXTURE"
export ZBUILD_CURRENT_STAGE=build
export ZBUILD_ROUTER_MAX_TURNS=10
: > "$ZBUILD_EVENTS_JSONL"

set +e
route_to_model "T2" "ping" --skip-precondition >/dev/null 2>&1
rc=$?
set -e
assert_eq "T6: per-stage wins → rc=0" "0" "$rc"
argv="$(_read_argv)"
if grep -qx -- "99" <<< "$argv"; then
    assert_pass "T6: per-stage 99 wins over env 10"
else
    assert_fail "T6: per-stage 99 wins over env 10" "argv: $argv"
fi
override_evt="$(grep '"router.max_turns.override_ignored"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="router.max_turns.override_ignored") | .data.applied // empty' 2>/dev/null | tail -1 || true)"
assert_eq "T6: override_ignored event applied=99" "99" "$override_evt"

unset ZBUILD_CURRENT_STAGE ZBUILD_ROUTER_MAX_TURNS

# ─── T7: out-of-range template value rejected at load_template time ──────────
BAD_FIXTURE="$TEST_TEMP_DIR/bad-fixture.yaml"
cat > "$BAD_FIXTURE" <<'EOF'
id: bad-fixture
name: Bad Fixture
defaults:
  strategy: fanout

stages:
  - id: build
    gate: auto
    roles: [builder]
    router:
      max_turns: 201
EOF
set +e
err_out="$(load_template "$BAD_FIXTURE" 2>&1)"
rc_bad=$?
set -e
assert_eq "T7: max_turns=201 rejected at template load" "1" "$rc_bad"
assert_contains "T7: error mentions stage and bound" "$err_out" "router.max_turns for stage 'build'"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
