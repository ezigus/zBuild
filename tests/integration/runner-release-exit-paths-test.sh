#!/usr/bin/env bash
# Integration test (#1829, ADR-054 §7): the runner dispatches cleanup(release)
# on EVERY exit path from a run — success, non-zero rc, the SIGINT propagation
# chain, an external SIGTERM, and an external timeout.
#
# This is the acceptance criterion the mechanism exists for: a stage's live
# resources must be freed however the run ends. A single missed exit path leaks
# whatever that stage spawned (#1748: suites observed alive 15+ min after exit).
#
# Why SIGINT is driven as rc=130 rather than `kill -INT`: this harness starts
# non-interactively with SIGINT inherited as SIG_IGN, and POSIX forbids a child
# from un-ignoring it — so `kill -INT` is silently dropped and the assertion
# would pass standalone while proving nothing. The repo's existing
# sigint-aborts-pipeline-test.sh drives the same chain the same way: the child
# returns 130, which is exactly what the kernel produces on Ctrl-C.
#
# Assertion in every case: the stub stages' cleanup hooks recorded `release`
# (and never `purge`) in the marker file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "runner dispatches cleanup(release) on every exit path (#1829)"
setup_test_env "runner-release-exit-paths"
export ZBUILD_CONTRACT_VALIDATOR=warn

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_CYCLES_ENABLED=0
mkdir -p "$PLUGINS_ROOT"

# The teardown plugin resolves its repo root by walking three levels up from
# its own directory (plugin-bootstrap), using a LOGICAL pwd — so symlinking the
# plugin itself would resolve to TEST_TEMP_DIR and fail to find helpers.sh.
# Give TEST_TEMP_DIR the shape of a repo root instead, then copy teardown in.
ln -s "$REPO_ROOT/scripts" "$TEST_TEMP_DIR/scripts"
ln -s "$REPO_ROOT/core"    "$TEST_TEMP_DIR/core"
mkdir -p "$PLUGINS_ROOT/tool"
cp -R "$REPO_ROOT/plugins/tool/teardown" "$PLUGINS_ROOT/tool/teardown"

mock_plugin_factory "intake" "agent" 0 >/dev/null
mock_plugin_factory "build"  "agent" 0 >/dev/null
mock_plugin_factory "test"   "tool"  0 >/dev/null

# Declare the optional cleanup hook — without it plugin_hook_call emits
# `plugin.cleanup.absent`, returns 0 (#1823: rc is binary), and the stage is a
# no-op rather than a witness.
# Re-emit the manifest rather than appending: `cleanup:` has to sit inside the
# contiguous `hooks:` block, and mock_plugin_factory already wrote `requires:`
# after it.
for _spec in "agent/intake:intake:intake_cleanup" "agent/build:build:build_cleanup" "tool/test:test:test_cleanup"; do
    _dir="${_spec%%:*}"; _rest="${_spec#*:}"; _id="${_rest%%:*}"; _fn="${_rest#*:}"
    _kind="${_dir%%/*}"
    cat > "$PLUGINS_ROOT/$_dir/manifest.yaml" <<EOF
