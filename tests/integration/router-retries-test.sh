#!/usr/bin/env bash
# tests/integration/router-retries-test.sh — #1230
#
# Per-stage `router.retries` knob, honored by the SINGLE-SHOT leaf path
# (route_to_model → _route_call_claude). On a router timeout (rc=124) the call
# retries up to N times with an escalated timeout before the verbatim-124
# fallback; each retry emits router.timeout.retry. Default 0 (opt-in).
#
# Harness: a call-counting mock `claude` that exits 124 for the first
# ZB_FAIL_N invocations then succeeds. gtimeout passes claude's own 124 through,
# so no real waiting occurs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "router.retries — single-shot leaf retry-on-timeout (#1230)"
setup_test_env "router-retries"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild" "$TEST_TEMP_DIR/bin"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

CALL_LOG="$TEST_TEMP_DIR/calls.log"
# Mock claude: increments CALL_LOG; exits 124 while call# <= ZB_FAIL_N.
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
printf 'x\n' >> "$ZB_CALL_LOG"
n="$(wc -l < "$ZB_CALL_LOG" | tr -d ' ')"
if [[ "$n" -le "${ZB_FAIL_N:-0}" ]]; then
    exit 124
fi
echo "OK-RESPONSE"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

# Fixture template: impact leaf with router.timeout_s=180 + retries=N (param).
_write_fixture() {
    local retries="$1" fixture="$2"
    {
        printf 'id: rr\nname: RR\ndefaults:\n  strategy: fanout\nstages:\n'
        printf '  - id: impact\n    gate: auto\n    roles: [impact_analyzer]\n'
        printf '    router:\n      timeout_s: 180\n'
        [[ -n "$retries" ]] && printf '      retries: %s\n' "$retries"
        true
    } > "$fixture"
}

# Run route_to_model in a child, capturing rc + events into a fresh jsonl.
# Args: <retries-in-template|""> <fail_n> <events_out> [env_retries]
_run_case() {
    local tpl_retries="$1" fail_n="$2" events_out="$3" env_retries="${4:-}"
    : > "$CALL_LOG"
    : > "$events_out"
    local fixture="$TEST_TEMP_DIR/fx.yaml"
    _write_fixture "$tpl_retries" "$fixture"
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
export ZB_CALL_LOG="$CALL_LOG"
export ZB_FAIL_N="$fail_n"
${env_retries:+export ZBUILD_ROUTER_RETRIES="$env_retries"}
mkdir -p "$TEST_TEMP_DIR/ev"
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/pipeline/template.sh"
source "$REPO_ROOT/core/router/route.sh"
load_template "$fixture"
export ZBUILD_CURRENT_STAGE=impact
route_to_model T2 'ping' --skip-precondition >/dev/null 2>&1 || true
EOF
    bash "$driver" >/dev/null 2>&1 || true
    return 0
}

_calls() { wc -l < "$CALL_LOG" | tr -d ' '; }
_retry_events() { local c; c="$(grep -c '"router.timeout.retry"' "$1" 2>/dev/null || true)"; echo "${c:-0}"; }

# Like _run_case but captures route_to_model's stderr (the operator terminal
# channel) to <err_out> so a mid-run retry line can be asserted (#1241).
_run_case_stderr() {
    local tpl_retries="$1" fail_n="$2" events_out="$3" err_out="$4"
    : > "$CALL_LOG"; : > "$events_out"; : > "$err_out"
    local fixture="$TEST_TEMP_DIR/fx.yaml"
    _write_fixture "$tpl_retries" "$fixture"
    local driver="$TEST_TEMP_DIR/driver-err.sh"
    cat > "$driver" <<EOF
set -uo pipefail
export PATH="$TEST_TEMP_DIR/bin:\$PATH"
export HOME="$HOME"
export ZBUILD_SCOPE_OVERRIDE=1
export ZBUILD_MODELS_FILE="$ZBUILD_MODELS_FILE"
export ZBUILD_EVENT_SCHEMA="$ZBUILD_EVENT_SCHEMA"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/ev"
export ZBUILD_EVENTS_JSONL="$events_out"
export ZB_CALL_LOG="$CALL_LOG"
export ZB_FAIL_N="$fail_n"
mkdir -p "$TEST_TEMP_DIR/ev"
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/pipeline/template.sh"
source "$REPO_ROOT/core/router/route.sh"
load_template "$fixture"
export ZBUILD_CURRENT_STAGE=impact
route_to_model T2 'ping' --skip-precondition >/dev/null 2>"$err_out"
EOF
    bash "$driver" >/dev/null 2>&1 || true
    return 0
}

