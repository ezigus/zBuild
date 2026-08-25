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
_wb_log_body="$(cat "$_wb_log" 2>/dev/null || true)"
assert_contains "[SPEC-4f] the violation log names the stage" \
    "$_wb_log_body" "stage=sink-stage"
# The path is the whole reason the sink exists — asserting only the stage let the
# `path=%s` half of the format string be dropped without reddening anything.
assert_contains "[SPEC-4f] the violation log names the offending path" \
    "$_wb_log_body" "path=$WATCH_DIR/sink-probe.txt"

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

# ─── SPEC-4g: the shipped default does not sweep the system temp ────────────
# scripts/lib/env-scrub.sh wipes every ZBUILD_* before a model spawn, so engine
# code in a spawned child cannot see ZBUILD_STAGE_SCRATCH and its temps land in
# the system temp. Those are the ENGINE's writes, not the swept stage's, and
# halting on them kills runs on the engine doing its job — ubuntu CI showed
# stage=intake path=/tmp/zb-route-redact-out.*, stage=test path=/tmp/zb-numstat.*
# (the latter from the INSTALLED engine, in a nested run). Coverage returns with
# a run-scoped TMPDIR, which is C10 (#1919). An operator can opt back in via the
# override file.
# CHANGE: fails at baseline (the shipped list carried both roots).

_wl_default="$(unset ZBUILD_WRITE_BOUNDARY_WATCH; write_boundary_watch_list)"
# Exact roots only. $HOME is redirected under the system temp in this harness,
# so a prefix match would flag the (legitimate) $HOME entry.
_sys_tmp_root="${TMPDIR:-/tmp}"; _sys_tmp_root="${_sys_tmp_root%/}"
if awk -v a="/tmp" -v b="$_sys_tmp_root" \
     '{p=$1} p==a||p==b{found=1} END{exit !found}' <<< "$_wl_default"; then
    assert_fail "[SPEC-4g] the shipped watch list does not carry a system-temp root" \
        "watch list: $_wl_default"
else
    assert_pass "[SPEC-4g] the shipped watch list does not carry a system-temp root"
fi

# GUARD: the roots an operator CAN attribute are still swept.
for _need in "$HOME" "$PWD"; do
    if grep -qF "$_need" <<< "$_wl_default"; then
        assert_pass "[SPEC-4g] the shipped watch list still covers $_need"
    else
        assert_fail "[SPEC-4g] the shipped watch list still covers $_need" \
            "watch list: $_wl_default"
    fi
done

# ─── SPEC-1: the Claude CLI's own state file is not a stage violation ────────
# ~/.claude.json is the CLI's global state file — project/session history,
# onboarding flags, MCP config. The `claude` process the engine spawns rewrites
# it on EVERY dispatch, with zero tool use required (measured on CLI 2.1.241: a
# `claude -p` run in an empty dir with no tools rewrote it). That is the engine's
# own tool doing bookkeeping, not the stage writing out of bounds — the same
# class already exempted for the event bus in SPEC-4d above.
#
# #1809 allowed the DIRECTORY ~/.claude. The state file is a SIBLING of that
# directory, sitting directly in $HOME, which the shipped watch list sweeps at
# maxdepth:1 — so every LLM stage halted with disposition=broken. $HOME is
# sandboxed under the test temp here, and the SHIPPED allow list is loaded
# additively on every call, so this exercises the entry an operator gets.
# CHANGE: fails at baseline (the entry covered the directory, not the file).

_CLI_STATE="$HOME/.claude.json"
mkdir -p "$HOME"
printf '{}\n' > "$_CLI_STATE"
_cls_cli="$(write_boundary_classify "$_CLI_STATE" "$JOB_DIR" "" 2>/dev/null)"
assert_eq "[SPEC-1] the Claude CLI's own top-level state file classifies as allowed" \
    "allowed" "$_cls_cli"

# ─── SPEC-2: a glob allow entry covers the whole backup family ──────────────
# The backups are timestamped and unbounded (.claude.json.backup-20251221-084359),
# so no exact entry can name them. They are written rarely — migration or repair
# — but the disposition is `broken`, terminal, so one landing mid-run kills it
# with no retry. The matcher did root/root-slash-star only, no globs.
# CHANGE: fails at baseline (allow entries were matched literally).

