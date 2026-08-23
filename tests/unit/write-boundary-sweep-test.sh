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

# ...and that it NAMES the offending path. Only the marker's existence is
# load-bearing for verdict.sh, so nothing else would notice this regressing to a
# bare `touch` — but the disposition is `broken`, which is terminal, so the
# marker body is the operator's only surviving evidence of WHICH path halted the
# run. Asserting existence alone left that diagnostic unprotected.
_marker_body="$(cat "$JOB_DIR/runtime/write-boundary-violated" 2>/dev/null || true)"
assert_contains "[SPEC-1] the marker names the offending path" \
    "$_marker_body" "$WATCH_DIR/forbidden-file.txt"

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

# The event must carry the offending path, not just the event name. Counting the
# name alone let the `path=` argument be dropped from emit_event without any test
# reddening — the event stream is the durable record of a halt, and a violation
# that names no path leaves an operator nothing to act on.
_ev_with_path=""
for _ev in "${_WB_EVENTS[@]}"; do
    [[ "$_ev" == *"stage.write_boundary.violated"* ]] && _ev_with_path="$_ev"
done
assert_contains "[SPEC-1] the violation event carries path= naming the offending file" \
    "$_ev_with_path" "path=$WATCH_DIR/forbidden-file.txt"

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

# ─── SPEC-4b: a symlinked allow root still matches (macOS /var → /private/var) ─
# The allow roots arrive already canonicalised — git rev-parse --show-toplevel
# returns /private/... on macOS — while sweep candidates come back through the
# logical /var path. Canonicalising with bare `pwd` leaves the two disagreeing,
# so every in-place dispatch reports a false violation (caught by
# tests/integration/worktree-run-isolation-test.sh SPEC-6). Both sides must
# resolve symlinks.
# CHANGE: fails at baseline (the classifier used `pwd`, not `pwd -P`).

_SYM_REAL="$TEST_TEMP_DIR/real-root"
_SYM_LINK="$TEST_TEMP_DIR/linked-root"
mkdir -p "$_SYM_REAL/sub"
ln -sfn "$_SYM_REAL" "$_SYM_LINK"
printf 'x\n' > "$_SYM_REAL/sub/written.txt"

# Allow the REAL path; classify the candidate reached through the SYMLINK.
_cls_sym="$(ZBUILD_WRITE_BOUNDARY_ALLOW="" ZBUILD_REPO_ROOT="$_SYM_REAL" \
    write_boundary_classify "$_SYM_LINK/sub/written.txt" "$JOB_DIR" "" 2>/dev/null)"
assert_eq "[SPEC-4b] symlinked candidate matches a canonical allow root" \
    "allowed" "$_cls_sym"

# ─── SPEC-4c: a directory CONTAINING an allowed root is not a violation ──────
# A directory's mtime changes when a child is created inside it, so a directory
# entry can surface as "changed" because of activity that is entirely legitimate
# — the state dir's own PARENT does exactly that whenever the state dir lives
# under a watched root. write_boundary_sweep no longer surfaces directories at
# all (`-type f`), so this arm is now reached only by a direct call like the one
# below; it stays because write_boundary_classify is a public entry point and
# must classify a directory candidate correctly on its own terms.
# (Caught by CI: all three ubuntu jobs red, all macOS green, because on macOS the
# test temp sits under $TMPDIR, which ADR-058 §3 redirects to scratch mid-dispatch
# and so is never swept.)
# CHANGE: fails at baseline (the classifier tested only "candidate under root").

_ANC_STATE="$TEST_TEMP_DIR/anc/state"
mkdir -p "$_ANC_STATE"
_cls_anc="$(write_boundary_classify "$TEST_TEMP_DIR/anc" "$_ANC_STATE" "" 2>/dev/null)"
assert_eq "[SPEC-4c] a directory containing the state dir classifies as allowed" \
    "allowed" "$_cls_anc"

# GUARD: the ancestor arm must not become a blanket pass. A stray directory that
# holds no allowed root is still a violation.
_STRAY="$TEST_TEMP_DIR/stray-dir"
mkdir -p "$_STRAY"
_cls_stray="$(ZBUILD_REPO_ROOT="$_ANC_STATE" write_boundary_classify "$_STRAY" "$_ANC_STATE" "" 2>/dev/null)"
assert_eq "[SPEC-4c] a stray directory holding no allowed root is still a violation" \
    "violation" "$_cls_stray"

# ─── SPEC-4d: the engine's own event log is not a stage violation ───────────
# With no events path pinned, core/event-bus/event-bus.sh falls back to an
# ephemeral per-process dir under $TMPDIR — which is /tmp on Linux, where TMPDIR
# is unset. That is inside a watched root, so every emit_event during a dispatch
# looked like the stage writing out of bounds. Caught by CI (ubuntu red, macOS
# green) once the violation started naming the path it flagged.
# CHANGE: fails at baseline (the event-bus files were not engine-owned roots).

_EV_DIR="$TEST_TEMP_DIR/ephemeral-events"
mkdir -p "$_EV_DIR"
printf '{}\n' > "$_EV_DIR/events.jsonl"
_cls_ev="$(ZBUILD_EVENTS_DIR="$_EV_DIR" \
    write_boundary_classify "$_EV_DIR/events.jsonl" "$JOB_DIR" "" 2>/dev/null)"
