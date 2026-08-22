#!/usr/bin/env bash
# tests/unit/write-boundary-sweep-test.sh
# Unit tests for core/pipeline/write-boundary.sh (#1809, ADR-058 C9).
#
# SPEC-1[change]: a stage writing outside its declared outputs and engine-owned
#                 areas causes write_boundary_check to return 1 (dispatch fails).
# SPEC-4[change]: write_boundary_classify returns declared|allowed|violation in
#                 the correct precedence order.
# SPEC-5[change]: write_boundary_mark and write_boundary_check are no-ops when
#                 state_file is empty; no events are emitted on a clean dispatch.
#
# Functions are called directly — no plugin_hook_call — so a Level-3 WIRING
# revert of lifecycle.sh leaves this test RED at L2 (lib absent) and GREEN at
# L3 (lib present but not wired). Level-2 revert of write-boundary.sh itself
# leaves this RED at L2.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "write-boundary sweep — SPEC-1/4/5 (#1809, ADR-058 C9)"
setup_test_env "write-boundary-sweep"

WB_LIB="$REPO_ROOT/core/pipeline/write-boundary.sh"
assert_file_exists "[SPEC-1] core/pipeline/write-boundary.sh exists" "$WB_LIB"

# Stub emit_event so no real event bus is needed.
_WB_EVENTS=()
emit_event() { _WB_EVENTS+=("$*"); }

# shellcheck source=../../core/pipeline/write-boundary.sh
source "$WB_LIB"

JOB_DIR="$TEST_TEMP_DIR/state/runs/20260822-wb-unit"
STATE_FILE="$JOB_DIR/pipeline-state.json"
mkdir -p "$JOB_DIR/artifacts" "$JOB_DIR/runtime"
echo '{}' > "$STATE_FILE"

# Fixture plugin with one declared output.
FIXTURE_DIR="$TEST_TEMP_DIR/plugins/tool/wb-fixture"
mkdir -p "$FIXTURE_DIR"
cat > "$FIXTURE_DIR/manifest.yaml" <<'MANIFEST_EOF'
id: wb-fixture
name: WB Fixture
kind: tool
version: 0.0.1
hooks:
  run: wb_run
outputs:
  - name: result
    path: ${artifact_dir}/wb-result.json
    required: true
MANIFEST_EOF

# ── A custom watch directory controlled by the test ───────────────────────────
WATCH_DIR="$TEST_TEMP_DIR/watch-canary"
mkdir -p "$WATCH_DIR"

# Custom watch list file: only our canary dir, no maxdepth (scan everything).
CUSTOM_WATCH="$TEST_TEMP_DIR/test-watch.txt"
printf '%s\n' "$WATCH_DIR" > "$CUSTOM_WATCH"

# Custom allow list file: only the job dir (engine-owned roots are hardcoded in
# code, so this override just ensures nothing extra is allowed).
CUSTOM_ALLOW="$TEST_TEMP_DIR/test-allow.txt"
printf '# empty — no extra allows\n' > "$CUSTOM_ALLOW"

# Override so tests are bounded and deterministic.
export ZBUILD_WRITE_BOUNDARY_WATCH="$CUSTOM_WATCH"
export ZBUILD_WRITE_BOUNDARY_ALLOW="$CUSTOM_ALLOW"
# Unset env vars that write_boundary_allow_list reads dynamically so the allow
# list is predictable. We keep ZBUILD_STATE_DIR unset; state_dir is passed in.
unset ZBUILD_REPO_ROOT 2>/dev/null || true
unset ZBUILD_SCRATCH_ROOT 2>/dev/null || true

# ── SPEC-5[change]: mark and check are no-ops when state_file is empty ───────
_WB_EVENTS=()
write_boundary_mark "" 2>/dev/null || true
assert_eq "[SPEC-5] write_boundary_mark with empty state_file does not create a marker" \
    "0" "$(ls "$JOB_DIR/runtime/" 2>/dev/null | wc -l | tr -d ' ')"

_noop_rc=0
write_boundary_check "$FIXTURE_DIR" "" "my-stage" "" 2>/dev/null || _noop_rc=$?
assert_eq "[SPEC-5] write_boundary_check with empty state_file returns 0 (no-op)" "0" "$_noop_rc"
assert_eq "[SPEC-5] write_boundary_check with empty state_file emits no events" \
    "0" "${#_WB_EVENTS[@]}"

