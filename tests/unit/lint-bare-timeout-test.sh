#!/usr/bin/env bash
# Tests: scripts/lib/lint-bare-timeout.sh (#1752, ADR-036 amendment 2026-10-09).
#
# Every timeout bound in core/, scripts/ and plugins/ goes through the shared
# helper (scripts/lib/timeout-cmd.sh). The lint fails on:
#   L1  a bare `timeout` call, in every command position it can take
#   L2  a hand-written gtimeout/timeout probe outside the helper — the old shape
#       a bare-call check alone cannot see
# and passes:
#   L3  text that only mentions the word (comments, strings, variable names)
#   L4  a line carrying `# lint-bare-timeout:allow: <reason>`; an allow with no
#       reason is itself a failure
#   L5  scripts/lib/test-helpers.sh (a test-only mock) and anything under legacy/
#   L6  the real tree — and `npm run lint` runs the lint
#   L7  scripts/release.sh's `pr checks` call is exempted with a reason
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "lint-bare-timeout — one helper for every timeout bound (#1752)"
setup_test_env "lint-bare-timeout"
_test_cleanup_hook() { cleanup_test_env; }

LINT="$REPO_ROOT/scripts/lib/lint-bare-timeout.sh"

# _lint_line <dir under root> <line> — run the lint on a fresh tree holding one
# file with that line; print `rc=<rc>` then the lint's output.
_lint_line() {
    local root; root="$(mktemp -d "$TEST_TEMP_DIR/root.XXXXXX")"
    mkdir -p "$root/$1"
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$root/$1/x.sh"
    local out rc=0
    out="$(bash "$LINT" "$root" 2>&1)" || rc=$?
    printf 'rc=%s\n%s\n' "$rc" "$out"
}
_rc() { local o; o="$(_lint_line "$@")"; printf '%s' "${o%%$'\n'*}"; }

print_test_section "L1: a bare timeout call fails, in any command position"
_l1="$(_lint_line scripts 'timeout 5 sleep 1')"
assert_eq "[L1] a planted bare call fails the lint" "rc=1" "${_l1%%$'\n'*}"
assert_contains "[L1] the failure names the file and line" "$_l1" "scripts/x.sh:2"
assert_eq "[L1] ...in core/"    "rc=1" "$(_rc core 'timeout 5 sleep 1')"
assert_eq "[L1] ...in plugins/" "rc=1" "$(_rc plugins/agent/x 'timeout 5 sleep 1')"
assert_eq "[L1] after if !"      "rc=1" "$(_rc scripts 'if ! timeout "$t" gh pr checks; then :; fi')"
assert_eq "[L1] after a pipe"    "rc=1" "$(_rc scripts 'echo x | timeout 3 cat')"
assert_eq "[L1] after &&"        "rc=1" "$(_rc scripts 'true && timeout 3 cat')"
assert_eq "[L1] in \$(...)"      "rc=1" "$(_rc scripts 'x=$(timeout 2 date)')"
assert_eq "[L1] in \"\$(...)\""  "rc=1" "$(_rc scripts 'x="$(timeout 2 date)"')"
assert_eq "[L1] after exec"      "rc=1" "$(_rc scripts 'exec timeout 2 date')"
assert_eq "[L1] after then"      "rc=1" "$(_rc scripts 'if true; then timeout 2 date; fi')"
assert_eq "[L1] indented"        "rc=1" "$(_rc scripts '    timeout 2 date')"
assert_eq "[L1] gtimeout called directly" "rc=1" "$(_rc scripts 'gtimeout 5 sleep 1')"

print_test_section "L2: a hand-written probe outside the helper fails"
assert_eq "[L2] command -v gtimeout" "rc=1" \
    "$(_rc scripts 'if command -v gtimeout >/dev/null 2>&1; then t=gtimeout; fi')"
assert_eq "[L2] command -v timeout"  "rc=1" \
    "$(_rc core 'command -v timeout >/dev/null && t=timeout')"
