#!/usr/bin/env bash
# Tests: A3 artifact contract check — plugin declares provides.artifact_type
# but writes nothing → plugin.contract.violated event + synthetic findings.json.
# ARCHITECTURE.md §2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "artifact contract — A3: missing artifact triggers plugin.contract.violated"

setup_test_env "artifact-contract"

EVENTS_DIR="$TEST_TEMP_DIR/events"
# #511 F2: this test pins the standard template explicitly (#978 flipped the
# default to simple); the F2 cycle wiring is irrelevant to artifact-contract
# assertions and would otherwise interact with the missing-artifact path. Force
# linear dispatch.
export ZBUILD_CYCLES_ENABLED=0
export ZBUILD_EVENTS_DIR="$EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$EVENTS_DIR"

# ─── Build a minimal isolated pipeline environment ───────────────────────────
A3_DIR="$TEST_TEMP_DIR/a3"
A3_PLUGINS="$A3_DIR/plugins"
A3_STATE_DIR="$A3_DIR/state"
A3_EVENTS_DIR="$A3_DIR/events"
A3_EVENTS_JSONL="$A3_EVENTS_DIR/events.jsonl"
mkdir -p "$A3_PLUGINS/agent/noartifact" "$A3_PLUGINS/agent/security-lens" \
         "$A3_PLUGINS/tool/output" "$A3_STATE_DIR" "$A3_EVENTS_DIR"

# ─── Fixture: plugin that declares provides.artifact_type but writes nothing ──
cat > "$A3_PLUGINS/agent/noartifact/manifest.yaml" <<'EOF'
id: intake
name: No-Artifact Intake
kind: agent
version: 0.0.1
hooks:
  run: noartifact_run
requires:
  core:
    - redaction
provides:
  # artifact-contract-minimal.yaml declares roles: [intake]; resolve_stage_plugin
  # fails closed when a declared role resolves to nothing.
  role: intake
  artifact_type: findings.json
outputs:
  - name: findings
    path: artifacts/intake-findings.json
    type: findings.json
EOF
cat > "$A3_PLUGINS/agent/noartifact/plugin.sh" <<'EOF'
noartifact_run() {
    # Intentionally does NOT write artifacts/intake-findings.json
    return 0
}
EOF

# ─── Fixture: downstream plugins that succeed (to isolate the contract check) ─
cat > "$A3_PLUGINS/agent/security-lens/manifest.yaml" <<'EOF'
id: security-lens
name: Fast SL
kind: agent
version: 0.0.1
hooks:
  run: sl_run
requires:
  core:
    - redaction
EOF
cat > "$A3_PLUGINS/agent/security-lens/plugin.sh" <<'EOF'
sl_run() { return 0; }
EOF
cat > "$A3_PLUGINS/tool/output/manifest.yaml" <<'EOF'
id: output
name: Fast Out
kind: tool
version: 0.0.1
hooks:
  run: out_run
EOF
cat > "$A3_PLUGINS/tool/output/plugin.sh" <<'EOF'
out_run() { return 0; }
EOF

# ─── Run the runner with the no-artifact plugin ───────────────────────────────
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# #978 (EPIC #966): template-agnostic. Was pinned to `--template standard`;
# standard.yaml retires in #979. The plugin.contract.violated mechanism is ENGINE
# behavior keyed off the bound plugin's manifest (declares provides.artifact_type,
# writes nothing) — not roster-specific. Drive a minimal single-intake fixture the
# test owns, via the #1270 per-repo `.zbuild/templates/` overlay: install the
# fixture into a temp repo and run the runner with CWD = that repo. A single intake
# leaf isolates the contract check — no downstream stages to satisfy or interfere.
OVERLAY_REPO="$(setup_git_temp_repo artifact-contract-overlay-repo)"
install_template_overlay "$OVERLAY_REPO" artifact-contract-minimal

# Runner is expected to fail (non-zero) on contract violation, but the
# behaviour under test is event emission, not the exit code itself. Tolerate
# non-zero with `|| true` rather than capturing an unused rc.
( cd "$OVERLAY_REPO" && ZBUILD_PLUGINS_ROOT="$A3_PLUGINS" \
    ZBUILD_STATE_DIR="$A3_STATE_DIR" \
    ZBUILD_EVENTS_DIR="$A3_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$A3_EVENTS_JSONL" \
    ZBUILD_EVENTS_DB="$A3_DIR/events.db" \
    bash "$RUNNER" --template artifact-contract-minimal --issue 83 2>/dev/null ) || true

