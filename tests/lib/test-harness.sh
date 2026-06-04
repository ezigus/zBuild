#!/usr/bin/env bash
# tests/lib/test-harness.sh — canonical test-mode env-init (Wave 14-B / #675)
#
# Implements the Layer 2 contract per ADR-024 amendment (Wave 14-A): tests
# source this file and call zb_test_init_env once to construct the canonical
# ZBUILD_* env they need, inside a fresh user shell or otherwise. The Tr-5
# (core-router-route-test) and banner-capture (test-test.sh sections 6+7)
# cases use the _with_* and _capture_fd3 helpers to scope mutations to a
# subshell so caller env stays clean.
#
# Opt-in: not sourcing this lib leaves existing tests behaving exactly as
# before. The five files this issue migrates are the first adopters; future
# tests benefit automatically.
#
# Sourced library — no `set -euo pipefail` here (would mutate caller options).

[[ -n "${_ZB_TEST_HARNESS_LOADED:-}" ]] && return 0
_ZB_TEST_HARNESS_LOADED=1

# ─── locate repo root from this file ────────────────────────────────────────
# this file lives at tests/lib/test-harness.sh
_ZB_TEST_HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZB_TEST_HARNESS_REPO_ROOT="$(cd "$_ZB_TEST_HARNESS_DIR/../.." && pwd)"

# ─── EXIT trap composition (additive, preserves existing) ───────────────────
# zb_test_init_env's tmpdir cleanup must not clobber an existing EXIT trap
# (test-helpers.sh installs _test_harness_cleanup; per-test files may also
# install their own). We chain by reading the current EXIT trap, appending our
# cleanup command, and re-installing.
_zb_test_chain_exit_trap() {
    local new_cmd="$1"
    local existing
    existing="$(trap -p EXIT 2>/dev/null || true)"
    if [[ -z "$existing" ]]; then
        # shellcheck disable=SC2064  # intentional eager expansion
        trap "$new_cmd" EXIT
        return 0
    fi
    # `trap -p EXIT` prints: trap -- 'cmd1; cmd2' EXIT
    # Strip the wrapper to extract the inner command string.
    local inner
    inner="${existing#trap -- \'}"
    inner="${inner%\' EXIT}"
    # shellcheck disable=SC2064
    trap "${inner}; ${new_cmd}" EXIT
}

# ─── zb_test_init_env: populate canonical Layer 2 env ───────────────────────
# Idempotent: first call allocates the tmpdir, sets the 5 canonical vars and
# chains an EXIT-trap cleanup; subsequent calls are no-ops (existing state
# preserved). Cleanup removes ZBUILD_STATE_DIR on exit.
zb_test_init_env() {
    [[ -n "${_ZB_TEST_ENV_INITIALIZED:-}" ]] && return 0
    _ZB_TEST_ENV_INITIALIZED=1

    export ZBUILD_STATE_DIR
    ZBUILD_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zb-test-harness.XXXXXX")"
    # Freeze the harness-owned tmpdir path at init time so cleanup removes
    # the exact dir we created even if a later test reassigns ZBUILD_STATE_DIR.
    _ZB_TEST_HARNESS_OWNED_DIR="$ZBUILD_STATE_DIR"

    export ZBUILD_RUN_ID="test-$$-${RANDOM}"
    export ZBUILD_EVENTS_JSONL="$ZBUILD_STATE_DIR/events.jsonl"
    : > "$ZBUILD_EVENTS_JSONL"

    export ZBUILD_ARTIFACT_DIR="$ZBUILD_STATE_DIR/artifacts"
    mkdir -p "$ZBUILD_ARTIFACT_DIR"

    export ZBUILD_EVENT_SCHEMA="$_ZB_TEST_HARNESS_REPO_ROOT/config/event-schema.json"

    _zb_test_chain_exit_trap "_zb_test_init_env_cleanup"
}

_zb_test_init_env_cleanup() {
    if [[ -n "${_ZB_TEST_HARNESS_OWNED_DIR:-}" && -d "$_ZB_TEST_HARNESS_OWNED_DIR" \
          && "$_ZB_TEST_HARNESS_OWNED_DIR" == */zb-test-harness.* ]]; then
        rm -rf "$_ZB_TEST_HARNESS_OWNED_DIR"
    fi
}

# ─── zb_test_with_router_timeout VALUE FN [ARGS...] ─────────────────────────
# Run FN with ZBUILD_ROUTER_TIMEOUT=VALUE exported inside a subshell. The
# export does not leak back to the caller (subshell boundary). FN may be
# either a shell function or an executable on PATH.
zb_test_with_router_timeout() {
    local value="$1"; shift
    ( export ZBUILD_ROUTER_TIMEOUT="$value"; "$@" )
}

# ─── zb_test_with_stage NAME FN [ARGS...] ───────────────────────────────────
# Run FN with ZBUILD_CURRENT_STAGE=NAME exported inside a subshell. Isolated.
zb_test_with_stage() {
    local stage="$1"; shift
    ( export ZBUILD_CURRENT_STAGE="$stage"; "$@" )
}

# ─── zb_test_capture_fd3 FN [ARGS...] ───────────────────────────────────────
# Run FN with fd 3 redirected to a tmpfile and ZBUILD_STAGE_IO_FD=3 exported
# in scope. Echoes ONLY the captured fd-3 content to stdout so callers can do
# `out="$(zb_test_capture_fd3 my_fn ...)"` without contamination from FN's
# own stdout. FN's stdout is redirected to stderr; FN's stderr is left
# untouched. The tmpfile is removed before return.
zb_test_capture_fd3() {
    local tmpfile
    tmpfile="$(mktemp "${TMPDIR:-/tmp}/zb-test-fd3.XXXXXX")"
    (
        export ZBUILD_STAGE_IO_FD=3
        "$@" 3>"$tmpfile" >&2
    )
    local rc=$?
    cat "$tmpfile"
    rm -f "$tmpfile"
    return $rc
}