_CLI_BAK="$HOME/.claude.json.backup-20251221-084359"
printf '{}\n' > "$_CLI_BAK"
_cls_bak="$(write_boundary_classify "$_CLI_BAK" "$JOB_DIR" "" 2>/dev/null)"
assert_eq "[SPEC-2] a timestamped backup in the same family classifies as allowed" \
    "allowed" "$_cls_bak"

# GUARD (SPEC-4): the glob arm must not become a blanket pass. An unrelated file
# at the same depth, under the same watched root, is still a violation.
_HOME_STRAY="$HOME/stray-note.txt"
printf 'x\n' > "$_HOME_STRAY"
_cls_hstray="$(write_boundary_classify "$_HOME_STRAY" "$JOB_DIR" "" 2>/dev/null)"
assert_eq "[SPEC-4] an unrelated file at the same depth is still a violation" \
    "violation" "$_cls_hstray"

# Both readings of where CLAUDE_CONFIG_DIR puts the state file are covered, and
# neither was exercised before — the suite only ever ran with the variable
# unset, so a home-relative-only entry and a config-dir-only entry were
# indistinguishable (claude-review flagged the gap on PR #1953).
_CCD="$TEST_TEMP_DIR/custom-claude-config"
mkdir -p "$_CCD"
printf '{}\n' > "$_CCD/.claude.json"
_cls_ccd="$(CLAUDE_CONFIG_DIR="$_CCD" \
    write_boundary_classify "$_CCD/.claude.json" "$JOB_DIR" "" 2>/dev/null)"
assert_eq "[SPEC-1] the state file under a custom CLAUDE_CONFIG_DIR classifies as allowed" \
    "allowed" "$_cls_ccd"

_cls_home_ccd="$(CLAUDE_CONFIG_DIR="$_CCD" \
    write_boundary_classify "$_CLI_STATE" "$JOB_DIR" "" 2>/dev/null)"
assert_eq "[SPEC-1] the home-relative state file stays allowed when CLAUDE_CONFIG_DIR is set" \
    "allowed" "$_cls_home_ccd"

# GUARD (SPEC-4): a glob entry names FILES, not roots. Without this, the glob
# arm reads `.claude.json*` as `.claude.json*/*` and a directory named to match
# — `.claude.json.evil/` — carries its whole subtree in with it. Raised by
# claude-review on PR #1953 and confirmed: the probe returned `allowed`.
_EVIL_DIR="$HOME/.claude.json.evil"
mkdir -p "$_EVIL_DIR"
printf 'x\n' > "$_EVIL_DIR/inside.txt"
_cls_evil="$(write_boundary_classify "$_EVIL_DIR/inside.txt" "$JOB_DIR" "" 2>/dev/null)"
assert_eq "[SPEC-4] a glob entry does not grant the subtree of a directory it matches" \
    "violation" "$_cls_evil"

# ─── SPEC-3: ${VAR:-default} expands generally, not per hardcoded token ─────
# The expander handled that form with one hardcoded string substitution PER
# TOKEN — two for CLAUDE_CONFIG_DIR, one for TMPDIR. Every new default form
# needed another, and a config line an operator writes with any other variable
# expanded to nothing at all.
# CHANGE: fails at baseline (only the three hardcoded tokens expanded).

_EXP_ALLOW="$TEST_TEMP_DIR/expand-allow.txt"
_EXP_DIR="$TEST_TEMP_DIR/expand-fallback"
mkdir -p "$_EXP_DIR"
printf 'x\n' > "$_EXP_DIR/written.txt"
unset ZB_WB_NO_SUCH_VAR 2>/dev/null || true
printf '${ZB_WB_NO_SUCH_VAR:-%s}\n' "$_EXP_DIR" > "$_EXP_ALLOW"
_cls_exp="$(ZBUILD_WRITE_BOUNDARY_ALLOW="$_EXP_ALLOW" \
    write_boundary_classify "$_EXP_DIR/written.txt" "$JOB_DIR" "" 2>/dev/null)"
assert_eq "[SPEC-3] an unset \${VAR:-default} falls back to the default" \
    "allowed" "$_cls_exp"

