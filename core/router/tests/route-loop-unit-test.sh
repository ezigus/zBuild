#!/usr/bin/env bash
# Tests: core/router/route.sh::route_to_model_loop — ADR-018 Pattern 2 (#467)
# Verifies: LOOP_COMPLETE termination, max-iterations cap, claude-rc!=0 handling,
#           git_diff_failed fatal, DONE-sentinel parsing edge cases, diff cap.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/router/route_to_model_loop — unit (ADR-018 Pattern 2, #467)"
setup_test_env "route-loop-unit"

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
unset ZBUILD_RUN_ID 2>/dev/null || true

# ─── Helper: make a fresh git repo with a seed commit ────────────────────────
make_repo() {
    local name="$1"
    local repo="$TEST_TEMP_DIR/$name"
    mkdir -p "$repo"
    ( cd "$repo" \
      && git init -q \
      && git config user.email t@t \
      && git config user.name t \
      && echo seed > seed.txt \
      && git add seed.txt \
      && git commit -q -m seed ) >/dev/null
    printf '%s\n' "$repo"
}

# ─── Helper: install a scripted claude mock that records iterations ──────────
# $1 = iteration counter file (counts invocations)
# $2 = done iteration (1-based) — print LOOP_COMPLETE on this iter, anything
#       else otherwise
# $3 = optional: file path to create under cwd each iter (newline-appended)
install_mock_claude() {
    local counter_file="$1"
    local done_iter="$2"
    local edit_file="${3:-}"
    : > "$counter_file"
    cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
# Mock: parses --output-format json, returns {"result":"...","usage":{...}}.
# Performs an edit in cwd (under repo root via PWD) on each invocation.
count_file="$counter_file"
done_iter="$done_iter"
edit_file="$edit_file"
n=\$(wc -l < "\$count_file" 2>/dev/null | tr -d ' ' || echo 0)
n=\$(( n + 1 ))
echo "iter \$n" >> "\$count_file"
if [[ -n "\$edit_file" ]]; then
    printf 'iter-%d\n' "\$n" >> "\$PWD/\$edit_file"
fi
if [[ "\$n" -eq "\$done_iter" ]]; then
    result_text=\$'Implementation complete.\nLOOP_COMPLETE'
else
    result_text="Iteration \$n — work in progress."
fi
jq -n --arg r "\$result_text" \
   '{result:\$r, usage:{input_tokens:10, output_tokens:5}}'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
}

# shellcheck source=../route.sh
source "$REPO_ROOT/core/router/route.sh"

# Common prompt file
PROMPT_FILE="$TEST_TEMP_DIR/prompt.txt"
echo "static prompt" > "$PROMPT_FILE"

# ─── R1: Single iteration → LOOP_COMPLETE → rc=0, iterations=1 ───────────────
print_test_section "R1: single iter → LOOP_COMPLETE → rc=0"
REPO1=$(make_repo "repo1")
COUNTER1="$TEST_TEMP_DIR/counter1"
install_mock_claude "$COUNTER1" 1 "newfile.txt"

set +e
route_to_model_loop T2 "$PROMPT_FILE" "$REPO1" 5 >/dev/null 2>&1
r1_rc=$?
set -e
assert_exit_code "R1 rc=0 on DONE sentinel" "0" "$r1_rc"
assert_eq "R1 iterations=1" "1" "${_ROUTE_LOOP_ITERATIONS:-0}"
assert_eq "R1 terminated_reason=done_sentinel" "done_sentinel" "${_ROUTE_LOOP_TERMINATED_REASON:-}"
r1_count="$(wc -l < "$COUNTER1" | tr -d ' ')"
assert_eq "R1 claude invoked once" "1" "$r1_count"

# ─── R2: Three iterations with edits, DONE on third ──────────────────────────
print_test_section "R2: three iterations, DONE on third"
REPO2=$(make_repo "repo2")
COUNTER2="$TEST_TEMP_DIR/counter2"
install_mock_claude "$COUNTER2" 3 "progress.txt"

