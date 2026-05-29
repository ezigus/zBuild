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
    if printf '%s\n' "$text" | grep -qE '^[[:space:]]*LOOP_COMPLETE[[:space:]]*$' 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "no anchored match"
    fi
}
_assert_done_sentinel_nomatch() {
    local desc="$1" text="$2"
    if printf '%s\n' "$text" | grep -qE '^[[:space:]]*LOOP_COMPLETE[[:space:]]*$' 2>/dev/null; then
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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
