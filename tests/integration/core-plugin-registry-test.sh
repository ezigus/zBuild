#!/usr/bin/env bash
# Tests: core/plugin-registry/registry.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

print_test_header "core/plugin-registry — discovery + lifecycle (ADR-001)"

setup_test_env "core-registry"
FIXTURE_ROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$FIXTURE_ROOT/agent/test-lens" "$FIXTURE_ROOT/tool/test-tool" "$FIXTURE_ROOT/agent/bad-no-redaction"

# ─── Fixture 1: valid agent plugin ──────────────────────────────────────────
cat > "$FIXTURE_ROOT/agent/test-lens/manifest.yaml" <<'EOF'
id: test-lens
name: Test Lens
kind: agent
version: 0.0.1
description: |
  Fixture for registry tests.
hooks:
  run: test_lens_run
requires:
  core:
    - redaction
    - event-bus
EOF

cat > "$FIXTURE_ROOT/agent/test-lens/plugin.sh" <<'EOF'
test_lens_run() { echo "run called: $*"; }
EOF

# ─── Fixture 2: valid tool plugin ───────────────────────────────────────────
cat > "$FIXTURE_ROOT/tool/test-tool/manifest.yaml" <<'EOF'
id: test-tool
name: Test Tool
kind: tool
version: 0.0.1
hooks:
  run: test_tool_run
EOF
cat > "$FIXTURE_ROOT/tool/test-tool/plugin.sh" <<'EOF'
test_tool_run() { echo "tool ran"; }
EOF

# ─── Fixture 3: invalid agent (no redaction required) ──────────────────────
cat > "$FIXTURE_ROOT/agent/bad-no-redaction/manifest.yaml" <<'EOF'
id: bad-no-redaction
name: Bad Agent (no redaction in requires)
kind: agent
version: 0.0.1
hooks:
  run: bad_run
requires:
  core:
    - event-bus
EOF
cat > "$FIXTURE_ROOT/agent/bad-no-redaction/plugin.sh" <<'EOF'
bad_run() { echo "should not be loaded"; }
EOF

# ─── Tests ──────────────────────────────────────────────────────────────────

# Valid manifest passes
set +e
validate_manifest "$FIXTURE_ROOT/agent/test-lens/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "validate_manifest accepts valid agent manifest" "0" "$rc"

# Tool manifest also valid (no redaction requirement for tool)
set +e
validate_manifest "$FIXTURE_ROOT/tool/test-tool/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "validate_manifest accepts valid tool manifest" "0" "$rc"

# Bad agent manifest (no redaction in requires) is rejected
set +e
validate_manifest "$FIXTURE_ROOT/agent/bad-no-redaction/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "validate_manifest rejects agent without redaction in requires.core (ADR-004 enforcement)" "1" "$rc"

# Discovery returns the two valid plugins, skips the invalid one
discovered="$(discover_plugins "$FIXTURE_ROOT" | sort)"
expected_count=2
actual_count=$(echo "$discovered" | grep -c .)
assert_eq "discover_plugins returns only valid manifests" "$expected_count" "$actual_count"

assert_contains "discovery includes test-lens" "$discovered" "agent/test-lens"
assert_contains "discovery includes test-tool" "$discovered" "tool/test-tool"
if grep -q "bad-no-redaction" <<< "$discovered"; then
    assert_fail "discovery should have skipped bad-no-redaction"
else
    assert_pass "discovery skipped bad-no-redaction"
fi

# Lockfile write + validate
ZBUILD_LOCKFILE="$TEST_TEMP_DIR/plugins.lock"
lockfile_write "$FIXTURE_ROOT" "$ZBUILD_LOCKFILE"
assert_file_exists "lockfile created" "$ZBUILD_LOCKFILE"

# Lockfile validates clean immediately after write
set +e
lockfile_validate "$ZBUILD_LOCKFILE"
rc=$?
set -e
assert_eq "lockfile validates clean after write" "0" "$rc"

