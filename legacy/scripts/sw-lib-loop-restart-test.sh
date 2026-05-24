#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/loop-restart test — Unit tests for loop state            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: loop-restart Tests"

setup_test_env "sw-lib-loop-restart-test"
_test_cleanup_hook() { cleanup_test_env; }

# ── Required variables ────────────────────────────────────────────────────────
export STATE_FILE="$TEST_TEMP_DIR/loop-state.md"
export GOAL=""
export ORIGINAL_GOAL=""
export ITERATION=1
export MAX_ITERATIONS=10
export MAX_ITERATIONS_EXPLICIT=false
export cli_max_iterations=10
export STATUS="running"
export TEST_CMD=""
export MODEL="sonnet"
export AGENTS=1
export CONSECUTIVE_FAILURES=0
export TOTAL_COMMITS=0
export AUDIT_ENABLED=false
export AUDIT_AGENT_ENABLED=false
export QUALITY_GATES_ENABLED=false
export DOD_FILE=""
export AUTO_EXTEND=false
export EXTENSION_COUNT=0
export MAX_EXTENSIONS=3
export DOD_DIFF_MAX_LINES=500
export HOLISTIC_DIFF_MAX_LINES=1000
export LOG_ENTRIES=""
export LOOP_START_COMMIT="abc123"   # pre-set to skip git call in resume_state
export PROJECT_ROOT="$TEST_TEMP_DIR" # non-git dir → git calls fail gracefully
export DIM="" RESET="" BOLD=""

# ── Stub functions ────────────────────────────────────────────────────────────
now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }
info()      { echo "▸ $*"; }
success()   { echo "✓ $*"; }
warn()      { echo "⚠ $*"; }
error()     { echo "✗ $*" >&2; }

# Source the module (module guard is cleared so we get a fresh load)
_LOOP_RESTART_LOADED=""
source "$SCRIPT_DIR/lib/loop-restart.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# write_state / resume_state — multi-line GOAL round-trip (issue #348)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "write_state / resume_state multi-line GOAL round-trip"

# --- Test 1: single-line goal round-trip (regression guard) ---
GOAL="simple loop goal" ORIGINAL_GOAL=""
write_state
GOAL=""
resume_state 2>/dev/null
if [[ "$GOAL" == "simple loop goal" ]]; then
    assert_pass "single-line loop goal round-trip"
else
    assert_fail "single-line loop goal round-trip" "got: $GOAL"
fi

# --- Test 2: multi-line goal write — goal value must be escaped (contains literal \n not real newlines) ---
GOAL="$(printf 'Fix loop tests\n\nKNOWN FIX: check src/foo.sh\nRun: npm test')" ORIGINAL_GOAL=""
write_state
_goal_line=$(grep '^goal:' "$STATE_FILE" | sed 's/^goal: *"//;s/" *$//')
# With the fix, newlines in GOAL are encoded as the two-char sequence \n in the file.
# [[ glob pattern $'\\n' matches literal backslash + n ]]
if [[ "$_goal_line" == *$'\\n'* ]]; then
    assert_pass "multi-line loop goal write encodes newlines as \\n"
else
    assert_fail "multi-line loop goal write encodes newlines as \\n" "no escaped \\n found; first 60 chars: ${_goal_line:0:60}"
fi

# --- Test 3: multi-line goal — full round-trip (write then read back) ---
GOAL=""
resume_state 2>/dev/null
_expected="$(printf 'Fix loop tests\n\nKNOWN FIX: check src/foo.sh\nRun: npm test')"
if [[ "$GOAL" == "$_expected" ]]; then
    assert_pass "multi-line loop goal full round-trip: all content restored"
else
    assert_fail "multi-line loop goal full round-trip: all content restored" "first 80 chars: $(printf '%s' "$GOAL" | head -c 80)"
fi

# --- Test 4: empty goal write — no crash ---
GOAL="" ORIGINAL_GOAL=""
write_state
assert_pass "empty loop goal write does not crash"

