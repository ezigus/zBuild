#!/usr/bin/env bash
# tests/unit/persist-secret-scan-cost-test.sh — what the push gate's secret
# scan starts (ADR-065 §5, round 5).
#
# _artifact_persist_find_secret runs after every stage. It read each artifact
# file on its own: `grep -Iq .`, `cat`, then three pattern greps — five
# programs a file, about 300 in a mocked full run, to find nothing.
#
# C1 [change] a clean artifact dir costs two greps over the whole dir, nothing
#             per file
# C2 [change] only a file that matches a pattern is read on its own
# C3 [guard]  the finding is unchanged: the first flagged file in find order,
#             with the kind the per-file scan names; binaries are skipped
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/secret-patterns.sh
source "$REPO_ROOT/scripts/lib/secret-patterns.sh"
# shellcheck source=../../core/state/artifact-persist.sh
source "$REPO_ROOT/core/state/artifact-persist.sh"

print_test_header "persist's secret scan: what it starts (ADR-065 §5)"
setup_test_env "persist-secret-scan-cost"

# Built from fragments so this file never carries the shape it tests.
_KEY='AKIA''ABCDEFGHIJKLMNOP'
_CRED='api_''key = "Zq8vN3kLx7PwR2mT"'

ART="$TEST_TEMP_DIR/art"
mkdir -p "$ART/sub"
for n in 1 2 3 4 5; do printf '{"stage":"s%s","outcome":"pass"}\n' "$n" > "$ART/s$n-result.json"; done
printf 'plain notes\n' > "$ART/sub/notes.md"
printf '\000\001binary\n' > "$ART/blob.bin"

CALLS="$TEST_TEMP_DIR/calls"
_count_on() {
    : > "$CALLS"
    for _c in grep cat find git; do
        eval "$_c() { printf '%s\\n' $_c >> \"\$CALLS\"; command $_c \"\$@\"; }"
    done
}
_count_off() { unset -f grep cat find git; }

print_test_section "C1: a clean dir"
_count_on
_f="$(_artifact_persist_find_secret "$ART" "$TEST_TEMP_DIR")"; _rc=$?
_count_off
assert_eq "[C1] nothing is found" "1|" "$_rc|$_f"
assert_eq "[C1] two greps over the whole dir, nothing per file" "grep grep" \
    "$(sort "$CALLS" | tr '\n' ' ' | sed 's/ $//')"

print_test_section "C2: only a matching file is read"
printf '%s\n' "$_KEY" > "$ART/sub/leak.txt"
_count_on
_f="$(_artifact_persist_find_secret "$ART" "$TEST_TEMP_DIR")"; _rc=$?
_count_off
assert_eq "[C2] the key is found" "0|sub/leak.txt:aws_access_key_id" "$_rc|$_f"
assert_eq "[C2] one file read on its own" "1" "$(/usr/bin/grep -cx cat "$CALLS")"

print_test_section "C3: the same finding as the per-file scan"
rm -f "$ART/sub/leak.txt"
# Two flagged files: the answer is whichever find lists first, as before.
printf '%s\n' "$_CRED" > "$ART/b-cred.txt"
printf '%s\n' "$_KEY" > "$ART/a-key.txt"
_first=""
while IFS= read -r -d '' _p; do
    case "$_p" in *a-key.txt) _first="a-key.txt:aws_access_key_id"; break ;;
                  *b-cred.txt) _first="b-cred.txt:credential_assignment"; break ;; esac
done < <(find "$ART" -type f -print0)
_f="$(_artifact_persist_find_secret "$ART" "$TEST_TEMP_DIR")"; _rc=$?
assert_eq "[C3] the first flagged file in find order, with its kind" "0|$_first" "$_rc|$_f"
rm -f "$ART/a-key.txt" "$ART/b-cred.txt"
printf '\000%s\n' "$_KEY" > "$ART/key.bin"
_f="$(_artifact_persist_find_secret "$ART" "$TEST_TEMP_DIR")"; _rc=$?
assert_eq "[C3] a binary file is not scanned" "1|" "$_rc|$_f"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
