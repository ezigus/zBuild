#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/helpers test — Unit tests for shared helper functions     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: helpers Tests"

setup_test_env "sw-lib-helpers-test"
_test_cleanup_hook() { cleanup_test_env; }

mock_git

# Source helpers (clear guard to re-source)
_SW_HELPERS_LOADED=""
export EVENTS_FILE="$TEST_TEMP_DIR/home/.shipwright/events.jsonl"
source "$SCRIPT_DIR/lib/helpers.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Output helpers
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Output helpers"

info_output=$(info "test message" 2>&1)
assert_contains "info outputs message" "$info_output" "test message"

success_output=$(success "done" 2>&1)
assert_contains "success outputs message" "$success_output" "done"

warn_output=$(warn "warning" 2>&1)
assert_contains "warn outputs message" "$warn_output" "warning"

error_output=$(error "bad" 2>&1)
assert_contains "error outputs message" "$error_output" "bad"

# ═══════════════════════════════════════════════════════════════════════════════
# Timestamp helpers
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Timestamp helpers"

iso=$(now_iso)
assert_contains_regex "now_iso format" "$iso" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

epoch=$(now_epoch)
assert_contains_regex "now_epoch is numeric" "$epoch" '^[0-9]+$'

# Epoch should be recent (after 2024)
if [[ "$epoch" -gt 1700000000 ]]; then
    assert_pass "now_epoch is a reasonable timestamp"
else
    assert_fail "now_epoch is a reasonable timestamp" "got: $epoch"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# emit_event
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "emit_event"

rm -f "$EVENTS_FILE"
emit_event "test.event" "key1=value1" "key2=42"

assert_file_exists "Events file created" "$EVENTS_FILE"

event_line=$(cat "$EVENTS_FILE")
assert_contains "Event has type" "$event_line" '"type":"test.event"'
assert_contains "Event has string field" "$event_line" '"key1":"value1"'
assert_contains "Event has numeric field" "$event_line" '"key2":42'
assert_contains "Event has timestamp" "$event_line" '"ts":'
assert_contains "Event has epoch" "$event_line" '"ts_epoch":'

# Valid JSON
if echo "$event_line" | jq empty 2>/dev/null; then
    assert_pass "Event line is valid JSON"
else
    assert_fail "Event line is valid JSON" "line: $event_line"
fi

# Multiple events
emit_event "test.event2" "data=hello"
line_count=$(wc -l < "$EVENTS_FILE" | tr -d ' ')
assert_eq "Two events produce two lines" "2" "$line_count"

# Escaped special characters in values
emit_event "test.escape" "msg=hello \"world\""
last_line=$(tail -1 "$EVENTS_FILE")
if echo "$last_line" | jq empty 2>/dev/null; then
    assert_pass "Event with quotes is valid JSON"
else
    assert_fail "Event with quotes is valid JSON" "line: $last_line"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# with_retry
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "with_retry"

# Successful command
if with_retry 3 true 2>/dev/null; then
    assert_pass "with_retry succeeds on first try"
else
    assert_fail "with_retry succeeds on first try"
fi

# Always-failing command
if with_retry 2 false 2>/dev/null; then
    assert_fail "with_retry fails after max attempts"
else
    assert_pass "with_retry fails after 2 attempts"
fi

# Command that succeeds eventually (use a counter file)
counter_file="$TEST_TEMP_DIR/retry_counter"
echo "0" > "$counter_file"
flaky_cmd() {
    local count
    count=$(cat "$counter_file")
    count=$((count + 1))
    echo "$count" > "$counter_file"
    [[ "$count" -ge 2 ]]
}
if with_retry 3 flaky_cmd 2>/dev/null; then
    assert_pass "with_retry succeeds on second attempt"
    final_count=$(cat "$counter_file")
    assert_eq "Flaky command ran exactly 2 times" "2" "$final_count"
else
    assert_fail "with_retry succeeds on second attempt"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# validate_json
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "validate_json"