# ─── Assert plugin.contract.violated event emitted ───────────────────────────
if [[ -f "$A3_EVENTS_JSONL" ]]; then
    violated_count="$(grep -c '"plugin.contract.violated"' "$A3_EVENTS_JSONL" 2>/dev/null || true)"
    if [[ "$violated_count" -gt 0 ]]; then
        assert_pass "plugin.contract.violated event emitted"
    else
        assert_fail "plugin.contract.violated event emitted" \
            "not found in $A3_EVENTS_JSONL"
    fi
else
    assert_fail "events.jsonl created for contract violation run"
fi

# ─── Assert synthetic findings.json exists with blocking finding ──────────────
# Written to artifacts/<stage>-<plugin_id>-contract-violated-findings.json so the output
# plugin's aggregator (which reads artifacts/*-findings.json) picks it up.
a3_findings="$A3_STATE_DIR/artifacts/intake-intake-contract-violated-findings.json"
assert_file_exists "synthetic findings.json created" "$a3_findings"

if [[ -f "$a3_findings" ]]; then
    blocking_count="$(jq '[.findings[] | select(.severity == "blocking")] | length' \
        "$a3_findings" 2>/dev/null || echo 0)"
    assert_eq "synthetic findings.json has exactly 1 blocking finding" "1" "$blocking_count"
fi

# ─── Assert the event names the correct plugin and artifact type ──────────────
if [[ -f "$A3_EVENTS_JSONL" ]]; then
    artifact_type="$(grep '"plugin.contract.violated"' "$A3_EVENTS_JSONL" 2>/dev/null \
        | jq -r '.data.artifact_type // empty' 2>/dev/null | head -1 || true)"
    assert_eq "plugin.contract.violated event carries correct artifact_type" \
        "findings.json" "$artifact_type"

    violation_reason="$(grep '"plugin.contract.violated"' "$A3_EVENTS_JSONL" 2>/dev/null \
        | jq -r '.data.reason // empty' 2>/dev/null | head -1 || true)"
    assert_eq "plugin.contract.violated event carries reason=artifact_missing_or_empty" \
        "artifact_missing_or_empty" "$violation_reason"
fi

# ─── Test the contract check also works when no outputs[] declared ────────────
# Verify that a plugin declaring artifact_type but without outputs[] also fires
# the check (uses the default artifacts/<stage>-findings.json path).
B_DIR="$TEST_TEMP_DIR/b"
B_PLUGINS="$B_DIR/plugins"
B_STATE_DIR="$B_DIR/state"
B_EVENTS_DIR="$B_DIR/events"
B_EVENTS_JSONL="$B_EVENTS_DIR/events.jsonl"
mkdir -p "$B_PLUGINS/agent/noartifact-nopaths" "$B_PLUGINS/agent/security-lens" \
         "$B_PLUGINS/tool/output" "$B_STATE_DIR" "$B_EVENTS_DIR"

cat > "$B_PLUGINS/agent/noartifact-nopaths/manifest.yaml" <<'EOF'
id: intake
name: No-Artifact No-Paths Intake
kind: agent
version: 0.0.1
hooks:
  run: noartifact_nopaths_run
requires:
  core:
    - redaction
provides:
  role: intake
  artifact_type: findings.json
EOF
cat > "$B_PLUGINS/agent/noartifact-nopaths/plugin.sh" <<'EOF'
noartifact_nopaths_run() { return 0; }
EOF
cp "$A3_PLUGINS/agent/security-lens/manifest.yaml" "$B_PLUGINS/agent/security-lens/"
cp "$A3_PLUGINS/agent/security-lens/plugin.sh"    "$B_PLUGINS/agent/security-lens/"
cp "$A3_PLUGINS/tool/output/manifest.yaml"        "$B_PLUGINS/tool/output/"
cp "$A3_PLUGINS/tool/output/plugin.sh"            "$B_PLUGINS/tool/output/"

# Same as A3 above: assertion is event-based, exit code is not under test.
( cd "$OVERLAY_REPO" && ZBUILD_PLUGINS_ROOT="$B_PLUGINS" \
    ZBUILD_STATE_DIR="$B_STATE_DIR" \
    ZBUILD_EVENTS_DIR="$B_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$B_EVENTS_JSONL" \
    ZBUILD_EVENTS_DB="$B_DIR/events.db" \
    bash "$RUNNER" --template artifact-contract-minimal --issue 83 2>/dev/null ) || true

if [[ -f "$B_EVENTS_JSONL" ]]; then
    b_violated="$(grep -c '"plugin.contract.violated"' "$B_EVENTS_JSONL" 2>/dev/null || true)"
    if [[ "$b_violated" -gt 0 ]]; then
        assert_pass "contract check fires for plugin with artifact_type but no outputs[] declared"
    else
        assert_fail "contract check fires for plugin with artifact_type but no outputs[] declared" \
            "plugin.contract.violated not emitted"
    fi
else
    assert_fail "events.jsonl created for no-outputs-paths run"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