id: $_id
name: Test $_id
kind: $_kind
version: 0.0.1
hooks:
  run: ${_id//-/_}_run
  cleanup: $_fn
requires:
  core:
    - redaction
EOF
done

# Stubs: run honours env-driven rc/sleep; cleanup records "<stage>:<scope>".
cat > "$PLUGINS_ROOT/agent/intake/plugin.sh" <<'PLUG'
intake_run() { return 0; }
intake_cleanup() { printf 'intake:%s\n' "${3:-NOSCOPE}" >> "${RELEASE_MARKER}"; return 0; }
PLUG
cat > "$PLUGINS_ROOT/agent/build/plugin.sh" <<'PLUG'
build_run() {
    : > "${BUILD_STARTED:-/dev/null}"
    if [[ "${BUILD_SLEEP:-0}" == "1" ]]; then
        local _i; for _i in $(seq 1 300); do sleep 0.1; done
    fi
    return "${BUILD_RC:-0}"
}
build_cleanup() {
    printf 'build:%s\n' "${3:-NOSCOPE}" >> "${RELEASE_MARKER}"
    # A hook that never returns — used to prove the dispatch is bounded.
    [[ "${BLOCK_CLEANUP:-0}" == "1" ]] && sleep 120
    return 0
}
PLUG
cat > "$PLUGINS_ROOT/tool/test/plugin.sh" <<'PLUG'
test_run() { return 0; }
test_cleanup() { printf 'test:%s\n' "${3:-NOSCOPE}" >> "${RELEASE_MARKER}"; return 0; }
PLUG

OVERLAY_REPO="$(setup_git_temp_repo release-exit-paths-repo)"
install_template_overlay "$OVERLAY_REPO" resume-minimal
export ZBUILD_SCOPE_OVERRIDE=1
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"

_case_no=0
# _prep <name> — fresh state dir + marker for one exit path.
_prep() {
    _case_no=$((_case_no + 1))
    CASE_DIR="$TEST_TEMP_DIR/case-$_case_no-$1"
    mkdir -p "$CASE_DIR/state" "$CASE_DIR/events"
    export ZBUILD_STATE_DIR="$CASE_DIR/state"
    export ZBUILD_EVENTS_DIR="$CASE_DIR/events"
    export ZBUILD_EVENTS_JSONL="$CASE_DIR/events/events.jsonl"
    export ZBUILD_EVENTS_DB="$CASE_DIR/events/events.db"
    export RELEASE_MARKER="$CASE_DIR/release-marker"
    export BUILD_STARTED="$CASE_DIR/build-started"
    : > "$RELEASE_MARKER"
    unset BUILD_RC BUILD_SLEEP 2>/dev/null || true
}

# _assert_released <case> <stage>... — EVERY named stage released, purge never.
#
# #1989: this used to grep the shared marker for any ':release' and pass. Three
# stages append to that one file, so one stage releasing masked two that never
# did — measured: neutering build_cleanup alone left the suite green, and it
# took neutering all three to turn it red. The assertion could only ever detect
# a TOTAL failure of the mechanism, never a partial one, which is the shape a
# real regression takes (#1748: suites observed alive 15+ min after exit).
#
# Each case now names the stages whose cleanup must have run. The sets differ
# by exit path because the teardown plugin iterates stages recorded EXECUTED in
# pipeline-state.json: a stage killed mid-flight was never recorded, so it gets
# no cleanup. SPEC-4/SPEC-5 therefore expect intake only. Whether an INTERRUPTED
# stage should also be released is an engine question, not a test question —
# raised separately; this assertion pins today's behaviour so a change to it
# cannot pass unnoticed in either direction.
_assert_released() {
    local _case="$1"; shift
    local _marker; _marker="$(cat "$RELEASE_MARKER" 2>/dev/null || true)"
    local _stage _missing=""
    for _stage in "$@"; do
        grep -q "^${_stage}:release$" <<< "$_marker" || _missing="${_missing}${_stage} "
    done
    if [[ -z "$_missing" ]]; then
        assert_pass "[$_case] cleanup dispatched with scope=release for: $*"
    else
        assert_fail "[$_case] cleanup dispatched with scope=release for: $*" \
            "no release from: ${_missing}| marker=$(tr '\n' ' ' <<< "$_marker")"
    fi
    if grep -q ':purge' <<< "$_marker"; then
        assert_fail "[$_case] purge is never reachable from a run" "marker contained purge"
    else
        assert_pass "[$_case] purge is never reachable from a run"
    fi
}

# ── SPEC-1: success ──────────────────────────────────────────────────────────
print_test_section "SPEC-1: exit path = success (rc 0)"
_prep success
export BUILD_RC=0
set +e
( cd "$OVERLAY_REPO" && bash "$RUNNER" --template resume-minimal --goal "release-success" ) \
    >"$CASE_DIR/out" 2>&1
_rc=$?
set -e
assert_eq "[SPEC-1] runner exits 0 on the success path" "0" "$_rc"
_assert_released "SPEC-1" intake build test

# ── SPEC-2: non-zero stage rc ────────────────────────────────────────────────
print_test_section "SPEC-2: exit path = non-zero stage rc"
_prep nonzero
export BUILD_RC=1
set +e
( cd "$OVERLAY_REPO" && bash "$RUNNER" --template resume-minimal --goal "release-nonzero" ) \
    >"$CASE_DIR/out" 2>&1
_rc=$?
set -e
if [[ "$_rc" -ne 0 ]]; then
    assert_pass "[SPEC-2] runner exits non-zero when a stage fails"
else
    assert_fail "[SPEC-2] runner exits non-zero when a stage fails" "rc=0"
fi
_assert_released "SPEC-2" intake build

# ── SPEC-3: SIGINT propagation chain (child rc=130) ──────────────────────────
print_test_section "SPEC-3: exit path = SIGINT chain (stage rc 130)"
_prep sigint
export BUILD_RC=130
set +e
( cd "$OVERLAY_REPO" && bash "$RUNNER" --template resume-minimal --goal "release-sigint" ) \
    >"$CASE_DIR/out" 2>&1
set -e
_assert_released "SPEC-3" intake build

# ── SPEC-4: external SIGTERM ─────────────────────────────────────────────────
print_test_section "SPEC-4: exit path = external SIGTERM"
_prep sigterm
export BUILD_RC=0 BUILD_SLEEP=1
if command -v setsid >/dev/null 2>&1; then
    setsid bash -c 'cd "$1" && exec bash "$2" --template resume-minimal --goal "$3"' \
        _ "$OVERLAY_REPO" "$RUNNER" "release-sigterm" >"$CASE_DIR/out" 2>&1 &
    RUNNER_PID=$!
else
    set -m
    bash -c 'cd "$1" && exec bash "$2" --template resume-minimal --goal "$3"' \
        _ "$OVERLAY_REPO" "$RUNNER" "release-sigterm" >"$CASE_DIR/out" 2>&1 &
    RUNNER_PID=$!
    set +m
fi
for _ in $(seq 1 300); do [[ -f "$BUILD_STARTED" ]] && break; sleep 0.1; done
kill -TERM "$RUNNER_PID" 2>/dev/null || true
wait "$RUNNER_PID" 2>/dev/null || true
# The EXIT trap dispatches release asynchronously w.r.t. this shell's `wait`
# on some platforms; give the marker a bounded moment to appear.
for _ in $(seq 1 50); do grep -q ':release' "$RELEASE_MARKER" 2>/dev/null && break; sleep 0.1; done
_assert_released "SPEC-4" intake

# ── SPEC-5: external hard kill (what an overrunning `timeout` produces) ──────
# ADR-053 §2: assert on an observable event, never a wall-clock budget.
#
# This case used to run the whole runner under `timeout 6`. Those 6 seconds had
# to cover process startup, template resolution AND reaching the build stage —
# so the budget was really a bet on host speed. Under the parallel pool (#991,
# the tier is parallel by default and the serial-pin list is empty) startup
# alone outran it: the runner was killed before any stage dispatched, the marker
# came back empty, and the failure read as a cleanup regression that standalone
# runs could never reproduce.
#
# The supervising timeout stays, but only as a runaway guard with a ceiling no
# healthy run approaches. The kill that this case actually asserts on is driven
# from BUILD_STARTED — the runner is provably inside the build stage — and
# escalates TERM→KILL the way `timeout` itself does, which is what separates
# this case from SPEC-4's plain SIGTERM.
print_test_section "SPEC-5: exit path = external hard kill (timeout-style)"
_prep timeout
export BUILD_RC=0 BUILD_SLEEP=1
_tbin=""
if   command -v gtimeout >/dev/null 2>&1; then _tbin=gtimeout
elif command -v timeout  >/dev/null 2>&1; then _tbin=timeout
fi
if [[ -z "$_tbin" ]]; then
    SKIP=$((SKIP + 1))
    echo -e "  ${YELLOW}SKIP${RESET}: [SPEC-5] external hard kill (no timeout binary available)" >&2
else
    set -m
    bash -c 'cd "$1" && exec "$4" 120 bash "$2" --template resume-minimal --goal "$3"' \
        _ "$OVERLAY_REPO" "$RUNNER" "release-timeout" "$_tbin" >"$CASE_DIR/out" 2>&1 &
    RUNNER_PID=$!
    set +m
    for _ in $(seq 1 300); do [[ -f "$BUILD_STARTED" ]] && break; sleep 0.1; done
    kill -TERM -"$RUNNER_PID" 2>/dev/null || kill -TERM "$RUNNER_PID" 2>/dev/null || true
    ( sleep 3; kill -KILL -"$RUNNER_PID" 2>/dev/null || kill -KILL "$RUNNER_PID" 2>/dev/null || true ) &
    _spec5_killer=$!
    wait "$RUNNER_PID" 2>/dev/null || true
    kill "$_spec5_killer" 2>/dev/null || true
    wait "$_spec5_killer" 2>/dev/null || true
    for _ in $(seq 1 50); do grep -q ':release' "$RELEASE_MARKER" 2>/dev/null && break; sleep 0.1; done
    _assert_released "SPEC-5" intake
fi

# ── SPEC-6: a blocking cleanup hook cannot hold the exit open ────────────────
# The dispatch runs inside the EXIT trap, so an unbounded hook would turn a
# normal exit into a hang — the same class of bug (a process that outlives the
# run) that this mechanism exists to prevent.
print_test_section "SPEC-6: a cleanup hook that blocks cannot hang the runner"
_prep blocking
export BUILD_RC=0 BLOCK_CLEANUP=1 ZBUILD_RELEASE_TIMEOUT=3
_t0=$(date +%s)
set +e
( cd "$OVERLAY_REPO" && bash "$RUNNER" --template resume-minimal --goal "release-blocking" ) \
    >"$CASE_DIR/out" 2>&1
set -e
_elapsed=$(( $(date +%s) - _t0 ))
unset BLOCK_CLEANUP ZBUILD_RELEASE_TIMEOUT
# The blocking hook sleeps 120s; the 3s bound must cut it short. Allow generous
# headroom for a loaded host while still failing an unbounded wait.
if [[ "$_elapsed" -lt 60 ]]; then
    assert_pass "[SPEC-6] blocking cleanup is bounded (runner exited in ${_elapsed}s)"
else
    assert_fail "[SPEC-6] blocking cleanup is bounded" "runner took ${_elapsed}s"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