# Mutate a manifest and check validation fails
echo "# extra comment" >> "$FIXTURE_ROOT/agent/test-lens/manifest.yaml"
set +e
lockfile_validate "$ZBUILD_LOCKFILE" 2>/dev/null
rc=$?
set -e
assert_eq "lockfile_validate detects manifest mutation" "1" "$rc"

# ─── Plugin.sh tamper detection (#290) ──────────────────────────────────────
# Re-lock with manifest restored; tamper plugin.sh only.
sed -i.bak '/^# extra comment$/d' "$FIXTURE_ROOT/agent/test-lens/manifest.yaml" 2>/dev/null \
    || sed -i '' '/^# extra comment$/d' "$FIXTURE_ROOT/agent/test-lens/manifest.yaml"
rm -f "$FIXTURE_ROOT/agent/test-lens/manifest.yaml.bak"
lockfile_write "$FIXTURE_ROOT" "$ZBUILD_LOCKFILE"
set +e
lockfile_validate "$ZBUILD_LOCKFILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "lockfile clean after re-lock" "0" "$rc"

# Append malicious-looking code to plugin.sh (manifest untouched).
echo 'test_lens_run() { echo "TAMPERED-RUN: $*"; }' >> "$FIXTURE_ROOT/agent/test-lens/plugin.sh"
set +e
lockfile_validate "$ZBUILD_LOCKFILE" 2>/dev/null
rc=$?
set -e
assert_eq "lockfile_validate detects plugin.sh tamper (manifest untouched) (#290)" "1" "$rc"

# Under ZBUILD_STRICT_PLUGIN_LOCK=1, plugin_hook_call refuses to source.
set +e
output="$(ZBUILD_STRICT_PLUGIN_LOCK=1 plugin_hook_call "$FIXTURE_ROOT/agent/test-lens" "run" "arg1" 2>&1)"
rc=$?
set -e
assert_eq "strict mode refuses tampered plugin.sh (rc != 0)" "1" "$rc"
if grep -q "TAMPERED-RUN" <<< "$output"; then
    assert_fail "strict mode must NOT execute tampered code" "got: $output"
else
    assert_pass "strict mode blocks tampered code execution"
fi

# Default (non-strict): warn but still source — keeps current behavior for
# users who haven't opted in.
set +e
output="$(plugin_hook_call "$FIXTURE_ROOT/agent/test-lens" "run" "arg1" 2>&1)"
rc=$?
set -e
# rc=0: hook still ran. A regression that started refusing in non-strict
# would surface here, not get hidden behind the warning-text check.
assert_eq "non-strict mode still returns rc=0 (hook ran)" "0" "$rc"
if grep -q "tamper\|hash mismatch" <<< "$output"; then
    assert_pass "non-strict mode emits tamper warning"
else
    assert_fail "non-strict mode emits tamper warning" "got: $output"
fi
# And the tampered code actually executed (TAMPERED-RUN output present).
if grep -q "TAMPERED-RUN" <<< "$output"; then
    assert_pass "non-strict mode sourced the tampered file (warn-only path)"
else
    assert_fail "non-strict mode sourced the tampered file" "got: $output"
fi

# Restore plugin.sh so the later dispatch tests see a clean file.
cat > "$FIXTURE_ROOT/agent/test-lens/plugin.sh" <<'EOF'
test_lens_run() { echo "run called: $*"; }
EOF
lockfile_write "$FIXTURE_ROOT" "$ZBUILD_LOCKFILE"

# Legacy single-hash lockfile entry is detected and flagged.
# Manually craft a legacy-format record (no colon).
LEGACY_LOCKFILE="$TEST_TEMP_DIR/plugins-legacy.lock"
legacy_hash="$(shasum -a 256 "$FIXTURE_ROOT/agent/test-lens/manifest.yaml" | cut -d' ' -f1)"
echo "test-lens $legacy_hash $FIXTURE_ROOT/agent/test-lens/manifest.yaml" > "$LEGACY_LOCKFILE"
set +e
lockfile_validate "$LEGACY_LOCKFILE" 2>/dev/null
rc=$?
set -e
assert_eq "lockfile_validate flags legacy single-hash records (#290 migration)" "1" "$rc"

