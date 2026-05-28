#!/usr/bin/env bash
# Tests: core/pipeline/contracts.sh — artifact contract checker
# Regression: quoted outputs[].path values must resolve correctly (#415)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/contracts.sh — _check_artifact_contract (#415)"

setup_test_env "pipeline-contracts"

# Wire event-bus to a local jsonl so we can assert on emitted events
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../core/pipeline/contracts.sh
source "$REPO_ROOT/core/pipeline/contracts.sh"

_make_manifest() {
    local dir="$1" id="$2" path_value="$3"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Test $id
kind: agent
version: 0.0.1
hooks:
  run: ${id}_run
requires:
  core: [redaction]
provides:
  artifact_type: ${id}.json
outputs:
  - name: ${id}_output
    path: $path_value
    type: ${id}.json
EOF
}

_count_violations() {
    local n
    n="$(grep -c '"plugin.contract.violated"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
    echo "${n:-0}"
}

# ─── Test 1: quoted path resolves correctly when artifact exists ─────────────
STATE_DIR="$TEST_TEMP_DIR/state-quoted"
mkdir -p "$STATE_DIR/artifacts"
PLUGIN_DIR="$TEST_TEMP_DIR/plugin-quoted"
_make_manifest "$PLUGIN_DIR" "qbuild" '"${artifact_dir}/qbuild.json"'
echo '{"ok":true}' > "$STATE_DIR/artifacts/qbuild.json"

: > "$ZBUILD_EVENTS_JSONL"
_check_artifact_contract "$PLUGIN_DIR" "$STATE_DIR" "qbuild"
v_after="$(_count_violations)"
assert_eq "quoted path resolves → no contract.violated emitted" "0" "$v_after"

# ─── Test 2: unquoted path resolves correctly when artifact exists ───────────
STATE_DIR2="$TEST_TEMP_DIR/state-unquoted"
mkdir -p "$STATE_DIR2/artifacts"
PLUGIN_DIR2="$TEST_TEMP_DIR/plugin-unquoted"
_make_manifest "$PLUGIN_DIR2" "ubuild" '${artifact_dir}/ubuild.json'
echo '{"ok":true}' > "$STATE_DIR2/artifacts/ubuild.json"

: > "$ZBUILD_EVENTS_JSONL"
_check_artifact_contract "$PLUGIN_DIR2" "$STATE_DIR2" "ubuild"
v_after2="$(_count_violations)"
assert_eq "unquoted path resolves → no contract.violated emitted" "0" "$v_after2"

# ─── Test 3: ${state_dir} substitution + quotes resolves ─────────────────────
STATE_DIR3="$TEST_TEMP_DIR/state-statedir"
mkdir -p "$STATE_DIR3"
PLUGIN_DIR3="$TEST_TEMP_DIR/plugin-statedir"
_make_manifest "$PLUGIN_DIR3" "sintake" '"${state_dir}/scope-manifest.md"'
echo "scope" > "$STATE_DIR3/scope-manifest.md"

: > "$ZBUILD_EVENTS_JSONL"
_check_artifact_contract "$PLUGIN_DIR3" "$STATE_DIR3" "sintake"
v_after3="$(_count_violations)"
assert_eq "quoted \${state_dir} path resolves → no contract.violated" "0" "$v_after3"

# ─── Test 4: missing artifact still emits violation (negative case) ──────────
STATE_DIR4="$TEST_TEMP_DIR/state-missing"
mkdir -p "$STATE_DIR4/artifacts"
PLUGIN_DIR4="$TEST_TEMP_DIR/plugin-missing"
_make_manifest "$PLUGIN_DIR4" "mbuild" '"${artifact_dir}/mbuild.json"'
# Intentionally do NOT create the artifact

: > "$ZBUILD_EVENTS_JSONL"
_check_artifact_contract "$PLUGIN_DIR4" "$STATE_DIR4" "mbuild"
v_after4="$(_count_violations)"
assert_eq "missing artifact still emits contract.violated" "1" "$v_after4"

# ─── Test 5: no provides.artifact_type → silent success (no event) ───────────
STATE_DIR5="$TEST_TEMP_DIR/state-no-contract"
mkdir -p "$STATE_DIR5/artifacts"
PLUGIN_DIR5="$TEST_TEMP_DIR/plugin-no-contract"
mkdir -p "$PLUGIN_DIR5"
cat > "$PLUGIN_DIR5/manifest.yaml" <<'EOF'
id: noctrct
name: No Contract
kind: agent
version: 0.0.1
hooks:
  run: noctrct_run
requires:
  core: [redaction]
EOF

: > "$ZBUILD_EVENTS_JSONL"
_check_artifact_contract "$PLUGIN_DIR5" "$STATE_DIR5" "noctrct"
v_after5="$(_count_violations)"
assert_eq "no provides.artifact_type → no event" "0" "$v_after5"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
