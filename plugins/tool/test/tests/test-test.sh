#!/usr/bin/env bash
# Tests: plugins/tool/test — test-stage plugin (issue #342)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: test-stage (tool/test — issue #342)"

setup_test_env "plugin-test-stage"

# Wire up isolated event bus
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

PLUGIN_DIR="$REPO_ROOT/plugins/tool/test"

# ─── Fake state + artifact dirs ──────────────────────────────────────────────
STATE_DIR="$TEST_TEMP_DIR/state"
ARTIFACT_DIR="$TEST_TEMP_DIR/state/artifacts"
mkdir -p "$STATE_DIR" "$ARTIFACT_DIR"

export ZBUILD_ARTIFACT_DIR="$ARTIFACT_DIR"
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo"

# ─── Minimal git repo fixture ────────────────────────────────────────────────
# The plugin copies the repo dir and calls `git apply` inside the copy.
# We need a real (or fake) git repo for `git apply` to work.
mkdir -p "$TEST_TEMP_DIR/repo"
git -C "$TEST_TEMP_DIR/repo" init -q
git -C "$TEST_TEMP_DIR/repo" -c user.name="zbuild-test" -c user.email="test@zbuild" \
    commit --allow-empty -m "init" -q

# ─── Source plugin ────────────────────────────────────────────────────────────
# shellcheck source=../../../../plugins/tool/test/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# ─── Helper: read a key from a JSON file ─────────────────────────────────────
_json_key() {
    local file="$1"
    local key="$2"
    jq -r "$key" "$file" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test 1: test_init sets ZBUILD_PLUGIN env
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "1. test_init sets env"

unset ZBUILD_PLUGIN ZBUILD_PLUGIN_KIND 2>/dev/null || true

test_init >/dev/null 2>&1

assert_eq "ZBUILD_PLUGIN set to 'test'" "test" "${ZBUILD_PLUGIN:-}"
assert_eq "ZBUILD_PLUGIN_KIND set to 'tool'" "tool" "${ZBUILD_PLUGIN_KIND:-}"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 2: missing diff.patch → error artifact, plugin exits 0
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "2. missing diff.patch → error artifact"

NONEXISTENT_PATCH="$ARTIFACT_DIR/nonexistent.patch"
OUT_JSON_2="$ARTIFACT_DIR/test-results-2.json"

set +e
_test_run_inner "$NONEXISTENT_PATCH" "$TEST_TEMP_DIR/repo" "$OUT_JSON_2" "true"
rc2=$?
set -e

assert_exit_code "plugin exits 0 even when diff.patch missing" "0" "$rc2"
assert_file_exists "test-results.json written on missing patch" "$OUT_JSON_2"

verdict2="$(_json_key "$OUT_JSON_2" '.verdict')"
diff_applied2="$(_json_key "$OUT_JSON_2" '.diff_applied')"

assert_eq "verdict is 'error' for missing patch" "error" "$verdict2"
assert_eq "diff_applied is false for missing patch" "false" "$diff_applied2"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 3: good diff.patch + passing mock test_cmd → verdict=pass
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "3. good diff.patch + passing test_cmd → pass"

OUT_JSON_3="$ARTIFACT_DIR/test-results-3.json"

# Override git in PATH so `git apply --check` and `git apply` both succeed
# without needing a real diff.  The mock also handles the repo copy step.
cat > "$TEST_TEMP_DIR/bin/git" <<'GITEOF'
#!/usr/bin/env bash
# Mock git: `git apply` and `git -C <dir> apply` always succeed.
# Strip leading `-C <dir>` so the subcommand check works regardless of form.
args=("$@")
# If called as: git -C <dir> <subcmd> [...], skip past -C and the dir arg
if [[ "${args[0]:-}" == "-C" ]]; then
    args=("${args[@]:2}")
fi
case "${args[0]:-}" in
    apply)
        # --check or real apply: succeed silently
        exit 0
        ;;
    *)
        # Delegate to real git for everything else (init, commit, rev-parse…)
        exec "$(PATH=/usr/bin:/usr/local/bin:/opt/homebrew/bin:$PATH command -v git)" "$@"
        ;;
esac
GITEOF
chmod +x "$TEST_TEMP_DIR/bin/git"

# Write a plausible (empty content) diff file so the existence check passes
GOOD_PATCH="$ARTIFACT_DIR/good.patch"
printf '' > "$GOOD_PATCH"

set +e
_test_run_inner "$GOOD_PATCH" "$TEST_TEMP_DIR/repo" "$OUT_JSON_3" "true"
rc3=$?
set -e

assert_exit_code "plugin exits 0 on passing test" "0" "$rc3"
assert_file_exists "test-results.json written for passing test" "$OUT_JSON_3"

verdict3="$(_json_key "$OUT_JSON_3" '.verdict')"
exit_code3="$(_json_key "$OUT_JSON_3" '.exit_code')"
diff_applied3="$(_json_key "$OUT_JSON_3" '.diff_applied')"

assert_eq "verdict is 'pass'" "pass" "$verdict3"
assert_eq "exit_code is 0" "0" "$exit_code3"
assert_eq "diff_applied is true" "true" "$diff_applied3"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 4: failing test_cmd → verdict=fail, plugin still exits 0
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "4. failing test_cmd → verdict=fail, plugin exits 0"

OUT_JSON_4="$ARTIFACT_DIR/test-results-4.json"

# Reuse the same mock git + good patch from test 3
set +e
_test_run_inner "$GOOD_PATCH" "$TEST_TEMP_DIR/repo" "$OUT_JSON_4" "exit 1"
rc4=$?
set -e

assert_exit_code "plugin exits 0 even when tests fail" "0" "$rc4"
assert_file_exists "test-results.json written for failing test" "$OUT_JSON_4"

verdict4="$(_json_key "$OUT_JSON_4" '.verdict')"
exit_code4="$(_json_key "$OUT_JSON_4" '.exit_code')"

assert_eq "verdict is 'fail' when test_cmd exits 1" "fail" "$verdict4"
assert_eq "exit_code is 1 in artifact" "1" "$exit_code4"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 5: test_finalize runs cleanly
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "5. test_finalize runs cleanly"

set +e
test_finalize >/dev/null 2>&1
rc5=$?
set -e

assert_exit_code "test_finalize exits 0" "0" "$rc5"

# Verify the finalize event was emitted
finalize_count="$(grep -c '"plugin.finalize.complete"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_gt "plugin.finalize.complete event emitted" "$finalize_count" "0"

# ─── Teardown ────────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }

print_test_results
exit $((FAIL > 0))