# --- Test 5: goal containing a literal \n (two chars: backslash + n) ---
# Full backslash-escaping scheme: literal \n is stored as \\n and round-trips correctly.
GOAL=$'Contains a literal \\n backslash-n and a real\nnewline' ORIGINAL_GOAL=""
write_state
GOAL=""
resume_state 2>/dev/null
if [[ "$GOAL" == $'Contains a literal \\n backslash-n and a real\nnewline' ]]; then
    assert_pass "literal \\n in loop goal round-trips correctly"
else
    assert_fail "literal \\n in loop goal round-trips correctly" "got: $(printf '%s' "$GOAL" | head -c 80)"
fi

# --- Test 7: legacy polluted goal with injection-style content is cleaned on resume ---
# Simulates a state file written by the OLD buggy write_state (no original_goal: field).
# resume_state should strip the pollution and restore the original goal.
_t7_goal="$(printf 'Original goal\n\nBLOCKING ISSUES — fix all of these before merge:\n- test_auth_flow fails\n\nFull review context:\nSee audit log for details')"
_t7_esc="${_t7_goal//\\/\\\\}"
_t7_esc="${_t7_esc//$'\n'/\\n}"
{
    printf -- '---\n'
    printf 'goal: "%s"\n' "$_t7_esc"
    printf 'iteration: 1\nmax_iterations: 10\nstatus: running\ntest_cmd: ""\nmodel: sonnet\nagents: 1\n'
    printf 'consecutive_failures: 0\ntotal_commits: 0\naudit_enabled: false\naudit_agent_enabled: false\n'
    printf 'quality_gates_enabled: false\ndod_file: ""\nauto_extend: false\nextension_count: 0\n'
    printf 'max_extensions: 3\ndod_diff_max_lines: 500\nholistic_diff_max_lines: 1000\n'
    printf -- '---\n\n## Log\n'
} > "$STATE_FILE"
GOAL=""
resume_state 2>/dev/null
_expected="Original goal"
if [[ "$GOAL" == "$_expected" ]]; then
    assert_pass "resume_state strips legacy polluted BLOCKING ISSUES injection"
