#!/usr/bin/env bash
# tests/integration/write-boundary-dispatch-test.sh
# Integration tests for write-boundary enforcement (#1809, ADR-058 C9).
#
# SPEC-2[change]: a write-boundary violation resolves to broken even when the
#                 stage declared disposition=complete in its v2 result.
# SPEC-3[change]: a missing declared output (artifact-contract violation) likewise
#                 resolves to broken via the new precedence branch in verdict.sh.
# SPEC-6[change]: the watch list is operator-overridable; the allow list is
#                 additive only — removing an engine-owned root does not widen the fence.
#
# Integration because the claim spans lifecycle.sh (mark + check), write-boundary.sh
# (sweep + classify + violation_recorded), and verdict.sh (precedence branch).
# This test flips pass→fail on a Level-3 WIRING revert.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
# write-boundary.sh is sourced lazily by lifecycle.sh; also source here so
# write_boundary_check is available for the direct calls in SPEC-6.
# shellcheck source=../../core/pipeline/write-boundary.sh
source "$REPO_ROOT/core/pipeline/write-boundary.sh"

print_test_header "write-boundary dispatch integration — SPEC-2/3/6 (#1809, ADR-058 C9)"
setup_test_env "write-boundary-dispatch"

# ── Event capture stubs ───────────────────────────────────────────────────────
_DISP_EVENTS=()
emit_event() { _DISP_EVENTS+=("$*"); }
verify_plugin_for_source() { return 0; }

# ── Shared state directory ────────────────────────────────────────────────────
JOB_DIR="$TEST_TEMP_DIR/state/runs/20260822-wb-int"
STATE_FILE="$JOB_DIR/pipeline-state.json"
mkdir -p "$JOB_DIR/artifacts" "$JOB_DIR/runtime"
echo '{}' > "$STATE_FILE"

# A canary directory: in the watch list but NOT an engine-owned allowed root.
CANARY_DIR="$TEST_TEMP_DIR/canary"
mkdir -p "$CANARY_DIR"

# Custom watch list: only the canary dir (bounded, deterministic).
CUSTOM_WATCH="$TEST_TEMP_DIR/watch.txt"
printf '%s\n' "$CANARY_DIR" > "$CUSTOM_WATCH"

# Custom allow list: empty (engine roots are always hardcoded in code).
CUSTOM_ALLOW="$TEST_TEMP_DIR/allow.txt"
printf '# no extra allowed paths\n' > "$CUSTOM_ALLOW"

export ZBUILD_WRITE_BOUNDARY_WATCH="$CUSTOM_WATCH"
export ZBUILD_WRITE_BOUNDARY_ALLOW="$CUSTOM_ALLOW"
# Suppress ZBUILD_REPO_ROOT so the allow list is predictable in this test.
unset ZBUILD_REPO_ROOT 2>/dev/null || true
unset ZBUILD_SCRATCH_ROOT 2>/dev/null || true

# ── Fixture factory ───────────────────────────────────────────────────────────
_make_fixture() {
    local _dir="$1" _id="$2" _body="$3"
    mkdir -p "$_dir"
    cat > "$_dir/manifest.yaml" <<MEOF
id: ${_id}
name: ${_id}
kind: tool
version: 0.0.1
hooks:
  run: ${_id}_run
outputs:
  - name: result
    path: \${artifact_dir}/${_id}-result.json
    required: true
MEOF
    cat > "$_dir/plugin.sh" <<PEOF
${_id}_run() {
${_body}
}
PEOF
}

# ─── SPEC-2: write-boundary violation overrides disposition=complete ──────────
print_test_section "SPEC-2: write-boundary violation overrides disposition=complete"