# Valid JSON
echo '{"valid": true}' > "$TEST_TEMP_DIR/good.json"
if validate_json "$TEST_TEMP_DIR/good.json" 2>/dev/null; then
    assert_pass "validate_json passes for valid JSON"
else
    assert_fail "validate_json passes for valid JSON"
fi
assert_file_exists "Backup created" "$TEST_TEMP_DIR/good.json.bak"

# Invalid JSON with valid backup
echo '{"valid": true}' > "$TEST_TEMP_DIR/corrupt.json.bak"
echo 'NOT JSON {{{' > "$TEST_TEMP_DIR/corrupt.json"
if validate_json "$TEST_TEMP_DIR/corrupt.json" 2>/dev/null; then
    assert_pass "validate_json recovers from backup"
    recovered=$(cat "$TEST_TEMP_DIR/corrupt.json")
    assert_contains "Recovered content is valid" "$recovered" '"valid"'
else
    assert_fail "validate_json recovers from backup"
fi

# Invalid JSON with no backup
echo 'NOT JSON' > "$TEST_TEMP_DIR/nobackup.json"
rm -f "$TEST_TEMP_DIR/nobackup.json.bak"
if validate_json "$TEST_TEMP_DIR/nobackup.json" 2>/dev/null; then
    assert_fail "validate_json fails with no backup"
else
    assert_pass "validate_json fails for corrupt JSON with no backup"
fi

# Non-existent file is OK
if validate_json "$TEST_TEMP_DIR/nonexistent.json" 2>/dev/null; then
    assert_pass "validate_json passes for non-existent file"
else
    assert_fail "validate_json passes for non-existent file"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# rotate_jsonl
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "rotate_jsonl"

# File under max_lines — no change
rotate_file="$TEST_TEMP_DIR/rotate_test.jsonl"
for i in $(seq 1 5); do echo "{\"line\":$i}" >> "$rotate_file"; done
rotate_jsonl "$rotate_file" 10
line_count=$(wc -l < "$rotate_file" | tr -d ' ')
assert_eq "Under-limit file not rotated" "5" "$line_count"

# File over max_lines — trimmed to max
for i in $(seq 6 25); do echo "{\"line\":$i}" >> "$rotate_file"; done
rotate_jsonl "$rotate_file" 10
line_count=$(wc -l < "$rotate_file" | tr -d ' ')
assert_eq "Over-limit file rotated to 10 lines" "10" "$line_count"

# Keeps most recent lines
last_line=$(tail -1 "$rotate_file")
assert_contains "Keeps most recent lines" "$last_line" '"line":25'

# Non-existent file is OK
rotate_jsonl "$TEST_TEMP_DIR/nonexistent.jsonl" 100
assert_pass "rotate_jsonl handles nonexistent file"

# ═══════════════════════════════════════════════════════════════════════════════
# Project identity helpers
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Project identity"

# _sw_github_repo fallback
export SHIPWRIGHT_GITHUB_REPO="testowner/testrepo"
result=$(_sw_github_repo)
# With mock git that returns "https://github.com/testuser/testrepo.git"
assert_contains "github_repo extracts from remote" "$result" "/"

# _sw_github_owner
owner=$(_sw_github_owner)
if [[ -n "$owner" ]]; then
    assert_pass "_sw_github_owner returns non-empty: $owner"
else
    assert_fail "_sw_github_owner returns non-empty"
fi

# _sw_docs_url
docs=$(_sw_docs_url)
assert_contains "_sw_docs_url contains github.io" "$docs" "github.io"

# _sw_github_url
url=$(_sw_github_url)
assert_contains "_sw_github_url contains github.com" "$url" "github.com"

unset SHIPWRIGHT_GITHUB_REPO

# extract_issue_from_tasks_file — multiple metadata format variants
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "extract_issue_from_tasks_file"

_tasks_tmp="$TEST_TEMP_DIR/tasks-format-test.md"

