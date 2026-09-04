#!/usr/bin/env bash
# scripts/lib/proc-group.sh — process-group resolution and kill helpers.
# Extracted from core/router/route.sh (Wave 15-G, #687) so the test stage and
# any other long-running spawn share one implementation (#1748).
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_PROC_GROUP_LOADED:-}" ]] && return 0
_ZBUILD_PROC_GROUP_LOADED=1

# #2056: there is no setsid prefix any more. Process groups come from `set -m`
# at the spawn site — bash job control makes a backgrounded job a group leader,
# which is POSIX and identical on macOS and Linux.
#
# `setsid -w` was wrong here twice over. It is absent on macOS (util-linux is
# keg-only), so the prefix went empty, no group was created, and an abort
# degraded to a single-PID kill while every descendant survived — the Wave 15-G
# guarantee held on Linux only, and the test covering it is Linux-only too, so
# nothing said so. And `-w` forces setsid to fork, because it waits for the
# child and returns its exit status, so the pid the caller captured was the
# wrapper rather than the new session leader.
#
# Do not reintroduce a prefix here. A spawn that needs an external binary to get
# a process group is a spawn whose guarantee is platform-conditional.

# Prints the PGID safe to signal for <pid>, or nothing. Empty is not "no group":
# it means the group could not be proven distinct from ours, and signalling it
# would take down the runner itself — so callers must fall back to a PID kill.
zbuild_pg_resolve() {
    local _pid="${1:-}"
    [[ -n "$_pid" && "$_pid" =~ ^[0-9]+$ ]] || return 0
    local _child _self
    _child="$(ps -o pgid= -p "$_pid" 2>/dev/null | tr -d ' ' || true)"
    _self="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ' || true)"
    if [[ -n "$_child" && -n "$_self" && "$_child" != "$_self" ]]; then
        printf '%s' "$_child"
        return 0
    fi
    # A short-lived child can exit before `ps` reports it. Under `set -m` the
    # spawn IS the group leader, so PGID == PID by construction and that stays
    # true after it is gone — reporting the pid is correct, not a guess.
    #
    # This branch previously justified itself with "setsid execs in place, so it
    # needs no fork". That was false under `-w` (#2056): setsid forks in order to
    # wait, so the captured pid was the wrapper and the group belonged to a
    # process one fork below. Under job control there is no wrapper to be wrong
    # about.
    if [[ -z "$_child" ]]; then
        printf '%s' "$_pid"
    fi
}

# TERM <target>, then KILL whatever is left after <grace_s>. Shared by the group
# and single-PID paths so both get the same grace — the escalation is the whole
# contract, and a caller that skips it is indistinguishable from a plain KILL.
#
# Synchronous by construction (#905): the `{ sleep 1 && kill -KILL; } &` backstop
# this replaces could outlive the caller that armed it, so teardown returned
# while the tree was still alive and the backstop was sometimes lost with it.
# Polling instead costs milliseconds when the target exits on TERM, costs the
# full grace only when it ignores TERM, and leaves nothing running on return.
_zbuild_pg_term_then_kill() {
    # `--` because a group target is spelled `-PGID` and would otherwise parse
    # as an option.
    local _target="$1" _grace="$2"
    kill -TERM -- "$_target" 2>/dev/null || true
    local _ticks=$(( _grace * 10 )) _i=0
    while (( _i < _ticks )); do
        kill -0 -- "$_target" 2>/dev/null || return 0
        sleep 0.1 2>/dev/null || true
        _i=$(( _i + 1 ))
    done
    kill -KILL -- "$_target" 2>/dev/null || true
}

# A non-numeric grace would evaluate to 0 in the arithmetic context above, so the
# poll loop would never run and the target would go straight to KILL — silently
# losing the escalation the caller asked for. Clamp to the default instead.
_zbuild_pg_grace() {
    local _g="${1:-1}"
    [[ "$_g" =~ ^[0-9]+$ && "$_g" -gt 0 ]] && printf '%s' "$_g" || printf '1'
}