# ── S3: retries=1, times out once then succeeds → 1 retry, 2 calls, success ──
EV="$TEST_TEMP_DIR/ev-s3.jsonl"
_run_case 1 1 "$EV" >/dev/null
assert_eq "[S3] retries=1, 1 timeout then success → exactly 2 claude calls" "2" "$(_calls)"
assert_eq "[S3] retries=1 → exactly 1 router.timeout.retry event" "1" "$(_retry_events "$EV")"
assert_contains "[S3] success recorded (model.outcome emitted)" \
    "$(cat "$EV")" "model.outcome"

# ── S4: retries=1, always times out → N+1 attempts then 124 fallback ─────────
EV="$TEST_TEMP_DIR/ev-s4.jsonl"
_run_case 1 99 "$EV" >/dev/null
assert_eq "[S4] retries=1, always-timeout → exactly 2 claude calls (N+1)" "2" "$(_calls)"
assert_eq "[S4] retries=1, always-timeout → exactly 1 retry event" "1" "$(_retry_events "$EV")"

# ── S5: no retries set (default 0) → zero retries, single attempt ────────────
EV="$TEST_TEMP_DIR/ev-s5.jsonl"
_run_case "" 99 "$EV" >/dev/null
assert_eq "[S5] default 0 → exactly 1 claude call (no retry)" "1" "$(_calls)"
assert_eq "[S5] default 0 → zero retry events" "0" "$(_retry_events "$EV")"

# ── S7: escalation next>prev, capped at 2×base ───────────────────────────────
EV="$TEST_TEMP_DIR/ev-s7.jsonl"
_run_case 2 99 "$EV" >/dev/null
assert_eq "[S7] retries=2, always-timeout → 3 calls" "3" "$(_calls)"
to1="$(grep '"router.timeout.retry"' "$EV" | jq -r 'select(.data.attempt=="1") | .data.to_secs' 2>/dev/null | head -1)"
to2="$(grep '"router.timeout.retry"' "$EV" | jq -r 'select(.data.attempt=="2") | .data.to_secs' 2>/dev/null | head -1)"
from1="$(grep '"router.timeout.retry"' "$EV" | jq -r 'select(.data.attempt=="1") | .data.from_secs' 2>/dev/null | head -1)"
# base=180 → attempt1 to=270 (>180), attempt2 to=360 (=2*180 cap, >270).
assert_eq "[S7] attempt1 escalated 180→270 (×1.5)" "270" "$to1"
assert_eq "[S7] attempt2 capped at 2× base (360)" "360" "$to2"
assert_gt "[S7] escalation strictly increases (to1 > from1)" "$to1" "$from1"

# ── S9: precedence — per-stage retries beats env; override_ignored emitted ───
EV="$TEST_TEMP_DIR/ev-s9.jsonl"
_run_case 1 99 "$EV" 5 >/dev/null
assert_eq "[S9] per-stage retries=1 wins over env=5 → 2 calls total" "2" "$(_calls)"
assert_contains "[S9] router.retries.override_ignored emitted when env differs" \
    "$(cat "$EV")" "router.retries.override_ignored"
applied="$(grep '"router.retries.override_ignored"' "$EV" | jq -r '.data.applied' 2>/dev/null | head -1)"
assert_eq "[S9] override_ignored records applied=1 (per-stage)" "1" "$applied"

# ── S11 (#1241): a mid-run retry surfaces a human-readable line on the terminal ─
# The retry previously emitted an event ONLY, so a multi-minute retry looked like
# a silent hang. Assert a warn() line reaches stderr (the operator channel).
EV="$TEST_TEMP_DIR/ev-s11.jsonl"
ERR="$TEST_TEMP_DIR/err-s11.txt"
_run_case_stderr 1 1 "$EV" "$ERR"
assert_eq "[S11] retries=1, 1 timeout then success → exactly 2 claude calls" "2" "$(_calls)"
assert_eq "[S11] retries=1 → exactly 1 router.timeout.retry event" "1" "$(_retry_events "$EV")"
assert_contains "[S11] retry prints a terminal (stderr) line naming the retry" \
    "$(cat "$ERR")" "retry"
assert_contains "[S11] retry line surfaces the timeout cause" \
    "$(cat "$ERR")" "timed out"

# ── S10: new events registered in event-schema.json known_types ──────────────
SCHEMA="$REPO_ROOT/config/event-schema.json"
assert_eq "[S10] router.timeout.retry in schema known_types" \
    "true" "$(jq --arg t router.timeout.retry '.known_types | index($t) != null' "$SCHEMA")"
assert_eq "[S10] router.retries.override_ignored in schema known_types" \
    "true" "$(jq --arg t router.retries.override_ignored '.known_types | index($t) != null' "$SCHEMA")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