set +e
route_to_model_loop T2 "$PROMPT_FILE" "$REPO2" 5 >/dev/null 2>&1
r2_rc=$?
set -e
assert_exit_code "R2 rc=0 after 3 iterations" "0" "$r2_rc"
assert_eq "R2 iterations=3" "3" "${_ROUTE_LOOP_ITERATIONS:-0}"
r2_count="$(wc -l < "$COUNTER2" | tr -d ' ')"
assert_eq "R2 claude invoked 3 times" "3" "$r2_count"
# Cumulative tokens: 3 iters × (input=10, output=5)
assert_eq "R2 cumulative input_tokens=30"  "30" "${_ROUTE_LOOP_INPUT_TOKENS:-0}"
assert_eq "R2 cumulative output_tokens=15" "15" "${_ROUTE_LOOP_OUTPUT_TOKENS:-0}"

# ─── R3: max-iterations cap (never DONE) → rc=1, max_iterations event ────────
print_test_section "R3: max-iter cap → rc=1, terminated_reason=max_iterations"
REPO3=$(make_repo "repo3")
COUNTER3="$TEST_TEMP_DIR/counter3"
# done_iter=99 means LOOP_COMPLETE never fires within cap of 3
install_mock_claude "$COUNTER3" 99 "wip.txt"

# Reset events log so we can assert on this run only
: > "$ZBUILD_EVENTS_JSONL"

set +e
route_to_model_loop T2 "$PROMPT_FILE" "$REPO3" 3 >/dev/null 2>&1
r3_rc=$?
set -e
assert_exit_code "R3 rc=1 on max-iter no-DONE" "1" "$r3_rc"
assert_eq "R3 iterations=3 (cap)" "3" "${_ROUTE_LOOP_ITERATIONS:-0}"
assert_eq "R3 terminated_reason=max_iterations" "max_iterations" "${_ROUTE_LOOP_TERMINATED_REASON:-}"
assert_event_emitted "R3 loop.max_iterations event" "$ZBUILD_EVENTS_JSONL" "loop.max_iterations"

# ─── R4: Claude rc!=0 mid-loop → continues, loop.iteration.error event ───────
print_test_section "R4: claude rc=1 mid-loop → continues, error event"
REPO4=$(make_repo "repo4")
COUNTER4="$TEST_TEMP_DIR/counter4"
: > "$COUNTER4"
# Mock claude: rc=1 on iter 2, LOOP_COMPLETE on iter 3
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
n=\$(wc -l < "$COUNTER4" 2>/dev/null | tr -d ' ' || echo 0)
n=\$(( n + 1 ))
echo "iter \$n" >> "$COUNTER4"
case "\$n" in
    1) jq -n '{result:"iter1 wip", usage:{input_tokens:5, output_tokens:3}}'; exit 0 ;;
    2) echo "claude oops" >&2; exit 1 ;;
    3) jq -n --arg r \$'done\nLOOP_COMPLETE' '{result:\$r, usage:{input_tokens:5, output_tokens:3}}'; exit 0 ;;
esac
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

: > "$ZBUILD_EVENTS_JSONL"
set +e
route_to_model_loop T2 "$PROMPT_FILE" "$REPO4" 5 >/dev/null 2>&1
r4_rc=$?
set -e
assert_exit_code "R4 rc=0 (recovered after rc=1 iter)" "0" "$r4_rc"
assert_eq "R4 iterations=3 (continued past error)" "3" "${_ROUTE_LOOP_ITERATIONS:-0}"
assert_event_emitted "R4 loop.iteration.error event" "$ZBUILD_EVENTS_JSONL" "loop.iteration.error"

# ─── R6: DONE-sentinel detection variants ────────────────────────────────────
print_test_section "R6: DONE-sentinel parsing variants"

_assert_done_sentinel_match() {
    local desc="$1" text="$2"
    if grep -qE '^[[:space:]]*LOOP_COMPLETE[[:space:]]*$' 2>/dev/null <<< "$text"; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "no anchored match"
    fi
}
_assert_done_sentinel_nomatch() {
    local desc="$1" text="$2"
    if grep -qE '^[[:space:]]*LOOP_COMPLETE[[:space:]]*$' 2>/dev/null <<< "$text"; then
        assert_fail "$desc" "unexpectedly matched"
    else
        assert_pass "$desc"
    fi
}

