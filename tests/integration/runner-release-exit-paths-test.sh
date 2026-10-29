#!/usr/bin/env bash
# Integration test (#1829, ADR-054 §7): the runner dispatches cleanup(release)
# on EVERY exit path from a run — success, non-zero rc, the SIGINT propagation
# chain, an external SIGTERM, and an external timeout.
#
# This is the acceptance criterion the mechanism exists for: a stage's live
# resources must be freed however the run ends. A single missed exit path leaks
# whatever that stage spawned (#1748: suites observed alive 15+ min after exit).
#
# Why SIGINT is driven by the stage rather than `kill -INT`: this harness starts
# non-interactively with SIGINT inherited as SIG_IGN, and POSIX forbids a child
# from un-ignoring it — so `kill -INT` is silently dropped and the assertion
# would pass standalone while proving nothing. The repo's existing
# sigint-aborts-pipeline-test.sh drives the same chain the same way: the child
# returns 130, which is exactly what the kernel produces on Ctrl-C. Since #1850
# (ADR-054 §4, ADR-025) a signal is a recorded WORD, not an rc, so the stage
# also arms the abort sentinel (empty = sigint), as the runner's INT trap in
# the process group would.
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
# after it. #1850/#2366: the re-emitted manifest keeps the factory's declaration —
# result_contract 3 and a JSON primary each run hook below writes.
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
provides:
  result_contract: 3
