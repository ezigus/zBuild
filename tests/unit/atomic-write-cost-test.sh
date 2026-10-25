#!/usr/bin/env bash
# tests/unit/atomic-write-cost-test.sh — what atomic_write starts, and keeps
# (ADR-065 §5, round 4).
#
# atomic_write takes every engine file write. Replacing a file started ten
# programs on macOS: df for a free-space check a full disk already fails on its
# own, mktemp for a name the shell can make, mktemp + cp + mv for a .bak that
# only state recovery ever reads, and two stats (GNU tried first) for the mode.
#
# W1 [change] replacing a file starts cat, one stat, chmod and mv — nothing else
# W2 [change] no .bak unless asked: `atomic_write --bak` keeps the previous
#             content in <target>.bak, as state recovery needs
# W3 [guard]  modes: a new file is 0600 (as mktemp made it); an existing file
#             keeps its own mode exactly, executable or not
# W4 [guard]  a write that cannot start (unwritable directory) refuses, leaves
#             no target, and still drains its stdin (#1773)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "atomic_write: what it starts, and what it keeps (ADR-065 §5)"
setup_test_env "atomic-write-cost"

_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

print_test_section "W1: replacing a file"
F1="$TEST_TEMP_DIR/w1/state.json"; mkdir -p "${F1%/*}"; printf '{"a":0}\n' > "$F1"; chmod 644 "$F1"
CALLS="$TEST_TEMP_DIR/calls"; : > "$CALLS"
for _c in df mktemp cp cat stat chmod mv dirname; do
    eval "$_c() { printf '%s\\n' $_c >> \"\$CALLS\"; command $_c \"\$@\"; }"
done
printf '{"a":1}\n' | atomic_write "$F1"; _rc1=$?
unset -f df mktemp cp cat stat chmod mv dirname
assert_eq "[W1] the file is replaced" "0|{\"a\":1}" "$_rc1|$(cat "$F1")"
assert_eq "[W1] it starts cat, one stat, chmod and mv" "cat chmod mv stat" \
    "$(sort "$CALLS" | tr '\n' ' ' | sed 's/ $//')"

print_test_section "W2: .bak only when asked"
assert_file_not_exists "[W2] a plain write leaves no .bak" "$F1.bak"
printf '{"a":2}\n' | atomic_write --bak "$F1"
assert_eq "[W2] --bak keeps the previous content" '{"a":1}' "$(cat "$F1.bak" 2>/dev/null)"
assert_eq "[W2] …and writes the new one" '{"a":2}' "$(cat "$F1")"

print_test_section "W3: modes"
F3="$TEST_TEMP_DIR/w3/new.json"; mkdir -p "${F3%/*}"
printf 'x\n' | atomic_write "$F3"
assert_eq "[W3] a new file is 0600" "600" "$(_mode "$F3")"
for _m in 644 640 755 700; do
    printf 'old\n' > "$F3.$_m"; chmod "$_m" "$F3.$_m"
    printf 'new\n' | atomic_write "$F3.$_m"
    assert_eq "[W3] an existing $_m file keeps $_m" "$_m|new" "$(_mode "$F3.$_m")|$(cat "$F3.$_m")"
done

print_test_section "W4: a write that cannot start"
RO="$TEST_TEMP_DIR/ro"; mkdir -p "$RO"; chmod 555 "$RO"
if [[ -w "$RO" ]]; then
    assert_pass "[W4] skipped — running as a user who can write a 555 directory"
else
    head -c 524288 /dev/zero | tr '\0' 'x' | atomic_write "$RO/out.json" 2>/dev/null
    _p=("${PIPESTATUS[@]}")
    assert_eq "[W4] the producer exits 0 (stdin drained) and atomic_write refuses" "0|1" "${_p[1]}|${_p[2]}"
    assert_file_not_exists "[W4] …and no target is left" "$RO/out.json"
fi
chmod 755 "$RO"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
