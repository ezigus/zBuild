#!/usr/bin/env bash
# tests/unit/manifest-validation-doc-fields-test.sh
# Unit tests for optional summary/usage doc fields in validate_manifest (issue #1414).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/manifest-validation.sh
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh"

print_test_header "manifest-validation — optional summary/usage doc fields (issue #1414)"

setup_test_env "manifest-doc-fields"
FIXTURE_DIR="$TEST_TEMP_DIR/fixtures"
mkdir -p "$FIXTURE_DIR"

# ─── Fixture helpers ─────────────────────────────────────────────────────────
# Base required fields for a valid tool manifest (no agent redaction needed).
_base_tool_manifest() {
    local file="$1"
    cat > "$file" <<'EOF'
id: doc-test-tool
name: Doc Test Tool
kind: tool
version: 0.0.1
hooks:
  run: doc_tool_run
EOF
}

# ─── SPEC-1: manifest with both summary and usage (non-empty) passes ─────────
MANIFEST="$FIXTURE_DIR/both-fields.yaml"
_base_tool_manifest "$MANIFEST"
cat >> "$MANIFEST" <<'EOF'
summary: One-line synopsis for tooling
usage: |
  Run this tool with a stage_id and state_file.
EOF

set +e
validate_manifest "$MANIFEST" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-1] manifest with non-empty summary and usage passes validation" "0" "$rc"

# ─── SPEC-2: manifest without summary or usage passes ────────────────────────
MANIFEST="$FIXTURE_DIR/no-doc-fields.yaml"
_base_tool_manifest "$MANIFEST"

set +e
validate_manifest "$MANIFEST" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-2] manifest without summary or usage passes validation" "0" "$rc"

# ─── SPEC-3: manifest with declared but empty summary fails ──────────────────
MANIFEST="$FIXTURE_DIR/empty-summary.yaml"
_base_tool_manifest "$MANIFEST"
printf 'summary:\n' >> "$MANIFEST"

set +e
validate_manifest "$MANIFEST" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-3] manifest with empty-string summary fails validation" "1" "$rc"

# Also verify the error message mentions summary.
set +e
err_out="$(validate_manifest "$MANIFEST" 2>&1)"
set -e
assert_contains "[SPEC-3] error message names the offending field 'summary'" "$err_out" "summary"

# ─── SPEC-4: manifest with declared but empty usage fails ────────────────────
MANIFEST="$FIXTURE_DIR/empty-usage.yaml"
_base_tool_manifest "$MANIFEST"
printf 'usage:\n' >> "$MANIFEST"

set +e
validate_manifest "$MANIFEST" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-4] manifest with empty-string usage fails validation" "1" "$rc"

set +e
err_out="$(validate_manifest "$MANIFEST" 2>&1)"
set -e
assert_contains "[SPEC-4] error message names the offending field 'usage'" "$err_out" "usage"

# ─── SPEC-5: manifest with summary only (no usage) passes ────────────────────
MANIFEST="$FIXTURE_DIR/summary-only.yaml"
_base_tool_manifest "$MANIFEST"
printf 'summary: Short synopsis only\n' >> "$MANIFEST"

set +e
validate_manifest "$MANIFEST" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-5] manifest with non-empty summary and no usage passes validation" "0" "$rc"

# ─── SPEC-6: manifest with usage only (no summary) passes ────────────────────
MANIFEST="$FIXTURE_DIR/usage-only.yaml"
_base_tool_manifest "$MANIFEST"
cat >> "$MANIFEST" <<'EOF'
usage: |
  Invoke with stage_id and state_file arguments.
EOF

set +e
validate_manifest "$MANIFEST" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-6] manifest with non-empty usage and no summary passes validation" "0" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
