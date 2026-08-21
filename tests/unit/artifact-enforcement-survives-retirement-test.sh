#!/usr/bin/env bash
# #1906 acceptance: "No plugin loses artifact-existence enforcement — proven by
# breaking one deliberately and confirming it still fails."
#
# Retiring `_check_artifact_contract` (core/pipeline/contracts.sh, #415) rests on
# the claim that #1803's scan_plugin_outputs subsumes it. This test breaks a
# plugin on purpose and proves the surviving check still catches it.
#
# Why the claim holds, and the one place it did NOT:
#   scan_plugin_outputs walks EVERY declared output, honours `required: false`
#   and the empty-diff capability, and catches zero-byte files as well as absent
#   ones. The retired check gated on provides.artifact_type being declared and
#   then tested only the FIRST output path. Its sole unique behaviour was a
#   fallback for a plugin declaring NO outputs at all — whose only occupant was
#   output-github-comment, which this issue gives a real outputs[] block.
#
# Coverage note: scan_plugin_outputs runs inside plugin_hook_call, and the
# parallel/map/fanout strategies dispatch generated work units that themselves
# call plugin_hook_call (strategies/common.sh), so it runs on every path the
# retired check ran on.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# event-bus.sh resolves ZBUILD_EVENTS_JSONL at SOURCE time and guards against
# re-init, so the events path must be pinned BEFORE helpers.sh pulls it in —
# exporting after setup_test_env would leave emissions going to the default file.
_EV_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zbuild-1906-ev.XXXXXX")"
export ZBUILD_EVENTS_DIR="$_EV_DIR"
export ZBUILD_EVENTS_JSONL="$_EV_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$_EV_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
: > "$ZBUILD_EVENTS_JSONL"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# helpers.sh defines a NO-OP emit_event stub for callers that never load the
# event bus, and registry.sh does not pull the real one in. Sourcing event-bus.sh
# after helpers.sh lets the real definition win — without this the emission
# assertions below silently pass over an empty file.
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "artifact enforcement survives artifact_type retirement (#1906)"
setup_test_env "artifact-enforcement-survives"

STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$STATE_DIR/artifacts"
STATE_FILE="$STATE_DIR/pipeline-state.json"
printf '{"schema_version":1,"status":"in_progress"}' > "$STATE_FILE"

# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

# ─── A deliberately broken plugin: declares an output, never writes it ────────
_make_plugin() {
    local dir="$1" required="$2"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<MANIFEST
id: brokenstage
kind: tool
version: 1.0.0
description: writes nothing despite declaring an output (#1906 fixture)

provides:
  role: brokenstage

outputs:
  - id: result
    path: \${artifact_dir}/brokenstage-result.json
    type: brokenstage-result.json@1
    format: json
    required: $required
    primary: true
MANIFEST
    cat > "$dir/plugin.sh" <<'PLUGIN'
#!/usr/bin/env bash
brokenstage_run() { return 0; }   # exits clean, writes nothing
PLUGIN
    chmod +x "$dir/plugin.sh"
}

# ─── SPEC-7 [change]: a required output that is never written still fails ─────
print_test_section "SPEC-7. a broken plugin is still caught after retirement"
BROKEN="$TEST_TEMP_DIR/plugins/brokenstage"
_make_plugin "$BROKEN" "true"

set +e
scan_plugin_outputs "$BROKEN" "$STATE_FILE" "brokenstage" >/dev/null 2>&1
SCAN_RC=$?
set -e
assert_eq "[SPEC-7] scan_plugin_outputs returns non-zero for a missing required output" \
    "1" "$SCAN_RC"

if grep -q '"plugin.artifact.missing"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-7b] plugin.artifact.missing emitted"
else
    assert_fail "[SPEC-7b] plugin.artifact.missing emitted" "missing"
fi
if grep -q '"plugin.contract.violated"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-7c] plugin.contract.violated emitted (blocking findings path)"
else
    assert_fail "[SPEC-7c] plugin.contract.violated emitted (blocking findings path)" "missing"
fi

# The retired check gated on provides.artifact_type. This fixture declares NONE,
# so under the old check it would have returned 0 and caught nothing — which is
# exactly the enforcement the survivor has to supply on its own.
if grep -q "brokenstage-result.json" "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-7d] the missing path is named in the event (no artifact_type needed)"
else
    assert_fail "[SPEC-7d] the missing path is named in the event (no artifact_type needed)" "absent"
fi

# ─── SPEC-8 [guard]: required:false is still honoured ─────────────────────────
# The survivor must not become stricter than the retired check: an optional
# output that is legitimately absent must NOT fail.
print_test_section "SPEC-8. an optional missing output is still allowed"
: > "$ZBUILD_EVENTS_JSONL"
OPTIONAL="$TEST_TEMP_DIR/plugins/optionalstage"
_make_plugin "$OPTIONAL" "false"

set +e
scan_plugin_outputs "$OPTIONAL" "$STATE_FILE" "optionalstage" >/dev/null 2>&1
OPT_RC=$?
set -e
assert_eq "[SPEC-8] a missing required:false output does not fail the scan" "0" "$OPT_RC"

# ─── SPEC-9 [guard]: the retired function is gone ─────────────────────────────
print_test_section "SPEC-9. _check_artifact_contract is retired"
_s9_hits="$(grep -rln "_check_artifact_contract" \
    "$REPO_ROOT/core" "$REPO_ROOT/scripts" "$REPO_ROOT/plugins" 2>/dev/null || true)"
assert_eq "[SPEC-9] no production source references _check_artifact_contract" "" "$_s9_hits"

print_test_results
cleanup_test_env
rm -rf "$_EV_DIR"
exit $((FAIL > 0))
