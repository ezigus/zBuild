#!/usr/bin/env bash
# tests/unit/large-text-not-argv-test.sh — text that can be large reaches a
# program through a file or stdin, never one argument (#2592, ADR-054).
#
# Linux caps one argument at 128 KiB; macOS caps all of them together at about
# 1 MiB (#1764 run 43220496101 died on an issue over 1 MiB). The text below is
# 1.2 MiB: as an argument it fails on both.
#
# L1 [change] stage_result_write takes 1.2 MiB of data and writes it whole
# L2 [change] intake's result carries a 1.2 MiB issue whole (_intake_result_data_v)
# L3 [change] an issue comment's body reaches gh on stdin, not in its argv
#             (core/output/destinations.sh). GitHub caps a comment at 65,536
#             characters, so this one is 60 KB: under the per-argument limit, but
#             one way of passing large text everywhere.
# L4 [change] the test results' lint block keeps 1.2 MiB of lint output
#             (scripts/lib/framework-result.sh _fr_emit_lint)
# L5 [change] the monitor's result keeps 1.2 MiB of checks
# L6 [change] a stage-io comment renders a stage whose prompt is 1.2 MiB
#             (core/output/stage-io.sh _stage_io_to_gh_comment)
#             (plugins/agent/monitor _monitor_write_result)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "large text reaches programs through a file or stdin (#2592)"
setup_test_env "large-text-not-argv"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"

