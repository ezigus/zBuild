#!/usr/bin/env bash
# Tests: plugins/tool/output-github-comment — final MVP pipeline stage (issue #87)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: output-github-comment (issue #87)"

setup_test_env "plugin-output"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# PATH-shadow for mocking gh CLI
mkdir -p "$TEST_TEMP_DIR/bin"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

# shellcheck source=../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

PLUGIN_DIR="$REPO_ROOT/plugins/tool/output-github-comment"

# ─── Test 1: Manifest validates + plugin discoverable ────────────────────────
set +e
validate_manifest "$PLUGIN_DIR/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "output manifest validates" "0" "$rc"

discovered="$(discover_plugins "$REPO_ROOT/plugins")"
assert_contains "output-github-comment discovered in plugin registry" "$discovered" "tool/output-github-comment"

# ─── Source plugin under test ─────────────────────────────────────────────────
# shellcheck source=../plugins/tool/output-github-comment/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# ─── Shared fixtures ──────────────────────────────────────────────────────────
STATE_DIR="$TEST_TEMP_DIR/state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"
echo '{"schema_version":1,"run_id":"test-run-001","issue":"0","stage_statuses":{}}' > "$STATE_FILE"
export ZBUILD_RUN_ID="test-run-001"
# Route all file-write assertions to a fixed path (ZBUILD_OUTPUT takes
# precedence over stdout default introduced in #238).
export ZBUILD_OUTPUT="$STATE_DIR/report-test-run-001.md"

output_init >/dev/null 2>&1

# ─── Test 2: No artifacts dir → local report with 0 findings ─────────────────
unset ZBUILD_ISSUE 2>/dev/null || true
rm -rf "$ARTIFACTS_DIR"

set +e
output_run "output" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "no artifacts returns rc=0" "0" "$rc"
assert_file_exists "local report written" "$STATE_DIR/report-test-run-001.md"
assert_contains "report contains 0 finding(s)" "$(cat "$STATE_DIR/report-test-run-001.md")" "0 finding(s)"
mkdir -p "$ARTIFACTS_DIR"

# ─── Test 3: One findings.json → report contains finding titles ───────────────
cat > "$ARTIFACTS_DIR/security-findings.json" <<'JSON'
{"schema_version":1,"plugin_id":"security-lens","findings":[
  {"title":"SQL Injection","severity":"high","category":"injection","file":"src/db.sh:42","evidence":"x","suggestion":"quote vars"},
  {"title":"Path Traversal","severity":"medium","category":"injection","file":"src/io.sh:7","evidence":"y","suggestion":"sanitize"}
],"stub":false}
JSON

unset ZBUILD_ISSUE 2>/dev/null || true

output_run "output" "$STATE_FILE" >/dev/null 2>&1
report="$(cat "$STATE_DIR/report-test-run-001.md")"
assert_contains "report contains SQL Injection" "$report" "SQL Injection"
assert_contains "report contains Path Traversal" "$report" "Path Traversal"

# ─── Test 4: Two findings.json files → all findings merged ───────────────────
cat > "$ARTIFACTS_DIR/lint-findings.json" <<'JSON'
{"schema_version":1,"plugin_id":"lint","findings":[
  {"title":"Unused Variable","severity":"low","category":"style","file":"src/util.sh:3","evidence":"z","suggestion":"remove"}
],"stub":false}
JSON

output_run "output" "$STATE_FILE" >/dev/null 2>&1
report="$(cat "$STATE_DIR/report-test-run-001.md")"
assert_contains "merged report has SQL Injection" "$report" "SQL Injection"
assert_contains "merged report has Unused Variable" "$report" "Unused Variable"

# ─── Test 5: Severity ordering — critical before high before medium ───────────
cat > "$ARTIFACTS_DIR/ordering-findings.json" <<'JSON'
{"schema_version":1,"plugin_id":"test","findings":[
  {"title":"Low Finding","severity":"low","category":"other","file":"a:1","evidence":"x","suggestion":"s"},
  {"title":"Critical Finding","severity":"critical","category":"injection","file":"b:1","evidence":"x","suggestion":"s"},
  {"title":"Medium Finding","severity":"medium","category":"other","file":"c:1","evidence":"x","suggestion":"s"}
],"stub":false}
JSON
rm -f "$ARTIFACTS_DIR/security-findings.json" "$ARTIFACTS_DIR/lint-findings.json"

