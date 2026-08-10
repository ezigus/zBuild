#!/usr/bin/env bash
# core/pipeline/disposition.sh — the disposition vocabulary and the engine's
# response table (issue #1822, ADR-054 §6).
#
# ONE question — "is this failure recoverable?" — answered ONCE, here, from a
# field the stage declared. Before this file, four stages answered it four ways:
# build's `did_not_finish` carve-out (#1208), design's separate copy of it
# (#1261), plan's hand-rolled `return 1` that killed the whole run, and test's
# nothing-at-all (#1747). Every new stage added a fifth answer.
#
# `disposition` is a CLOSED set owned by the engine. Each word exists only
# because the engine acts differently on it — a word with no distinct response
# does not belong in the set:
#
#   complete     nothing went wrong
#   interrupted  retry as-is
#   throttled    wait, then retry
#   exhausted    more budget, or the work must shrink
#   unavailable  halt; operator action required
#   broken       halt; it is a defect
#
# The response table lives HERE, not in any plugin: no stage decides its own
# retry policy. A stage declares what happened; the engine decides what to do.
#
# Two rules the rest of the engine depends on:
#   - A disposition outside the set is a STRUCTURAL FAILURE. No default is ever
#     invented. Inventing one is how "unrecognized is never a failure" — the
#     #1819 generator defect — grows back.
#   - `broken` is the engine's OWN conclusion about a dispatch that explained
#     nothing. The engine never writes it into the stage's artifact; it holds it
#     on its own channels (`runner_read_stage_disposition`, the dispatch event).
#
# NOT in this file, deliberately: the re-dispatch mechanism. ADR-054's delivery
# map gives #1822 the vocabulary and the table; nothing owns the loop yet, and
# no plugin emits a v2 result to drive one (`grep result_contract plugins/` is
# empty). `disposition_retryable` / `disposition_wait_s` state the policy so the
# loop, when it lands, reads it instead of re-deriving it.
#
# Name collision, for the record: ADR-021's member-disposition contract already
# writes `.disposition` on plugin primaries with an unrelated vocabulary
# (terminal|recoverable|advisory|none — see `_cycle_member_terminal_failure` in
# cycle-orchestrator.sh). The two axes are genuinely different: ADR-021 asks
# "this stage's verdict was fail — does that stop the cycle?", ADR-054 asks "did
# the stage get far enough to produce a verdict worth reading?". They chain; they
# do not overlap. Those artifacts are v1, and the reader only consults this
# vocabulary at `result_contract >= 2`, so the collision is inert today. Freeing
# the field name belongs with the plugin migration (#1832), not here.

[[ -n "${_ZBUILD_DISPOSITION_SH_LOADED:-}" ]] && return 0
_ZBUILD_DISPOSITION_SH_LOADED=1

# The closed set, in ADR-054 §6 table order.
_ZBUILD_DISPOSITION_SET="complete interrupted throttled exhausted unavailable broken"

# How long a `throttled` stage waits before a retry. Overridable because the
# right backoff is a deployment property, not a contract property; bounded and
# validated because it arrives from the environment.
_ZBUILD_DISPOSITION_THROTTLE_WAIT_DEFAULT=30

# ─── disposition_vocabulary ─────────────────────────────────────────────────
# The closed set, space-separated, in table order. Callers iterate this rather
# than restating the words — a second copy of the list is a second contract.
disposition_vocabulary() {
    printf '%s' "$_ZBUILD_DISPOSITION_SET"
}

# ─── disposition_is_valid <disposition> ─────────────────────────────────────
# rc 0 when the word is a member of the closed set, 1 otherwise. An empty
# string is NOT a member: a v1 result declares no disposition at all, and that
# absence is distinct from any of the six words.
disposition_is_valid() {
    local d="${1-}"
    [[ -n "$d" ]] || return 1
    case " $_ZBUILD_DISPOSITION_SET " in
        *" $d "*) return 0 ;;
        *)        return 1 ;;
    esac
}

# ─── disposition_response <disposition> ─────────────────────────────────────
# THE response table. Prints the engine's response and returns 0 for a member of
# the set; prints nothing and returns 1 for anything else.
#
# Refusing to answer for an unknown word is the point: a caller that wants a
# response for `wedged` has already failed structurally, and handing it back a
# plausible-looking default would bury that.
#
# `unavailable` and `broken` both stop the run but are NOT interchangeable — an
# operator reading the log has to distinguish "something outside us is down, a
# human needs to act" from "this is our own defect". They differ in what is
# reported, not in the stopping.
disposition_response() {
    case "${1-}" in
        complete)    printf 'proceed' ;;
        interrupted) printf 'retry' ;;
        throttled)   printf 'retry_after_wait' ;;
        exhausted)   printf 'escalate' ;;
        unavailable) printf 'halt_unavailable' ;;
        broken)      printf 'halt_broken' ;;
        *)           return 1 ;;
    esac
}

# ─── disposition_halts <disposition> ────────────────────────────────────────
# rc 0 when the engine must stop the run. Derived from the response table rather
# than restating it, so the two can never disagree.
# rc 2 (not 1) for a non-member: "I cannot answer" is not "it does not halt", and
# a caller must have already treated the unknown word as a structural failure.
disposition_halts() {
    local r; r="$(disposition_response "${1-}")" || return 2
    case "$r" in
        halt_*) return 0 ;;
        *)      return 1 ;;
    esac
}

# ─── disposition_retryable <disposition> ────────────────────────────────────
# rc 0 when the engine may re-dispatch the stage. Retry is a property of the
# DISPOSITION, not of the stage — this is the inversion ADR-054 §6 describes.
# Derived from the response table, which is what makes "nothing both halts and
# retries" structurally true rather than a rule someone has to remember.
# rc 2 for a non-member, on the same terms as disposition_halts.
disposition_retryable() {
    local r; r="$(disposition_response "${1-}")" || return 2
    case "$r" in
        retry|retry_after_wait) return 0 ;;
        *)                      return 1 ;;
    esac
}

# ─── disposition_wait_s <disposition> ───────────────────────────────────────
# Seconds to wait before re-dispatching. What separates `interrupted` from
# `throttled` is not the word but this number: a throttled stage re-dispatched
# immediately is simply throttled again, which is a retry loop that burns budget
# to learn nothing. Non-members return 1 and print nothing.
disposition_wait_s() {
    local d="${1-}"
    disposition_is_valid "$d" || return 1
    # A wait is meaningless for a disposition that is not going to be retried,
    # and answering "0" for one is actively dangerous: a caller that skipped
    # `disposition_retryable` would read "0 seconds until retry" for `broken`
    # and re-dispatch a halted stage immediately. Refuse instead of returning a
    # plausible-looking number.
    disposition_retryable "$d" || return 1
    if [[ "$d" != "throttled" ]]; then
        printf '0'
        return 0
    fi
    local w="${ZBUILD_DISPOSITION_THROTTLE_WAIT_S:-$_ZBUILD_DISPOSITION_THROTTLE_WAIT_DEFAULT}"
    # Environment input: must be a positive integer within a sane bound, else
    # fall back to the default rather than honouring a value that would hang a
    # run or defeat the wait entirely.
    if [[ "$w" =~ ^[0-9]+$ ]] && [[ "$w" -ge 1 ]] && [[ "$w" -le 3600 ]]; then
        printf '%s' "$w"
    else
        printf '%s' "$_ZBUILD_DISPOSITION_THROTTLE_WAIT_DEFAULT"
    fi
}
