#!/usr/bin/env bash
# tests/unit/write-boundary-window-test.sh
# Unit tests for the write-boundary SWEEP WINDOW (#1956, from #1953).
#
# SPEC-6[change]: the marker is keyed on stage and map element, so concurrent
#                 dispatches sharing a state file do not share a window.
# SPEC-7[change]: a sibling dispatch does not move this dispatch's window.
# SPEC-8[guard]:  a plain single dispatch is still caught, and an unkeyed marker
#                 from an older engine is still honoured.
# SPEC-9[change]: a write immediately after the snapshot is still caught — the
#                 measured cause of the ubuntu-only SPEC-4 flake.
#
# Split from write-boundary-sweep-test.sh, which the additions pushed past the
# 500-line limit in CLAUDE.md.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "write-boundary sweep window — SPEC-6/7/8/9 (#1956)"
setup_test_env "write-boundary-window"

_WB_EVENTS=()
emit_event() { _WB_EVENTS+=("$*"); }

# shellcheck source=../../core/pipeline/write-boundary.sh
source "$REPO_ROOT/core/pipeline/write-boundary.sh"

JOB_DIR="$TEST_TEMP_DIR/state/runs/20260825-wb-window"
STATE_FILE="$JOB_DIR/pipeline-state.json"
mkdir -p "$JOB_DIR/artifacts" "$JOB_DIR/runtime"
echo '{}' > "$STATE_FILE"

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

WATCH_DIR="$TEST_TEMP_DIR/watch-canary"
mkdir -p "$WATCH_DIR"
CUSTOM_WATCH="$TEST_TEMP_DIR/test-watch.txt"
printf '%s\n' "$WATCH_DIR" > "$CUSTOM_WATCH"
CUSTOM_ALLOW="$TEST_TEMP_DIR/test-allow.txt"
printf '# empty — no extra allows\n' > "$CUSTOM_ALLOW"
export ZBUILD_WRITE_BOUNDARY_WATCH="$CUSTOM_WATCH"
export ZBUILD_WRITE_BOUNDARY_ALLOW="$CUSTOM_ALLOW"
unset ZBUILD_REPO_ROOT 2>/dev/null || true
unset ZBUILD_SCRATCH_ROOT 2>/dev/null || true

# ─── SPEC-9: a write immediately after the snapshot is still caught ─────────
# THE MEASURED CAUSE of the ubuntu-only SPEC-4 flake (#1953, #1956 defect 3).
# Linux stamps inode times from a coarse clock that advances once per timer
# tick, so two files stamped inside one tick get BYTE-IDENTICAL mtimes — and
# `find -newer` is strictly greater, so the write is invisible. 222 of 222
# captured failures on ubuntu had marker and write mtimes identical to the
# nanosecond, with the sweep returning nothing. macOS stamps from a fine-grained
# clock, which is the whole reason this never reproduced there.
#
# This is not a test defect: on Linux ANY stage writing out of bounds quickly
# after dispatch start evaded the fence entirely.
#
# Asserted through the guarantee rather than the timing, so it is deterministic
# on every platform: after the mark returns, a file created next must be
# strictly newer than the marker.
# CHANGE: fails at baseline (the helper does not exist).

if declare -F _wb_clock_advance_past >/dev/null 2>&1; then
    assert_pass "[SPEC-9] the engine has a clock-advance guarantee for the sweep window"
else
    assert_fail "[SPEC-9] the engine has a clock-advance guarantee for the sweep window" \
        "_wb_clock_advance_past is not defined"
fi

_CA_DIR="$TEST_TEMP_DIR/clock-advance"
mkdir -p "$_CA_DIR"
_ca_fails=0
for _i in 1 2 3 4 5 6 7 8 9 10; do
    _ca_ref="$_CA_DIR/ref.$_i"
    : > "$_ca_ref"
    _wb_clock_advance_past "$_ca_ref" 2>/dev/null || true
    _ca_probe="$_CA_DIR/probe.$_i"
    : > "$_ca_probe"
    [[ "$_ca_probe" -nt "$_ca_ref" ]] || _ca_fails=$((_ca_fails + 1))
done
assert_eq "[SPEC-9] a file created right after the mark is strictly newer, every time" \
    "0" "$_ca_fails"

# The guarantee has to hold through the real entry point, not just the helper.
_CA_JOB="$TEST_TEMP_DIR/state/runs/clock-advance"
mkdir -p "$_CA_JOB/runtime"
_CA_SF="$_CA_JOB/pipeline-state.json"; echo '{}' > "$_CA_SF"
_ca_mark_fails=0
for _i in 1 2 3 4 5 6 7 8 9 10; do
    write_boundary_mark "$_CA_SF"
    _ca_w="$_CA_JOB/../written.$_i"
    : > "$_ca_w"
    [[ "$_ca_w" -nt "$_CA_JOB/runtime/write-boundary.marker" ]] || _ca_mark_fails=$((_ca_mark_fails + 1))