output_run "output" "$STATE_FILE" >/dev/null 2>&1
report="$(cat "$STATE_DIR/report-test-run-001.md")"

critical_pos=$(echo "$report" | grep -n "Critical Finding" | cut -d: -f1 || echo 9999)
medium_pos=$(echo "$report" | grep -n "Medium Finding" | cut -d: -f1 || echo 9999)
low_pos=$(echo "$report" | grep -n "Low Finding" | cut -d: -f1 || echo 9999)
if [[ "$critical_pos" -lt "$medium_pos" && "$medium_pos" -lt "$low_pos" ]]; then
    assert_pass "severity ordering: critical < medium < low in report"
else
    assert_fail "severity ordering wrong: critical=$critical_pos medium=$medium_pos low=$low_pos"
fi
rm -f "$ARTIFACTS_DIR/ordering-findings.json"

# ─── Test 6: ZBUILD_ISSUE unset → local report written, gh NOT called ─────────
cat > "$ARTIFACTS_DIR/f.json" <<'JSON'
{"schema_version":1,"plugin_id":"test","findings":[{"title":"T1","severity":"low","category":"other","file":"x:1","evidence":"e","suggestion":"s"}],"stub":false}
JSON
unset ZBUILD_ISSUE 2>/dev/null || true

output_run "output" "$STATE_FILE" >/dev/null 2>&1

assert_file_exists "local report written when no issue" "$STATE_DIR/report-test-run-001.md"
if [[ -f "$TEST_TEMP_DIR/last_gh_args" ]]; then
    assert_fail "gh should NOT be called when ZBUILD_ISSUE unset"
else
    assert_pass "gh not called when ZBUILD_ISSUE unset"
fi

# ─── Test 7: ZBUILD_ISSUE set → gh called with correct args ──────────────────
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TEMP_DIR/last_gh_args"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

export ZBUILD_ISSUE="42"

set +e
output_run "output" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "gh run returns rc=0" "0" "$rc"
assert_file_exists "gh was called (last_gh_args written)" "$TEST_TEMP_DIR/last_gh_args"
gh_args="$(cat "$TEST_TEMP_DIR/last_gh_args")"
assert_contains "gh called with 'issue'" "$gh_args" "issue"
assert_contains "gh called with 'comment'" "$gh_args" "comment"
assert_contains "gh called with issue number" "$gh_args" "42"
assert_contains "gh called with --body-file" "$gh_args" "--body-file"
rm -f "$TEST_TEMP_DIR/last_gh_args"

# ─── Test 8: gh fails → plugin returns rc=1 + error event ────────────────────
cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

export ZBUILD_ISSUE="42"

set +e
output_run "output" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "gh failure returns plugin rc=1" "1" "$rc"
error_reason=$(grep '"plugin.run.error"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="plugin.run.error") | .data.reason // empty' 2>/dev/null | tail -1 || true)
assert_eq "plugin.run.error emitted with gh_failed" "gh_failed" "$error_reason"
unset ZBUILD_ISSUE

# ─── Test 9: plugin.run.complete event with findings_count ───────────────────
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"
unset ZBUILD_ISSUE 2>/dev/null || true

output_run "output" "$STATE_FILE" >/dev/null 2>&1

run_complete=$(grep '"plugin.run.complete"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="plugin.run.complete" and .data.plugin=="output-github-comment") | .data.findings_count // empty' 2>/dev/null | tail -1 || true)
if [[ -n "$run_complete" ]]; then
    assert_pass "plugin.run.complete event has findings_count field"
else
    assert_fail "plugin.run.complete missing findings_count"
fi