# Guard: no marker file was created.
assert_eq "[SPEC-5] no marker file exists after no-op mark" \
    "0" "$(ls "$JOB_DIR/runtime/" 2>/dev/null | wc -l | tr -d ' ')"

# ── SPEC-5[change]: clean dispatch emits no events ───────────────────────────
_WB_EVENTS=()
write_boundary_mark "$STATE_FILE"
# Don't write anything to WATCH_DIR → sweep finds nothing → no events.
_clean_rc=0
write_boundary_check "$FIXTURE_DIR" "$STATE_FILE" "my-stage" "" 2>/dev/null || _clean_rc=$?
assert_eq "[SPEC-5] write_boundary_check returns 0 on clean dispatch (nothing new in watch)" \
    "0" "$_clean_rc"
assert_eq "[SPEC-5] no stage.write_boundary.violated event on a clean dispatch" \
    "0" "${#_WB_EVENTS[@]}"

# ── SPEC-1[change]: write to watched dir → violation → rc=1 ──────────────────
# Reset marker and event list.
_WB_EVENTS=()
rm -f "$JOB_DIR/runtime/write-boundary.marker" "$JOB_DIR/runtime/write-boundary-violated"
write_boundary_mark "$STATE_FILE"

# Write a file to the watched canary dir (simulates a plugin hardcoding a path
# outside engine-owned areas — e.g. the /tmp case from the ADR).
touch "$WATCH_DIR/forbidden-file.txt"

_viol_rc=0
write_boundary_check "$FIXTURE_DIR" "$STATE_FILE" "my-stage" "" 2>/dev/null || _viol_rc=$?
assert_eq "[SPEC-1] write_boundary_check returns 1 when a file is written outside allowed areas" \
    "1" "$_viol_rc"

# Verify the violation marker was created.
assert_file_exists "[SPEC-1] write-boundary-violated marker created in runtime/" \
    "$JOB_DIR/runtime/write-boundary-violated"

# Verify the event was emitted.
_ev_count=0
for _ev in "${_WB_EVENTS[@]}"; do
    [[ "$_ev" == *"stage.write_boundary.violated"* ]] && _ev_count=$((_ev_count + 1))
done
if [[ "$_ev_count" -gt 0 ]]; then
    assert_pass "[SPEC-1] stage.write_boundary.violated event emitted on violation"
else
    assert_fail "[SPEC-1] stage.write_boundary.violated event emitted on violation" \
        "events: ${_WB_EVENTS[*]:-none}"
fi

# ── SPEC-4[change]: classifier precedence — declared → allowed → violation ───
# Set up paths to classify:
#   declared: the manifest's resolved output path
#   allowed:  something under state_dir but not a declared output
#   violation: something under the canary watch dir (not in allow list)
DECL_PATH="$JOB_DIR/artifacts/wb-result.json"
ALLOWED_PATH="$JOB_DIR/runtime/some-internal-file"
VIOL_PATH="$WATCH_DIR/another-bad-file.txt"

# Ensure the candidate files exist so dirname resolution works.
touch "$DECL_PATH" "$ALLOWED_PATH" "$VIOL_PATH"

_cls_decl="$(write_boundary_classify "$DECL_PATH" "$JOB_DIR" "$FIXTURE_DIR" 2>/dev/null)"
assert_eq "[SPEC-4] classifier returns 'declared' for a manifest-declared output path" \
    "declared" "$_cls_decl"

_cls_allowed="$(write_boundary_classify "$ALLOWED_PATH" "$JOB_DIR" "$FIXTURE_DIR" 2>/dev/null)"
assert_eq "[SPEC-4] classifier returns 'allowed' for a path under state_dir (engine-owned)" \
    "allowed" "$_cls_allowed"

_cls_viol="$(write_boundary_classify "$VIOL_PATH" "$JOB_DIR" "$FIXTURE_DIR" 2>/dev/null)"
assert_eq "[SPEC-4] classifier returns 'violation' for a path outside all allowed areas" \
    "violation" "$_cls_viol"

# Verify precedence: 'declared' beats 'allowed' even though state_dir is in the
# allow list. The declared output IS under state_dir/artifacts (which is under
# state_dir, an allowed area), but it must resolve as 'declared' not 'allowed'.
if [[ "$_cls_decl" == "declared" ]]; then
    assert_pass "[SPEC-4] 'declared' takes precedence over 'allowed' (correct order)"
else
    assert_fail "[SPEC-4] 'declared' must take precedence over 'allowed'" \
        "got: $_cls_decl"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
