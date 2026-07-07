#!/usr/bin/env bash
# Integration (#887): per-run state-directory isolation. Two concurrent
# `pipeline start` runs must NOT share a state dir / artifacts. Regression for
# dogfood run 20260614203820-82916 (#864), where a concurrent #846 run clobbered
# #864's plan.json because both defaulted to ~/.zbuild/state/.
#
# Contract:
#   T1: a default-state run roots state under $HOME/.zbuild/state/runs/<run_id>/.
#   T2: two runs with distinct run_ids land in distinct run dirs (no clobber).
#   T3: the `latest` symlink points at the most recent run.
#   T4: an explicit ZBUILD_STATE_DIR still wins (no runs/ re-root) — back-compat.
#   T5: the runner exports ZBUILD_EVENTS_DIR per-run (events don't interleave).
#   T7: --no-resume clears stale shared global-default event log + lock files.
#   T8: an engine run never writes to the shared global-default event log.
#   T9: an UNPINNED ad-hoc emit defaults to an ephemeral $TMPDIR dir, not global.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "per-run state isolation (#887)"
setup_test_env "per-run-state-isolation-887"
export ZBUILD_CONTRACT_VALIDATOR=warn

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
# #1149 (EPIC #1129 R2): the state-isolation contract is NOT stage-count
# dependent — it only needs the runner to start, root its state dir, and reach a
# build env-capture stage. Drive a MINIMAL two-leaf template (intake → build)
# instead of the full ~14-stage standard roster, which made each of T6's SIX
# subprocess runner invocations ~22s (~132s total). Under a loaded shared CI box
# (where the event-bus SQLite mirror can block up to busy_timeout=2000 per event,
# #1059 Class B) that cumulative cost drifted toward the 300s per-file harness
# timeout (scripts/run-tests.sh), whose gtimeout SIGTERM killed the runner
# mid-T6 → runner_rc=143. Fewer stages ⇒ far fewer event writes ⇒ each run drops
# to a few seconds, restoring a wide margin. Same fixture+mechanism as
# runner-exports-state-dir-test.sh (#1097 PC4) and resume-after-sigint-test.sh
# (#1098 PC5). Assertions are unchanged — only the per-invocation cost shrinks.
# #1270: install the fixture as a per-repo `.zbuild/templates/` overlay in a temp
# repo and run the runner with CWD = that repo (resolver reads from $PWD) rather
# than writing into the tracked config/templates/ (reaped by the master trap; no
# source-tree leak on interrupt).
OVERLAY_REPO="$(setup_git_temp_repo tpl-overlay-repo)"
install_template_overlay "$OVERLAY_REPO" runner-state-dir-minimal
# Two-leaf roster matching the minimal template: intake (first stage) + build
# (the env-capture stage T5/T6 overwrite below). build is overwritten per-test,
# so register it as a plain stub here only to satisfy registry resolution.
mock_plugin_factory "intake" "agent" 0 "" "" >/dev/null
mock_plugin_factory "build"  "agent" 0 "" "" >/dev/null

HOME_DIR="$TEST_TEMP_DIR/home"; mkdir -p "$HOME_DIR/.zbuild"

# run_pipeline <run_id> [extra env KEY=VAL ...] — default-state run under HOME_DIR.
run_pipeline() {
    local run_id="$1"; shift
    set +e
    # #1240: also scrub ZBUILD_STATE_ROOT — a default-state run must root under
    # $HOME/.zbuild/state/runs/<id>/. Nested inside the pipeline test stage the
    # #1127 sandbox exports ZBUILD_STATE_ROOT=<tmp>/.zbuild-nested-state; leaking
    # it in re-roots the runner off HOME and breaks the isolation assertions.
    # #1270: CWD = overlay repo so the resolver finds the fixture.
    ( cd "$OVERLAY_REPO" && env -u ZBUILD_STATE_DIR -u ZBUILD_STATE_ROOT -u ZBUILD_EVENTS_DIR -u ZBUILD_EVENTS_JSONL -u ZBUILD_STATE_FILE \
        ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
        ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
        ZBUILD_CYCLES_ENABLED=0 ZBUILD_CONTRACT_VALIDATOR=warn \
        ZBUILD_RUN_ID="$run_id" HOME="$HOME_DIR" PATH="$PATH" "$@" \
        bash "$RUNNER" --issue 887 --no-resume --template runner-state-dir-minimal ) >/dev/null 2>&1
    local rc=$?; set -e; return $rc
}