outputs:
  - id: ${_id//-/_}_result
    path: \${artifact_dir}/${_id}-result.json
    type: ${_id}-result.json@1
    format: json
    required: true
    primary: true
EOF
done

# Stubs: run honours env-driven rc/sleep; cleanup records "<stage>:<scope>".
cat > "$PLUGINS_ROOT/agent/intake/plugin.sh" <<'PLUG'
intake_run() {
    local _art; _art="${ZBUILD_ARTIFACT_DIR:-$(dirname "$2")/artifacts}"; mkdir -p "$_art"
    printf '%s' '{"result_contract":3,"outcome":"pass","reason":"stub"}' > "$_art/intake-result.json"
    return 0
}
intake_cleanup() { printf 'intake:%s\n' "${3:-NOSCOPE}" >> "${RELEASE_MARKER}"; return 0; }
PLUG
cat > "$PLUGINS_ROOT/agent/build/plugin.sh" <<'PLUG'
build_run() {
    printf '%s\n' "$BASHPID" > "${BUILD_STARTED:-/dev/null}"
    if [[ "${BUILD_SLEEP:-0}" == "1" ]]; then
        local _i; for _i in $(seq 1 300); do sleep 0.1; done
    fi
    local _art; _art="${ZBUILD_ARTIFACT_DIR:-$(dirname "$2")/artifacts}"; mkdir -p "$_art"
    [[ "${BUILD_ARM_ABORT:-0}" == "1" ]] && : > "${ZBUILD_STATE_DIR}/.abort.signal"
    if [[ "${BUILD_RC:-0}" == "0" ]]; then
        printf '%s' '{"result_contract":3,"outcome":"pass","reason":"stub"}' > "$_art/build-result.json"
    else
        printf '%s' '{"result_contract":3,"outcome":"broken","reason":"stub failure"}' > "$_art/build-result.json"
    fi
    return "${BUILD_RC:-0}"
}
build_cleanup() {
    printf 'build:%s\n' "${3:-NOSCOPE}" >> "${RELEASE_MARKER}"
    # A hook that never returns — used to prove the dispatch is bounded. It
    # records its own pid so SPEC-6 can check it does not outlive the run (#2287).
    if [[ "${BLOCK_CLEANUP:-0}" == "1" ]]; then
        printf '%s\n' "$BASHPID" >> "${RELEASE_MARKER%/*}/hook.pid"
        sleep 120
    fi
    if [[ "${BLOCK_CLEANUP_IGNORE_TERM:-0}" == "1" ]]; then
        # #2333: a child that ignores TERM, under a hook shell that does not.
        ( trap '' TERM; printf '%s\n' "$BASHPID" >> "${RELEASE_MARKER%/*}/hook-child.pid"; sleep 120 ) &
        wait
    fi
    return 0
}
PLUG
cat > "$PLUGINS_ROOT/tool/test/plugin.sh" <<'PLUG'
test_run() {
    local _art; _art="${ZBUILD_ARTIFACT_DIR:-$(dirname "$2")/artifacts}"; mkdir -p "$_art"
    printf '%s' '{"result_contract":3,"outcome":"pass","reason":"stub"}' > "$_art/test-result.json"
    return 0
}
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
    export RELEASE_MARKER="$CASE_DIR/release-marker"
    export BUILD_STARTED="$CASE_DIR/build-started"
    : > "$RELEASE_MARKER"
    unset BUILD_RC BUILD_SLEEP BUILD_ARM_ABORT 2>/dev/null || true
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
# by exit path because a stage only reaches release once it has been dispatched.
#
# ADR-062 §2: reclamation reads the process group recorded at DISPATCH, not the
# completion status map, so a stage killed mid-flight IS reclaimable. SPEC-4 and
# SPEC-5 therefore expect `build` as well as `intake` — build had demonstrably
# started (it wrote BUILD_STARTED) before the signal landed. Before #2001 both
# freed `intake` only, because teardown iterated `.stage_statuses`, which
# `_update_stage_status` writes only on complete/failed — i.e. after a stage
# returns, which a killed stage never does.
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

# SPEC-6 and SPEC-6b each wait out the release bound on purpose: their hook
# blocks, and the bound (the base template's release `timeout_s:` at the
# top-level stage block, 30s after #1801) is what ends it. Started here, each
# from its own repo, so that bound runs while SPEC-1..5 do; their assertions
# are made below, in order.

_start_blocking() {   # <case name> <hook switch>
    local _repo; _repo="$(setup_git_temp_repo "release-exit-paths-$1")"
    install_template_overlay "$_repo" resume-minimal
    (
        _prep "$1"
        export BUILD_RC=0 "$2"=1
        _t0=$(date +%s)
        ( cd "$_repo" && bash "$RUNNER" --template resume-minimal --goal "release-$1" ) \
            >"$CASE_DIR/out" 2>&1 || true
        printf '%s\n' "$(( $(date +%s) - _t0 ))" > "$CASE_DIR/elapsed"
    ) &
}
_start_blocking blocking BLOCK_CLEANUP;                   _SPEC6_PID=$!
_start_blocking blocking-ignore-term BLOCK_CLEANUP_IGNORE_TERM; _SPEC6B_PID=$!
_SPEC6_DIR="$TEST_TEMP_DIR/case-1-blocking"
_SPEC6B_DIR="$TEST_TEMP_DIR/case-1-blocking-ignore-term"

# ── SPEC-1: success ──────────────────────────────────────────────────────────
print_test_section "SPEC-1: exit path = success (rc 0)"
_prep success
export BUILD_RC=0
set +e
( cd "$OVERLAY_REPO" && bash "$RUNNER" --template resume-minimal --goal "release-success" ) \
    >"$CASE_DIR/out" 2>&1
_rc=$?
set -e
# SPEC-6/6b run alongside this case; if it fails, say what the runner said.
[[ $_rc -eq 0 ]] || tail -20 "$CASE_DIR/out" >&2
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

# ── SPEC-3: SIGINT propagation chain (child rc=130 + abort word) ─────────────
print_test_section "SPEC-3: exit path = SIGINT chain (stage rc 130, sentinel armed)"
_prep sigint
export BUILD_RC=130 BUILD_ARM_ABORT=1
set +e
( cd "$OVERLAY_REPO" && bash "$RUNNER" --template resume-minimal --goal "release-sigint" ) \
    >"$CASE_DIR/out" 2>&1
_rc=$?
set -e
# #1850: the run really took the SIGINT path — exit 1 (not 130) and the abort
# named sigint — or this case would only repeat SPEC-2's non-zero rc.
assert_eq "[SPEC-3] runner exits 1 on the SIGINT chain (not 130)" "1" "$_rc"
assert_eq "[SPEC-3] pipeline.aborted carries reason=sigint" "sigint" \
    "$(jq -r 'select(.type=="pipeline.aborted") | .data.reason // empty' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | sort -u | tr -d '\n')"
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
for _ in $(seq 1 300); do [[ -s "$BUILD_STARTED" ]] && break; sleep 0.1; done
_build_pid="$(head -n 1 "$BUILD_STARTED" 2>/dev/null || true)"
_t0=$(date +%s)
kill -TERM "$RUNNER_PID" 2>/dev/null || true
wait "$RUNNER_PID" 2>/dev/null || true
_elapsed=$(( $(date +%s) - _t0 ))
# ADR-054 §7: the runner acts on the signal while the stage is still running.
# Build holds for 30s; a runner that waits for it to return took 30s+ here.
if [[ "$_elapsed" -lt 15 ]]; then
    assert_pass "[SPEC-4] the runner stops without waiting for the stage (${_elapsed}s)"
else
    assert_fail "[SPEC-4] the runner stops without waiting for the stage" "took ${_elapsed}s; build holds 30s"
fi
if [[ -n "$_build_pid" ]] && kill -0 "$_build_pid" 2>/dev/null; then
    assert_fail "[SPEC-4] the stage does not outlive the run" "build pid $_build_pid still alive"
    kill -KILL "$_build_pid" 2>/dev/null || true
else
    assert_pass "[SPEC-4] the stage does not outlive the run"
fi
# The EXIT trap dispatches release asynchronously w.r.t. this shell's `wait`
# on some platforms; give the marker a bounded moment to appear.
for _ in $(seq 1 50); do grep -q ':release' "$RELEASE_MARKER" 2>/dev/null && break; sleep 0.1; done
_assert_released "SPEC-4" intake build

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
    # #2029: the force-kill grace must be DERIVED from the release budget, not a
    # hardcoded literal. _SPEC5_STAGE_TIMEOUT is the per-stage bound (after #1801
    # this is template_stage_time_limit — 30s in simple.yaml; 3s here is a
    # test-safe stand-in). Three stages release on this path, so the grace clears
    # 3x the per-hook bound. The hooks in this case return promptly; the grace is
    # only a runaway guard so a runner that ignores TERM cannot hang the suite.
    _SPEC5_STAGE_TIMEOUT=3
    _SPEC5_KILL_GRACE=$(( _SPEC5_STAGE_TIMEOUT * 3 + 6 ))   # 3 stages + margin
    set -m
    bash -c 'cd "$1" && exec "$4" 120 bash "$2" --template resume-minimal --goal "$3"' \
        _ "$OVERLAY_REPO" "$RUNNER" "release-timeout" "$_tbin" >"$CASE_DIR/out" 2>&1 &
    RUNNER_PID=$!
    set +m
    for _ in $(seq 1 300); do [[ -s "$BUILD_STARTED" ]] && break; sleep 0.1; done
    kill -TERM -"$RUNNER_PID" 2>/dev/null || kill -TERM "$RUNNER_PID" 2>/dev/null || true
    ( sleep "$_SPEC5_KILL_GRACE"; kill -KILL -"$RUNNER_PID" 2>/dev/null || kill -KILL "$RUNNER_PID" 2>/dev/null || true ) &
    _spec5_killer=$!
    wait "$RUNNER_PID" 2>/dev/null || true
    kill "$_spec5_killer" 2>/dev/null || true
    wait "$_spec5_killer" 2>/dev/null || true
    for _ in $(seq 1 50); do grep -q ':release' "$RELEASE_MARKER" 2>/dev/null && break; sleep 0.1; done
    _assert_released "SPEC-5" intake build
    # [#1801/SPEC-5]: the hard-kill exit path must dispatch cleanup — pre-existing
    # [SPEC-5] (#1829) assertion that must continue to hold after #1801's changes
    # to _runner_dispatch_always_run (template_stage_time_limit replaces router.timeout_s).
    # The runner's EXIT trap dispatches teardown on TERM→KILL; cleanup hooks write the
    # release marker before the kill grace expires.
    # FAILS on old code (EXIT trap not invoked on TERM→KILL path); PASSES on new code.
    _hk_marker="$(cat "$RELEASE_MARKER" 2>/dev/null || true)"
    if grep -q '^intake:release$' <<< "$_hk_marker" && \
       grep -q '^build:release$'  <<< "$_hk_marker"; then
        assert_pass "[#1801/SPEC-5] hard-kill path: EXIT trap dispatched cleanup for intake and build"
    else
        assert_fail "[#1801/SPEC-5] hard-kill path: EXIT trap must dispatch cleanup for intake and build" \
            "expected intake:release and build:release in marker; got: $(tr '\n' ' ' <<< "$_hk_marker"); old code: EXIT trap not invoked on TERM→KILL path"
    fi
fi

# ── SPEC-6: a blocking cleanup hook cannot hold the exit open ────────────────
# The dispatch runs inside the EXIT trap, so an unbounded hook would turn a
# normal exit into a hang — the same class of bug (a process that outlives the
# run) that this mechanism exists to prevent.
print_test_section "SPEC-6: a cleanup hook that blocks cannot hang the runner"
wait "$_SPEC6_PID" 2>/dev/null || true
CASE_DIR="$_SPEC6_DIR"
_elapsed="$(cat "$CASE_DIR/elapsed" 2>/dev/null || echo 999)"
# The blocking hook sleeps 120s. The bound is the release stage's own
# `timeout_s:` at the top-level stage block (read by template_stage_time_limit
# after #1801 — 30s in simple.yaml), so the runner returns in about 30s.
# Allow generous headroom for a loaded host while still failing an unbounded wait.
if [[ "$_elapsed" -lt 60 ]]; then
    assert_pass "[SPEC-6] blocking cleanup is bounded (runner exited in ${_elapsed}s)"
else
    assert_fail "[SPEC-6] blocking cleanup is bounded" "runner took ${_elapsed}s"
fi
# #2287: the bound must stop the hook, not just stop waiting for it. Before,
# the hook lived on after the run, finished its sleep ~2 min later, and wrote
# into a state folder the run no longer owned. The kills are sent before the
# runner returns; up to 1s covers the killed processes exiting on a loaded host.
_hook_pid="$(head -n 1 "$CASE_DIR/hook.pid" 2>/dev/null || true)"
if [[ -n "$_hook_pid" ]]; then
    for _ in $(seq 1 10); do kill -0 "$_hook_pid" 2>/dev/null || break; sleep 0.1; done
fi
if [[ -z "$_hook_pid" ]]; then
    assert_fail "[SPEC-6] fixture: the blocking hook recorded its pid" "no $CASE_DIR/hook.pid"
elif kill -0 "$_hook_pid" 2>/dev/null; then
    assert_fail "[SPEC-6] the blocked hook does not outlive the run" "pid $_hook_pid still alive after the runner returned"
    # Leave nothing behind for the rest of the suite: the hook first, so it
    # cannot carry on once its sleep ends, then the sleep it leaves orphaned.
    _hook_kids="$(pgrep -P "$_hook_pid" 2>/dev/null || true)"
    kill -KILL "$_hook_pid" 2>/dev/null || true
    for _k in $_hook_kids; do kill -KILL "$_k" 2>/dev/null || true; done
else
    assert_pass "[SPEC-6] the blocked hook does not outlive the run"
fi

# ── SPEC-6b (#2333): a child that ignores TERM is killed too ────────────────
# The bound sends TERM to the hook's group, then KILL after a grace. The runner
# waited only for the group leader and cancelled the watchdog when it exited, so
# a member that ignored TERM never got the KILL and outlived the run.
print_test_section "SPEC-6b: a hook child that ignores TERM does not outlive the run"
# The time bound itself is SPEC-6's check, on the same dispatch path; this
# case is only about what survives it.
wait "$_SPEC6B_PID" 2>/dev/null || true
CASE_DIR="$_SPEC6B_DIR"
_child_pid=""
for _ in $(seq 1 50); do
    _child_pid="$(head -n 1 "$CASE_DIR/hook-child.pid" 2>/dev/null || true)"
    [[ -n "$_child_pid" ]] && break; sleep 0.1
done
_alive=1
# Only poll a pid that was recorded; a missing pid is reported as a fixture failure below.
if [[ -n "$_child_pid" ]]; then
    for _ in $(seq 1 50); do kill -0 "$_child_pid" 2>/dev/null || { _alive=0; break; }; sleep 0.1; done
fi
if [[ -z "$_child_pid" ]]; then
    assert_fail "[SPEC-6b] fixture: the child recorded its pid" "no $CASE_DIR/hook-child.pid"
elif [[ "$_alive" -eq 1 ]]; then
    assert_fail "[SPEC-6b] a hook child that ignores TERM does not outlive the run" "pid $_child_pid still alive 5s after the runner returned"
    kill -KILL "$_child_pid" 2>/dev/null || true
else
    assert_pass "[SPEC-6b] a hook child that ignores TERM does not outlive the run"
fi

# [#1801/SPEC-5] the always-run bound is `timeout_s:` — proved at runtime by
# always-run-exit-paths-test.sh (persist: timeout_s 4 vs router.timeout_s 120).
# [#1801/SPEC-5] static guard: ZBUILD_RELEASE_TIMEOUT must not appear in runner.sh.
# Old code reads ZBUILD_RELEASE_TIMEOUT for the always-run watchdog; new code reads
# template_stage_time_limit instead. This grep fails on old code (the var is there)
# and passes on new code (it has been removed).
if ! grep -q 'ZBUILD_RELEASE_TIMEOUT' "$RUNNER"; then
    assert_pass "[#1801/SPEC-5] runner.sh does not reference ZBUILD_RELEASE_TIMEOUT (removed in #1801)"
else
    assert_fail "[#1801/SPEC-5] runner.sh must not reference ZBUILD_RELEASE_TIMEOUT" \
        "ZBUILD_RELEASE_TIMEOUT still present in $RUNNER; must be replaced by template_stage_time_limit"
fi

# [#1801/SPEC-5] static guard: _runner_dispatch_always_run must not reference
# router.timeout_s (its bash manifestation: _TPL_STAGE_ROUTER_TIMEOUT_*).
# Old code (runner.sh): local _ar_to_var="_TPL_STAGE_ROUTER_TIMEOUT_${_ar_safe}"
# which reads router.timeout_s from the template config.
# New code: reads template_stage_time_limit instead.
# This grep fails on old code (the string is present) and passes on new (removed).
if ! grep -q '_TPL_STAGE_ROUTER_TIMEOUT' "$RUNNER"; then
    assert_pass "[#1801/SPEC-5] runner.sh does not reference _TPL_STAGE_ROUTER_TIMEOUT (router.timeout_s removed from always-run watchdog in #1801)"
else
    assert_fail "[#1801/SPEC-5] runner.sh must not reference _TPL_STAGE_ROUTER_TIMEOUT (router.timeout_s)" \
        "_TPL_STAGE_ROUTER_TIMEOUT still present in $RUNNER; must be replaced by template_stage_time_limit"
fi

# [#1801/SPEC-5] static: shipped templates carry timeout_s: at stage level ──────
# template_stage_time_limits_load reads timeout_s: at stage-level indent (2
# spaces from the stage name at column 0, NOT inside `router:` at 4 spaces).
# These assertions verify that simple.yaml and deployed.yaml carry the correct
# values directly under the stage block — so the watchdog reads them, not
# router.timeout_s.
#
# Old code: these values might not exist or might only be under router:
#   → awk extracts nothing (or wrong value) → assertion fails on old code ✓
# New code: values are present at stage level → assertions pass ✓
print_test_section "[#1801/SPEC-5] static: simple.yaml and deployed.yaml carry timeout_s: at stage level"

_SIMPLE_YAML="$REPO_ROOT/config/templates/simple.yaml"
_DEPLOYED_YAML="$REPO_ROOT/config/templates/deployed.yaml"

# Extract stage-level timeout_s: for release in simple.yaml.
# awk: enter release: section, stop at next top-level key (0-indent), stop
# inside router: sub-section, only match `  timeout_s:` (exactly 2 leading spaces).
_simple_release_ts="$(awk '
    /^release:/{in_r=1;in_sub=0;next}
    in_r && /^[a-zA-Z]/{in_r=0}
    in_r && /^  [a-zA-Z]/ && !/^  timeout_s:/{
        if ($0 ~ /^  router:/) { in_sub=1 } else { in_sub=0 }
        next
    }
    in_r && !in_sub && /^  timeout_s:/{
        sub(/^[[:space:]]*timeout_s:[[:space:]]*/, ""); print; exit
    }
' "$_SIMPLE_YAML" 2>/dev/null || printf '')"

if [[ "$_simple_release_ts" == "30" ]]; then
    assert_pass "[#1801/SPEC-5] simple.yaml: release.timeout_s is 30 at stage level (not under router:)"
else
    assert_fail "[#1801/SPEC-5] simple.yaml: release.timeout_s must be 30 at stage level" \
        "got: '${_simple_release_ts:-<not found>}'; template_stage_time_limits_load reads 2-space indent, not router.timeout_s"
fi

# Extract stage-level timeout_s: for persist in simple.yaml.
_simple_persist_ts="$(awk '
    /^persist:/{in_r=1;in_sub=0;next}
    in_r && /^[a-zA-Z]/{in_r=0}
    in_r && /^  [a-zA-Z]/ && !/^  timeout_s:/{
        if ($0 ~ /^  router:/) { in_sub=1 } else { in_sub=0 }
        next
    }
    in_r && !in_sub && /^  timeout_s:/{
        sub(/^[[:space:]]*timeout_s:[[:space:]]*/, ""); print; exit
    }
' "$_SIMPLE_YAML" 2>/dev/null || printf '')"

if [[ "$_simple_persist_ts" == "120" ]]; then
    assert_pass "[#1801/SPEC-5] simple.yaml: persist.timeout_s is 120 at stage level"
else
    assert_fail "[#1801/SPEC-5] simple.yaml: persist.timeout_s must be 120 at stage level" \
        "got: '${_simple_persist_ts:-<not found>}'"
fi

# deployed.yaml: same values.
_deployed_release_ts="$(awk '
    /^release:/{in_r=1;in_sub=0;next}
    in_r && /^[a-zA-Z]/{in_r=0}
    in_r && /^  [a-zA-Z]/ && !/^  timeout_s:/{
        if ($0 ~ /^  router:/) { in_sub=1 } else { in_sub=0 }
        next
    }
    in_r && !in_sub && /^  timeout_s:/{
        sub(/^[[:space:]]*timeout_s:[[:space:]]*/, ""); print; exit
    }
' "$_DEPLOYED_YAML" 2>/dev/null || printf '')"

if [[ "$_deployed_release_ts" == "30" ]]; then
    assert_pass "[#1801/SPEC-5] deployed.yaml: release.timeout_s is 30 at stage level"
else
    assert_fail "[#1801/SPEC-5] deployed.yaml: release.timeout_s must be 30 at stage level" \
        "got: '${_deployed_release_ts:-<not found>}'"
fi

_deployed_persist_ts="$(awk '
    /^persist:/{in_r=1;in_sub=0;next}
    in_r && /^[a-zA-Z]/{in_r=0}
    in_r && /^  [a-zA-Z]/ && !/^  timeout_s:/{
        if ($0 ~ /^  router:/) { in_sub=1 } else { in_sub=0 }
        next
    }
    in_r && !in_sub && /^  timeout_s:/{
        sub(/^[[:space:]]*timeout_s:[[:space:]]*/, ""); print; exit
    }
' "$_DEPLOYED_YAML" 2>/dev/null || printf '')"

if [[ "$_deployed_persist_ts" == "120" ]]; then
    assert_pass "[#1801/SPEC-5] deployed.yaml: persist.timeout_s is 120 at stage level"
else
    assert_fail "[#1801/SPEC-5] deployed.yaml: persist.timeout_s must be 120 at stage level" \
        "got: '${_deployed_persist_ts:-<not found>}'"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