# Format 1: standard "- Issue: #42"
printf '# Pipeline Tasks\n- Issue: #42\n' > "$_tasks_tmp"
_iss=$(extract_issue_from_tasks_file "$_tasks_tmp")
assert_eq "dash prefix with # sign" "42" "$_iss"

# Format 2: "Issue: #42" (no leading dash)
printf '# Pipeline Tasks\nIssue: #42\n' > "$_tasks_tmp"
_iss=$(extract_issue_from_tasks_file "$_tasks_tmp")
assert_eq "no dash prefix with # sign" "42" "$_iss"

# Format 3: "- Issue: 42" (no # sign)
printf '# Pipeline Tasks\n- Issue: 42\n' > "$_tasks_tmp"
_iss=$(extract_issue_from_tasks_file "$_tasks_tmp")
assert_eq "dash prefix without # sign" "42" "$_iss"

# Format 4: "- issue: #42" (lowercase key)
printf '# Pipeline Tasks\n- issue: #42\n' > "$_tasks_tmp"
_iss=$(extract_issue_from_tasks_file "$_tasks_tmp")
assert_eq "lowercase issue key" "42" "$_iss"

# Format 5: "- Issue:  #42" (extra whitespace)
printf '# Pipeline Tasks\n- Issue:  #42\n' > "$_tasks_tmp"
_iss=$(extract_issue_from_tasks_file "$_tasks_tmp")
assert_eq "extra whitespace after colon" "42" "$_iss"

# Format 6: missing file → exit 1
rm -f "$_tasks_tmp"
if extract_issue_from_tasks_file "$_tasks_tmp" >/dev/null 2>&1; then
    assert_fail "missing file returns failure"
else
    assert_pass "missing file returns failure"
fi

# Format 7: no Issue: line → exit 1
printf '# Pipeline Tasks\n- [ ] some task\n' > "$_tasks_tmp"
if extract_issue_from_tasks_file "$_tasks_tmp" >/dev/null 2>&1; then
    assert_fail "no Issue line returns failure"
else
    assert_pass "no Issue line returns failure"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# strip_ansi
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "strip_ansi"

# Argument form
result=$(strip_ansi $'\x1b[31mred text\x1b[0m')
assert_eq "strip_ansi removes SGR color codes (argument)" "red text" "$result"

# Pipe form
result=$(echo $'\x1b[38;2;248;113;113mfailed\x1b[0m' | strip_ansi)
assert_eq "strip_ansi removes 24-bit color codes (pipe)" "failed" "$result"

# Non-SGR CSI sequences (cursor movement, clear)
result=$(strip_ansi $'\x1b[2Jcleared\x1b[H')
assert_eq "strip_ansi removes cursor/clear CSI codes" "cleared" "$result"

# Plain text passes through unchanged
result=$(strip_ansi "no escape codes here")
assert_eq "strip_ansi preserves plain text" "no escape codes here" "$result"

# Mixed content
result=$(strip_ansi $'\x1b[1m\x1b[31mERROR:\x1b[0m something broke')
assert_eq "strip_ansi handles multiple codes" "ERROR: something broke" "$result"

# Empty input
result=$(strip_ansi "")
assert_eq "strip_ansi handles empty input" "" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# _trim — whitespace trimming without xargs
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_trim"

assert_eq "_trim strips leading spaces" "hello" "$(_trim "  hello")"
assert_eq "_trim strips trailing spaces" "hello" "$(_trim "hello  ")"
assert_eq "_trim strips both sides" "hello" "$(_trim "  hello  ")"
assert_eq "_trim preserves internal spaces" "hello world" "$(_trim "  hello world  ")"
assert_eq "_trim handles empty string" "" "$(_trim "")"
assert_eq "_trim handles single quotes" "it's a test" "$(_trim "  it's a test  ")"
assert_eq "_trim handles tabs" "hello" "$(_trim "	hello	")"

# ═══════════════════════════════════════════════════════════════════════════════
# _file_in_scope
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_file_in_scope"