# 1.2 MiB of words, built in the shell (no program).
_big=""; _w="the issue says this many times over; "
while (( ${#_big} < 1258291 )); do _big+="$_w$_w$_w$_w$_w$_w$_w$_w"; done
_big+="BIG-END"

print_test_section "L1: the result writer"
_d="$(jq -nc --rawfile t <(printf '%s' "$_big") '{issue_text: $t}')"
_rc=0; stage_result_write "$TEST_TEMP_DIR/r1.json" pass "took it in" "$_d" || _rc=$?
assert_eq "[L1] a 1.2 MiB result is written" "0" "$_rc"
assert_eq "[L1] ...whole" "${#_big}" "$(jq -r '.data.issue_text | length' "$TEST_TEMP_DIR/r1.json" 2>/dev/null)"
# The data is one JSON object, as before: two values, or one and garbage, are refused.
_rc=0; stage_result_write "$TEST_TEMP_DIR/r2.json" pass "two" '{"a":1} {"b":2}' 2>/dev/null || _rc=$?
assert_eq "[L1] data that is two JSON values is refused" "1" "$_rc"
_rc=0; stage_result_write "$TEST_TEMP_DIR/r3.json" pass "junk" '{"a":1} junk' 2>/dev/null || _rc=$?
assert_eq "[L1] ...and one followed by garbage" "1" "$_rc"

print_test_section "L2: intake's result data"
# shellcheck source=../../plugins/agent/intake/plugin.sh
source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
_j=""; _rc=0; _intake_result_data_v _j "$_big" 1 null "" "[]" "[]" || _rc=$?
assert_eq "[L2] intake builds its data from a 1.2 MiB issue" "0" "$_rc"
assert_eq "[L2] ...the issue text whole" "${#_big}" "$(jq -r '.issue_text | length' <<< "$_j" 2>/dev/null)"
assert_eq "[L2] ...its length recorded" "${#_big}" "$(jq -r '.goal_len' <<< "$_j" 2>/dev/null)"

# A gh that records its argv and what it read on stdin.
GHLOG="$TEST_TEMP_DIR/gh.log"
cat > "$TEST_TEMP_DIR/bin/gh" <<EOF
#!/usr/bin/env bash
printf 'ARGV:' >> "$GHLOG"; for a in "\$@"; do printf ' [%s]' "\${a:0:40}" >> "$GHLOG"; done; printf '\n' >> "$GHLOG"
for a in "\$@"; do [[ "\$a" == "-" ]] && { printf 'STDIN:%s\n' "\$(wc -c | tr -d ' ')" >> "$GHLOG"; }; done
exit 0
EOF
chmod +x "$TEST_TEMP_DIR/bin/gh"; export PATH="$TEST_TEMP_DIR/bin:$PATH"

print_test_section "L3: an issue comment's body"
# shellcheck source=../../core/output/destinations.sh
source "$REPO_ROOT/core/output/destinations.sh" >/dev/null 2>&1
: > "$GHLOG"; export ZBUILD_ISSUE="$(zb_test_issue)"
_c60="${_big:0:60000}"
[[ "$(command -v gh)" == "$TEST_TEMP_DIR/bin/gh" ]] || { assert_fail "[L3] premise: the fake gh is first on PATH" "$(command -v gh)"; exit 1; }
_rc=0; _dest_gh_comment "$_c60" run-1 "$TEST_TEMP_DIR" >/dev/null 2>&1 || _rc=$?
assert_eq "[L3] a 60 KB comment is posted" "0" "$_rc"
assert_contains "[L3] ...its body read from stdin" "$(cat "$GHLOG")" "[--body-file] [-]"
assert_contains "[L3] ...all of it (and the newline a here-string adds)" "$(cat "$GHLOG")" "STDIN:$(( ${#_c60} + 1 ))"

print_test_section "L4: the lint block"
# shellcheck source=../../scripts/lib/framework-result.sh
source "$REPO_ROOT/scripts/lib/framework-result.sh" >/dev/null 2>&1
_l="$(_fr_emit_lint fail 1 "lint failed" "$_big")"
assert_eq "[L4] 1.2 MiB of lint output is kept whole" "${#_big}" "$(jq -r '.detail | length' <<< "$_l" 2>/dev/null)"

print_test_section "L5: the monitor's result"
# shellcheck source=../../plugins/agent/monitor/plugin.sh
source "$REPO_ROOT/plugins/agent/monitor/plugin.sh" >/dev/null 2>&1
_ck="$(jq -nc --rawfile t <(printf '%s' "$_big") '[{name: "big", detail: $t}]')"
_rc=0; _monitor_write_result "$TEST_TEMP_DIR/m.json" pass "checked" "fine" "$_ck" "" >/dev/null 2>&1 || _rc=$?
assert_eq "[L5] a 1.2 MiB monitor result is written" "0" "$_rc"
assert_eq "[L5] ...its checks whole" "${#_big}" "$(jq -r '.data.checks[0].detail | length' "$TEST_TEMP_DIR/m.json" 2>/dev/null)"

print_test_section "L6: a stage-io comment for a 1.2 MiB prompt"
# shellcheck source=../../core/output/stage-io.sh
source "$REPO_ROOT/core/output/stage-io.sh" >/dev/null 2>&1
_rec="$(jq -nc --rawfile i <(printf '%s' "$_big") '{stage: "intake", kind: "llm", seq: 1, input: $i, output: "ok", exit_code: "0", duration_ms: "100", metadata: {}}')"
printf '%s\n' '#!/usr/bin/env bash' "for a in \"\$@\"; do [[ \"\$a\" == \"-\" ]] && cat > \"$TEST_TEMP_DIR/l6-body.txt\"; done" 'exit 0' > "$TEST_TEMP_DIR/bin/gh"
chmod +x "$TEST_TEMP_DIR/bin/gh"; rm -f "$TEST_TEMP_DIR/l6-body.txt"
ZBUILD_OUTPUT_GH_COMMENT=1 _stage_io_to_gh_comment "$_rec" >/dev/null 2>&1 || true
assert_contains "[L6] the comment is rendered, not empty" "$(cat "$TEST_TEMP_DIR/l6-body.txt" 2>/dev/null)" "<summary>"
assert_contains "[L6] ...with the prompt's words in it" "$(cat "$TEST_TEMP_DIR/l6-body.txt" 2>/dev/null)" "the issue says this many times over"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
