#!/usr/bin/env bash
# tests/unit/lint-silenced-redirect-test.sh — `cmd < "$f" 2>/dev/null` does not
# silence a missing file (#2246).
#
# Redirections apply left to right: `< "$f"` fails BEFORE `2>/dev/null` is in
# place, so bash prints "No such file or directory" anyway. design/plugin.sh
# printed it on every first design (`cksum < "$design_md" 2>/dev/null`). The fix
# is the order: `cmd 2>/dev/null < "$f"`.
#
# R1 [change] the lint refuses `< "$f" … 2>/dev/null` in one command
# R2 [guard]  the reordered form, and a `{ …; } 2>/dev/null` group, pass
# R3 [change] `# redirect-ok: <why>` on the line or the 3 above excuses one
# R4 [change] the real tree passes
# R5 [guard]  the reordered form really is silent for a missing file
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "a missing file is silenced only by redirecting stderr first (#2246)"
setup_test_env "lint-silenced-redirect"
LINT="$REPO_ROOT/scripts/lib/lint-silenced-redirect.sh"
F="$TEST_TEMP_DIR/tree/x.sh"; mkdir -p "$(dirname "$F")"
_lint() { bash "$LINT" "$TEST_TEMP_DIR/tree" >/dev/null 2>&1; echo $?; }

printf '%s\n' 'sum="$(cksum < "$f" 2>/dev/null || printf absent)"' > "$F"
assert_eq "[R1] cmd < \"\$f\" 2>/dev/null is refused" "1" "$(_lint)"
printf '%s\n' 'n="$(wc -c < "$log" 2>/dev/null | tr -d " ")"' > "$F"
assert_eq "[R1] ...inside a pipeline too" "1" "$(_lint)"
printf '%s\n' 'sum="$(cksum 2>/dev/null < "$f" || printf absent)"' '{ cksum < "$f"; } 2>/dev/null' > "$F"
assert_eq "[R2] stderr redirected first, or a group, passes" "0" "$(_lint)"
printf '%s\n' '# redirect-ok: the file is created two lines above' 'n="$(wc -l < "$f" 2>/dev/null)"' > "$F"
assert_eq "[R3] an annotated line passes" "0" "$(_lint)"
_real="$(bash "$LINT" 2>&1)"; _rc=$?
assert_eq "[R4] the real tree passes" "0" "$_rc"
[[ "$_rc" -eq 0 ]] || printf '%s\n' "$_real" >&2
_err="$(bash -c 'x="$(cksum 2>/dev/null < /nonexistent/zb-2246 || printf absent)"; printf "%s" "$x"' 2>&1)"
assert_eq "[R5] the reordered form prints nothing but its fallback" "absent" "$_err"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