# zbuild_pg_record_pgid <file> — the pgid out of a `.pgid` record.
#
# ONE reader, because there are two formats on disk and three places that read
# them (#2018). The engine's dispatch record is `<pgid>\t<leader start time>`;
# tool/test's own `test-stage.pgid` is a bare number; and a record written before
# #2018 is bare too. A reader that only understands one of those does not error —
# it fails the numeric guard and `continue`s, so the caller kills NOTHING and
# reports success. That is how a format change here silently disables ADR-062 §2
# reclamation, which is the path that actually runs on every normal exit.
#
# Prints nothing and returns 1 when there is no usable pgid, so a caller can
# still distinguish "no record" from "record says 1234".
zbuild_pg_record_pgid() {
    local _f="${1:-}" _pgid=""
    [[ -n "$_f" && -f "$_f" ]] || return 1
    IFS=$'\t' read -r _pgid _ < "$_f" 2>/dev/null || true
    [[ "$_pgid" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$_pgid"
}

# zbuild_pg_register <pgid> — record a process group the caller just created.
#
# ADR-062 §1 had the ENGINE record this at dispatch. It could not, and the reason
# is structural: a stage is a bash function call, not a subprocess, so at the
# dispatch seam no group exists yet. That code fell back to `$$`'s group — the
# engine's own — which teardown then skipped, correctly, because signalling your
# own group takes the runner down with it. Every record was unkillable, every
# record was skipped, and §2's kill loop never freed anything (#2024).
#
# So the direction reverses: whoever CREATES a group registers it. Two sites do,
# and only two — `tool/test`'s `set -m` suite and the router's `setsid` spawn.
#
# Refusing to register our own group is the invariant, not a safety check. A
# record naming the registrar's own group is strictly worse than no record: it
# cannot be acted on, and it makes the mechanism look live while it does nothing
# — which is exactly how the original defect survived #2001, #2018 and an ADR.
#
# Fail-open throughout: a spawn is never refused because bookkeeping was
# unavailable. Silence here costs a possible leak; failing here costs the run.
zbuild_pg_register() {
    local _pgid="${1:-}"
    [[ -n "$_pgid" && "$_pgid" =~ ^[0-9]+$ ]] || return 0
    local _self
    _self="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ' || true)"
    [[ -n "$_self" && "$_self" == "$_pgid" ]] && return 0
    local _sd="${ZBUILD_STATE_DIR:-}"
    [[ -n "$_sd" && -d "$_sd" ]] || return 0
    local _stage="${2:-${ZBUILD_CURRENT_STAGE:-}}"
    [[ -n "$_stage" ]] || return 0
    # One path component, sanitised the same way stage scratch keys are, so no
    # stage name can climb out of runtime/.
    _stage="${_stage//[^A-Za-z0-9_-]/_}"
    local _dir="${_sd}/runtime/stages"
    mkdir -p "$_dir" 2>/dev/null || return 0
    # #2018 format: the leader's start time proves the pgid still names what
    # recorded it, so a later sweep cannot signal a recycled pid.
    local _start
    _start="$(ps -o lstart= -p "$_pgid" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//' || true)"
    printf '%s\t%s' "$_pgid" "$_start" > "${_dir}/${_stage}.pgid" 2>/dev/null || true
    return 0
}

# TERM then KILL a whole process group. `-PGID` is the negative-pid convention.
zbuild_pg_kill() {
    local _pgid="${1:-}"
    [[ -n "$_pgid" && "$_pgid" =~ ^[0-9]+$ ]] || return 0
    # Refuse our own group: `kill -- -PGID` from inside it takes down the runner.
    local _self
    _self="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ' || true)"
    [[ -n "$_self" && "$_self" == "$_pgid" ]] && return 0
    _zbuild_pg_term_then_kill "-$_pgid" "$(_zbuild_pg_grace "${2:-}")"
}

# TERM then KILL a single PID — the path taken when no group could be proven.
# It gets the same grace as the group path: a suite that flushes coverage or
# writes partial results on SIGTERM needs the window wherever it is killed from.
zbuild_pid_kill() {
    local _pid="${1:-}"
    [[ -n "$_pid" && "$_pid" =~ ^[0-9]+$ ]] || return 0
    _zbuild_pg_term_then_kill "$_pid" "$(_zbuild_pg_grace "${2:-}")"
}
