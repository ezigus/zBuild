#!/usr/bin/env bash
# scripts/lib/acceptance-judge.sh — the design as the judges read it: its decision prose,
# and each requirement in plain words (#2304, ADR-069 §7).
# Split from acceptance-block.sh (#2525), which sources it: load that file, not
# this one.
#
# Sourced library: no set -euo pipefail.

# design_decisions_prose_v <var> <design_md> [max_lines] — the design's DECISION
# PROSE: everything outside fenced blocks, under whatever heading design gave it,
# capped at max_lines (default 120; 0 is no cap). UNCLEAR, REMOVED and WIRING
# lines, with the lines they wrap onto up to a blank line, are not decisions, nor
# are headings alone; no
# leading blank line, and one blank line between paragraphs. One extractor for
# build (honours the decisions), review-lens (judges against them, #1654) and
# design's check (judges them, #2567), so none reads a design differently. No fork.
design_decisions_prose_v() {
    local -n _ddp="$1"; local _ddp_f="${2:-}" _ddp_cap="${3:-120}" _l _t _in=0 _skip=0 _n=0 _blank=0 _prose=0
    _ddp=""
    [[ -n "$_ddp_f" && -f "$_ddp_f" ]] || return 0
    while IFS= read -r _l || [[ -n "$_l" ]]; do
        _l="${_l%$'\r'}"
        if [[ "$_l" =~ ^[[:space:]]*'```' ]]; then _in=$(( 1 - _in )); _skip=0; continue; fi
        (( _in )) && continue
        _t="${_l#"${_l%%[![:space:]]*}"}"; _t="${_t%"${_t##*[![:space:]]}"}"
        if [[ -z "$_t" ]]; then _skip=0; [[ -n "$_ddp" ]] && _blank=1; continue; fi
        if [[ "$_t" == UNCLEAR:* || "$_t" == REMOVED:* || "$_t" == WIRING:* ]]; then _skip=1; continue; fi
        (( _skip )) && continue
        (( _blank )) && { _ddp+=$'\n'; _blank=0; }
        [[ "$_t" == \#* ]] || _prose=1
        _ddp+="$_l"$'\n'; _n=$(( _n + 1 ))
        (( _ddp_cap > 0 && _n >= _ddp_cap )) && break
    done < "$_ddp_f"
    # Headings alone are no decisions.
    if (( _prose )); then _ddp="${_ddp%$'\n'}"; else _ddp=""; fi
    return 0
}

# design_decisions_prose <design_md> [max_lines] — the same, printed.
design_decisions_prose() {
    local _ddp_out; design_decisions_prose_v _ddp_out "${1:-}" "${2:-120}"
    [[ -n "${_ddp_out//[[:space:]]/}" ]] && printf '%s\n' "$_ddp_out"
    return 0
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
