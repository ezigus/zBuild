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

# ── SPEC-2: required:true output exists but is zero-bytes → returns 1 ──────────
# CHANGE: at baseline the scanner uses -e (existence only), which passes for a
# zero-byte file. The fix changes to -s so zero-byte files are rejected even
# when the file was created (empty) on disk.
mkdir -p "$FIXTURE_ROOT/agent/zero-byte-required"
cat > "$FIXTURE_ROOT/agent/zero-byte-required/manifest.yaml" <<'EOF'
id: zero-byte-required
name: Zero Byte Required Output
kind: agent
version: 0.0.1
hooks:
  run: zbr_run
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
cat > "$FIXTURE_ROOT/agent/zero-byte-required/plugin.sh" <<'EOF'
zbr_run() { :; }
EOF

# Pre-create the artifact as a zero-byte file — the scanner must still reject it.
: > "$STATE_DIR/artifacts/findings.json"
set +e
scan_plugin_outputs "$FIXTURE_ROOT/agent/zero-byte-required" "$STATE_FILE" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-2] required:true output exists but is zero-bytes returns 1" "1" "$rc"

# ── empty_diff_legitimate exemption: scope and limits ─────────────────────────
# ADR-047 §4 lets a plugin declare that an empty artifact is legitimate (build's
# diff.patch when a turn changed no code). SPEC-3/4/5 pin how far that reaches.
_write_exempt_plugin() {   # $1=dir  $2=id  $3=primary value for the output
    mkdir -p "$FIXTURE_ROOT/agent/$1"
    cat > "$FIXTURE_ROOT/agent/$1/manifest.yaml" <<EOF
id: $2
name: Exempt $2
kind: agent
version: 0.0.1
hooks:
  run: ${2//-/_}_run
outputs:
  - name: out
    path: \${artifact_dir}/$2.json
    required: true
    primary: $3
capabilities:
  empty_diff_legitimate: true
EOF
    echo "${2//-/_}_run() { :; }" > "$FIXTURE_ROOT/agent/$1/plugin.sh"
}

# SPEC-3: the flag exempts a NON-primary zero-byte output — build's empty diff.patch
# must keep passing, otherwise the fix breaks every no-code-change build turn.
_write_exempt_plugin exempt-nonprimary exempt-nonprimary false
: > "$STATE_DIR/artifacts/exempt-nonprimary.json"
set +e
scan_plugin_outputs "$FIXTURE_ROOT/agent/exempt-nonprimary" "$STATE_FILE" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-3] empty_diff_legitimate exempts a zero-byte NON-primary output (rc 0)" "0" "$rc"

# SPEC-4: the flag must NOT exempt a primary output — a plugin cannot mask an
# empty verdict artifact by declaring the capability in its own manifest.
_write_exempt_plugin exempt-primary exempt-primary true
: > "$STATE_DIR/artifacts/exempt-primary.json"
set +e
scan_plugin_outputs "$FIXTURE_ROOT/agent/exempt-primary" "$STATE_FILE" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-4] empty_diff_legitimate does NOT exempt a zero-byte PRIMARY output (rc 1)" "1" "$rc"

# SPEC-5: the flag downgrades emptiness only — an absent output still fails.
_write_exempt_plugin exempt-absent exempt-absent false
rm -f "$STATE_DIR/artifacts/exempt-absent.json"
set +e
scan_plugin_outputs "$FIXTURE_ROOT/agent/exempt-absent" "$STATE_FILE" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-5] empty_diff_legitimate still fails an ABSENT output (rc 1)" "1" "$rc"