# Empty allowlist → fail-open (return 0)
_file_in_scope "scripts/lib/helpers.sh" "" && assert_pass "_file_in_scope: empty allowlist returns 0 (fail-open)" \
    || assert_fail "_file_in_scope: empty allowlist returns 0 (fail-open)" ""

# Literal match
_file_in_scope "scripts/lib/helpers.sh" "scripts/lib/helpers.sh" && assert_pass "_file_in_scope: literal exact match" \
    || assert_fail "_file_in_scope: literal exact match" ""

# Literal non-match
_file_in_scope ".claude/helpers/foo.cjs" "scripts/lib/helpers.sh" && assert_fail "_file_in_scope: literal non-match should return 1" "" \
    || assert_pass "_file_in_scope: literal non-match returns 1"

# Directory prefix (trailing /)
_file_in_scope "scripts/lib/helpers.sh" "scripts/lib/" && assert_pass "_file_in_scope: directory prefix match" \
    || assert_fail "_file_in_scope: directory prefix match" ""

_file_in_scope ".claude/helpers/foo.cjs" "scripts/lib/" && assert_fail "_file_in_scope: directory prefix non-match should return 1" "" \
    || assert_pass "_file_in_scope: directory prefix non-match returns 1"

# Single-star glob
_file_in_scope "scripts/lib/helpers.sh" "scripts/lib/*.sh" && assert_pass "_file_in_scope: single-star glob match" \
    || assert_fail "_file_in_scope: single-star glob match" ""

_file_in_scope "scripts/lib/sub/helpers.sh" "scripts/lib/*.sh" && assert_fail "_file_in_scope: single-star does not cross dirs" "" \
    || assert_pass "_file_in_scope: single-star does not cross dirs"

# Double-star glob (**) — matches across directories
_file_in_scope "scripts/lib/sub/helpers.sh" "scripts/**" && assert_pass "_file_in_scope: double-star matches subdirs" \
    || assert_fail "_file_in_scope: double-star matches subdirs" ""

_file_in_scope ".claude/helpers/foo.cjs" "scripts/**" && assert_fail "_file_in_scope: double-star non-match returns 1" "" \
    || assert_pass "_file_in_scope: double-star non-match returns 1"

# Double-star with suffix (e.g. **/*.ts) — must NOT fail-open
_file_in_scope "scripts/lib/helpers.sh" "**/*.ts" && assert_fail "_file_in_scope: **/*.ts does not match non-.ts file" "" \
    || assert_pass "_file_in_scope: **/*.ts does not match non-.ts file"

_file_in_scope "src/components/Button.ts" "**/*.ts" && assert_pass "_file_in_scope: **/*.ts matches .ts file anywhere" \
    || assert_fail "_file_in_scope: **/*.ts matches .ts file anywhere" ""

# Comment lines are ignored
_file_in_scope "scripts/lib/helpers.sh" "# this is a comment
scripts/lib/helpers.sh" && assert_pass "_file_in_scope: comment lines are skipped" \
    || assert_fail "_file_in_scope: comment lines are skipped" ""

# ═══════════════════════════════════════════════════════════════════════════════
# _redact_paths_outside_scope
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_redact_paths_outside_scope"

# Pass-through when allowlist is empty
_rps_out=$(_redact_paths_outside_scope "some text with scripts/lib/helpers.sh:42" "")
assert_eq "_redact_paths_outside_scope: empty allowlist pass-through" \
    "some text with scripts/lib/helpers.sh:42" "$_rps_out"

# In-scope path is NOT redacted
_rps_out=$(_redact_paths_outside_scope "fix scripts/lib/helpers.sh:42" "scripts/lib/helpers.sh" "test" "0")
assert_eq "_redact_paths_outside_scope: in-scope path not redacted" \
    "fix scripts/lib/helpers.sh:42" "$_rps_out"

