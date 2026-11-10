#!/usr/bin/env bash
# tests/unit/lint-multiline-test.sh — each repository lint reads a command
# continued onto the next line as one command (#2460).
#
# Why: the lints checked shell code one line at a time. A call whose arguments
# carried on to the next line — `\`, or a line ending in `|`, `&&` or `||` —
# slipped past them, or tripped them falsely. Each now reads whole commands
# (scripts/lib/shell-join.sh), and the prose lints read a sentence or a phrase
# that wraps.
#
# L1  [change] lint-stage-io: a route_to_model call silenced on a continued line
# L2  [change] lint-silenced-redirect: `cmd < "$f" \` then `2>/dev/null`
# L3  [change] lint-stage-signals: `trap '…' \` then `TERM INT`
# L4  [change] lint-disposition-words: a result written with its word on the next line
# L5  [change] lint-test-identity: `--issue \` then a real issue number
# L6  [change] lint-test-engine-state: a cycle_iterations write split over lines
# L7  [change] lint-bare-timeout: `echo \` then `timeout` is not flagged
# L8  [change] lint-atomic-write-unchecked: a pipe ending a line into atomic_write
#              on the next is checked; `| atomic_write \` then `"$f" || true` is not flagged
# L9  [change] lint-grep-c: a count piped on with the pipe ending the line
# L10 [change] lint-plain-prompts: a banned phrase split over two lines
# L11 [change] lint-doc-style: an opening sentence wrapped over two lines passes
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "the lints read whole commands (#2460)"
setup_test_env "lint-multiline"
L="$REPO_ROOT/scripts/lib"
# Lint words assembled at runtime, so this file itself stays clean.
RTM="route_to_""model"; DN="/dev/""null"; AW="atomic""_write"; GC="grep"" -c"; ISS="--iss""ue"
_rc() { "$@" >/dev/null 2>&1; echo $?; }
_mk() { mkdir -p "$(dirname "$1")"; printf '%s\n' "${@:2}" > "$1"; }

# ── L1 ───────────────────────────────────────────────────────────────────────
_mk "$TEST_TEMP_DIR/l1/plugin.sh" "$RTM \"\$tier\" \\" "    \"\$prompt\" 2>$DN"
assert_eq "[L1] a model call silenced on its continued line is caught" "1" "$(_rc bash "$L/lint-stage-io.sh" "$TEST_TEMP_DIR/l1/plugin.sh")"

# ── L2 ───────────────────────────────────────────────────────────────────────
_mk "$TEST_TEMP_DIR/l2/x.sh" 'wc -l < "$f" \' "    2>$DN"
assert_eq "[L2] an input redirect silenced on the next line is caught" "1" "$(_rc bash "$L/lint-silenced-redirect.sh" "$TEST_TEMP_DIR/l2")"

# ── L3 ───────────────────────────────────────────────────────────────────────
_mk "$TEST_TEMP_DIR/l3/agent/p/plugin.sh" "trap 'cleanup' \\" "    TERM INT"
assert_eq "[L3] a trap whose signals are on the next line is caught" "1" "$(_rc bash "$L/lint-stage-signals.sh" "$TEST_TEMP_DIR/l3")"

# ── L4 ───────────────────────────────────────────────────────────────────────
_mk "$TEST_TEMP_DIR/l4/agent/p/plugin.sh" 'stage_result_write "$out" \' '    bogusword "the reason"'
assert_eq "[L4] a result word on the next line is checked" "1" "$(_rc bash "$L/lint-disposition-words.sh" "$TEST_TEMP_DIR/l4")"

# ── L5 ───────────────────────────────────────────────────────────────────────
_mk "$TEST_TEMP_DIR/l5/tests/unit/x-test.sh" "bash runner.sh $ISS \\" "    1835"
assert_eq "[L5] a real issue number on the next line is caught" "1" "$(_rc bash "$L/lint-test-identity.sh" "$TEST_TEMP_DIR/l5")"

# ── L6 ───────────────────────────────────────────────────────────────────────
_mk "$TEST_TEMP_DIR/l6/tests/unit/x-test.sh" "jq '.cycle_iterations[\"c\"]" "    = {current_iter: 1}' s.json"
assert_eq "[L6] a cycle_iterations write split over lines is caught" "1" "$(_rc bash "$L/lint-test-engine-state.sh" "$TEST_TEMP_DIR/l6")"

# ── L7 ───────────────────────────────────────────────────────────────────────
_mk "$TEST_TEMP_DIR/l7/scripts/x.sh" 'echo \' '    timeout'
assert_eq "[L7] an argument on a continued line is not a bare timeout" "0" "$(_rc bash "$L/lint-bare-timeout.sh" "$TEST_TEMP_DIR/l7")"

# ── L8 ───────────────────────────────────────────────────────────────────────
_mk "$TEST_TEMP_DIR/l8/bad.sh" "printf '%s' \"\$x\" |" "    $AW \"\$f\""
_mk "$TEST_TEMP_DIR/l8/ok.sh" "printf '%s' \"\$x\" | $AW \\" '    "$f" || true'
assert_eq "[L8] a pipe ending a line into the write is checked" "1" "$(_rc bash "$L/lint-atomic-write-unchecked.sh" "$TEST_TEMP_DIR/l8/bad.sh")"
assert_eq "[L8] ...a checked write with its check on the next line is not flagged" "0" "$(_rc bash "$L/lint-atomic-write-unchecked.sh" "$TEST_TEMP_DIR/l8/ok.sh")"

# ── L9 ───────────────────────────────────────────────────────────────────────
_mk "$TEST_TEMP_DIR/l9/x.sh" "n=\"\$($GC x f |" "    tr -d ' ' || echo 0)\""
assert_eq "[L9] a count piped on, the pipe ending its line, is caught" "1" "$(_rc bash "$L/lint-grep-c.sh" "$TEST_TEMP_DIR/l9")"

# ── L10 ──────────────────────────────────────────────────────────────────────
mkdir -p "$TEST_TEMP_DIR/l10/config" "$TEST_TEMP_DIR/l10/p"
printf 'p/prompt.md\n' > "$TEST_TEMP_DIR/l10/config/model-facing-sources.txt"
printf '%s\n' "Check the result. This part is not" "your job to do." > "$TEST_TEMP_DIR/l10/p/prompt.md"
assert_eq "[L10] a banned phrase split over two lines is caught" "1" "$(_rc bash "$L/lint-plain-prompts.sh" "$TEST_TEMP_DIR/l10")"

# ── L11 ──────────────────────────────────────────────────────────────────────
mkdir -p "$TEST_TEMP_DIR/l11/docs/wiki"
printf '%s\n' "# Readme" "" "This page explains how a run works and" "who it is for." > "$TEST_TEMP_DIR/l11/README.md"
printf '%s\n' "# Page" "" "This page says what the engine does for" "a newcomer." > "$TEST_TEMP_DIR/l11/docs/wiki/Page.md"
assert_eq "[L11] an opening sentence wrapped over two lines passes" "0" "$(ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/l11" _rc bash "$L/lint-doc-style.sh")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
