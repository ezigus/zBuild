#!/usr/bin/env bash
# tests/unit/write-boundary-sweep-test.sh
# Unit tests for core/pipeline/write-boundary.sh (#1809, ADR-058 C9).
#
# SPEC-1[change]: (ADR-058 C12) a write in a watched SHARED place is recorded —
#                 stderr, the log sink, stage.write_boundary.unattributable
#                 reason=shared_location — and write_boundary_check returns 0;
#                 SPEC-1b: a stage that does not declare writes_repository and
#                 changes the run's own worktree returns 1, and the marker and
#                 the violated event name the path.
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

# ── SPEC-1[change]: write to a watched shared place → recorded, rc=0 ─────────
# ADR-058 C12: `find -newer` knows when, never who, and every watched place is
# shared with other processes — so a hit there can never be attributed to the
# dispatching stage (#1845: a nested build blamed for another test's
# cost-ledger lock).
_WB_EVENTS=()
rm -f "$JOB_DIR/runtime/write-boundary.marker" "$JOB_DIR/runtime/write-boundary-violated"
write_boundary_mark "$STATE_FILE"
touch "$WATCH_DIR/forbidden-file.txt"
_viol_rc=0
# stderr to a file, not $( ): a subshell would drop the _WB_EVENTS it appends.
write_boundary_check "$FIXTURE_DIR" "$STATE_FILE" "my-stage" "" 2>"$TEST_TEMP_DIR/spec1.err" >/dev/null || _viol_rc=$?
_viol_err="$(cat "$TEST_TEMP_DIR/spec1.err" 2>/dev/null || true)"
assert_eq "[SPEC-1] a shared-place write does not fail the dispatch" "0" "$_viol_rc"
assert_eq "[SPEC-1] no write-boundary-violated marker for it" \
    "0" "$([[ -f "$JOB_DIR/runtime/write-boundary-violated" ]] && echo 1 || echo 0)"
assert_contains "[SPEC-1] stderr still names the path" "$_viol_err" "$WATCH_DIR/forbidden-file.txt"
_ev_sh=""
for _ev in "${_WB_EVENTS[@]}"; do
    [[ "$_ev" == *"stage.write_boundary.unattributable"* ]] && _ev_sh="$_ev"
done
assert_contains "[SPEC-1] the event carries the path" "$_ev_sh" "path=$WATCH_DIR/forbidden-file.txt"
assert_contains "[SPEC-1] ...and says it was a shared location" "$_ev_sh" "reason=shared_location"

# ── SPEC-1b[change]: the run's own worktree changed by a non-writer → rc=1 ────
# The one place a write can be attributed: ADR-059's issue lock makes the
# worktree the run's alone, and git records exactly what changed.
WB_WT="$TEST_TEMP_DIR/wb-worktree"
mkdir -p "$WB_WT"
git -C "$WB_WT" init -q
printf 'a\n' > "$WB_WT/code.txt"
git -C "$WB_WT" add -A
git -C "$WB_WT" -c user.name=t -c user.email=t@t commit -q -m base
export ZBUILD_REPO_ROOT="$WB_WT"
_WB_EVENTS=()
rm -f "$JOB_DIR/runtime/write-boundary.marker" "$JOB_DIR/runtime/write-boundary-violated"
write_boundary_mark "$STATE_FILE"
printf 'b\n' > "$WB_WT/code.txt"
_repo_rc=0
write_boundary_check "$FIXTURE_DIR" "$STATE_FILE" "my-stage" "" 2>/dev/null || _repo_rc=$?
assert_eq "[SPEC-1b] a non-writer changing the worktree fails the dispatch" "1" "$_repo_rc"
# First offence: put back and retried, so the per-stage undo marker — not the
# halting one — is written, and its body names the path.
assert_file_exists "[SPEC-1b] the undo marker is created in runtime/" \
    "$JOB_DIR/runtime/write-boundary-reverted.my-stage"
assert_contains "[SPEC-1b] the marker names the offending path" \
    "$(cat "$JOB_DIR/runtime/write-boundary-reverted.my-stage" 2>/dev/null || true)" "$WB_WT/code.txt"
_ev_with_path=""
for _ev in "${_WB_EVENTS[@]}"; do
    [[ "$_ev" == *"stage.write_boundary.violated"* ]] && _ev_with_path="$_ev"
