#!/usr/bin/env bash
# Unit tests for scan_plugin_outputs: required:true enforcement (#1803)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

print_test_header "lifecycle scan_plugin_outputs — required:true enforcement (#1803)"
setup_test_env "lifecycle-required-output"

FIXTURE_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$FIXTURE_ROOT" "$STATE_DIR/artifacts"
STATE_FILE="$STATE_DIR/pipeline-state.json"
echo '{}' > "$STATE_FILE"

# ── SPEC-1: required:true with NO artifact_type — absent output → returns 1 ───
# CHANGE: at baseline the scanner short-circuits on missing artifact_type and
# returns 0, silently ignoring the required:true declaration.
mkdir -p "$FIXTURE_ROOT/tool/no-type-required"
cat > "$FIXTURE_ROOT/tool/no-type-required/manifest.yaml" <<'EOF'
id: no-type-required
name: No Artifact Type Required Output
kind: tool
version: 0.0.1
hooks:
  run: ntr_run
outputs:
  - name: result
    path: ${artifact_dir}/result.json
    required: true
EOF
cat > "$FIXTURE_ROOT/tool/no-type-required/plugin.sh" <<'EOF'
ntr_run() { :; }
EOF

set +e
scan_plugin_outputs "$FIXTURE_ROOT/tool/no-type-required" "$STATE_FILE" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-1] required:true output absent with no artifact_type returns 1" "1" "$rc"

# ── SPEC-2: required:true WITH artifact_type — absent output → returns 1 ──────
# GUARD: existing behavior preserved — artifact_type path was already enforced.
mkdir -p "$FIXTURE_ROOT/agent/with-type-required"
cat > "$FIXTURE_ROOT/agent/with-type-required/manifest.yaml" <<'EOF'
id: with-type-required
name: With Artifact Type Required Output
kind: agent
version: 0.0.1
hooks:
  run: wtr_run
requires:
  core:
    - redaction
    - event-bus
provides:
  artifact_type: findings.json
  schema_version: 1
outputs:
  - name: findings
    path: ${artifact_dir}/findings.json
    required: true
EOF
cat > "$FIXTURE_ROOT/agent/with-type-required/plugin.sh" <<'EOF'
wtr_run() { :; }
EOF

set +e
scan_plugin_outputs "$FIXTURE_ROOT/agent/with-type-required" "$STATE_FILE" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-2] required:true output absent WITH artifact_type returns 1" "1" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