# Out-of-scope path IS redacted
_rps_out=$(_redact_paths_outside_scope "found .claude/helpers/foo.cjs:88" "scripts/lib/helpers.sh" "test" "0")
if echo "$_rps_out" | grep -qF ".claude/helpers/foo.cjs"; then
    assert_fail "_redact_paths_outside_scope: OOS path removed" "path still visible in output: $_rps_out"
else
    assert_pass "_redact_paths_outside_scope: OOS path removed"
fi
assert_contains "_redact_paths_outside_scope: sentinel present" "$_rps_out" "[redacted:out-of-scope:TOKEN-1]"

# URL is NOT redacted (negative filter)
_rps_url_out=$(_redact_paths_outside_scope "see https://example.com/foo.js for details" "scripts/" "test" "0")
assert_contains "_redact_paths_outside_scope: URL not redacted" "$_rps_url_out" "https://example.com/foo.js"

# Version string is NOT redacted (negative filter — starts with digit)
_rps_ver_out=$(_redact_paths_outside_scope "requires node 18.1.0 or newer" "scripts/" "test" "0")
assert_contains "_redact_paths_outside_scope: version not redacted" "$_rps_ver_out" "18.1.0"

# Code fence block is preserved verbatim
_rps_fence_in=$'## diff\n```\nscripts/lib/helpers.sh:42\n```\nafter fence'
_rps_fence_out=$(_redact_paths_outside_scope "$_rps_fence_in" "nothing/" "test" "0")
assert_contains "_redact_paths_outside_scope: code fence preserved verbatim" \
    "$_rps_fence_out" "scripts/lib/helpers.sh:42"

# <out-of-scope-context> block preserved verbatim
_rps_oos_in=$'line before\n<out-of-scope-context>\n.claude/helpers/foo.cjs:10\n</out-of-scope-context>\nline after'
_rps_oos_out=$(_redact_paths_outside_scope "$_rps_oos_in" "scripts/lib/" "test" "0")
assert_contains "_redact_paths_outside_scope: out-of-scope-context block preserved" \
    "$_rps_oos_out" ".claude/helpers/foo.cjs:10"

# Idempotency: running redaction twice produces no further changes
_rps_once=$(_redact_paths_outside_scope "fixed .claude/helpers/bar.cjs:5" "scripts/" "test" "0")
_rps_twice=$(_redact_paths_outside_scope "$_rps_once" "scripts/" "test" "0")
assert_eq "_redact_paths_outside_scope: idempotent (second pass no-op)" "$_rps_once" "$_rps_twice"

# Sidecar manifest is written when allowlist non-empty and OOS token found
_rps_sidecar_dir=$(mktemp -d "${TMPDIR:-/tmp}/sw-rps-sidecar.XXXXXX")
ARTIFACTS_DIR="$_rps_sidecar_dir" _redact_paths_outside_scope \
    "found .claude/helpers/baz.cjs" "scripts/lib/" "test_seam" "5" >/dev/null
if [[ -f "${_rps_sidecar_dir}/oos-redactions-cycle-5.json" ]]; then
    assert_pass "_redact_paths_outside_scope: sidecar manifest written"
    _sidecar_content=$(cat "${_rps_sidecar_dir}/oos-redactions-cycle-5.json")
    assert_contains "_redact_paths_outside_scope: sidecar contains original path" \
        "$_sidecar_content" ".claude/helpers/baz.cjs"
else
    assert_fail "_redact_paths_outside_scope: sidecar manifest written" "file not found"
fi
rm -rf "$_rps_sidecar_dir"

# Extensionless path with slash component is detected and redacted when OOS
_rps_out=$(_redact_paths_outside_scope "check scripts/sw for issues" "scripts/lib/" "test" "0")
if echo "$_rps_out" | grep -qF "scripts/sw"; then
    assert_fail "_redact_paths_outside_scope: extensionless slashed path redacted" "path still visible: $_rps_out"
else
    assert_pass "_redact_paths_outside_scope: extensionless slashed path redacted"
fi

print_test_results