done
assert_contains "[SPEC-1b] the violation event carries path= naming the offending file" \
    "$_ev_with_path" "path=$WB_WT/code.txt"
git -C "$WB_WT" checkout -q -- code.txt
unset ZBUILD_REPO_ROOT

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

# The allow list must derive ~/.zbuild the SAME WAY the writer does. The bus's
# unpinned default is
#   ${ZBUILD_DATA_ROOT:-${ZBUILD_STATE_ROOT:-$HOME/.zbuild}}/ephemeral-events/$$
# (core/event-bus/event-bus.sh), i.e. it FOLLOWS ZBUILD_STATE_ROOT — while
# write_boundary_allow_list emitted a hardcoded "$HOME/.zbuild". Those agree
# only while nobody redirects the root, and plugins/tool/test/plugin.sh
# redirects it on purpose (ZBUILD_STATE_ROOT="$tmp/.zbuild-nested-state") to
# fence a nested run. The moment they diverge, the engine's own event log
# becomes a stage violation again — the exact defect SPEC-4d above closed for
# the unredirected case.
# CHANGE: fails at baseline (allow list names only $HOME/.zbuild).
_ALT_ROOT="$TEST_TEMP_DIR/alt-state-root"
_ALT_EV="$_ALT_ROOT/ephemeral-events/$$"
mkdir -p "$_ALT_EV"
printf '{}\n' > "$_ALT_EV/events.jsonl"
_cls_alt="$(ZBUILD_STATE_ROOT="$_ALT_ROOT" \
    write_boundary_classify "$_ALT_EV/events.jsonl" "$JOB_DIR" "" 2>/dev/null)"
assert_eq "[SPEC-4d] a redirected ZBUILD_STATE_ROOT still allows the engine's own event log" \
    "allowed" "$_cls_alt"

_DATA_ROOT="$TEST_TEMP_DIR/alt-data-root"
_DATA_EV="$_DATA_ROOT/ephemeral-events/$$"
mkdir -p "$_DATA_EV"
printf '{}\n' > "$_DATA_EV/events.jsonl"
_cls_data="$(ZBUILD_DATA_ROOT="$_DATA_ROOT" \
    write_boundary_classify "$_DATA_EV/events.jsonl" "$JOB_DIR" "" 2>/dev/null)"
assert_eq "[SPEC-4d] a redirected ZBUILD_DATA_ROOT still allows the engine's own event log" \
    "allowed" "$_cls_data"

# ─── SPEC-4f: ZBUILD_WRITE_BOUNDARY_LOG captures what the sweep saw ─────────
# Most integration tests send the runner's stderr to /dev/null, so the sink is
# the channel that survives. Since ADR-058 C12 a shared-place hit is recorded
# as `unattributable` (never a violation); the sink carries it all the same.
# CHANGE: fails at baseline (the variable is not read).

_wb_log="$TEST_TEMP_DIR/wb-sink.log"
: > "$_wb_log"
rm -f "$JOB_DIR/runtime/write-boundary-violated"
write_boundary_mark "$STATE_FILE"
touch "$WATCH_DIR/sink-probe.txt"
ZBUILD_WRITE_BOUNDARY_LOG="$_wb_log" \
    write_boundary_check "$FIXTURE_DIR" "$STATE_FILE" "sink-stage" "" >/dev/null 2>&1 || true
_wb_log_body="$(cat "$_wb_log" 2>/dev/null || true)"
assert_contains "[SPEC-4f] the log names the stage" \
    "$_wb_log_body" "stage=sink-stage"
# The path is the whole reason the sink exists — asserting only the stage let the
# `path=%s` half of the format string be dropped without reddening anything.
assert_contains "[SPEC-4f] the log names the path the sweep saw" \
    "$_wb_log_body" "path=$WATCH_DIR/sink-probe.txt"

# GUARD: unset variable writes nothing anywhere — a diagnostic must not change
# behaviour, and must not create files of its own.
_wb_log2="$TEST_TEMP_DIR/wb-sink-2.log"
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