_EXP_SET="$TEST_TEMP_DIR/expand-set"
mkdir -p "$_EXP_SET"
printf 'x\n' > "$_EXP_SET/written.txt"
printf '${ZB_WB_SET_VAR:-%s}\n' "$_EXP_DIR" > "$_EXP_ALLOW"
_cls_exp2="$(ZB_WB_SET_VAR="$_EXP_SET" ZBUILD_WRITE_BOUNDARY_ALLOW="$_EXP_ALLOW" \
    write_boundary_classify "$_EXP_SET/written.txt" "$JOB_DIR" "" 2>/dev/null)"
assert_eq "[SPEC-3] a set \${VAR:-default} uses the variable, not the default" \
    "allowed" "$_cls_exp2"

# The nested shape already shipped in config/write-boundary-allow.txt —
# ${CLAUDE_CONFIG_DIR:-${HOME}/.claude} — must survive the generalisation. Plain
# references expand innermost-first so the default is brace-free by the time the
# defaulted form is matched.
_NEST_ALLOW="$TEST_TEMP_DIR/expand-nested.txt"
printf '${ZB_WB_NO_SUCH_VAR:-${TEST_TEMP_DIR}/expand-fallback}\n' > "$_NEST_ALLOW"
_cls_nest="$(ZBUILD_WRITE_BOUNDARY_ALLOW="$_NEST_ALLOW" \
    write_boundary_classify "$_EXP_DIR/written.txt" "$JOB_DIR" "" 2>/dev/null)"
assert_eq "[SPEC-3] a nested \${VAR} inside a default expands too" \
    "allowed" "$_cls_nest"

# GUARD: the per-token substitutions are gone. CLAUDE_CONFIG_DIR is config data;
# once the expander is general it has no business being named in engine code.
# Comment lines are exempt: the expander's own comment cites the nested shape it
# has to keep handling, and naming it there is documentation, not a code path.
_hardcoded="$(grep -n 'CLAUDE_CONFIG_DIR' "$WB_LIB" | grep -v '^[0-9]*: *#' || true)"
if [[ -n "$_hardcoded" ]]; then
    assert_fail "[SPEC-3] no per-token hardcoded expansion remains in the lib" \
        "$_hardcoded"
else
    assert_pass "[SPEC-3] no per-token hardcoded expansion remains in the lib"
fi
if grep -qF 'TMPDIR:-\/tmp' "$WB_LIB"; then
    assert_fail "[SPEC-3] no hardcoded TMPDIR substitution remains in the lib" \
        "$(grep -nF 'TMPDIR:-\/tmp' "$WB_LIB")"
else
    assert_pass "[SPEC-3] no hardcoded TMPDIR substitution remains in the lib"
fi

# ─── SPEC-1/2/3/4: a sweep that could not look must not report "clean" ──────
# `find … 2>/dev/null || true`, consumed through a command substitution,
# discarded the status twice and the stderr once. A sweep that FAILED and a
# sweep that found nothing were the same observation, and the fence reported a
# clean dispatch without having looked. Found while hunting the ubuntu-only
# SPEC-4 flake (#1953); true on every platform (#1956).
# CHANGE: fails at baseline (the failure was unobservable by construction).

_SW_ROOT="$TEST_TEMP_DIR/sweep-fail"
_SW_LOG="$TEST_TEMP_DIR/sweep-fail.log"
mkdir -p "$_SW_ROOT/readable" "$_SW_ROOT/locked"
_SW_MARKER="$TEST_TEMP_DIR/sweep-fail.marker"
touch "$_SW_MARKER"
# Both files are newer than the marker; one of them sits where find cannot look.
printf 'x\n' > "$_SW_ROOT/readable/seen.txt"
printf 'x\n' > "$_SW_ROOT/locked/unseen.txt"
_SW_WATCH="$TEST_TEMP_DIR/sweep-fail-watch.txt"
printf '%s\n' "$_SW_ROOT" > "$_SW_WATCH"
chmod 000 "$_SW_ROOT/locked"

_sw_out="$(ZBUILD_WRITE_BOUNDARY_WATCH="$_SW_WATCH" ZBUILD_WRITE_BOUNDARY_LOG="$_SW_LOG" \
    write_boundary_sweep "$_SW_MARKER" 2>"$TEST_TEMP_DIR/sweep-fail.err")"
_sw_err="$(cat "$TEST_TEMP_DIR/sweep-fail.err" 2>/dev/null || true)"
_sw_log="$(cat "$_SW_LOG" 2>/dev/null || true)"