else
    assert_fail "resume_state strips legacy polluted BLOCKING ISSUES injection" "got: $(printf '%s' "$GOAL" | head -c 80)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# write_state — ORIGINAL_GOAL protection (issues #362, Codex P1, Codex P2)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "write_state ORIGINAL_GOAL protection (issue #362 + Codex P1/P2)"

# Reload the real write_state — do NOT re-source loop-restart.sh; use fresh module guard
unset -f write_state
unset -f resume_state
_LOOP_RESTART_LOADED=""
source "$SCRIPT_DIR/lib/loop-restart.sh"

# Helper: write a legacy state file (no original_goal: field) simulating old buggy write_state
_write_legacy_loop_state() {
    local polluted_goal="$1"
    local _esc="${polluted_goal//\\/\\\\}"
    _esc="${_esc//$'\n'/\\n}"
    {
        printf -- '---\n'
        printf 'goal: "%s"\n'           "$_esc"
        printf 'iteration: %s\n'        "$ITERATION"
        printf 'max_iterations: %s\n'   "$MAX_ITERATIONS"
        printf 'status: %s\n'           "${STATUS:-running}"
        printf 'test_cmd: "%s"\n'       "${TEST_CMD:-}"
        printf 'model: %s\n'            "${MODEL:-sonnet}"
        printf 'agents: %s\n'           "${AGENTS:-1}"
        printf 'consecutive_failures: %s\n' "${CONSECUTIVE_FAILURES:-0}"
        printf 'total_commits: %s\n'    "${TOTAL_COMMITS:-0}"
        printf 'audit_enabled: %s\n'    "${AUDIT_ENABLED:-false}"
        printf 'audit_agent_enabled: %s\n'   "${AUDIT_AGENT_ENABLED:-false}"
        printf 'quality_gates_enabled: %s\n' "${QUALITY_GATES_ENABLED:-false}"
        printf 'dod_file: "%s"\n'       "${DOD_FILE:-}"
        printf 'auto_extend: %s\n'      "${AUTO_EXTEND:-false}"
        printf 'extension_count: %s\n'  "${EXTENSION_COUNT:-0}"
        printf 'max_extensions: %s\n'   "${MAX_EXTENSIONS:-3}"
        printf 'dod_diff_max_lines: %s\n'       "${DOD_DIFF_MAX_LINES:-500}"
        printf 'holistic_diff_max_lines: %s\n'  "${HOLISTIC_DIFF_MAX_LINES:-1000}"
        printf -- '---\n\n'
        printf '## Log\n'
    } > "$STATE_FILE"
}

# Test A: write_state uses ORIGINAL_GOAL when GOAL is mutated
GOAL="Original pipeline goal"
ORIGINAL_GOAL="Original pipeline goal"
GOAL="$(printf 'Original pipeline goal\n\nBLOCKING ISSUES — fix all of these before merge: tests fail')"
write_state
_saved=$(grep '^goal:' "$STATE_FILE" | sed 's/^goal: *"//;s/" *$//')
assert_contains "write_state writes ORIGINAL_GOAL not mutated GOAL" "$_saved" "Original pipeline goal"
_blocking_count=$(echo "$_saved" | grep -c 'BLOCKING ISSUES' || true)
assert_eq "write_state does not write BLOCKING ISSUES" "0" "$_blocking_count"

# Test A2: write_state persists original_goal field
_orig_saved=$(grep '^original_goal:' "$STATE_FILE" | sed 's/^original_goal: *"//;s/" *$//')
assert_eq "write_state persists original_goal field" "Original pipeline goal" "$_orig_saved"

# Test B: ORIGINAL_GOAL empty → bootstrapped from GOAL on first non-empty write
GOAL="Fallback goal"
ORIGINAL_GOAL=""
write_state
GOAL="" ORIGINAL_GOAL=""
resume_state 2>/dev/null
assert_eq "write_state bootstraps ORIGINAL_GOAL from GOAL when not set" "Fallback goal" "$GOAL"
assert_eq "resume_state reads ORIGINAL_GOAL from original_goal field" "Fallback goal" "$ORIGINAL_GOAL"

# Test C: legacy state file — resume_state strips BLOCKING ISSUES (no original_goal field)
_write_legacy_loop_state "$(printf 'Clean goal\n\nBLOCKING ISSUES — fix all: test fails\n\nFull feedback...')"
GOAL="" ORIGINAL_GOAL=""
resume_state 2>/dev/null
assert_eq "legacy: resume_state strips BLOCKING ISSUES" "Clean goal" "$GOAL"
assert_eq "legacy: resume_state sets ORIGINAL_GOAL after strip" "Clean goal" "$ORIGINAL_GOAL"

# Test D: legacy state file — resume_state strips HUMAN FEEDBACK (no original_goal field)
_write_legacy_loop_state "$(printf 'Clean goal\n\nHUMAN FEEDBACK (received after iteration 3): fix the auth bug')"
GOAL="" ORIGINAL_GOAL=""
resume_state 2>/dev/null
assert_eq "legacy: resume_state strips HUMAN FEEDBACK" "Clean goal" "$GOAL"

# Test E: legacy state file — resume_state strips KNOWN FIX prefix (no original_goal field)
_write_legacy_loop_state "$(printf 'KNOWN FIX (from past success): retry logic\n\nClean goal')"
GOAL="" ORIGINAL_GOAL=""
resume_state 2>/dev/null
assert_eq "legacy: resume_state strips KNOWN FIX prefix" "Clean goal" "$GOAL"

# Test E2 (Codex P2): new state file — legitimate goal with sentinel-like text is NOT truncated
GOAL="Fix the BLOCKING ISSUES in the auth module"
ORIGINAL_GOAL="Fix the BLOCKING ISSUES in the auth module"
write_state
GOAL="" ORIGINAL_GOAL=""
resume_state 2>/dev/null
assert_eq "P2: legitimate goal with sentinel text not truncated" "Fix the BLOCKING ISSUES in the auth module" "$GOAL"

# Test F: no unbounded growth across 2 compound_quality cycles
GOAL="Original"
ORIGINAL_GOAL="Original"
GOAL="$(printf 'Original\n\nBLOCKING ISSUES — something: fail')"
write_state
GOAL="" ORIGINAL_GOAL=""
resume_state 2>/dev/null
GOAL="$(printf '%s\n\nBLOCKING ISSUES — something else: fail' "$GOAL")"
write_state
GOAL="" ORIGINAL_GOAL=""
resume_state 2>/dev/null
assert_eq "no unbounded growth across 2 compound_quality cycles" "Original" "$GOAL"

# ═══════════════════════════════════════════════════════════════════════════════
# resume_state — terminal status: stuck (preparatory for #443/#451)
# ═══════════════════════════════════════════════════════════════════════════════
#
# AUDIT — every reader of the `status:` field in `.claude/loop-state.md`
# (verifiable by `grep -n 'STATUS\|status:' scripts/sw-loop.sh
#  scripts/lib/loop-restart.sh scripts/sw-checkpoint.sh`):
#
#   #  File:Line                              What it does                     Behavior on `stuck` before this PR              Fix in this PR
#   1  scripts/lib/loop-restart.sh:77         YAML parser → STATUS variable    Permissive — accepts `stuck` literal verbatim   None — already correct
#   2  scripts/lib/loop-restart.sh:128-131    Terminal-state check (complete)  Fell through → STATUS reset → OOM cycle         Added explicit `stuck` arm; exits with user guidance
#   3  scripts/lib/loop-restart.sh:146        Unconditional STATUS="running"   Overwrote `stuck` if reached                    Now unreachable for stuck (early exit at #2)
#   4  scripts/sw-loop.sh:show_summary        `case $STATUS` in show_summary   Fell through to dim default — generic           Added explicit `stuck` case arm with red ✗ label
#   5  scripts/sw-loop.sh:LOOP banner         Uppercase LOOP $STATUS banner    Renders "LOOP STUCK" — already legible          None — incidentally correct
#   6  scripts/sw-loop.sh:complete check      if [[ STATUS == "complete" ]]    False for stuck — correct (stuck ≠ success)     None
#   7  scripts/sw-checkpoint.sh               Reads SW_LOOP_STATUS env var     Pass-through, no branching                      None
#
# OUT OF SCOPE (intentionally deferred — separate work items):
#   • Writer side (#451) — write_state() does NOT yet emit `status: stuck`.
#   • .claude/pipeline-state.md readers — different file, different schema.
#   • Documentation / public docs — status enum is internal.
#   • Backfill of legacy state files — unchanged.
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "resume_state stuck terminal-state handling"

# Helper: write a state file with an arbitrary status value
_write_state_with_status() {
    local _status="$1"
    local _goal="${2:-Test goal}"
    local _esc="${_goal//\\/\\\\}"
    _esc="${_esc//$'\n'/\\n}"
    {
        printf -- '---\n'
        printf 'goal: "%s"\n'           "$_esc"
        printf 'original_goal: "%s"\n'  "$_esc"
        printf 'iteration: %s\n'        "${ITERATION:-1}"
        printf 'max_iterations: %s\n'   "${MAX_ITERATIONS:-10}"
        printf 'status: %s\n'           "$_status"
        printf 'test_cmd: "%s"\n'       "${TEST_CMD:-}"
        printf 'model: %s\n'            "${MODEL:-sonnet}"
        printf 'agents: %s\n'           "${AGENTS:-1}"
        printf 'consecutive_failures: 0\ntotal_commits: 0\naudit_enabled: false\n'
        printf 'audit_agent_enabled: false\nquality_gates_enabled: false\ndod_file: ""\n'
        printf 'auto_extend: false\nextension_count: 0\nmax_extensions: 3\n'
        printf 'dod_diff_max_lines: 500\nholistic_diff_max_lines: 1000\n'
        printf -- '---\n\n## Log\n'
    } > "$STATE_FILE"
}

# Test G1: resume_state on stuck status exits cleanly (no resume, no STATUS overwrite)
_write_state_with_status "stuck" "Stuck loop goal"
_g1_output="$(GOAL="" ORIGINAL_GOAL="" bash -c "
    set +e
    source '$SCRIPT_DIR/lib/test-helpers.sh' 2>/dev/null
    export STATE_FILE='$STATE_FILE' MAX_ITERATIONS='$MAX_ITERATIONS' MAX_ITERATIONS_EXPLICIT=false
    export PROJECT_ROOT='$PROJECT_ROOT' SCRIPT_DIR='$SCRIPT_DIR' DIM='' RESET=''
    export ITERATION=1 STATUS='' TEST_CMD='' MODEL=sonnet AGENTS=1
    export CONSECUTIVE_FAILURES=0 TOTAL_COMMITS=0 LOG_ENTRIES=''
    export AUDIT_ENABLED=false AUDIT_AGENT_ENABLED=false QUALITY_GATES_ENABLED=false
    export DOD_FILE='' AUTO_EXTEND=false EXTENSION_COUNT=0 MAX_EXTENSIONS=3
    export DOD_DIFF_MAX_LINES=500 HOLISTIC_DIFF_MAX_LINES=1000
    export LOOP_START_COMMIT=abc123 GOAL='' ORIGINAL_GOAL=''
    now_iso(){ date -u +'%Y-%m-%dT%H:%M:%SZ'; }; now_epoch(){ date +%s; }
    info(){ echo \"\$*\"; }; success(){ echo \"\$*\"; }
    warn(){ echo \"WARN:\$*\"; }; error(){ echo \"ERR:\$*\" >&2; }
    _LOOP_RESTART_LOADED=''
    source '$SCRIPT_DIR/lib/loop-restart.sh'
    resume_state 2>&1
    echo \"AFTER_RESUME_STATUS=\$STATUS\"
" || true)"
if echo "$_g1_output" | grep -q "AFTER_RESUME_STATUS="; then
    assert_fail "resume_state exits when status is stuck" "execution continued past resume_state; output: $_g1_output"
else
    assert_pass "resume_state exits when status is stuck"
fi
assert_contains "resume_state warns about stuck state" "$_g1_output" "stuck"

# Test G2: terminal check distinguishes stuck from running (running must still resume)
_write_state_with_status "running" "Resumable loop"
GOAL="" ORIGINAL_GOAL="" STATUS=""
resume_state 2>/dev/null
assert_eq "resume_state still resumes when status is running" "running" "$STATUS"

# Test G3: complete still terminates (regression guard — pre-existing behavior preserved)
_write_state_with_status "complete" "Done loop"
_g3_output="$(GOAL="" ORIGINAL_GOAL="" bash -c "
    set +e
    export STATE_FILE='$STATE_FILE' MAX_ITERATIONS='$MAX_ITERATIONS' MAX_ITERATIONS_EXPLICIT=false
    export PROJECT_ROOT='$PROJECT_ROOT' SCRIPT_DIR='$SCRIPT_DIR' DIM='' RESET=''
    export ITERATION=1 STATUS='' TEST_CMD='' MODEL=sonnet AGENTS=1
    export CONSECUTIVE_FAILURES=0 TOTAL_COMMITS=0 LOG_ENTRIES=''
    export AUDIT_ENABLED=false AUDIT_AGENT_ENABLED=false QUALITY_GATES_ENABLED=false
    export DOD_FILE='' AUTO_EXTEND=false EXTENSION_COUNT=0 MAX_EXTENSIONS=3
    export DOD_DIFF_MAX_LINES=500 HOLISTIC_DIFF_MAX_LINES=1000
    export LOOP_START_COMMIT=abc123 GOAL='' ORIGINAL_GOAL=''
    now_iso(){ date -u +'%Y-%m-%dT%H:%M:%SZ'; }; now_epoch(){ date +%s; }
    info(){ echo \"\$*\"; }; success(){ echo \"\$*\"; }
    warn(){ echo \"WARN:\$*\"; }; error(){ echo \"ERR:\$*\" >&2; }
    _LOOP_RESTART_LOADED=''
    source '$SCRIPT_DIR/lib/loop-restart.sh'
    resume_state 2>&1
    echo \"AFTER_RESUME_STATUS=\$STATUS\"
" || true)"
if echo "$_g3_output" | grep -q "AFTER_RESUME_STATUS="; then
    assert_fail "resume_state exits when status is complete (regression guard)" "got: $_g3_output"
else
    assert_pass "resume_state exits when status is complete (regression guard)"
fi

# Test G4: write_state preserves a stuck status set by the writer (no transformation)
GOAL="Stuck round-trip" ORIGINAL_GOAL="Stuck round-trip"
STATUS="stuck"
write_state
_persisted_status=$(grep '^status:' "$STATE_FILE" | sed 's/^status: *//')
assert_eq "write_state persists stuck status verbatim" "stuck" "$_persisted_status"

# ═══════════════════════════════════════════════════════════════════════════════
# show_summary — stuck status display (preparatory for #443/#451)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "sw-loop.sh show_summary stuck case"

_loop_script="$SCRIPT_DIR/sw-loop.sh"
if grep -q '^[[:space:]]*stuck)[[:space:]]*status_display=' "$_loop_script"; then
    assert_pass "show_summary has explicit stuck case arm"
else
    assert_fail "show_summary has explicit stuck case arm" "no 'stuck)' arm found in $_loop_script"
fi
_stuck_arm=$(grep -E '^[[:space:]]*stuck\)[[:space:]]*status_display=' "$_loop_script" | head -1)
if echo "$_stuck_arm" | grep -qi 'stuck'; then
    assert_pass "show_summary stuck display string mentions stuck"
else
    assert_fail "show_summary stuck display string mentions stuck" "got: $_stuck_arm"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Layer C: resume_state — unified synthesis sentinel stripping (#444)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Layer C: resume_state sentinel stripping (issue #444)"

# Source goal-sanitize helper
source "$SCRIPT_DIR/lib/goal-sanitize.sh" 2>/dev/null || {
    assert_fail "goal-sanitize.sh not found" "cannot load $_GOAL_SANITIZE_PATH"
}

# Test H1: resume_state strips ## Plan Summary from original_goal field
_write_state_with_status "running" "$(printf 'Clean goal\n\n## Plan Summary\nCompile plan here')"
GOAL="" ORIGINAL_GOAL="" STATUS=""
resume_state 2>/dev/null
assert_eq "resume_state strips ## Plan Summary from original_goal" "Clean goal" "$ORIGINAL_GOAL"

# Test H2: resume_state strips ## Skill Guidance from original_goal field
_write_state_with_status "running" "$(printf 'Clean goal\n\n## Skill Guidance\nGuide content here')"
GOAL="" ORIGINAL_GOAL="" STATUS=""
resume_state 2>/dev/null
assert_eq "resume_state strips ## Skill Guidance from original_goal" "Clean goal" "$ORIGINAL_GOAL"

# Test H3: resume_state strips ## Historical Build Context from original_goal field
_write_state_with_status "running" "$(printf 'Clean goal\n\n## Historical Build Context\nHistory here')"
GOAL="" ORIGINAL_GOAL="" STATUS=""
resume_state 2>/dev/null
assert_eq "resume_state strips ## Historical Build Context from original_goal" "Clean goal" "$ORIGINAL_GOAL"

# Test H4: legacy — resume_state strips ## Plan Summary from goal field when no original_goal field
_write_legacy_loop_state "$(printf 'Clean goal\n\n## Plan Summary\nPlan details')"
GOAL="" ORIGINAL_GOAL="" STATUS=""
resume_state 2>/dev/null
assert_eq "legacy: resume_state strips ## Plan Summary from goal" "Clean goal" "$GOAL"

# ═══════════════════════════════════════════════════════════════════════════════
# Layer D: check_fatal_error — session-limit patterns + err_file arg (F1 fix)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Layer D: check_fatal_error — session/usage limit detection"

# Source check_fatal_error from loop-restart.sh
source "$SCRIPT_DIR/lib/loop-restart.sh" 2>/dev/null || {
    assert_fail "loop-restart.sh not sourceable" "cannot load loop-restart.sh"
}

_cfe_log="$TEST_TEMP_DIR/cfe-stdout.log"
_cfe_err="$TEST_TEMP_DIR/cfe-stderr.log"

# F1-D1: returns 1 (no fatal error) for normal output
printf 'All tests passed\n' > "$_cfe_log"
: > "$_cfe_err"
if check_fatal_error "$_cfe_log" "0" "$_cfe_err" 2>/dev/null; then
    assert_fail "F1-D1: check_fatal_error must return 1 for normal output" "returned 0 (fatal)"
else
    assert_pass "F1-D1: check_fatal_error returns 1 (no error) for normal output"
fi

# F1-D2: detects session limit pattern in stdout
printf "You've hit your session limit · resets 2:40pm (UTC)\n" > "$_cfe_log"
: > "$_cfe_err"
if check_fatal_error "$_cfe_log" "1" "$_cfe_err" 2>/dev/null; then
    assert_pass "F1-D2: check_fatal_error detects 'session limit' pattern in stdout"
else
    assert_fail "F1-D2: check_fatal_error must detect 'session limit' pattern in stdout" \
        "pattern not matched in: $(cat "$_cfe_log")"
fi

# F1-D3: detects session limit pattern in stderr (err_file arg)
printf 'No useful output\n' > "$_cfe_log"
printf "Usage limit reached — please check claude.ai/usage\n" > "$_cfe_err"
if check_fatal_error "$_cfe_log" "1" "$_cfe_err" 2>/dev/null; then
    assert_pass "F1-D3: check_fatal_error detects 'Usage limit reached' in stderr (err_file arg)"
else
    assert_fail "F1-D3: check_fatal_error must detect usage limit from err_file" \
        "stderr was: $(cat "$_cfe_err")"
fi

# F1-D4: does NOT detect session limit when err_file arg is omitted (2-arg call)
printf 'No useful output\n' > "$_cfe_log"
printf "Usage limit reached\n" > "$_cfe_err"
if check_fatal_error "$_cfe_log" "1" 2>/dev/null; then
    assert_fail "F1-D4: without err_file arg, stderr patterns should not be detected" \
        "check_fatal_error incorrectly returned 0 (fatal) without err_file"
else
    assert_pass "F1-D4: without err_file arg, stderr-only patterns are not detected (expected)"
fi

# F1-D5: detects API key error in stdout (pre-existing pattern)
printf 'Error: Invalid API key provided\n' > "$_cfe_log"
: > "$_cfe_err"
if check_fatal_error "$_cfe_log" "1" "$_cfe_err" 2>/dev/null; then
    assert_pass "F1-D5: check_fatal_error detects 'Invalid API key' in stdout"
else
    assert_fail "F1-D5: check_fatal_error must detect 'Invalid API key' pattern" \
        "pattern not matched"
fi

# F1-D6: non-zero exit + tiny output returns 1 (not conclusively fatal)
printf 'err\n' > "$_cfe_log"
: > "$_cfe_err"
if check_fatal_error "$_cfe_log" "1" "$_cfe_err" 2>/dev/null; then
    assert_fail "F1-D6: tiny output with non-zero exit should return 1 (non-conclusive)" \
        "returned 0 (conclusive fatal)"
else
    assert_pass "F1-D6: tiny output + non-zero exit returns 1 (non-conclusive, deferred to circuit breaker)"
fi

# F1-D7: missing log file returns 1 (guard at top of function)
rm -f "$TEST_TEMP_DIR/missing.log"
if check_fatal_error "$TEST_TEMP_DIR/missing.log" "0" 2>/dev/null; then
    assert_fail "F1-D7: missing log file must return 1 (not fatal)" \
        "returned 0 (fatal) for missing file"
else
    assert_pass "F1-D7: missing log file returns 1 safely"
fi

# Emit explicit "$PASS/$TOTAL pass" as the final visible line for DoD audit parsers.
printf '%s/%s pass\n' "$PASS" "$TOTAL"
print_test_results