# ─── SPEC-4h: a candidate written by a DEMONSTRABLY live external process ────
# does not halt the dispatch.
#
# The sweep is `find <roots> -newer <marker> -type f`. mtime carries no
# authorship, so any file appearing in a watched root during the window is
# attributed to whichever stage happens to be dispatching. Reproduced against
# the real parity fixture: a bare `touch` loop in an unrelated process got
# hydrate, release and persist each reported for files they never wrote, and
# the run ended status=interrupted.
#
# ADR-058 C9 already conceded this for DIRECTORIES ("any concurrent process can
# kill a run") and fixed that half with -type f. This is the same argument for
# the file half.
#
# The fix is NOT to stop watching: a stage's own writer is dead by the time
# write_boundary_check runs (the dispatch subshell has returned), so continued
# activity in the root after the dispatch is positive evidence of somebody
# else. That makes the candidate unattributable rather than innocent — it is
# still recorded on all three channels, it just cannot resolve the stage to
# `broken` on evidence that does not identify it.
_WB_EVENTS=()
rm -f "$JOB_DIR/runtime/write-boundary.marker" "$JOB_DIR/runtime/write-boundary-violated"
write_boundary_mark "$STATE_FILE"
touch "$WATCH_DIR/concurrent-victim.txt"

# An external writer that keeps going THROUGH the settle window.
( for _i in $(seq 1 200); do touch "$WATCH_DIR/.ext-$_i" 2>/dev/null; sleep 0.02; done ) &
_ext_pid=$!
# Synchronise before checking. Starting the subprocess does not mean it has been
# scheduled: if its first touch lands after the settle window closes, the probe
# finds no witness, reports the candidate as a genuine violation, and this test
# fails for a reason that has nothing to do with the code under test. That is
# precisely the flaky-on-a-loaded-runner class this PR exists to stop blaming on
# the wrong thing.
_sync_n=0
while [[ ! -e "$WATCH_DIR/.ext-1" && $_sync_n -lt 500 ]]; do
    sleep 0.01; _sync_n=$((_sync_n + 1))
done
assert_eq "[SPEC-4h] the external writer is demonstrably running before the check" \
    "1" "$([[ -e "$WATCH_DIR/.ext-1" ]] && echo 1 || echo 0)"
_unattr_rc=0
write_boundary_check "$FIXTURE_DIR" "$STATE_FILE" "victim-stage" "" 2>/dev/null || _unattr_rc=$?
kill "$_ext_pid" 2>/dev/null || true
wait "$_ext_pid" 2>/dev/null || true

assert_eq "[SPEC-4h] a candidate racing a live external writer does not fail the dispatch" \
    "0" "$_unattr_rc"
assert_eq "[SPEC-4h] no write-boundary-violated marker is written for an unattributable candidate" \
    "0" "$([[ -f "$JOB_DIR/runtime/write-boundary-violated" ]] && echo 1 || echo 0)"
_unattr_ev=0
for _e in "${_WB_EVENTS[@]:-}"; do
    case "$_e" in *unattributable*) _unattr_ev=1 ;; esac
done
assert_eq "[SPEC-4h] the unattributable candidate is still recorded as an event" \
    "1" "$_unattr_ev"

# ─── SPEC-4i: GUARD — the fence is moved, not disarmed ──────────────────────
# SPEC-4h's shared-place hit and this one both pass (C12: timing never decides),
# but a change to the run's own worktree by a non-writer still halts with no
# concurrent writer anywhere. If this goes red the fence has been disarmed.
rm -f "$WATCH_DIR"/.ext-* 2>/dev/null || true
export ZBUILD_REPO_ROOT="$WB_WT"
_WB_EVENTS=()
rm -f "$JOB_DIR/runtime/write-boundary.marker" "$JOB_DIR/runtime/write-boundary-violated"
write_boundary_mark "$STATE_FILE"
touch "$WATCH_DIR/genuine-shared.txt"
printf 'stray\n' > "$WB_WT/genuine-violation.txt"
_genuine_rc=0
write_boundary_check "$FIXTURE_DIR" "$STATE_FILE" "guilty-stage" "" 2>/dev/null || _genuine_rc=$?
assert_eq "[SPEC-4i] GUARD: a worktree write by a non-writer still fails the dispatch" \
    "1" "$_genuine_rc"
assert_contains "[SPEC-4i] GUARD: and the marker names the worktree file, not the shared one" \
    "$(cat "$JOB_DIR/runtime/write-boundary-reverted.guilty-stage" 2>/dev/null || true)" "genuine-violation.txt"
rm -f "$WB_WT/genuine-violation.txt"
unset ZBUILD_REPO_ROOT

cleanup_test_env
print_test_results
exit $((FAIL > 0))