assert_contains "[SPEC-1] a failed sweep says so on stderr, naming the path" \
    "$_sw_err" "$_SW_ROOT"
assert_contains "[SPEC-1] the stderr diagnostic carries find's exit status" \
    "$_sw_err" "rc="
assert_contains "[SPEC-1] the failure reaches the ZBUILD_WRITE_BOUNDARY_LOG sink" \
    "$_sw_log" "sweep_failed"

# SPEC-3 is the reason this is not fixed by failing closed. find returns
# non-zero on a PARTIAL error while still enumerating everything it could read,
# and on a real machine `find $HOME -maxdepth 1` hits permission-denied on other
# users' entries routinely. Treating rc!=0 as a violation would resolve nearly
# every dispatch to broken — terminal per verdict.sh:648-651. The defect is that
# the failure is invisible, not that it is tolerated.
assert_contains "[SPEC-3] a partial failure still yields the candidates find could read" \
    "$_sw_out" "$_SW_ROOT/readable/seen.txt"

chmod 755 "$_SW_ROOT/locked"

# GUARD: the diagnostic must not fire on a healthy sweep — a fence that cries
# wolf on every dispatch teaches an operator to ignore it.
: > "$_SW_LOG"
_sw_ok_err="$(ZBUILD_WRITE_BOUNDARY_WATCH="$_SW_WATCH" ZBUILD_WRITE_BOUNDARY_LOG="$_SW_LOG" \
    write_boundary_sweep "$_SW_MARKER" 2>&1 >/dev/null)"
assert_eq "[SPEC-1] a healthy sweep emits no failure diagnostic" "" "$_sw_ok_err"
assert_eq "[SPEC-1] a healthy sweep writes nothing to the sink" \
    "" "$(cat "$_SW_LOG" 2>/dev/null || true)"

# SPEC-2: the degraded fence is queryable in the durable event stream, not just
# in scrollback that most integration tests discard.
_WB_EVENTS=()
chmod 000 "$_SW_ROOT/locked"
ZBUILD_WRITE_BOUNDARY_WATCH="$_SW_WATCH" \
    write_boundary_sweep "$_SW_MARKER" >/dev/null 2>&1 || true
chmod 755 "$_SW_ROOT/locked"
_sw_ev=""
for _ev in "${_WB_EVENTS[@]}"; do
    [[ "$_ev" == *"stage.write_boundary.sweep_failed"* ]] && _sw_ev="$_ev"
done
assert_contains "[SPEC-2] a failed sweep emits stage.write_boundary.sweep_failed" \
    "$_sw_ev" "stage.write_boundary.sweep_failed"

if jq -e '.known_types | index("stage.write_boundary.sweep_failed")' \
     "$REPO_ROOT/config/event-schema.json" >/dev/null 2>&1; then
    assert_pass "[SPEC-2] the event type is registered in event-schema.json"
else
    assert_fail "[SPEC-2] the event type is registered in event-schema.json" \
        "stage.write_boundary.sweep_failed missing from known_types"
fi

# SPEC-4: a snapshot that was never taken must not read as a clean dispatch
# either — write_boundary_mark swallowed both its mkdir and its touch failure,
# and write_boundary_check returns 0 before sweeping when the marker is absent.
_MK_LOG="$TEST_TEMP_DIR/mark-fail.log"
_MK_BLOCKED="$TEST_TEMP_DIR/mark-blocked"
mkdir -p "$_MK_BLOCKED"
chmod 500 "$_MK_BLOCKED"
ZBUILD_WRITE_BOUNDARY_LOG="$_MK_LOG" \
    write_boundary_mark "$_MK_BLOCKED/pipeline-state.json" 2>"$TEST_TEMP_DIR/mark-fail.err" || true
chmod 755 "$_MK_BLOCKED"
_mk_err="$(cat "$TEST_TEMP_DIR/mark-fail.err" 2>/dev/null || true)$(cat "$_MK_LOG" 2>/dev/null || true)"
assert_contains "[SPEC-4] a snapshot that could not be taken is reported, not swallowed" \
    "$_mk_err" "mark"

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
_alpha_after="$(python3 -c "import os,sys;print(os.stat(sys.argv[1]).st_mtime_ns)" "$_alpha_marker")"
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
