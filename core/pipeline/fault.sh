#!/usr/bin/env bash
# core/pipeline/fault.sh — the fault-class vocabulary (#1987).
#
# A gate that finds a problem it cannot fix used to write `route_target: design`
# into its result. That is a stage naming another stage — the thing ADR-055
# eliminated for data, where a consumer names the ARTIFACT it needs and never
# the producer. It is also wrong in general: the same gate in a flow with no
# design stage names a destination that does not exist.
#
# So a gate declares the KIND of fault instead — something it genuinely knows
# about its own failure — and the TEMPLATE maps that class to a destination,
# because the template is the thing that knows the flow's shape. The engine
# matches; it does not judge.
#
# This deliberately mirrors disposition.sh, which ADR-054 §6 describes as "a
# closed set, owned by the engine. Each word exists only because the engine acts
# differently on it." A second shape here would be a second contract.
#
# The two axes do not overlap. `disposition` answers "did the stage get far
# enough to produce a verdict worth reading?"; `fault` answers "the verdict was
# fail — whose problem is it?". An infra flake is a disposition, never a fault:
# `environment` is absent from this set precisely because
# interrupted/throttled/unavailable/broken already own it, and two vocabularies
# answering one question is how #1767 happened.

[[ -n "${_ZBUILD_FAULT_SH_LOADED:-}" ]] && return 0
_ZBUILD_FAULT_SH_LOADED=1

# The closed set, in table order.
#
#   specification  — what we agreed to build is wrong or unsatisfiable as
#                    written. Building harder cannot fix it.
#   scope          — the boundary is wrong; the work needs files outside it.
#                    Kept distinct from `specification` even though both route
#                    to design in simple.yaml today: where intake or plan owns
#                    the boundary it routes elsewhere, and merging now would
#                    make every historical `specification` ambiguous if it is
#                    split later.
#   implementation — the code is wrong. Fix it here; no rewind. An EXPLICIT
#                    word rather than an absent field, so "I decided this is
#                    local" and "I never thought about it" stay distinguishable.
_ZBUILD_FAULT_SET="specification scope implementation"

# ─── fault_vocabulary ────────────────────────────────────────────────────────
# The closed set, space-separated, in table order. Callers iterate this rather
# than restating the words — a second copy of the list is a second contract.
fault_vocabulary() {
    printf '%s' "$_ZBUILD_FAULT_SET"
}

# ─── fault_is_valid <fault> ──────────────────────────────────────────────────
# rc 0 when the word is a member of the closed set, 1 otherwise. The empty
# string is NOT a member: a gate that declared no fault is distinct from one
# that declared any of the three.
fault_is_valid() {
    local f="${1-}"
    [[ -n "$f" ]] || return 1
    case " $_ZBUILD_FAULT_SET " in
        *" $f "*) return 0 ;;
        *)        return 1 ;;
    esac
}

# ─── fault_routes <fault> ────────────────────────────────────────────────────
# rc 0 when the fault sends the work back to an earlier unit, 1 when it is
# fixed where it was found, and rc 2 for a non-member.
#
# rc 2 (not 1) for an unknown word, matching disposition_halts: "I cannot
# answer" is not "it does not rewind", and a caller asking about `wedged` has
# already failed structurally. Handing back a plausible default would bury that.
#
# WHERE it rewinds to is not decided here — that is the template's mapping.
# This only says whether a destination is needed at all.
fault_routes() {
    local f="${1-}"
    fault_is_valid "$f" || return 2
    case "$f" in
        specification|scope) return 0 ;;
        *)                   return 1 ;;
    esac
}