_root="$(mktemp -d "$TEST_TEMP_DIR/root.XXXXXX")"; mkdir -p "$_root/scripts/lib"
printf 'if command -v gtimeout >/dev/null 2>&1; then b=gtimeout; fi\n' > "$_root/scripts/lib/timeout-cmd.sh"
_rc_h=0; bash "$LINT" "$_root" >/dev/null 2>&1 || _rc_h=$?
assert_eq "[L2] the probe inside scripts/lib/timeout-cmd.sh is the helper itself" "0" "$_rc_h"

print_test_section "L3: mentions of the word pass"
assert_eq "[L3] a comment"             "rc=0" "$(_rc scripts '# timeout 5 is what we used to call')"
assert_eq "[L3] a trailing comment"    "rc=0" "$(_rc scripts 'x=1  # then timeout 5 cmd')"
assert_eq "[L3] a comment right after an operator" "rc=0" "$(_rc scripts 'case "$x" in a)# off; timeout 5 y')"
assert_eq "[L3] inside a string"       "rc=0" "$(_rc scripts 'info "checks-wait (timeout ${s}s)"')"
assert_eq "[L3] inside single quotes"  "rc=0" "$(_rc scripts "echo 'x; timeout 5 y'")"
assert_eq "[L3] a variable name"       "rc=0" "$(_rc scripts 'local timeout_secs=3; ZBUILD_TEST_FILE_TIMEOUT=1')"
assert_eq "[L3] a flag"                "rc=0" "$(_rc scripts 'curl --timeout 5 x')"
assert_eq "[L3] the helper's argv"     "rc=0" "$(_rc scripts '"${_ACCEPTANCE_TOUT[@]}" bash "$f"')"
assert_eq "[L3] a timeout() function's name" "rc=0" "$(_rc scripts '_rt_timeout() { :; }')"

print_test_section "L4: the allow marker"
assert_eq "[L4] an allow with a reason passes" "rc=0" \
    "$(_rc scripts 'timeout 5 x  # lint-bare-timeout:allow: release tooling, out of scope')"
assert_eq "[L4] an allow with no reason fails" "rc=1" \
    "$(_rc scripts 'timeout 5 x  # lint-bare-timeout:allow')"

print_test_section "L5: exemptions"
_root="$(mktemp -d "$TEST_TEMP_DIR/root.XXXXXX")"; mkdir -p "$_root/scripts/lib" "$_root/legacy/scripts"
printf 'command -v timeout >/dev/null || x=1\ntimeout 5 y\n' > "$_root/scripts/lib/test-helpers.sh"
printf 'timeout 5 y\n' > "$_root/legacy/scripts/old.sh"
_rc_e=0; bash "$LINT" "$_root" >/dev/null 2>&1 || _rc_e=$?
assert_eq "[L5] scripts/lib/test-helpers.sh and legacy/ are not scanned" "0" "$_rc_e"
assert_contains "[L5] the test-helpers exemption states its reason" \
    "$(/usr/bin/grep -F 'test-helpers.sh' "$LINT" 2>/dev/null || true)" "mock"

print_test_section "L6: the real tree"
_rc_t=0; _out_t="$(bash "$LINT" "$REPO_ROOT" 2>&1)" || _rc_t=$?
assert_eq "[L6] the repository passes the lint" "0" "$_rc_t"
[[ "$_rc_t" -eq 0 ]] || printf '%s\n' "$_out_t" >&2
assert_contains "[L6] npm run lint runs it" \
    "$(jq -r '.scripts.lint' "$REPO_ROOT/package.json")" "bash scripts/lib/lint-bare-timeout.sh"

print_test_section "L7: scripts/release.sh"
assert_contains "[L7] the pr-checks call is exempted with a reason" \
    "$(/usr/bin/grep -E 'pr checks' "$REPO_ROOT/scripts/release.sh" || true)" "lint-bare-timeout:allow: "

cleanup_test_env
print_test_results
exit $((FAIL > 0))