# Hook dispatch: an undeclared required hook is refused, not silently no-op'd
# (ADR-056: init/finalize are gone, so "init" is now just an undeclared hook).
set +e
plugin_hook_call "$FIXTURE_ROOT/agent/test-lens" "init" >/dev/null 2>&1
rc=$?
set -e
assert_eq "plugin_hook_call refuses an undeclared required hook" "1" "$rc"

# Hook dispatch: pass args to run
output="$(plugin_hook_call "$FIXTURE_ROOT/agent/test-lens" "run" "arg1" "arg2" 2>&1)"
assert_contains "plugin_hook_call dispatches run hook with args" "$output" "run called: arg1 arg2"

# Disabled plugin: create disabled file
ZBUILD_DISABLED_FILE="$TEST_TEMP_DIR/plugins.disabled"
echo "test-tool" > "$ZBUILD_DISABLED_FILE"
discovered="$(ZBUILD_DISABLED_FILE="$ZBUILD_DISABLED_FILE" discover_plugins "$FIXTURE_ROOT" | sort)"
if grep -q "test-tool" <<< "$discovered"; then
    assert_fail "disabled plugin should not be discovered"
else
    assert_pass "disabled plugin (test-tool) excluded from discovery"
fi

# ─── #287/#294: hook-per-kind validation ─────────────────────────────────────
# Agent plugin without a `run` hook should fail validation.
mkdir -p "$FIXTURE_ROOT/agent/no-run-hook"
cat > "$FIXTURE_ROOT/agent/no-run-hook/manifest.yaml" <<'EOF'
id: no-run-hook
name: Agent Missing Run Hook
kind: agent
version: 0.0.1
hooks:
  cleanup: nr_cleanup
requires:
  core:
    - redaction