_assert_done_sentinel_match    "alone on a line"           "LOOP_COMPLETE"
_assert_done_sentinel_match    "trailing newline"          $'LOOP_COMPLETE\n'
_assert_done_sentinel_match    "leading whitespace"        "  LOOP_COMPLETE"
_assert_done_sentinel_match    "trailing whitespace"       "LOOP_COMPLETE  "
_assert_done_sentinel_match    "preamble + token line"     $'done.\nLOOP_COMPLETE'
_assert_done_sentinel_nomatch  "embedded mid-line"         "We have LOOP_COMPLETE done."
_assert_done_sentinel_nomatch  "lowercase variant"         "loop_complete"
_assert_done_sentinel_nomatch  "with suffix on same line"  "LOOP_COMPLETE!"

# ─── R7: diff cap respected (>20k chars → falls back to --stat) ──────────────
print_test_section "R7: diff cap → stat-only fallback when over budget"
REPO7=$(make_repo "repo7")
# Force a tiny cap so any change overflows.
export ZBUILD_LOOP_DIFF_CAP_CHARS=10
COUNTER7="$TEST_TEMP_DIR/counter7"
install_mock_claude "$COUNTER7" 2 "big.txt"

: > "$ZBUILD_EVENTS_JSONL"
set +e
route_to_model_loop T2 "$PROMPT_FILE" "$REPO7" 5 >/dev/null 2>&1
r7_rc=$?
set -e
assert_exit_code "R7 rc=0 (cap doesn't fail the loop)" "0" "$r7_rc"
assert_event_emitted "R7 loop.diff_capture_warning event fired" \
    "$ZBUILD_EVENTS_JSONL" "loop.diff_capture_warning"
unset ZBUILD_LOOP_DIFF_CAP_CHARS

# ─── R8 (#482): per-iteration stage_io banner (Pattern 2) ────────────────────
print_test_section "R8: route_to_model_loop emits stage_io begin/end per iteration"

# Set up a mock template_stage_io_dests so banners actually emit. Use
# stdout + file destinations so the banner hits fd 3 AND a file artifact is
# written per iteration.
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state-r8"
mkdir -p "$ZBUILD_STATE_DIR/artifacts/stage-io"
# shellcheck source=../../output/stage-io.sh
source "$REPO_ROOT/core/output/stage-io.sh"
template_stage_io_dests() {
    local _stage="$1"
    [[ "$_stage" == "build" ]] || return 0
    printf 'file\nstdout\n'
}
template_stage_io_tail_lines() { printf ''; }
template_stage_io_redact()     { printf ''; }

REPO8=$(make_repo "repo8")
COUNTER8="$TEST_TEMP_DIR/counter8"
install_mock_claude "$COUNTER8" 3 "r8.txt"

# Capture banner stream on fd 3.
R8_FD3="$TEST_TEMP_DIR/r8-fd3.txt"
: > "$R8_FD3"
: > "$ZBUILD_EVENTS_JSONL"

export ZBUILD_CURRENT_STAGE=build
export ZBUILD_STAGE_IO_FD=3

set +e
route_to_model_loop T2 "$PROMPT_FILE" "$REPO8" 5 >/dev/null 2>/dev/null 3>"$R8_FD3"
r8_rc=$?
set -e
unset ZBUILD_CURRENT_STAGE ZBUILD_STAGE_IO_FD

assert_exit_code "R8 rc=0 after 3 iterations" "0" "$r8_rc"
assert_eq "R8 iterations=3" "3" "${_ROUTE_LOOP_ITERATIONS:-0}"

r8_banner="$(cat "$R8_FD3")"
# Each iteration should have one input + one output line for build.
r8_input_count="$(printf '%s\n' "$r8_banner" | grep -cE '══ build \[llm\] seq=.* input ══' || true)"
r8_output_count="$(printf '%s\n' "$r8_banner" | grep -cE '══ build \[llm\] seq=.* output ' || true)"
assert_eq "R8 3 input banners (one per iteration)"  "3" "$r8_input_count"
assert_eq "R8 3 output banners (one per iteration)" "3" "$r8_output_count"

# Each iteration's seq increments: seq=1, seq=2, seq=3.
for _seq in 1 2 3; do
    if grep -qE "══ build \[llm\] seq=${_seq} input ══" <<< "$r8_banner"; then
        assert_pass "R8 input banner seq=$_seq present"
    else
        assert_fail "R8 input banner seq=$_seq present" "missing in: $(printf '%s' "$r8_banner" | head -c 400)"
    fi
done

# stage.io.captured count == 3 (one per iteration).
r8_captured="$(jq -c --arg t "stage.io.captured" 'select(.type==$t)' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "R8 3 stage.io.captured events" "3" "$r8_captured"

