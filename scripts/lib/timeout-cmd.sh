#!/usr/bin/env bash
# scripts/lib/timeout-cmd.sh — shared gtimeout-first timeout probe (#1752, ADR-036)
# Extracted from acceptance-block.sh so every timeout bound in core/, scripts/,
# and plugins/ goes through one helper rather than six hand-copied probes.
#
# Contract:
#   _acceptance_timeout_prefix <timeout_s>
#     Fills _ACCEPTANCE_TOUT (global array) with the timeout-command prefix tokens.
#     Empty when no usable binary is found (best-effort — callers run unbounded).
#     Memoises the -k probe in _ACCEPTANCE_TIMEOUT_KILL_OK (once per process).
#     Always returns 0.
#   Kill-grace: ZBUILD_NEGCTL_KILL_GRACE (default 10).  Callers with their own
#     kill-grace env var (ZBUILD_TEST_KILL_GRACE, ZBUILD_MUTATION_KILL_GRACE) must
#     bridge: ZBUILD_NEGCTL_KILL_GRACE="${CALLER_VAR:-10}" before calling.

[[ -n "${_ZBUILD_TIMEOUT_CMD_LOADED:-}" ]] && return 0
_ZBUILD_TIMEOUT_CMD_LOADED=1

# _acceptance_timeout_prefix <timeout_s>  (#1660, extracted #1752)
# Fills the global array _ACCEPTANCE_TOUT with the `timeout` prefix tokens that
# bound one testfile run — empty when no usable timeout binary exists
# (best-effort, same convention as core/router/route.sh). Always returns 0.
#
# Sets a global rather than printing because the probe below is memoized, and a
# `$(...)`/`< <(...)` caller would run it in a subshell where the memo dies.
#
# `-k` is what makes the bound real: plain `timeout` sends TERM only, so a child
# that traps or ignores TERM runs unbounded — the 9h22m hang in #1611. The grace
# is ZBUILD_NEGCTL_KILL_GRACE (default 10s).
#
# `-k` is probed, not assumed. GNU coreutils has had it since 7.0, but a
# `timeout` lacking it exits 125 on the unknown flag, and 125 is not a timeout rc
# — every bounded run would fall through to the ordinary control comparison and
# report `tautology`/`not_passing_at_head`, condemning correct changes. That is
# strictly worse than the hang this replaces, so support is verified once before
# the flag is used, and a `timeout` without it degrades to the old TERM-only
# bound instead of failing every run.
_acceptance_timeout_prefix() {
    local timeout_s="$1"
    local kill_grace="${ZBUILD_NEGCTL_KILL_GRACE:-10}"
    _ACCEPTANCE_TOUT=()
    local bin=""
    # gtimeout first: where both exist gtimeout is unambiguously GNU, while
    # `timeout` may be a thinner platform build.
    if   command -v gtimeout >/dev/null 2>&1; then bin="gtimeout"
    elif command -v timeout  >/dev/null 2>&1; then bin="timeout"
    else return 0
    fi
    if [[ -z "${_ACCEPTANCE_TIMEOUT_KILL_OK:-}" ]]; then
        # Probe -k support. The PATH prefix (/usr/bin:/bin) ensures shell-script
        # stubs (#!/usr/bin/env bash) used in tests can exec bash while the
        # binary itself is still found via the caller's PATH.
        if PATH="${PATH}:/usr/bin:/bin" "$bin" -k 1 1 /bin/true >/dev/null 2>&1; then
            _ACCEPTANCE_TIMEOUT_KILL_OK=yes
        else
            _ACCEPTANCE_TIMEOUT_KILL_OK=no
        fi
    fi
    _ACCEPTANCE_TOUT=("$bin")
    [[ "$_ACCEPTANCE_TIMEOUT_KILL_OK" == "yes" ]] && _ACCEPTANCE_TOUT+=("-k" "$kill_grace")
    _ACCEPTANCE_TOUT+=("$timeout_s")
    return 0
}
