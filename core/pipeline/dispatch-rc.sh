#!/usr/bin/env bash
# core/pipeline/dispatch-rc.sh — the binary exit-code vocabulary, the fallback
# classification for a dispatch that explained nothing, and the one place a
# legacy engine rc becomes a word (issue #1823, ADR-054 §4).
#
# rc carries exactly TWO facts:
#
#   0  my result file is on disk, read it
#   1  I failed — read my result if present; if it is absent I died
#
# Everything anything needs to say beyond those two belongs in the result file
# (ADR-054 §5), on `disposition` (§6), or on the routing state that already
# carries it. ADR-001's rc=1 → `kind: recovery` routing is deleted: no recovery
# plugin was ever registered and the path was never implemented.
#
# ─── Why an integer channel had to go ───────────────────────────────────────
#
# The engine grew a private rc vocabulary one caller at a time — 5 blocked,
# 6 cycle_abort, 8 blocking_member_failure, 9 llm_unavailable, 10 scope_too_large,
# 11 route_back, 130/143 signal — and every reader mapped it differently.
# `cycle_orchestrator_run` special-cases 8, 11 and 130 and collapses every other
# abort rc to 4 (config_invalid), so a cycle_abort and a SIGTERM both surface to
# an operator as a configuration error. An integer channel with no declared
# vocabulary cannot be enforced, which is the defect ADR-054 exists to remove;
# exempting the engine from its own contract would reproduce it one layer down.
#
# ─── What this file does NOT do ─────────────────────────────────────────────
#
# It does not rip the legacy numbers out. They still flow inside the engine
# during versioned coexistence, and #1850 deletes them together with the v1
# result reader — its acceptance says so in as many words ("the legacy rc
# mapping (5, 8, 9, 10, 11) is deleted"). What changes here is that a legacy
# number is interpreted in exactly ONE place (`dispatch_rc_legacy_reason`)
# instead of at each reader, so there is a single thing for #1850 to remove and
# a single answer to "what does 8 mean today".

[[ -n "${_ZBUILD_DISPATCH_RC_SH_LOADED:-}" ]] && return 0
_ZBUILD_DISPATCH_RC_SH_LOADED=1

# The whole vocabulary. Named so callers stop writing bare integers.
ZBUILD_RC_OK=0
ZBUILD_RC_FAIL=1

# ─── dispatch_rc_narrow <raw_rc> ────────────────────────────────────────────
# Collapse any raw wait status to the binary contract. Non-zero is non-zero;
# the engine never re-derives meaning from HOW non-zero it was.
#
# Call `dispatch_rc_observation` on the RAW status BEFORE narrowing when the
# distinction matters — narrowing is lossy by design, and that loss is the whole
# point. A non-numeric status is a failure, not a 0: a caller holding something
# that is not a number has already lost the status.
dispatch_rc_narrow() {
    local rc="${1-}"
    [[ "$rc" =~ ^[0-9]+$ ]] || { printf '%s' "$ZBUILD_RC_FAIL"; return 0; }
    if [[ "$rc" -eq 0 ]]; then
        printf '%s' "$ZBUILD_RC_OK"
    else
        printf '%s' "$ZBUILD_RC_FAIL"
    fi
}

# ─── dispatch_rc_observation <raw_rc> ───────────────────────────────────────
# What the raw wait status OBSERVED about how the dispatch ended, captured at
# the boundary before the status is narrowed away. Prints one of:
#
#   signal   the process was killed (SIGINT 130, SIGKILL 137, SIGTERM 143, …)
#   timeout  timeout(1)/gtimeout(1) fired — rc 124
#   <empty>  nothing observable; it just returned non-zero
#
# This is an OBSERVATION, not a conclusion. It says what happened to the
# process, and `dispatch_rc_failure_disposition` decides what that means. The
# two are separate because only the first is knowable at the dispatch boundary
# and only the second belongs to ADR-054 §6's closed set.
#
# The signal test is `> 128` rather than a list of the three named codes: any
# 128+N is a death by signal N, and enumerating three of them would silently
# classify the rest as `broken` — a defect report for a stage that was killed.
# 192 is the ceiling because signals stop there; anything above it is a plugin
# returning a large number, which is not a signal death.
dispatch_rc_observation() {
    local rc="${1-}"
    [[ "$rc" =~ ^[0-9]+$ ]] || return 0
    if [[ "$rc" -eq 124 ]]; then printf 'timeout'; return 0; fi
    if [[ "$rc" -gt 128 && "$rc" -le 192 ]]; then printf 'signal'; return 0; fi
    return 0
}

