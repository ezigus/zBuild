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

# proc_classify <present_before> <read_ok> <cmdline> <needle> <present_after>
#
# The DECISION, separated from the observations that feed it (#2020).
#
# Every interesting state here is a race — a process on its way out — and a race
# cannot be staged in a fixture directory. That is why this detector has been
# fixed three times (#1942, #1949, #1975) and each fix was reasoned rather than
# observed. A pure function makes every state drivable by writing the
# observations down, including ones that exist for microseconds on a loaded
# runner.
#
# Prints the classification; exits 0 when the process should be COUNTED as a
# leftover and 1 when it should not.
#
#   present_before=0                    gone        not counted
#   read ok, cmdline empty              zombie      not counted   (#1942)
#   read ok, needle absent              stranger    not counted   (PID reuse)
#   read ok, needle present             ours        COUNTED
#   read failed, present_after=0        gone        not counted   (#2020)
#   read failed, present_after=1        unprovable  COUNTED       (fails closed)
#
# The fifth row is the one #2020 added. An entry that was there, could not be
# read, and is GONE by the re-check is a process that exited between two
# syscalls — which is the outcome the assertion wants, not a leak. It cannot
# produce a false negative: a running process does not have its /proc entry
# disappear.
#
# The sixth row must not change. An unreadable cmdline under an entry that is
# still there is not evidence of absence, and a detector that skips what it
# cannot read has stopped detecting — the permissive direction #1796 removes.
proc_classify() {
    local _before="${1:-0}" _readok="${2:-0}" _cl="${3:-}" _needle="${4:-}" _after="${5:-0}"
    if [[ "$_before" != "1" ]]; then
        printf 'gone'; return 1
    fi
    if [[ "$_readok" == "1" ]]; then
        if [[ -z "$_cl" ]]; then printf 'zombie'; return 1; fi
        if [[ -z "$_needle" ]]; then printf 'stranger'; return 1; fi
        if [[ "$_cl" == *"$_needle"* ]]; then printf 'ours'; return 0; fi
        printf 'stranger'; return 1
    fi
    if [[ "$_after" != "1" ]]; then
        printf 'gone'; return 1
    fi
    printf 'unprovable'; return 0
}

# PROC_IDENTITY_REASON — the classification from the last proc_is_my_process
# call, for the caller's diagnostic. Two of the three previous fixes to this
# detector were guesses because the failure output was a bare count, and a count
# that cannot be explained is not evidence.
PROC_IDENTITY_REASON=""

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
#   /proc/<pid> exists, cmdline MISSING    ambiguous                 -> 0
#   /proc/<pid> exists, cmdline UNREADABLE ambiguous                 -> 0
#
# The last TWO rows are the deliberate ones. They reach the same branch by
# different routes — a missing file and an unreadable file both make the
# redirect fail — and both mean the same thing: an unreadable cmdline under a directory
# that still exists is not evidence of absence. Count it and let the caller's
# diagnostic explain, rather than silently stop detecting.
proc_is_my_process() {
    local _p="$1" _needle="$2" _cl="" _readok=0 _before=0 _after=0
    PROC_IDENTITY_REASON=""
    [[ -n "$_p" && -n "$_needle" ]] || return 1
    [[ -d "$_RFA_PROC/$_p" ]] && _before=1
    if [[ "$_before" == "1" ]]; then
        # Braces, not `tr ... 2>/dev/null`: a FAILED REDIRECT is reported by the
        # shell itself, not by tr, so stderr must be redirected around the whole
        # compound or the "unreadable" case prints a Permission denied line while
        # claiming to be silent (#1631's class).
        if _cl="$( { tr '\0' ' ' < "$_RFA_PROC/$_p/cmdline"; } 2>/dev/null )"; then
            _readok=1
        else
            # Re-observe AFTER the failed read, not before: the whole question is
            # whether the entry survived the attempt (#2020).
            [[ -d "$_RFA_PROC/$_p" ]] && _after=1
        fi
    fi
    PROC_IDENTITY_REASON="$(proc_classify "$_before" "$_readok" "$_cl" "$_needle" "$_after")"
    proc_classify "$_before" "$_readok" "$_cl" "$_needle" "$_after" >/dev/null
}
