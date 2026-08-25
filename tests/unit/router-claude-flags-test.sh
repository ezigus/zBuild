#!/usr/bin/env bash
# Tests: ADR-018 (#466, #1919 C10) — router adopts shipwright's claude flag set.
# Locks the argv shape: --max-turns N --disallowed-tools "..." --permission-mode acceptEdits
# --settings <file> coexist with --print/--model/--output-format and resolve max_turns
# via the per-stage > env > 25 precedence rule (mirrors ADR-017's timeout_s).
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
# #1919 (C10): permissions.sh needs these to build the settings file.
export ZBUILD_STAGE_SCRATCH="$TEST_TEMP_DIR/scratch"
export ZBUILD_REPO_ROOT="$REPO_ROOT"
mkdir -p "$TEST_TEMP_DIR/scratch"

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
assert_contains "[SPEC-5] T1: argv contains --disallowed-tools" "$argv" "--disallowed-tools"
# Comma must remain intact in a single argv token (no shell expansion).
if grep -qx -- "EnterPlanMode,ExitPlanMode" <<< "$argv"; then
    assert_pass "T1: disallowed-tools value is single token with comma intact"
else
    assert_fail "T1: disallowed-tools value is single token with comma intact" "argv: $argv"
fi
# [SPEC-1] C10: --dangerously-skip-permissions replaced by acceptEdits mode + settings file.
if grep -qx -- "--permission-mode" <<< "$argv"; then
    assert_pass "[SPEC-1] T1: argv contains --permission-mode"
else
    assert_fail "[SPEC-1] T1: argv contains --permission-mode" "argv: $argv"
fi
if grep -qx -- "acceptEdits" <<< "$argv"; then
    assert_pass "[SPEC-1] T1: argv contains acceptEdits"
else
    assert_fail "[SPEC-1] T1: argv contains acceptEdits" "argv: $argv"
fi
if grep -qx -- "--settings" <<< "$argv"; then
    assert_pass "[SPEC-1] T1: argv contains --settings"
else
    assert_fail "[SPEC-1] T1: argv contains --settings" "argv: $argv"
fi
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
# [SPEC-1] C10: acceptEdits replaces --dangerously-skip-permissions in JSON mode too.
if grep -qx -- "--permission-mode" <<< "$argv"; then
    assert_pass "[SPEC-1] T2: --permission-mode still present in JSON mode"
else
    assert_fail "[SPEC-1] T2: --permission-mode still present in JSON mode" "argv: $argv"
fi
if grep -qx -- "acceptEdits" <<< "$argv"; then
    assert_pass "[SPEC-1] T2: acceptEdits still present in JSON mode"
else
    assert_fail "[SPEC-1] T2: acceptEdits still present in JSON mode" "argv: $argv"
fi

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
# ADR-018 Amendment N (#762): 0 is now a valid sentinel (omit --max-turns flag).
# Only negatives, non-numeric, and >200 remain invalid.
for bad in "-3" "-1" abc 201; do
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

# ─── T4b: max_turns=0 sentinel — flag must be ABSENT from argv ───────────────
# ADR-018 Amendment N (#762): router.max_turns=0 means "omit --max-turns".
_install_recording_mock
export ZBUILD_ROUTER_MAX_TURNS=0
: > "$ZBUILD_EVENTS_JSONL"
set +e
route_to_model "T2" "ping" --skip-precondition >/dev/null 2>&1
rc=$?
set -e
assert_eq "T4b: max_turns=0 sentinel → rc=0 (valid)" "0" "$rc"
argv="$(_read_argv)"
if grep -qx -- "--max-turns" <<< "$argv"; then
    assert_fail "T4b: argv MUST NOT contain --max-turns when sentinel=0" "argv: $argv"
else
    assert_pass "T4b: --max-turns flag omitted when sentinel=0"
fi
# Emit a flag_omitted event documenting the sentinel resolution.
omitted_count="$(grep '"router.max_turns.flag_omitted"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T4b: router.max_turns.flag_omitted event emitted" "1" "$omitted_count"
omitted_source="$(jq -r 'select(.type=="router.max_turns.flag_omitted") | .data.source // empty' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1)"
assert_eq "T4b: flag_omitted event has source=env" "env" "$omitted_source"
unset ZBUILD_ROUTER_MAX_TURNS

# ─── T4d: per-stage template max_turns=0 → flag omitted, source=template ─────
_install_recording_mock
T4D_FIXTURE="$TEST_TEMP_DIR/sentinel-fixture.yaml"
cat > "$T4D_FIXTURE" <<'EOF'
id: sentinel-fixture
name: Sentinel Fixture
defaults:
  strategy: fanout

stages:
  - id: build
    gate: auto
    roles: [builder]
    router:
      max_turns: 0
EOF
load_template "$T4D_FIXTURE"
export ZBUILD_CURRENT_STAGE=build
unset ZBUILD_ROUTER_MAX_TURNS
: > "$ZBUILD_EVENTS_JSONL"
set +e
route_to_model "T2" "ping" --skip-precondition >/dev/null 2>&1
rc=$?
set -e
assert_eq "T4d: template max_turns=0 sentinel → rc=0" "0" "$rc"
argv="$(_read_argv)"
if grep -qx -- "--max-turns" <<< "$argv"; then
    assert_fail "T4d: argv MUST NOT contain --max-turns under template sentinel" "argv: $argv"
else
    assert_pass "T4d: --max-turns flag omitted under template sentinel"
fi
omitted_source="$(jq -r 'select(.type=="router.max_turns.flag_omitted") | .data.source // empty' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1)"
assert_eq "T4d: flag_omitted event source=template" "template" "$omitted_source"
unset ZBUILD_CURRENT_STAGE

# ─── T4e: "00" (leading-zero zero) classifies correctly as env-sentinel ──────
# Copilot review #764: source detection must compare numerically so values
# like "00" / "000" (accepted by ^[0-9]+$ validator) classify correctly
# rather than falling through to "default".
_install_recording_mock
export ZBUILD_ROUTER_MAX_TURNS=00
: > "$ZBUILD_EVENTS_JSONL"
set +e
route_to_model "T2" "ping" --skip-precondition >/dev/null 2>&1
rc=$?
set -e
assert_eq "T4e: ZBUILD_ROUTER_MAX_TURNS=00 → rc=0 (numeric zero)" "0" "$rc"
argv="$(_read_argv)"
if grep -qx -- "--max-turns" <<< "$argv"; then
    assert_fail "T4e: argv MUST NOT contain --max-turns when value is 00" "argv: $argv"
else
    assert_pass "T4e: --max-turns flag omitted for numeric-zero '00'"
fi
omitted_source="$(jq -r 'select(.type=="router.max_turns.flag_omitted") | .data.source // empty' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1)"
assert_eq "T4e: flag_omitted source classified as env (not default)" "env" "$omitted_source"
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
