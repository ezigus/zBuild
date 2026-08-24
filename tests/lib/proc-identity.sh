#!/usr/bin/env bash
# Process IDENTITY for test assertions, as distinct from process liveness (#1949).
#
# `kill -0 <pid>` answers "does something own this PID". Tests that hunt their own
# leaked children need "is the process I spawned still running", and the two come
# apart: a reaped PID is reissued by the kernel, so on a loaded CI runner an
# unrelated process answers to a PID a test recorded earlier. route-fast-abort
# counted exactly that and failed with no bug behind it, twice.
#
# Lives here rather than inside the integration file it serves because that file
# is `skip_unless_platform linux` — on a macOS developer machine it never runs,
# so logic embedded in it ships on reasoning alone. That is how #1943 went out.
# Extracted, it is driven by tests/unit/route-fast-abort-identity-test.sh on every
# platform. Do NOT re-implement this check in a caller (#1692).

# _RFA_PROC — the procfs root. A seam for testing, not configuration.
_RFA_PROC="${_RFA_PROC:-/proc}"

# proc_is_my_process <pid> <needle>
#   0 = this PID is a live process whose cmdline contains <needle> (count it)
#   1 = it is not (skip it)
#
# The two "cannot read it" cases mean OPPOSITE things and must not collapse.
# Collapsing them makes a leak detector fail OPEN, which is the permissive
# direction #1796 exists to remove:
#
#   /proc/<pid> absent                     process is gone           -> 1
#   cmdline readable but EMPTY             zombie (#1942)            -> 1
#   cmdline non-empty, needle absent       PID reuse, a stranger     -> 1
#   cmdline non-empty, needle present      ours, alive               -> 0
#   /proc/<pid> exists, cmdline UNREADABLE ambiguous                 -> 0
#
# The last row is the deliberate one: an unreadable cmdline under a directory
# that still exists is not evidence of absence. Count it and let the caller's
# diagnostic explain, rather than silently stop detecting.
proc_is_my_process() {
    local _p="$1" _needle="$2" _cl=""
    [[ -n "$_p" && -n "$_needle" ]] || return 1
    [[ -d "$_RFA_PROC/$_p" ]] || return 1
    # Braces, not `tr ... 2>/dev/null`: a FAILED REDIRECT is reported by the
    # shell itself, not by tr, so stderr must be redirected around the whole
    # compound or the "unreadable" case prints a Permission denied line while
    # claiming to be silent (#1631's class).
    if ! _cl="$( { tr '\0' ' ' < "$_RFA_PROC/$_p/cmdline"; } 2>/dev/null )"; then
        return 0
    fi
    [[ -z "$_cl" ]] && return 1
    [[ "$_cl" == *"$_needle"* ]]
}