# ─── T1 + T2: two distinct runs isolate ─────────────────────────────────────
run_pipeline "run-aaa"; assert_eq "T1: run-aaa exits 0" "0" "$?"
run_pipeline "run-bbb"; assert_eq "T2: run-bbb exits 0" "0" "$?"
assert_file_exists "T1: run-aaa state under runs/run-aaa/" "$HOME_DIR/.zbuild/state/runs/run-aaa/pipeline-state.json"
assert_file_exists "T2: run-bbb state under runs/run-bbb/" "$HOME_DIR/.zbuild/state/runs/run-bbb/pipeline-state.json"
a_run="$(jq -r '.run_id' "$HOME_DIR/.zbuild/state/runs/run-aaa/pipeline-state.json" 2>/dev/null)"
b_run="$(jq -r '.run_id' "$HOME_DIR/.zbuild/state/runs/run-bbb/pipeline-state.json" 2>/dev/null)"
assert_eq "T2: run-aaa state has its own run_id (no clobber)" "run-aaa" "$a_run"
assert_eq "T2: run-bbb state has its own run_id (no clobber)" "run-bbb" "$b_run"

# ─── T3: latest → most recent run ───────────────────────────────────────────
if [[ -L "$HOME_DIR/.zbuild/state/latest" ]]; then
    latest_target="$(readlink "$HOME_DIR/.zbuild/state/latest")"
    case "$latest_target" in
        *"/runs/run-bbb") assert_pass "T3: latest → run-bbb (most recent)" ;;
        *) assert_fail "T3: latest should point at run-bbb" "got: $latest_target" ;;
    esac
else
    assert_fail "T3: latest symlink not created"
fi

# ─── T4: explicit ZBUILD_STATE_DIR still wins (no runs/ re-root) ─────────────
EXPLICIT="$TEST_TEMP_DIR/explicit-state"; mkdir -p "$EXPLICIT"
set +e
# #1240: scrub ambient ZBUILD_STATE_ROOT so the explicit-STATE_DIR-wins contract
# is asserted without an interfering fence (the #1127 sandbox sets it when nested).
( cd "$OVERLAY_REPO" && env -u ZBUILD_STATE_ROOT ZBUILD_STATE_DIR="$EXPLICIT" ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CYCLES_ENABLED=0 ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_RUN_ID="run-ccc" HOME="$HOME_DIR" PATH="$PATH" \
    bash "$RUNNER" --issue 887 --no-resume --template runner-state-dir-minimal ) >/dev/null 2>&1
rc=$?; set -e
assert_eq "T4: explicit-state run exits 0" "0" "$rc"
assert_file_exists "T4: explicit ZBUILD_STATE_DIR used verbatim (no runs/)" "$EXPLICIT/pipeline-state.json"
if [[ -d "$EXPLICIT/runs" ]]; then
    assert_fail "T4: explicit state dir must NOT get a runs/ subdir"
else
    assert_pass "T4: explicit state dir not re-rooted"
fi

# ─── T5: events captured per-run (a build stub captures ZBUILD_EVENTS_DIR) ──
ENVCAP="$TEST_TEMP_DIR/envcap.txt"
cat > "$PLUGINS_ROOT/agent/build/plugin.sh" <<EOF
build_run() { env | grep '^ZBUILD_EVENTS_DIR=' > "$ENVCAP" 2>/dev/null || true; return 0; }
EOF
run_pipeline "run-ddd"
ev="$(cat "$ENVCAP" 2>/dev/null || echo)"
case "$ev" in
    *"/runs/run-ddd"*) assert_pass "T5: ZBUILD_EVENTS_DIR is per-run (runs/run-ddd)" ;;
    *) assert_fail "T5: ZBUILD_EVENTS_DIR not per-run" "got: $ev" ;;
esac

# ─── T6: resume path (explicit STATE_FILE) → events still follow the per-run dir ─
# On `pipeline resume` the CLI sets ZBUILD_STATE_FILE to the run's per-run state
# file (so _state_is_default=false). Events must still follow that dir, not leak
# to the flat default (review finding #2).
RESUME_DIR="$HOME_DIR/.zbuild/state/runs/run-eee"; mkdir -p "$RESUME_DIR"
ENVCAP2="$TEST_TEMP_DIR/envcap2.txt"
cat > "$PLUGINS_ROOT/agent/build/plugin.sh" <<EOF
build_run() { env | grep '^ZBUILD_EVENTS_DIR=' > "$ENVCAP2" 2>/dev/null || true; return 0; }
EOF
set +e
# #1240: scrub ambient ZBUILD_STATE_ROOT (the #1127 nested-sandbox fence) so
# STATE_FILE-driven resolution isn't shadowed by an interfering state root.
( cd "$OVERLAY_REPO" && env -u ZBUILD_STATE_DIR -u ZBUILD_STATE_ROOT -u ZBUILD_EVENTS_DIR -u ZBUILD_EVENTS_JSONL -u ZBUILD_EVENTS_DB \
    ZBUILD_STATE_FILE="$RESUME_DIR/pipeline-state.json" \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CYCLES_ENABLED=0 ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_RUN_ID="run-eee" HOME="$HOME_DIR" PATH="$PATH" \
    bash "$RUNNER" --issue 887 --no-resume --template runner-state-dir-minimal ) >/dev/null 2>&1
