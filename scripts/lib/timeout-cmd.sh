#!/usr/bin/env bash
# The one place a timeout bound is resolved (#1752, ADR-036 amendment 2026-10-09).
# Every timeout bound in core/, scripts/ and plugins/ is built here; a bare
# `timeout` call or a hand-written probe elsewhere fails scripts/lib/lint-bare-timeout.sh.
#
# Why a helper at all: macOS has no `timeout` — Homebrew's coreutils installs it
# as `gtimeout` only (install.sh). Six sites each hand-copied the "gtimeout, else
# timeout" probe, and a seventh that called `timeout` bare ran its command
# unbounded on macOS (#2113).
#
# Source-only, no side effects on load. Sources nothing, so it can sit in the
# contract-lib closure (acceptance-block.sh loads it) without pulling more in.

[[ -n "${_ZBUILD_TIMEOUT_CMD_LOADED:-}" ]] && return 0
_ZBUILD_TIMEOUT_CMD_LOADED=1

# _acceptance_timeout_prefix <timeout_s> [kill_grace|none]  (#1660, shared #1752)
# Fills the global array _ACCEPTANCE_TOUT with the prefix tokens that bound one
# command: `<bin> [-k <grace>] <timeout_s>`. Empty when neither gtimeout nor
# timeout exists — the caller then runs its command UNBOUNDED, never skips it.
# Always returns 0. rc of the bounded command is untouched: 124 = timed out,
# 137 = killed (ADR-021 R2, ADR-036 "a signal is not a timeout").
#
# kill_grace: the `-k` grace in seconds; omitted → ZBUILD_NEGCTL_KILL_GRACE
# (default 10), the acceptance gates' contract. `none` → TERM-only, no `-k`
# (the router and gh-automation keep the bound they always had).
#
# Sets a global rather than printing because the probe below is memoized, and a
# `$(...)`/`< <(...)` caller would run it in a subshell where the memo dies.
#
# `-k` is what makes the bound real: plain `timeout` sends TERM only, so a child
# that traps or ignores TERM runs unbounded — the 9h22m hang in #1611.
#
# `-k` is probed, not assumed, once per process (_ACCEPTANCE_TIMEOUT_KILL_OK). A
# `timeout` lacking it exits 125 on the unknown flag, and 125 is not a timeout
# rc — every bounded run would fail for the wrong reason. A binary without it
# degrades to the TERM-only bound instead.
_acceptance_timeout_prefix() {
    local timeout_s="$1"
    local kill_grace="${ZBUILD_NEGCTL_KILL_GRACE:-10}"
    [[ $# -ge 2 ]] && kill_grace="$2"
    _ACCEPTANCE_TOUT=()
    local bin=""
    # gtimeout first: where both exist gtimeout is unambiguously GNU, while
    # `timeout` may be a thinner platform build.
    if   command -v gtimeout >/dev/null 2>&1; then bin="gtimeout"
    elif command -v timeout  >/dev/null 2>&1; then bin="timeout"
    else return 0
    fi
    _ACCEPTANCE_TOUT=("$bin")
    if [[ "$kill_grace" != "none" ]]; then
        if [[ -z "${_ACCEPTANCE_TIMEOUT_KILL_OK:-}" ]]; then
            if "$bin" -k 1 1 true >/dev/null 2>&1; then
                _ACCEPTANCE_TIMEOUT_KILL_OK=yes
            else
                _ACCEPTANCE_TIMEOUT_KILL_OK=no
            fi
        fi
        [[ "$_ACCEPTANCE_TIMEOUT_KILL_OK" == "yes" ]] && _ACCEPTANCE_TOUT+=("-k" "$kill_grace")
    fi
    _ACCEPTANCE_TOUT+=("$timeout_s")
    return 0
}