# ── SPEC-6/7: the real build manifest, not a fixture ──────────────────────────
# Production check: build declares empty_diff_legitimate and two required
# outputs — diff.patch (non-primary, legitimately empty) and build-summary.json
# (primary). The empty diff must pass; an empty summary must not.
BUILD_PLUGIN="$REPO_ROOT/plugins/agent/build"
if [[ -f "$BUILD_PLUGIN/manifest.yaml" ]]; then
    : > "$STATE_DIR/artifacts/diff.patch"
    echo '{"verdict":"pass"}' > "$STATE_DIR/artifacts/build-summary.json"
    set +e
    scan_plugin_outputs "$BUILD_PLUGIN" "$STATE_FILE" 2>/dev/null
    rc=$?
    set -e
    assert_eq "[SPEC-6] real build plugin: empty diff.patch + written summary passes" "0" "$rc"

    : > "$STATE_DIR/artifacts/build-summary.json"
    set +e
    scan_plugin_outputs "$BUILD_PLUGIN" "$STATE_FILE" 2>/dev/null
    rc=$?
    set -e
    assert_eq "[SPEC-7] real build plugin: zero-byte primary build-summary.json fails" "1" "$rc"

    # [SPEC-11] (#1832, ADR-054 §6): lifecycle enforcement accepts verdict=fail (the new
    # encoding for inert_build). scan_plugin_outputs checks artifact presence, not verdict
    # vocabulary — the manifest's valid_verdicts update (inert_build→fail) is invisible here,
    # so this is a guard: primary artifact present with any non-empty verdict JSON passes.
    printf '{"result_contract":2,"verdict":"fail","disposition":"broken","data":{"build_kind":"inert_build"}}' \
        > "$STATE_DIR/artifacts/build-summary.json"
    set +e
    scan_plugin_outputs "$BUILD_PLUGIN" "$STATE_FILE" 2>/dev/null
    rc=$?
    set -e
    assert_eq "[SPEC-11] real build plugin: verdict=fail (inert_build encoding) accepted as valid primary output" "0" "$rc"
else
    assert_fail "[SPEC-6/7/11] real build plugin manifest present" "not found at $BUILD_PLUGIN"
fi

# ── SPEC-10: a non-canonical `primary: True` must still count as primary ──────
# The exemption check compares strings; if `True` read as non-primary, a plugin
# holding the capability flag would silently regain the zero-byte pass it is
# supposed to be denied. Fails OPEN if unhandled, hence a guard.
_write_exempt_plugin exempt-primary-caps exempt-primary-caps True
: > "$STATE_DIR/artifacts/exempt-primary-caps.json"
set +e
scan_plugin_outputs "$FIXTURE_ROOT/agent/exempt-primary-caps" "$STATE_FILE" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-10] 'primary: True' still counts as primary (zero-byte rejected)" "1" "$rc"

# ── SPEC-8/9: per-member output paths (${ZBUILD_REVIEW_LENS_ID}) ──────────────
# review-lens declares `lens-${ZBUILD_REVIEW_LENS_ID}.json` required:true and has
# no provides.artifact_type — it was exempt from the scanner before #1803. Once
# required:true is enforced, the element var MUST expand or the stage fails on
# every run (the work unit exports it per ADR-047 §2).
LENS_PLUGIN="$REPO_ROOT/plugins/agent/review-lens"
if [[ -f "$LENS_PLUGIN/manifest.yaml" ]]; then
    export ZBUILD_REVIEW_LENS_ID="security"
    echo '{"lens":"security"}' > "$STATE_DIR/artifacts/lens-security.json"
    set +e
    scan_plugin_outputs "$LENS_PLUGIN" "$STATE_FILE" 2>/dev/null
    rc=$?
    set -e
    assert_eq "[SPEC-8] real review-lens: \${ZBUILD_REVIEW_LENS_ID} expands and passes" "0" "$rc"

    # Same plugin, the element's artifact absent → still fails (enforcement real).
    rm -f "$STATE_DIR/artifacts/lens-security.json"
    set +e
    scan_plugin_outputs "$LENS_PLUGIN" "$STATE_FILE" 2>/dev/null
    rc=$?
    set -e
    assert_eq "[SPEC-9] real review-lens: absent per-lens artifact still fails" "1" "$rc"
    unset ZBUILD_REVIEW_LENS_ID
else
    assert_fail "[SPEC-8/9] real review-lens manifest present" "not found at $LENS_PLUGIN"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