# ─── dispatch_rc_failure_disposition <observation> [rate_limited] ───────────
# ADR-054 §4's fallback table: the ONE place the engine is permitted to infer,
# and it infers a DISPOSITION, not a verdict.
#
#   rate-limit envelope detected  → throttled
#   killed by signal, or rc=124   → interrupted
#   anything else                 → broken
#
# `rate_limited` is passed as "1" by a caller that ran the router's rate-limit
# detector (#1237) over the response envelope. It is a separate argument rather
# than a fourth observation value because it is evidence from the RESPONSE, not
# from the wait status — the process exited perfectly normally while carrying a
# 429.
#
# Rate-limit wins over signal deliberately. The two responses are not equally
# safe when the evidence is ambiguous: `interrupted` retries immediately, which
# for a throttled stage is simply throttled again — the zero-output loop that
# burns max_iterations that #1723 reports. `throttled` waits first, which costs
# a genuine interruption one bounded wait and nothing else. Where the engine
# must guess, it guesses toward the response that cannot spin.
#
# Everything else is `broken` and NOT something softer: a dispatch that
# explained nothing cannot be distinguished from a defective one, and guessing
# "probably transient" is how a real defect retries forever.
dispatch_rc_failure_disposition() {
    local observation="${1-}" rate_limited="${2:-0}"
    if [[ "$rate_limited" == "1" ]]; then printf 'throttled'; return 0; fi
    case "$observation" in
        signal|timeout) printf 'interrupted' ;;
        *)              printf 'broken' ;;
    esac
}

# ─── dispatch_rc_legacy_reason <raw_rc> ─────────────────────────────────────
# THE v1 boundary. A legacy engine rc becomes the reason word the engine
# already sets for it on `_CYCLE_LAST_TERMINATED_REASON` — this function does
# not invent a vocabulary, it names the one that is already there, so a reader
# can consult a word instead of re-interpreting a number.
#
# Prints nothing and returns 1 for a code with no legacy meaning, so a caller
# cannot mistake "I have no word for this" for a word.
#
# DELETED WHOLESALE BY #1850, together with the v1 result reader. Nothing new
# may be added here — that is what the guard test in
# tests/unit/dispatch-rc-guard-test.sh pins.
#
# 143 is mapped alongside 130 on purpose: `_cycle_handle_terminal_rc` has a
# `130)` arm and no `143)` arm, so a SIGTERM currently falls through to
# `*) reason="error"` and is reported to an operator as an ordinary error
# rather than an abort. Naming it here is what makes the two agree.
dispatch_rc_legacy_reason() {
    case "${1-}" in
        4)     printf 'config_invalid' ;;
        5)     printf 'blocked' ;;
        6)     printf 'cycle_abort' ;;
        8)     printf 'blocking_member_failure' ;;
        9)     printf 'llm_unavailable' ;;
        10)    printf 'scope_too_large' ;;
        11)    printf 'route_back' ;;
        130)   printf 'aborted' ;;
        143)   printf 'aborted' ;;
        *)     return 1 ;;
    esac
}

# ─── dispatch_rc_legacy_disposition <raw_rc> ────────────────────────────────
# The subset of legacy rcs that ADR-054 §6 has a word for, so a reader on the
# disposition channel gets the same answer as one on the reason channel.
#
# Only three map, and each is an exact fit against §6's own wording:
#
#   9  llm_unavailable  → unavailable  "halt; operator action required"
#   10 scope_too_large  → exhausted    "more budget, or the work must shrink"
#   130/143 signal      → interrupted  "retry as-is"
#
# The rest — blocked, cycle_abort, blocking_member_failure, route_back,
# config_invalid — deliberately map to NOTHING. They are control-flow decisions
# the cycle made, not statements about whether a stage got far enough to
# produce a verdict worth reading, and ADR-054 §4 re-homes them onto routing
# state (ADR-045) and the blocking-member halt (ADR-013) rather than onto §6.
# Forcing them into the disposition set would be the invented default the whole
# contract exists to forbid.
#
# Prints nothing and returns 1 when there is no mapping.
dispatch_rc_legacy_disposition() {
    case "${1-}" in
        9)        printf 'unavailable' ;;
        10)       printf 'exhausted' ;;
        130|143)  printf 'interrupted' ;;
        *)        return 1 ;;
    esac
}