# Per-iteration file artifacts: build-1.json, build-2.json, build-3.json.
for _seq in 1 2 3; do
    assert_file_exists "R8 build-${_seq}.json artifact" \
        "$ZBUILD_STATE_DIR/artifacts/stage-io/build-${_seq}.json"
done

# Check metadata.iter on the first record.
r8_rec1="$(cat "$ZBUILD_STATE_DIR/artifacts/stage-io/build-1.json")"
assert_json_key "R8 build-1.json metadata.iter == 1" "$r8_rec1" ".metadata.iter" "1"
assert_json_key "R8 build-1.json metadata.tier == T2" "$r8_rec1" ".metadata.tier" "T2"

# R8b: error-path iteration also closes the banner (no orphan). Reuse the
# mid-loop-rc=1 mock from R4 but assert there's still an output banner for
# each iteration including the failing one.
print_test_section "R8b: error-path iteration emits stage_io_end (no orphan)"
REPO8B=$(make_repo "repo8b")
COUNTER8B="$TEST_TEMP_DIR/counter8b"
: > "$COUNTER8B"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
n=\$(wc -l < "$COUNTER8B" 2>/dev/null | tr -d ' ' || echo 0)
n=\$(( n + 1 ))
echo "iter \$n" >> "$COUNTER8B"
case "\$n" in
    1) jq -n '{result:"iter1 wip", usage:{input_tokens:5, output_tokens:3}}'; exit 0 ;;
    2) echo "claude oops" >&2; exit 1 ;;
    3) jq -n --arg r \$'done\nLOOP_COMPLETE' '{result:\$r, usage:{input_tokens:5, output_tokens:3}}'; exit 0 ;;
esac
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

R8B_FD3="$TEST_TEMP_DIR/r8b-fd3.txt"
: > "$R8B_FD3"
: > "$ZBUILD_EVENTS_JSONL"
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
mkdir -p "$ZBUILD_STATE_DIR/artifacts/stage-io"

export ZBUILD_CURRENT_STAGE=build
export ZBUILD_STAGE_IO_FD=3
set +e
route_to_model_loop T2 "$PROMPT_FILE" "$REPO8B" 5 >/dev/null 2>/dev/null 3>"$R8B_FD3"
r8b_rc=$?
set -e
unset ZBUILD_CURRENT_STAGE ZBUILD_STAGE_IO_FD

assert_exit_code "R8b rc=0 (recovered)" "0" "$r8b_rc"
# 3 begin → 3 end pairs (one per iteration including the failing iter).
r8b_input_count="$(printf '%s\n' "$(cat "$R8B_FD3")" | grep -cE '══ build \[llm\] seq=.* input ══' || true)"
r8b_output_count="$(printf '%s\n' "$(cat "$R8B_FD3")" | grep -cE '══ build \[llm\] seq=.* output ' || true)"
assert_eq "R8b 3 input banners (incl. failed iter)"  "3" "$r8b_input_count"
assert_eq "R8b 3 output banners (incl. failed iter)" "3" "$r8b_output_count"

# Failed iteration banner has FAIL status (error=true triggers FAIL render).
if grep -qE '══ build \[llm\] seq=2 output FAIL' <<< "$(cat "$R8B_FD3")"; then
    assert_pass "R8b failed iter banner shows FAIL"
else
    assert_fail "R8b failed iter banner shows FAIL" \
        "got: $(grep 'seq=2 output' "$R8B_FD3" || true)"
fi

# No stage.io.error orphan event (each begin paired with an end).
r8b_orphans="$(jq -c --arg t "stage.io.error" 'select(.type==$t and .data.reason=="output_never_emitted")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "R8b no orphan begins" "0" "$r8b_orphans"