FX2="$TEST_TEMP_DIR/plugins/wb-fx2"
_make_fixture "$FX2" "wb-fx2" "
    # Write the declared artifact (so scan_plugin_outputs is happy).
    echo '{}' > \"\${ZBUILD_ARTIFACT_DIR:-\${artifact_dir:-}}/wb-fx2-result.json\"
    # Write a v2 result declaring disposition=complete.
    cat > \"\${ZBUILD_ARTIFACT_DIR:-\${artifact_dir:-}}/wb-fx2-result.json\" <<'REOF'
{\"result_contract\":2,\"disposition\":\"complete\",\"verdict\":\"pass\"}
REOF
    # Write to the canary dir — a boundary violation.
    touch \"\$ZB_WB_CANARY_FILE\"
"

mkdir -p "$JOB_DIR/artifacts" "$JOB_DIR/runtime"
rm -f "$JOB_DIR/runtime/write-boundary-violated" "$JOB_DIR/runtime/artifact-contract-violated"
export ZB_WB_CANARY_FILE="$CANARY_DIR/bad-write-spec2.txt"

# stub scan_plugin_outputs: the declared artifact will exist, but we also need
# the real one to produce the artifact-contract-violated marker when the
# artifact is ABSENT. For SPEC-2 the artifact IS written, so we skip the scan.
scan_plugin_outputs() { return 0; }

_DISP_EVENTS=()
plugin_hook_call "$FX2" "run" "wb-test-stage" "$STATE_FILE" || true

# The write-boundary-violated marker must have been created by write_boundary_check.
assert_file_exists "[SPEC-2] write-boundary-violated marker created after boundary violation" \
    "$JOB_DIR/runtime/write-boundary-violated"

# The disposition must resolve to broken even though the stage declared complete.
_disp2="$(runner_read_stage_disposition "$JOB_DIR" "$FX2/manifest.yaml" "wb-test-stage" 0 "" 0)"
assert_eq "[SPEC-2] write-boundary violation overrides disposition=complete → broken" \
    "broken" "$_disp2"

# ─── SPEC-3: artifact-contract violation resolves to broken ──────────────────
print_test_section "SPEC-3: missing declared output resolves to broken"

FX3="$TEST_TEMP_DIR/plugins/wb-fx3"
_make_fixture "$FX3" "wb-fx3" "
    # Intentionally does NOT write the declared artifact.
    return 0
"

JOB3="$TEST_TEMP_DIR/state/runs/20260822-wb-spec3"
SF3="$JOB3/pipeline-state.json"
mkdir -p "$JOB3/artifacts" "$JOB3/runtime"
echo '{}' > "$SF3"

# Restore the real scan_plugin_outputs (defined in lifecycle.sh).
# The double-load guard must be cleared first so the source actually runs.
unset -f scan_plugin_outputs 2>/dev/null || true
unset _ZBUILD_REGISTRY_LIFECYCLE_LOADED 2>/dev/null || true
source "$REPO_ROOT/core/plugin-registry/lifecycle.sh"

_DISP_EVENTS=()
plugin_hook_call "$FX3" "run" "wb-stage3" "$SF3" || true

# scan_plugin_outputs must have created the artifact-contract-violated marker.
assert_file_exists "[SPEC-3] artifact-contract-violated marker created for missing declared output" \
    "$JOB3/runtime/artifact-contract-violated"

# Disposition must resolve to broken.
_disp3="$(runner_read_stage_disposition "$JOB3" "$FX3/manifest.yaml" "wb-stage3" 0 "" 0)"
assert_eq "[SPEC-3] missing declared output resolves to broken via artifact-contract marker" \
    "broken" "$_disp3"

# ─── SPEC-6: watch list overridable; allow list additive only ─────────────────
print_test_section "SPEC-6: watch list override + allow list additive guarantee"

# Part A: watch list is operator-overridable via env.
# Create a NEW canary dir that is only watched when the custom watch list is active.
CANARY6="$TEST_TEMP_DIR/canary6"
mkdir -p "$CANARY6"

WATCH6="$TEST_TEMP_DIR/watch6.txt"
printf '%s\n' "$CANARY6" > "$WATCH6"

ALLOW6="$TEST_TEMP_DIR/allow6.txt"
printf '# no extra allows\n' > "$ALLOW6"

# Reset state for SPEC-6 job dir.
JOB6="$TEST_TEMP_DIR/state/runs/20260822-wb-spec6"
SF6="$JOB6/pipeline-state.json"
mkdir -p "$JOB6/artifacts" "$JOB6/runtime"
echo '{}' > "$SF6"

FX6="$TEST_TEMP_DIR/plugins/wb-fx6"
_make_fixture "$FX6" "wb-fx6" "
    echo '{}' > \"\${ZBUILD_ARTIFACT_DIR:-/tmp}/wb-fx6-result.json\"
    touch \"\$ZB_WB_CANARY6_FILE\"
"
export ZB_WB_CANARY6_FILE="$CANARY6/bad-write-spec6.txt"

# stub scan_plugin_outputs so only the boundary check fires.
scan_plugin_outputs() { return 0; }

export ZBUILD_WRITE_BOUNDARY_WATCH="$WATCH6"
export ZBUILD_WRITE_BOUNDARY_ALLOW="$ALLOW6"
unset ZBUILD_REPO_ROOT 2>/dev/null || true

_DISP_EVENTS=()
plugin_hook_call "$FX6" "run" "wb-stage6" "$SF6" || true

assert_file_exists "[SPEC-6] operator-supplied watch list catches a write to the custom canary dir" \
    "$JOB6/runtime/write-boundary-violated"

# Part B: allow list is additive — removing an engine-owned root does not widen the fence.
# The engine-owned root is state_dir (JOB6). Even if the operator's allow file is
# empty (no extra paths), state_dir must remain allowed because it's hardcoded in code.
JOB6B="$TEST_TEMP_DIR/state/runs/20260822-wb-spec6b"
SF6B="$JOB6B/pipeline-state.json"
mkdir -p "$JOB6B/artifacts" "$JOB6B/runtime"
echo '{}' > "$SF6B"

# Watch ONLY the job dir (so a file written inside job dir can be found).
WATCH6B="$TEST_TEMP_DIR/watch6b.txt"
printf '%s\n' "$JOB6B" > "$WATCH6B"

# Allow file is empty — an operator that tried to "remove" state_dir from the list.
ALLOW6B="$TEST_TEMP_DIR/allow6b.txt"
printf '# operator override — engine-owned roots should still be allowed\n' > "$ALLOW6B"

export ZBUILD_WRITE_BOUNDARY_WATCH="$WATCH6B"
export ZBUILD_WRITE_BOUNDARY_ALLOW="$ALLOW6B"
unset ZBUILD_REPO_ROOT 2>/dev/null || true

# Mark the timestamp before writing anything.
write_boundary_mark "$SF6B"

# Write a file inside the state dir (the engine-owned root that must always be allowed).
touch "$JOB6B/artifacts/wb-fx6b-result.json"

_6b_rc=0
write_boundary_check "$FX6" "$SF6B" "wb-stage6b" "" 2>/dev/null || _6b_rc=$?
assert_eq "[SPEC-6] engine-owned state_dir is always allowed even when allow file is empty" \
    "0" "$_6b_rc"

if [[ ! -f "$JOB6B/runtime/write-boundary-violated" ]]; then
    assert_pass "[SPEC-6] no write-boundary-violated marker when writing inside state_dir"
else
    assert_fail "[SPEC-6] state_dir must remain allowed regardless of operator allow file" \
        "write-boundary-violated marker was created — engine-owned root was incorrectly blocked"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
