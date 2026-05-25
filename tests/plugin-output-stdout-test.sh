#!/usr/bin/env bash
# Tests: plugins/tool/output-github-comment — stdout default (issue #238)
# When neither ZBUILD_ISSUE nor ZBUILD_OUTPUT is set, the rendered report
# is printed to stdout and gh is never invoked.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: output-github-comment stdout default (issue #238)"

setup_test_env "plugin-output-stdout"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# PATH-shadow: gh mock writes a sentinel file if called (proves gh was invoked)
mkdir -p "$TEST_TEMP_DIR/bin"
export PATH="$TEST_TEMP_DIR/bin:$PATH"
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
touch "$TEST_TEMP_DIR/gh_was_called"
exit 1
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

# shellcheck source=../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

PLUGIN_DIR="$REPO_ROOT/plugins/tool/output-github-comment"

# ─── Shared fixtures ──────────────────────────────────────────────────────────
STATE_DIR="$TEST_TEMP_DIR/state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"
echo '{"schema_version":1,"run_id":"test-run-238","issue":"0","stage_statuses":{}}' > "$STATE_FILE"
export ZBUILD_RUN_ID="test-run-238"

# Both destination vars unset for every test in this file
unset ZBUILD_ISSUE  2>/dev/null || true
unset ZBUILD_OUTPUT 2>/dev/null || true
# CI sets GITHUB_STEP_SUMMARY which would activate the step-summary destination
# and change the expected dest telemetry — explicitly disable it for this test.
unset GITHUB_STEP_SUMMARY 2>/dev/null || true

# shellcheck source=../plugins/tool/output-github-comment/plugin.sh
source "$PLUGIN_DIR/plugin.sh"
output_init >/dev/null 2>&1

# ─── Test 1: Manifest validates + plugin discoverable ────────────────────────
set +e
validate_manifest "$PLUGIN_DIR/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "output manifest validates" "0" "$rc"

discovered="$(discover_plugins "$REPO_ROOT/plugins")"
assert_contains "output-github-comment discovered in plugin registry" \
    "$discovered" "tool/output-github-comment"

# ─── Test 2: No artifacts, both vars unset → stdout contains "0 finding(s)" ──
rm -rf "$ARTIFACTS_DIR"
mkdir -p "$ARTIFACTS_DIR"

stdout="$(output_run "output" "$STATE_FILE" 2>/dev/null)"
assert_contains "stdout contains 0 finding(s) when no artifacts" \
    "$stdout" "0 finding(s)"

# ─── Test 3: One findings.json, both vars unset → stdout contains title ───────
cat > "$ARTIFACTS_DIR/sec-findings.json" <<'JSON'
{"schema_version":1,"plugin_id":"security-lens","findings":[
  {"title":"SQL Injection","severity":"high","category":"injection","file":"src/db.sh:42","evidence":"x","suggestion":"quote vars"}
],"stub":false}
JSON

stdout="$(output_run "output" "$STATE_FILE" 2>/dev/null)"
assert_contains "stdout contains finding title" "$stdout" "SQL Injection"

# ─── Test 4: Both vars unset → gh NOT called (sentinel file absent) ──────────
rm -f "$TEST_TEMP_DIR/gh_was_called"

set +e
output_run "output" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "stdout path returns rc=0" "0" "$rc"
if [[ -f "$TEST_TEMP_DIR/gh_was_called" ]]; then
    assert_fail "gh must NOT be called when ZBUILD_ISSUE and ZBUILD_OUTPUT are unset"
else
    assert_pass "gh not called when both destination vars unset"
fi

# ─── Test 5: plugin.run.complete event has dest=stdout ───────────────────────
output_run "output" "$STATE_FILE" >/dev/null 2>&1

dest_val=$(grep '"plugin.run.complete"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="plugin.run.complete" and .data.plugin=="output-github-comment") | .data.dest // empty' \
    2>/dev/null | tail -1 || true)
assert_eq "plugin.run.complete event has dest=stdout,local-report" "stdout,local-report" "$dest_val"

# ─── Teardown ────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
