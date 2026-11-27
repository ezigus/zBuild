#!/usr/bin/env bash
# plugins/agent/design/lib/checks-trace.sh — every SPEC traces to a requirement
# or limit intake listed, by name in its covers: (#2629, ADR-075 §2). C7 asks
# the other way round — every requirement has a SPEC. Its own file, to keep
# checks.sh under 500 lines.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_DESIGN_CHECKS_TRACE_LOADED:-}" ]] && return 0
_ZBUILD_DESIGN_CHECKS_TRACE_LOADED=1
# shellcheck source=../../../../scripts/lib/trace.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/trace.sh"

# _dck_specs_trace <req_rows> <spec-covers lines> — <req_rows> as _design_checks
# reads requirements.json ("A|L<US>id<US>text"); each other line
# "<spec><US><covers ids, space-separated>", in the design's order. Adds to its
# caller's violations SPEC_COVERS_NOTHING <spec> and SPEC_COVERS_UNKNOWN <spec>
# <id>. A list with no requirement or limit asks nothing.
_dck_specs_trace() {
    local listed=" " k id spec covers c
    while IFS=$'\x1f' read -r k id _; do
        [[ ( "$k" == A || "$k" == L ) && -n "$id" ]] && listed+="$id "
    done <<< "$1"
    [[ "$listed" != " " ]] || return 0
    while IFS=$'\x1f' read -r spec covers; do
        [[ -n "$spec" ]] || continue
        if [[ -z "${covers// }" ]]; then violations+=("SPEC_COVERS_NOTHING $spec"); continue; fi
        for c in $covers; do
            [[ "$listed" == *" $c "* ]] || violations+=("SPEC_COVERS_UNKNOWN $spec $c")
        done
    done <<< "$2"
    return 0
}

# _dck_trace_plain <violation> — its words, in the rule's (rc 1: not one of these).
_dck_trace_plain() {
    local rest="${1#* }" id third m
    id="${rest%% *}"; third="${rest#* }"; third="${third%% *}"
    case "$1" in
        SPEC_COVERS_NOTHING*)
            zb_trace_finding_v m "$id, which covers no requirement," "requirement intake listed" "the issue, with a requirement intake lists,"
            printf '%s: end its line with " covers: <the id of the requirement it delivers>" (before any " evidence: "), or take the SPEC out' "$m" ;;
        SPEC_COVERS_UNKNOWN*)
            printf '%s covers %s, which is not a requirement or limit intake listed — name in its covers: the requirement it delivers, or take the SPEC out: a SPEC traces to what intake listed' "$id" "$third" ;;
        *) return 1 ;;
    esac
}