EOF
cat > "$FIXTURE_ROOT/agent/no-run-hook/plugin.sh" <<'EOF'
nr_cleanup() { :; }
EOF
set +e
validate_manifest "$FIXTURE_ROOT/agent/no-run-hook/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "validate_manifest rejects agent without 'run' hook (#287)" "1" "$rc"

# Tool plugin without `run` hook → rejected.
mkdir -p "$FIXTURE_ROOT/tool/no-run-tool"
cat > "$FIXTURE_ROOT/tool/no-run-tool/manifest.yaml" <<'EOF'
id: no-run-tool
name: Tool Missing Run
kind: tool
version: 0.0.1
hooks:
  cleanup: t_cleanup
EOF
set +e
validate_manifest "$FIXTURE_ROOT/tool/no-run-tool/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "validate_manifest rejects tool without 'run' hook (#287)" "1" "$rc"

# Claim-coordinator missing required hooks → rejected.
mkdir -p "$FIXTURE_ROOT/claim-coordinator/incomplete"
cat > "$FIXTURE_ROOT/claim-coordinator/incomplete/manifest.yaml" <<'EOF'
id: claim-incomplete
name: Incomplete Claim Coordinator
kind: claim-coordinator
version: 0.0.1
hooks:
  claim: c_claim
EOF
set +e
validate_manifest "$FIXTURE_ROOT/claim-coordinator/incomplete/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "validate_manifest rejects claim-coordinator missing release/heartbeat/list_claims (#287)" "1" "$rc"

# Malformed requires.core (scalar instead of list) → rejected.
# Use kind: orchestrator so the ADR-004 redaction check doesn't fire — this
# isolates the new scalar-shape check (#294) from the redaction requirement.
mkdir -p "$FIXTURE_ROOT/orchestrator/bad-requires-core"
cat > "$FIXTURE_ROOT/orchestrator/bad-requires-core/manifest.yaml" <<'EOF'
id: bad-requires
name: Bad Requires
kind: orchestrator
version: 0.0.1
hooks:
  run: br_run
requires:
  core: redaction
EOF
set +e
validate_manifest "$FIXTURE_ROOT/orchestrator/bad-requires-core/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "validate_manifest rejects scalar requires.core for non-agent kind (#294)" "1" "$rc"

# ─── #294 bypass: '- redaction' outside requires.core should NOT satisfy ─────
# Pre-fix the agent-redaction check used a file-wide grep, so a `- redaction`
# anywhere in the manifest (e.g. inside outputs:) would falsely satisfy it.
# After structural validation the bypass is closed.
mkdir -p "$FIXTURE_ROOT/agent/bypass-attempt"
cat > "$FIXTURE_ROOT/agent/bypass-attempt/manifest.yaml" <<'EOF'
id: bypass-attempt
name: Bypass Attempt (redaction outside requires.core)
kind: agent
version: 0.0.1
hooks:
  run: ba_run
requires:
  core:
    - event-bus
config:
  notes:
    - redaction is mentioned here but not under requires.core
EOF
cat > "$FIXTURE_ROOT/agent/bypass-attempt/plugin.sh" <<'EOF'
ba_run() { :; }
EOF
set +e
validate_manifest "$FIXTURE_ROOT/agent/bypass-attempt/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "validate_manifest rejects agent with 'redaction' outside requires.core (#294 bypass closed)" "1" "$rc"

# ─── #294 bypass: YAML comment '# - redaction' must NOT satisfy requires.core ─
# The awk extractor only emits list items matching ^[[:space:]]+-[[:space:]]+
# so a comment line is silently ignored; this fixture pins that behaviour.
mkdir -p "$FIXTURE_ROOT/agent/comment-bypass"
cat > "$FIXTURE_ROOT/agent/comment-bypass/manifest.yaml" <<'EOF'
id: comment-bypass
name: Comment Bypass (redaction as YAML comment)
kind: agent
version: 0.0.1
hooks:
  run: cb_run
requires:
  core:
    # - redaction
    - event-bus
EOF
cat > "$FIXTURE_ROOT/agent/comment-bypass/plugin.sh" <<'EOF'
cb_run() { :; }
EOF
set +e
validate_manifest "$FIXTURE_ROOT/agent/comment-bypass/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "validate_manifest rejects agent with '# - redaction' YAML comment (#294 comment bypass closed)" "1" "$rc"

# ─── #288: fail-closed artifact scanner ──────────────────────────────────────
mkdir -p "$FIXTURE_ROOT/agent/declares-output"
cat > "$FIXTURE_ROOT/agent/declares-output/manifest.yaml" <<'EOF'
id: declares-output
name: Declares Output
kind: agent
version: 0.0.1
hooks:
  run: do_run
requires:
  core:
    - redaction
provides:
  artifact_type: findings.json
  schema_version: 1
outputs:
  - name: findings
    path: ${artifact_dir}/findings.json
    type: findings.json
EOF
# Two plugin.sh variants: one writes the artifact, one doesn't.
cat > "$FIXTURE_ROOT/agent/declares-output/plugin.sh" <<'EOF'
do_run() {
    local _stage_id="$1" state_file="$2"
    # Intentionally writes NOTHING — exercises the scanner's blocking behavior.
    return 0
}
EOF

# Set up a state_dir + artifact_dir so the scanner can substitute the template.
PLUG_STATE_DIR="$TEST_TEMP_DIR/plugin-state"
mkdir -p "$PLUG_STATE_DIR/artifacts"
PLUG_STATE_FILE="$PLUG_STATE_DIR/pipeline-state.json"
echo '{}' > "$PLUG_STATE_FILE"

# Lockfile from earlier tests is for the FIRST plugins set; regenerate so this
# fixture is recognized (otherwise verify_plugin_for_source would warn).
lockfile_write "$FIXTURE_ROOT" "$ZBUILD_LOCKFILE"

# Direct scanner call: no artifact present → returns 1.
set +e
scan_plugin_outputs "$FIXTURE_ROOT/agent/declares-output" "$PLUG_STATE_FILE" 2>/dev/null
rc=$?
set -e
assert_eq "scan_plugin_outputs returns 1 when declared output missing (#288)" "1" "$rc"

# plugin_hook_call should surface the scanner failure as a non-zero hook exit.
set +e
plugin_hook_call "$FIXTURE_ROOT/agent/declares-output" "run" "stage-id" "$PLUG_STATE_FILE" >/dev/null 2>&1
hook_rc=$?
set -e
assert_eq "plugin_hook_call returns non-zero when scanner finds missing artifact (#288)" "1" "$hook_rc"

# When the artifact IS produced, the scanner is happy + hook returns 0.
cat > "$FIXTURE_ROOT/agent/declares-output/plugin.sh" <<'EOF'
do_run() {
    local _stage_id="$1" state_file="$2"
    local state_dir; state_dir="$(dirname "$state_file")"
    mkdir -p "$state_dir/artifacts"
    echo '{"findings":[]}' > "$state_dir/artifacts/findings.json"
    return 0
}
EOF
lockfile_write "$FIXTURE_ROOT" "$ZBUILD_LOCKFILE"

# Pre-create the artifact so the direct scanner call has something to find.
echo '{"findings":[]}' > "$PLUG_STATE_DIR/artifacts/findings.json"

set +e
scan_plugin_outputs "$FIXTURE_ROOT/agent/declares-output" "$PLUG_STATE_FILE" 2>/dev/null
rc=$?
set -e
assert_eq "scan_plugin_outputs returns 0 when declared output exists" "0" "$rc"

set +e
plugin_hook_call "$FIXTURE_ROOT/agent/declares-output" "run" "stage-id" "$PLUG_STATE_FILE" >/dev/null 2>&1
hook_rc=$?
set -e
assert_eq "plugin_hook_call returns 0 when scanner passes" "0" "$hook_rc"

# Tool plugin without provides.artifact_type → scanner is no-op (always passes).
set +e
scan_plugin_outputs "$FIXTURE_ROOT/tool/test-tool" "$PLUG_STATE_FILE" 2>/dev/null
rc=$?
set -e
assert_eq "scanner no-op for plugins without provides.artifact_type" "0" "$rc"

# ─── Optional doc fields: summary + usage (issue #1414) ─────────────────────
# (a) manifest with both fields present and non-empty passes.
mkdir -p "$FIXTURE_ROOT/tool/doc-fields-valid"
cat > "$FIXTURE_ROOT/tool/doc-fields-valid/manifest.yaml" <<'EOF'
id: doc-fields-valid
name: Doc Fields Valid
kind: tool
version: 0.0.1
summary: Short one-line synopsis
usage: |
  Run with stage_id and state_file.
hooks:
  run: dfv_run
EOF
cat > "$FIXTURE_ROOT/tool/doc-fields-valid/plugin.sh" <<'EOF'
dfv_run() { :; }
EOF
set +e
validate_manifest "$FIXTURE_ROOT/tool/doc-fields-valid/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "validate_manifest accepts manifest with non-empty summary and usage (#1414)" "0" "$rc"

# (b) manifest without either field passes (existing tool/test-tool already covers this,
#     but an explicit fixture makes the intent clear).
mkdir -p "$FIXTURE_ROOT/tool/doc-fields-absent"
cat > "$FIXTURE_ROOT/tool/doc-fields-absent/manifest.yaml" <<'EOF'
id: doc-fields-absent
name: Doc Fields Absent
kind: tool
version: 0.0.1
hooks:
  run: dfa_run
EOF
cat > "$FIXTURE_ROOT/tool/doc-fields-absent/plugin.sh" <<'EOF'
dfa_run() { :; }
EOF
set +e
validate_manifest "$FIXTURE_ROOT/tool/doc-fields-absent/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "validate_manifest accepts manifest without summary or usage (#1414)" "0" "$rc"

# (c) manifest with an empty-string summary is rejected.
mkdir -p "$FIXTURE_ROOT/tool/doc-fields-empty-summary"
cat > "$FIXTURE_ROOT/tool/doc-fields-empty-summary/manifest.yaml" <<'EOF'
id: doc-fields-empty-summary
name: Doc Fields Empty Summary
kind: tool
version: 0.0.1
hooks:
  run: dfes_run
summary:
EOF
set +e
validate_manifest "$FIXTURE_ROOT/tool/doc-fields-empty-summary/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "validate_manifest rejects manifest with declared-but-empty summary (#1414)" "1" "$rc"

# (d) manifest with an empty-string usage is rejected (symmetry with (c)).
mkdir -p "$FIXTURE_ROOT/tool/doc-fields-empty-usage"
cat > "$FIXTURE_ROOT/tool/doc-fields-empty-usage/manifest.yaml" <<'EOF'
id: doc-fields-empty-usage
name: Doc Fields Empty Usage
kind: tool
version: 0.0.1
hooks:
  run: dfeu_run
usage:
EOF
set +e
validate_manifest "$FIXTURE_ROOT/tool/doc-fields-empty-usage/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "validate_manifest rejects manifest with declared-but-empty usage (#1414)" "1" "$rc"

# ─── SPEC-8: validate_manifest names the plugin when run hook is missing ─────
# CHANGE: error message now names the specific plugin that is missing hooks.run.
# Uses the existing no-run-hook fixture (id: no-run-hook).
set +e
_spec8_err="$(validate_manifest "$FIXTURE_ROOT/agent/no-run-hook/manifest.yaml" 2>&1)"
set -e
if grep -q "no-run-hook" <<< "$_spec8_err"; then
    assert_pass "[SPEC-8] validate_manifest error names the missing-run plugin"
else
    assert_fail "[SPEC-8] validate_manifest error names the missing-run plugin" \
        "got: $_spec8_err"
fi

# ─── SPEC-9: absent optional cleanup hook returns ZBUILD_HOOK_ABSENT (3) ─────
# CHANGE: before ADR-056, absent cleanup returned 0; now it returns 3.
# Uses the existing test-tool fixture (has run, no cleanup).
set +e
plugin_hook_call "$FIXTURE_ROOT/tool/test-tool" "cleanup" >/dev/null 2>&1
_spec9_rc=$?
set -e
assert_eq "[SPEC-9] plugin_hook_call returns ZBUILD_HOOK_ABSENT (3) for absent cleanup" \
    "3" "$_spec9_rc"

# ── SPEC-3: required:false output absent returns 0 ────────────────────────────
# GUARD: the awk already skips required:false entries, so the scanner is a no-op
# for absent optional outputs regardless of whether artifact_type is set.
mkdir -p "$FIXTURE_ROOT/tool/optional-output"
cat > "$FIXTURE_ROOT/tool/optional-output/manifest.yaml" <<'EOF'
id: optional-output
name: Optional Output
kind: tool
version: 0.0.1
hooks:
  run: oo_run
outputs:
  - name: optional
    path: ${artifact_dir}/optional.json
    required: false
EOF
cat > "$FIXTURE_ROOT/tool/optional-output/plugin.sh" <<'EOF'
oo_run() { :; }
EOF

set +e
scan_plugin_outputs "$FIXTURE_ROOT/tool/optional-output" "$PLUG_STATE_FILE" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-3] required:false output absent returns 0" "0" "$rc"

# ── SPEC-4: zero-byte output returns 1 even when the file exists ──────────────
# CHANGE: at baseline the scanner uses -e (existence only), which passes for a
# zero-byte file. The fix changes to -s so zero-byte files are rejected.
# Uses the existing declares-output fixture (artifact_type: findings.json).
: > "$PLUG_STATE_DIR/artifacts/findings.json"
set +e
scan_plugin_outputs "$FIXTURE_ROOT/agent/declares-output" "$PLUG_STATE_FILE" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-4] zero-byte output returns 1 even when file exists" "1" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
