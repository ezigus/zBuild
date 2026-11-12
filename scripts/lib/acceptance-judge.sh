#!/usr/bin/env bash
# scripts/lib/acceptance-judge.sh — the design as the judges read it: its decision prose,
# and each requirement in plain words (#2304, ADR-069 §7).
# Split from acceptance-block.sh (#2525), which sources it: load that file, not
# this one.
#
# Sourced library: no set -euo pipefail.

# design_decisions_prose <design_md> [max_lines] — the design's DECISION PROSE:
# everything outside fenced blocks, capped (default 120 lines). Empty when absent.
# Shared by build (honours the decisions) and review-lens (judges against them,
# #1654) — one extractor, so the two cannot read a design differently.
design_decisions_prose() {
    local design_md="${1:-}" cap="${2:-120}" body
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 0
    body="$(awk -v cap="$cap" '
        /^```/ { infence = !infence; next }
        infence { next }
        { print; emitted++ }
        emitted >= cap { exit }
    ' "$design_md" 2>/dev/null || true)"
    body="$(printf '%s\n' "$body" | sed '/./,$!d')"
    [[ -z "${body//[[:space:]]/}" ]] && return 0
    printf '%s\n' "$body"
}

# acceptance_requirements_for_judge <design_md>  (#2304, ADR-069 §7)
# The requirements as issue-acceptance reads them: each one's words and, in
# plain words, what its status means — never the raw tag. A done requirement
# also gets its evidence, a file and a piece of its text: the judge opens the
# file and reads as much of it as it needs (#2464, ADR-072 §2 — no window of
# lines). The caller cleans the text before it reaches a model.
acceptance_requirements_for_judge() {
    local design_md="${1:-}" blk l sid ev
    blk="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    while IFS= read -r l; do
        [[ "$l" =~ $_ACCEPTANCE_SPEC_RE ]] || continue
        sid="${BASH_REMATCH[1]}"
        _acceptance_spec_line "$blk" "$sid" || continue
        printf -- '- %s: %s\n' "$sid" "$_ACC_SPEC_TEXT"
        # #2467: and its parts, each on its own line.
        local -a _rfj_p=(); local _rfj_x
        acceptance_parts_shown_v _rfj_p "$_ACC_SPEC_PARTS"
        for _rfj_x in ${_rfj_p[@]+"${_rfj_p[@]}"}; do printf '  %s: %s\n' "${_rfj_x%%$'\t'*}" "${_rfj_x#*$'\t'}"; done
        case "$_ACC_SPEC_STATUS" in
            no-code) printf '  Status: needs work (no code) — nothing checked it mechanically; judge it yourself, and say whether its tests would catch it broken\n' ;;
            # #2525 (ADR-069 §7): no test proves a doc; the judge reads it.
            doc)     printf '  Status: a doc change — no test checks it; read the doc on the branch and judge whether it says this\n'; continue ;;
            done)    printf '  Status: already done — design says the code already does this; check the claim\n' ;;
            *)       printf '  Status: needs work (code) — its test failed on the old code and passes now\n'; continue ;;
        esac
        [[ "$_ACC_SPEC_STATUS" == "done" && "$_ACC_SPEC_REST" == *" evidence: "* ]] || continue
        local -a _evs=(); local _evl="${_ACC_SPEC_REST#* evidence: }"
        _acceptance_evidence_items_v _evs "${_evl%% covers: *}"
        for ev in "${_evs[@]+"${_evs[@]}"}"; do
            printf '  Evidence: %s — open the file and read the code around that text\n' "$ev"
        done
    done <<< "$blk"
    return 0
}