assert_eq "[SPEC-4d] the engine's own event log classifies as allowed" \
    "allowed" "$_cls_ev"

# A pinned JSONL with no dir set must allow its parent too — that is the shape
# the test harness uses (it pins only ZBUILD_EVENTS_JSONL).
_cls_ev2="$(ZBUILD_EVENTS_JSONL="$_EV_DIR/events.jsonl" \
    write_boundary_classify "$_EV_DIR/events.jsonl" "$JOB_DIR" "" 2>/dev/null)"
assert_eq "[SPEC-4d] a pinned events JSONL allows its own directory" \
    "allowed" "$_cls_ev2"

# ─── SPEC-4e: every zbuild_engine_tmpdir caller can actually see it ─────────
# The helper lives in scripts/lib/helpers.sh. A file that calls it without
# sourcing helpers gets an UNDEFINED function, and `$(undefined)` in a path
# expands to the empty string rather than failing — producing `/zbuild-x.XXXX`,
# a write at the filesystem root. That is silent and only shows up as a
# "Read-only file system" mktemp error at runtime, which is how it reached CI.
# A static check is the cheap guard.

_bad_callers=""
while IFS= read -r _f; do
    [[ -z "$_f" ]] && continue
    [[ "$_f" == *"scripts/lib/helpers.sh" ]] && continue   # the definition itself
    grep -q "helpers.sh" "$_f" || _bad_callers="${_bad_callers}${_f} "
done < <(grep -rl "zbuild_engine_tmpdir" "$REPO_ROOT/core" "$REPO_ROOT/scripts" 2>/dev/null || true)

if [[ -z "$_bad_callers" ]]; then
    assert_pass "[SPEC-4e] every zbuild_engine_tmpdir caller sources helpers.sh"
else
    assert_fail "[SPEC-4e] a zbuild_engine_tmpdir caller does not source helpers.sh" \
        "callers missing the source: $_bad_callers"
fi

# ─── SPEC-4f: ZBUILD_WRITE_BOUNDARY_LOG captures the violation ──────────────
# Most integration tests send the runner's stderr to /dev/null, so a halt there
# reports rc=1 and nothing else. The sink is the channel that survives that.
# CHANGE: fails at baseline (the variable is not read).

_wb_log="$TEST_TEMP_DIR/wb-violations.log"
: > "$_wb_log"
rm -f "$JOB_DIR/runtime/write-boundary-violated"
write_boundary_mark "$STATE_FILE"
touch "$WATCH_DIR/sink-probe.txt"
ZBUILD_WRITE_BOUNDARY_LOG="$_wb_log" \
    write_boundary_check "$FIXTURE_DIR" "$STATE_FILE" "sink-stage" "" >/dev/null 2>&1 || true
assert_contains "[SPEC-4f] the violation log names the stage and the path" \
    "$(cat "$_wb_log" 2>/dev/null || true)" "stage=sink-stage"

# GUARD: unset variable writes nothing anywhere — a diagnostic must not change
# behaviour, and must not create files of its own.
_wb_log2="$TEST_TEMP_DIR/wb-violations-2.log"
rm -f "$JOB_DIR/runtime/write-boundary-violated"
write_boundary_mark "$STATE_FILE"
touch "$WATCH_DIR/sink-probe-2.txt"
write_boundary_check "$FIXTURE_DIR" "$STATE_FILE" "sink-stage" "" >/dev/null 2>&1 || true
if [[ ! -e "$_wb_log2" ]]; then
    assert_pass "[SPEC-4f] no sink file is created when the variable is unset"
else
    assert_fail "[SPEC-4f] no sink file is created when the variable is unset" \
        "unexpected: $_wb_log2"
fi

# ─── SPEC-4g: the system temp is swept only when TMPDIR was redirected ──────
# ADR-058 §3 points TMPDIR at the per-stage scratch dir for the span of a
# dispatch. Only then is a file in the system temp attributable to a stage:
# where the redirect is not in effect, the engine's own temps (template merge,
# redaction buffers, router captures) land there legitimately, as does anything
# else running on the box. Sweeping it then halts runs on the engine doing its
# job — observed on ubuntu CI as stage=intake path=/tmp/zb-route-redact-out.*
# CHANGE: fails at baseline (the roots were swept unconditionally).

# Against the SHIPPED config, not this file's canary override — the system-temp
# roots only exist in the default list.
_wl_off="$(unset ZBUILD_WRITE_BOUNDARY_WATCH; write_boundary_watch_list)"
if grep -qE '^(/tmp|/private/tmp)( |$)' <<< "$_wl_off"; then
    assert_fail "[SPEC-4g] system temp is NOT swept when ZBUILD_STAGE_SCRATCH is unset" \
        "watch list still contains a system-temp root: $_wl_off"
else
    assert_pass "[SPEC-4g] system temp is NOT swept when ZBUILD_STAGE_SCRATCH is unset"
fi

_wl_on="$(unset ZBUILD_WRITE_BOUNDARY_WATCH; ZBUILD_STAGE_SCRATCH="$TEST_TEMP_DIR" write_boundary_watch_list)"
if grep -qE '^(/tmp|/private/tmp)( |$)' <<< "$_wl_on"; then
    assert_pass "[SPEC-4g] system temp IS swept once the redirect is in effect"
else
    assert_fail "[SPEC-4g] system temp IS swept once the redirect is in effect" \
        "watch list: $_wl_on"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