t6_rc=$?; set -e
# macOS $TMPDIR is /var/folders (/var -> /private/var symlink), so a literal
# substring match on the captured ZBUILD_EVENTS_DIR can disagree with the
# expected RESUME_DIR. Canonicalize both via `pwd -P` before comparing, and
# keep the original `*/runs/run-eee*` substring as an accepted alternative.
# t6_rc is folded into the failure message so a future CI failure self-diagnoses
# (rc!=0 => runner exited early before the build stub; else => wrong dir).
ev2="$(cat "$ENVCAP2" 2>/dev/null || echo)"
ev2_dir="${ev2#ZBUILD_EVENTS_DIR=}"
ev2_canon="$(cd "$ev2_dir" 2>/dev/null && pwd -P || printf '%s' "$ev2_dir")"
resume_canon="$(cd "$RESUME_DIR" 2>/dev/null && pwd -P || printf '%s' "$RESUME_DIR")"
case "$ev2" in
    *"/runs/run-eee"*) assert_pass "T6: explicit STATE_FILE → events follow its dir (not flat)" ;;
    *)
        if [[ -n "$ev2_dir" && "$ev2_canon" == "$resume_canon" ]]; then
            assert_pass "T6: explicit STATE_FILE → events follow its dir (canonicalized)"
        else
            assert_fail "T6: events did not follow STATE_FILE dir" \
                "runner_rc=$t6_rc got=$ev2 (canon=$ev2_canon) expected=$resume_canon"
        fi
        ;;
esac

# ─── T7: --no-resume clears stale shared global-default event log + locks ────
# A killed/ad-hoc run can leave $HOME/.zbuild/state/events.jsonl(.lock) behind
# (a deferred TERM-trap never removes it); a stale lock would hang a later run's
# flock -w. --no-resume must clear them at startup (#run-hygiene).
GLOBAL_STATE="$HOME_DIR/.zbuild/state"
: > "$GLOBAL_STATE/events.jsonl"
: > "$GLOBAL_STATE/events.jsonl.lock"
: > "$GLOBAL_STATE/events.db.lock"
run_pipeline "run-hyg"; assert_eq "T7: run-hyg exits 0" "0" "$?"
if [[ -e "$GLOBAL_STATE/events.jsonl" || -e "$GLOBAL_STATE/events.jsonl.lock" \
      || -e "$GLOBAL_STATE/events.db.lock" ]]; then
    assert_fail "T7: --no-resume must clear stale global-default event log + locks" \
        "still present under $GLOBAL_STATE"
else
    assert_pass "T7: --no-resume cleared stale global-default event log + locks"
fi

# ─── T8: an engine run never writes to the shared global default event log ───
assert_file_exists "T8: run-hyg events under its per-run dir" \
    "$GLOBAL_STATE/runs/run-hyg/events.jsonl"
if [[ -e "$GLOBAL_STATE/events.jsonl" ]]; then
    assert_fail "T8: engine run must NOT recreate the shared global events.jsonl"
else
    assert_pass "T8: engine run kept events out of the shared global default"
fi

# ─── T9: an UNPINNED ad-hoc emit defaults to an ephemeral $TMPDIR dir ─────────
# Sourcing the event-bus directly (no ZBUILD_EVENTS_* pinned) must NOT append to
# the durable shared global default; it writes to $TMPDIR/zbuild-ephemeral-events.*.
EPHEMERAL_TMP="$TEST_TEMP_DIR/ephemeral-tmp"; mkdir -p "$EPHEMERAL_TMP"
rm -f "$GLOBAL_STATE/events.jsonl" 2>/dev/null || true
set +e
# #1240: scrub ZBUILD_STATE_ROOT too — event-bus.sh derives its default events dir
# from ${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}, so a leaked fence (from the #1127
# nested sandbox) would divert this unpinned emit away from the ephemeral $TMPDIR.
env -u ZBUILD_EVENTS_DIR -u ZBUILD_EVENTS_JSONL -u ZBUILD_EVENTS_DB -u ZBUILD_STATE_DIR -u ZBUILD_STATE_ROOT \
    HOME="$HOME_DIR" TMPDIR="$EPHEMERAL_TMP" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" PATH="$PATH" \
    bash -c 'source "'"$REPO_ROOT"'/core/event-bus/event-bus.sh"; eb_emit_event "pipeline.start" k=v' >/dev/null 2>&1
set -e
if compgen -G "$EPHEMERAL_TMP/zbuild-ephemeral-events.*/events.jsonl" >/dev/null; then
    assert_pass "T9: unpinned ad-hoc emit → ephemeral \$TMPDIR events dir"
else
    assert_fail "T9: unpinned ad-hoc emit should write to an ephemeral \$TMPDIR dir" \
        "no zbuild-ephemeral-events.* under $EPHEMERAL_TMP"
fi
if [[ -e "$GLOBAL_STATE/events.jsonl" ]]; then
    assert_fail "T9: unpinned ad-hoc emit must NOT touch the shared global default"
else
    assert_pass "T9: unpinned ad-hoc emit left the shared global default untouched"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