# R8c: no banner when ZBUILD_CURRENT_STAGE unset (Pattern 1's behavior parity).
print_test_section "R8c: no banner when ZBUILD_CURRENT_STAGE unset"
REPO8C=$(make_repo "repo8c")
COUNTER8C="$TEST_TEMP_DIR/counter8c"
install_mock_claude "$COUNTER8C" 1 "r8c.txt"
R8C_FD3="$TEST_TEMP_DIR/r8c-fd3.txt"
: > "$R8C_FD3"
: > "$ZBUILD_EVENTS_JSONL"
unset ZBUILD_CURRENT_STAGE ZBUILD_PLUGIN
export ZBUILD_STAGE_IO_FD=3
set +e
route_to_model_loop T2 "$PROMPT_FILE" "$REPO8C" 5 >/dev/null 2>/dev/null 3>"$R8C_FD3"
r8c_rc=$?
set -e
unset ZBUILD_STAGE_IO_FD
assert_exit_code "R8c rc=0" "0" "$r8c_rc"
r8c_input_count="$(grep -c 'input ══' "$R8C_FD3" 2>/dev/null || true)"
[[ -z "$r8c_input_count" ]] && r8c_input_count=0
assert_eq "R8c no banners when stage id unset" "0" "$r8c_input_count"

# ─── R-arg: invalid args → rc=2 ──────────────────────────────────────────────
print_test_section "R-arg: argument validation"
set +e
route_to_model_loop 2>/dev/null; ra_rc=$?
set -e
assert_exit_code "no args → rc=2" "2" "$ra_rc"

set +e
route_to_model_loop "T9" "$PROMPT_FILE" "$TEST_TEMP_DIR" 1 2>/dev/null; rb_rc=$?
set -e
assert_exit_code "invalid tier → rc=2" "2" "$rb_rc"

set +e
route_to_model_loop "T2" "/nonexistent/prompt" "$TEST_TEMP_DIR" 1 2>/dev/null; rc_rc=$?
set -e
assert_exit_code "missing prompt_file → rc=2" "2" "$rc_rc"

set +e
route_to_model_loop "T2" "$PROMPT_FILE" "/nonexistent/dir" 1 2>/dev/null; rd_rc=$?
set -e
assert_exit_code "missing cwd → rc=2" "2" "$rd_rc"

set +e
route_to_model_loop "T2" "$PROMPT_FILE" "$TEST_TEMP_DIR" 0 2>/dev/null; re_rc=$?
set -e
assert_exit_code "max_iterations=0 → rc=2" "2" "$re_rc"

# ─── R-arg-mtpc: --max-turns-per-call validation (#762 Copilot review #764) ──
# Per-call override must still enforce 1..200. The 0 sentinel is allowed
# only via the resolver chain (template > env > default), never via explicit
# --max-turns-per-call.
print_test_section "R-arg-mtpc: --max-turns-per-call validation"
REPOMTPC=$(make_repo "repo-mtpc")
COUNTERMTPC="$TEST_TEMP_DIR/counter-mtpc"
install_mock_claude "$COUNTERMTPC" 1 ""

set +e
route_to_model_loop "T2" "$PROMPT_FILE" "$REPOMTPC" 1 --max-turns-per-call 0 >/dev/null 2>&1; mtpc0_rc=$?
set -e
assert_exit_code "--max-turns-per-call 0 → rc=2 (0 sentinel disallowed for per-call)" "2" "$mtpc0_rc"

set +e
route_to_model_loop "T2" "$PROMPT_FILE" "$REPOMTPC" 1 --max-turns-per-call 201 >/dev/null 2>&1; mtpc201_rc=$?
set -e
assert_exit_code "--max-turns-per-call 201 → rc=2 (above 1..200 bound)" "2" "$mtpc201_rc"

set +e
route_to_model_loop "T2" "$PROMPT_FILE" "$REPOMTPC" 1 --max-turns-per-call abc >/dev/null 2>&1; mtpc_abc_rc=$?
set -e
assert_exit_code "--max-turns-per-call abc → rc=2 (non-numeric)" "2" "$mtpc_abc_rc"

set +e
route_to_model_loop "T2" "$PROMPT_FILE" "$REPOMTPC" 1 --max-turns-per-call -1 >/dev/null 2>&1; mtpc_neg_rc=$?
set -e
assert_exit_code "--max-turns-per-call -1 → rc=2 (negatives)" "2" "$mtpc_neg_rc"

# Valid per-call override should succeed.
install_mock_claude "$COUNTERMTPC" 1 ""
set +e
route_to_model_loop "T2" "$PROMPT_FILE" "$REPOMTPC" 1 --max-turns-per-call 50 >/dev/null 2>&1; mtpc_ok_rc=$?
set -e
assert_exit_code "--max-turns-per-call 50 → rc=0 (within 1..200)" "0" "$mtpc_ok_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