done
assert_eq "[SPEC-9] write_boundary_mark leaves a window every later write falls inside" \
    "0" "$_ca_mark_fails"

# ─── SPEC-6/7/8: one sweep window per dispatch, not per run ─────────────────
# The window was a single file named from the state dir alone, and mark
# RE-STAMPS it. Teardown dispatches nested cleanups from inside its own run,
# `map:` emits a work unit per element and parallel members one per member —
# all against the same state file — so a sibling's mark moved the window past
# writes that had already happened and they stopped being visible.
# runner.sh:2543-2552 keyed the throttle marker per stage for this exact reason
# (#1823). CHANGE: fails at baseline (one shared filename).

_KEY_JOB="$TEST_TEMP_DIR/state/runs/keyed"
mkdir -p "$_KEY_JOB/runtime"
_KEY_SF="$_KEY_JOB/pipeline-state.json"; echo '{}' > "$_KEY_SF"

write_boundary_mark "$_KEY_SF" "stage-alpha" ""
write_boundary_mark "$_KEY_SF" "stage-beta" ""
_key_count="$(find "$_KEY_JOB/runtime" -maxdepth 1 -name 'write-boundary*.marker' | wc -l | tr -d ' ')"
assert_eq "[SPEC-6] two stages against one state file get two distinct windows" \
    "2" "$_key_count"

# A map element is part of the identity too — parallel members share a stage.
write_boundary_mark "$_KEY_SF" "stage-alpha" "element-1"
write_boundary_mark "$_KEY_SF" "stage-alpha" "element-2"
_key_count2="$(find "$_KEY_JOB/runtime" -maxdepth 1 -name 'write-boundary*.marker' | wc -l | tr -d ' ')"
assert_eq "[SPEC-6] map elements of one stage get their own windows" \
    "4" "$_key_count2"

# SPEC-7: the sibling's mark must not move this dispatch's window. Compared by
# mtime, which is the property the sweep actually depends on.
_alpha_marker="$(_wb_marker_path "$_KEY_JOB" "stage-alpha" "" 2>/dev/null || true)"
# NON-VACUITY: with no keying the path resolves to nothing, both stat calls fail,
# and the comparison below is "" == "" — a pass that proves nothing.
assert_file_exists "[SPEC-7] the keyed window this dispatch owns exists" "$_alpha_marker"
_alpha_before="$(python3 -c "import os,sys;print(os.stat(sys.argv[1]).st_mtime_ns)" "$_alpha_marker" 2>/dev/null || echo none)"
assert_eq "[SPEC-7] that window has a readable timestamp to compare" \
    "0" "$([[ "$_alpha_before" == none ]] && echo 1 || echo 0)"
write_boundary_mark "$_KEY_SF" "stage-beta" ""
write_boundary_mark "$_KEY_SF" "stage-alpha" "element-9"
_alpha_after="$(python3 -c "import os,sys;print(os.stat(sys.argv[1]).st_mtime_ns)" "$_alpha_marker" 2>/dev/null || echo none)"
assert_eq "[SPEC-7] a sibling dispatch does not move this dispatch's window" \
    "$_alpha_before" "$_alpha_after"

# SPEC-8 guard: keying must not cost detection on the ordinary single dispatch.
# Covered end-to-end by SPEC-1 above; pinned here at the reader/writer seam so a
# mark/check key mismatch cannot pass silently.
_KEY_SF2="$TEST_TEMP_DIR/state/runs/keyed2/pipeline-state.json"
mkdir -p "$(dirname "$_KEY_SF2")/runtime" "$(dirname "$_KEY_SF2")/artifacts"
echo '{}' > "$_KEY_SF2"
write_boundary_mark "$_KEY_SF2" "solo-stage" ""
assert_file_exists "[SPEC-8] mark and check agree on the keyed marker path" \
    "$(_wb_marker_path "$(dirname "$_KEY_SF2")" "solo-stage" "")"

# GUARD: a marker left by an older engine (unkeyed name) must still be swept
# rather than silently skipped mid-upgrade.
_LEG_JOB="$TEST_TEMP_DIR/state/runs/legacy"
mkdir -p "$_LEG_JOB/runtime" "$_LEG_JOB/artifacts"
_LEG_SF="$_LEG_JOB/pipeline-state.json"; echo '{}' > "$_LEG_SF"
touch "$_LEG_JOB/runtime/write-boundary.marker"
_wb_clock_advance_past "$_LEG_JOB/runtime/write-boundary.marker"
touch "$WATCH_DIR/legacy-marker-probe.txt"
_leg_rc=0
write_boundary_check "$FIXTURE_DIR" "$_LEG_SF" "legacy-stage" "" >/dev/null 2>&1 || _leg_rc=$?
assert_eq "[SPEC-8] an unkeyed marker from an older engine is still honoured" \
    "1" "$_leg_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
