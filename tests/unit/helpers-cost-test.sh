#!/usr/bin/env bash
# tests/unit/helpers-cost-test.sh — what the engine's file helpers start
# (ADR-065 §5, round 5).
#
# H1 [change] zbuild_engine_tmpdir starts nothing once runtime/ exists — it ran
#             `mkdir -p` on every call
# H2 [change] atomic_replace starts cp and mv only — mktemp only made a name
# H3 [guard]  atomic_replace still replaces the target, and the copy keeps the
#             source's mode (a state .bak stays 0600)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "file helpers: what they start (ADR-065 §5)"
setup_test_env "helpers-cost"

_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
CALLS="$TEST_TEMP_DIR/calls"
_wrap()   { local c; for c in "$@"; do eval "$c() { printf '%s\\n' $c >> \"\$CALLS\"; command $c \"\$@\"; }"; done; }
_calls()  { sort "$CALLS" | tr '\n' ' ' | sed 's/ $//'; }

print_test_section "H1: zbuild_engine_tmpdir"
mkdir -p "$TEST_TEMP_DIR/state/runtime"
: > "$CALLS"
_wrap mkdir
_d="$(ZBUILD_STAGE_SCRATCH="" ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state" zbuild_engine_tmpdir)"
unset -f mkdir
assert_eq "[H1] the runtime dir is the answer" "$TEST_TEMP_DIR/state/runtime" "$_d"
assert_eq "[H1] …and nothing was started for it" "" "$(_calls)"

print_test_section "H2/H3: atomic_replace"
SRC="$TEST_TEMP_DIR/state.json"; DST="$TEST_TEMP_DIR/state.json.bak"
printf '{"a":1}\n' > "$SRC"; chmod 600 "$SRC"
: > "$CALLS"
_wrap mktemp cp mv rm
atomic_replace "$SRC" "$DST"; _rc=$?
unset -f mktemp cp mv rm
assert_eq "[H2] it starts cp and mv only" "cp mv" "$(_calls)"
assert_eq "[H3] the target is replaced" "0|{\"a\":1}" "$_rc|$(cat "$DST")"
assert_eq "[H3] …and keeps the source's mode" "600" "$(_mode "$DST")"
_left="$(find "$TEST_TEMP_DIR" -maxdepth 1 -name 'state.json.bak.tmp.*' | wc -l | tr -d ' ')"
assert_eq "[H3] …and leaves no temp behind" "0" "$_left"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