# ─── Test 10: output_finalize → plugin.finalize.complete event ───────────────
output_finalize >/dev/null 2>&1
finalize_count=$(grep -c '"plugin.finalize.complete"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
assert_gt "plugin.finalize.complete event emitted" "$finalize_count" "0"

# ─── Test 11: findings.json with stub:false field → ignored cleanly ──────────
rm -f "$ARTIFACTS_DIR"/*.json
cat > "$ARTIFACTS_DIR/stub-test-findings.json" <<'JSON'
{"schema_version":1,"plugin_id":"test","stub":false,"findings":[{"title":"Real Finding","severity":"high","category":"injection","file":"x:1","evidence":"e","suggestion":"s"}],"extra_field":"ignored"}
JSON
unset ZBUILD_ISSUE 2>/dev/null || true

set +e
output_run "output" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "stub:false field ignored, rc=0" "0" "$rc"
assert_contains "Real Finding in report" "$(cat "$STATE_DIR/report-test-run-001.md")" "Real Finding"

# ─── Test 12: one malformed + one valid findings.json → valid findings kept ───
rm -f "$ARTIFACTS_DIR"/*.json
cat > "$ARTIFACTS_DIR/bad-findings.json" <<'JSON'
this is not json at all
JSON
cat > "$ARTIFACTS_DIR/good-findings.json" <<'JSON'
{"schema_version":1,"plugin_id":"test","findings":[{"title":"Good Finding","severity":"high","category":"injection","file":"src/x.sh:1","evidence":"e","suggestion":"s"}],"stub":false}
JSON
unset ZBUILD_ISSUE 2>/dev/null || true

set +e
output_run "output" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "malformed file alongside valid file returns rc=0" "0" "$rc"
assert_contains "valid finding kept despite malformed sibling" \
    "$(cat "$STATE_DIR/report-test-run-001.md")" "Good Finding"

# ─── Test 13: pipe and newline in finding fields → table cell sanitized ───────
rm -f "$ARTIFACTS_DIR"/*.json
cat > "$ARTIFACTS_DIR/pipe-findings.json" <<'JSON'
{"schema_version":1,"plugin_id":"test","findings":[{"title":"A | B title","severity":"low","category":"style","file":"src/x.sh:1","evidence":"e","suggestion":"do this\nor that"}],"stub":false}
JSON
unset ZBUILD_ISSUE 2>/dev/null || true

output_run "output" "$STATE_FILE" >/dev/null 2>&1
report="$(cat "$STATE_DIR/report-test-run-001.md")"

if echo "$report" | grep -qF 'A \| B title'; then
    assert_pass "pipe in title escaped with backslash in table cell"
else
    assert_fail "pipe in title should be escaped as \\| in table cell"
fi
# Both substrings must appear on the same line — only possible if the newline was collapsed.
if echo "$report" | grep -q "do this.*or that"; then
    assert_pass "newline in suggestion collapsed to space in table cell"
else
    assert_fail "newline in suggestion should be collapsed in table cell"
fi

# ─── Test 14: local-report destination writes correct path ───────────────────
# (ZBUILD_OUTPUT is superseded by the destinations abstraction in #213;
#  the local-report destination always writes state_dir/report-<run_id>.md)
rm -f "$ARTIFACTS_DIR"/*.json
cat > "$ARTIFACTS_DIR/t14-findings.json" <<'JSON'
{"schema_version":1,"plugin_id":"test","findings":[{"title":"T14 Finding","severity":"low","category":"other","file":"x:1","evidence":"e","suggestion":"s"}],"stub":false}
JSON
unset ZBUILD_ISSUE 2>/dev/null || true
unset ZBUILD_OUTPUT 2>/dev/null || true

set +e
output_run "output" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "local-report destination returns rc=0" "0" "$rc"
assert_file_exists "local report written at state_dir/report-<run_id>.md" \
    "$STATE_DIR/report-test-run-001.md"
assert_contains "local report contains finding" \
    "$(cat "$STATE_DIR/report-test-run-001.md")" "T14 Finding"
rm -f "$ARTIFACTS_DIR/t14-findings.json"

# ─── Teardown ────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
