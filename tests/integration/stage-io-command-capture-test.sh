#!/usr/bin/env bash
# Tests: end-to-end command-kind stage-io capture for adopted call sites
# (ADR-015 v2, issue #439). Exercises intake (`gh issue view`) and build
# (`git apply --check`) — the two adoption sites for #439.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "stage-io command-kind capture — intake + build adoption (ADR-015 v2, #439)"
setup_test_env "stage-io-command-int"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="run-stage-io-cmd"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# ─── Load template machinery + mock destinations ─────────────────────────────
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

TPL="$TEST_TEMP_DIR/cmd-io-template.yaml"
cat > "$TPL" <<'EOF'
id: cmd-io-int
name: Command IO Integration
defaults:
  strategy: fanout

stages:
  - id: intake
    gate: auto
    roles: [intake]
    io:
      destinations: [file]
  - id: build
    gate: auto
    roles: [build]
    io:
      destinations: [file]
EOF
load_template "$TPL"

# ─── Mock gh in $TEST_TEMP_DIR/bin so intake's run_captured_command captures it
cat > "$TEST_TEMP_DIR/bin/gh" <<'GHSHIM'
#!/usr/bin/env bash
# Mock: gh issue view <N> --json title,body --jq <filter>
# Produces title+body for jq's default filter to assemble.
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
    # Find --jq filter
    filter=""
    for ((i=1;i<=$#;i++)); do
        if [[ "${!i}" == "--jq" ]]; then
            j=$((i+1))
            filter="${!j}"
        fi
    done
    payload='{"title":"Test Issue Title","body":"Test issue body line."}'
    if [[ -n "$filter" ]]; then
        printf '%s' "$payload" | jq -r "$filter"
    else
        printf '%s' "$payload"
    fi
    exit 0
fi
exit 0
GHSHIM
chmod +x "$TEST_TEMP_DIR/bin/gh"

# ─── Source intake plugin ─────────────────────────────────────────────────────
# shellcheck source=../../plugins/agent/intake/plugin.sh
source "$REPO_ROOT/plugins/agent/intake/plugin.sh"
intake_init >/dev/null 2>&1 || true

STATE_DIR="$TEST_TEMP_DIR/intake-state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
mkdir -p "$STATE_DIR"
echo '{"schema_version":1,"run_id":"test","issue":"439","stage_statuses":{}}' > "$STATE_FILE"

unset ZBUILD_GOAL 2>/dev/null || true
export ZBUILD_ISSUE="439"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
intake_rc=$?
set -e

assert_eq "intake_run with mocked gh returns rc=0" "0" "$intake_rc"
assert_file_exists "intake.md created" "$STATE_DIR/intake.md"
intake_md="$(cat "$STATE_DIR/intake.md")"
assert_contains "intake.md contains mocked title" "$intake_md" "Test Issue Title"
assert_contains "intake.md contains mocked body" "$intake_md" "Test issue body line."

artifact_intake="$ZBUILD_STATE_DIR/artifacts/stage-io/intake-1.json"
assert_file_exists "intake stage-io artifact written" "$artifact_intake"
json_intake="$(cat "$artifact_intake" 2>/dev/null || echo '{}')"
assert_json_key "intake artifact kind == command" "$json_intake" ".kind" "command"
assert_json_key "intake artifact stage == intake" "$json_intake" ".stage" "intake"
intake_input="$(printf '%s' "$json_intake" | jq -r .input)"
assert_contains "intake artifact .input starts with gh issue view" "$intake_input" "gh issue view"

# ─── Build adoption: invoke _build_stage_run_inner with a broken patch ───────
# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"
build_stage_init >/dev/null 2>&1 || true

BUILD_ART="$TEST_TEMP_DIR/build-artifacts"
mkdir -p "$BUILD_ART"
SCOPE_MANIFEST="$BUILD_ART/scope-manifest.md"
cat > "$SCOPE_MANIFEST" <<'EOF'
+ core/
+ plugins/
+ tests/
EOF
PLAN_JSON="$BUILD_ART/plan.json"
cat > "$PLAN_JSON" <<'EOF'
{"schema_version":1,"summary":"test","approach":"test","files_to_modify":[],"tests_to_add":[],"risks":[]}
EOF

# Deliberately broken patch — passes the `diff --git` filter so build invokes
# git apply --check, but the diff body is invalid so the check fails (rc != 0).
BROKEN_PATCH='diff --git a/nonexistent.txt b/nonexistent.txt
index 0000000..0000000 100644
--- a/nonexistent.txt
+++ b/nonexistent.txt
@@ -1,1 +1,1 @@
-this content does not exist in the file
+broken patch should fail apply check'

# Route ZBUILD_REPO_ROOT to TEST_TEMP_DIR so git -C works (a non-git dir will
# still produce a non-zero rc from git apply --check, which is what we test).
mkdir -p "$TEST_TEMP_DIR/fakerepo"
( cd "$TEST_TEMP_DIR/fakerepo" && git init -q . >/dev/null 2>&1 ) || true
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/fakerepo"

# Stub route_to_model so build doesn't actually call the router; return broken diff.
route_to_model() { printf '%s' "$BROKEN_PATCH"; return 0; }

OUT_DIFF="$BUILD_ART/diff.patch"
OUT_SUMMARY="$BUILD_ART/build-summary.json"

set +e
_build_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$OUT_DIFF" "$OUT_SUMMARY" >/dev/null 2>&1
build_rc=$?
set -e

# Look for any build-N.json artifact (the validation call should have written one).
build_artifact=""
for f in "$ZBUILD_STATE_DIR/artifacts/stage-io"/build-*.json; do
    [[ -f "$f" ]] && build_artifact="$f" && break
done

if [[ -n "$build_artifact" ]]; then
    assert_pass "build stage-io artifact written (path=$build_artifact)"
else
    assert_fail "build stage-io artifact written" "no build-*.json under $ZBUILD_STATE_DIR/artifacts/stage-io"
fi

if [[ -n "$build_artifact" ]]; then
    json_build="$(cat "$build_artifact" 2>/dev/null || echo '{}')"
    assert_json_key "build artifact kind == command" "$json_build" ".kind" "command"
    build_input="$(printf '%s' "$json_build" | jq -r .input)"
    assert_contains "build artifact .input starts with git -C" "$build_input" "git -C"
    build_rc_field="$(printf '%s' "$json_build" | jq -r .exit_code)"
    if [[ "$build_rc_field" != "0" && -n "$build_rc_field" && "$build_rc_field" != "null" ]]; then
        assert_pass "build artifact .exit_code != 0 (got $build_rc_field — apply check failed as expected)"
    else
        assert_fail "build artifact .exit_code != 0" "got: $build_rc_field"
    fi
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
