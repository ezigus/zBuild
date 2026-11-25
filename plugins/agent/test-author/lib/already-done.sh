#!/usr/bin/env bash
# plugins/agent/test-author/lib/already-done.sh — test-author's report of a
# [code] requirement the code from before this change already meets (#2543,
# ADR-069, amended 2026-11-14).
#
# No test of such a requirement can fail on the old code, and no test can fix
# its status. The model reports it instead of looking for one:
#   <SPEC id>: already_done / why: <how> / quote: <file> | <one line of it>
#   (a block, #2609; the old one-line form is still read)
# The quote is checked in the copy of the code from before the change — the
# model's word is not taken. A report that holds ends the round with a finding
# for the requirement (ADR-068 §3); one that does not is a finding back to
# test-author.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_TA_ALREADY_DONE_LOADED:-}" ]] && return 0
_ZBUILD_TA_ALREADY_DONE_LOADED=1
# shellcheck source=../../../../scripts/lib/stage-handoff.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/stage-handoff.sh"
# shellcheck source=../../../../scripts/lib/reply-units.sh
declare -F zb_reply_join_v >/dev/null 2>&1 \
    || source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/reply-units.sh"

# _ta_to_design <dir> <findings_json> — a finding only design can fix (a SPEC no
# test can prove, a requirement the old code already meets) goes to
# test-author's design-findings output, the one design takes (#2569, ADR-071
# §1): its own result is test-findings. Added to what the engine's handoff
# writes there in the same run, never in its place.
_ta_to_design() {
    stage_findings_add "$1/test-author-design-result.json" "${2:-[]}" "${_TA_FCODE:-}" || true
}

# _ta_already_done <design.md> <reply> <base_dir> — reads the reply's reports.
# Sets _TA_DONE_VERIFIED (one finding line per report whose quote is in the old
# code), _TA_DONE_IDS (their ids) and _TA_DONE_FINDINGS (one entry per report
# whose quote is not). A report for a SPEC not marked [code] is not read.
_ta_already_done() {
    local design="$1" reply="${2:-}" base="${3:-}"
    _TA_DONE_VERIFIED="" _TA_DONE_IDS="" _TA_DONE_FINDINGS=()
    [[ "$reply" == *already_done* ]] || return 0
    # #2609 (ADR-072 §3): a report written as a block, or wrapped, is one line.
    zb_reply_join_v reply "$reply"
    local blk l sid rest why quote w
    blk="$(extract_acceptance_block "$design" 2>/dev/null)" || blk=""
    local re='^[[:space:]*`_-]*([A-Za-z0-9][A-Za-z0-9_-]*)[*`_]*:[[:space:]]*already_done[[:space:]]*\|[[:space:]]*WHY:[[:space:]]*(.*)$'
    while IFS= read -r l; do
        [[ "$l" =~ $re ]] || continue
        sid="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
        [[ " $_TA_DONE_IDS " == *" $sid "* ]] && continue
        _acceptance_spec_line "$blk" "$sid" || continue
        [[ "${_ACC_SPEC_STATUS:-code}" == code ]] || continue
        [[ "$rest" == *"| QUOTE:"* ]] || { _TA_DONE_FINDINGS+=("$sid's already_done report has no QUOTE — quote a line of the code from before this change that already does it, or write its test"); continue; }
        why="${rest%%| QUOTE:*}"; quote="${rest#*| QUOTE:}"
        why="${why%"${why##*[![:space:]]}"}"; quote="${quote#"${quote%%[![:space:]]*}"}"
        quote="${quote%"${quote##*[![:space:]*\`]}"}"
        w=""
        if [[ -z "$base" ]]; then
            w="could not be checked: there is no copy of the code from before this change"
        # The old code as the repository, and no second copy: the quote is
        # looked for in the code from before the change only.
        elif judge_quote_check_v w "$quote" "" "$base"; then
            _TA_DONE_IDS+="${_TA_DONE_IDS:+ }$sid"
            _TA_DONE_VERIFIED+="${_TA_DONE_VERIFIED:+$'\n'}$sid: the code from before this change already does this — ${why:-it already does it} — evidence: $quote [FIX IN DESIGN: mark it [done] with this evidence, or say what this change makes different]"
            continue
        fi
        _TA_DONE_FINDINGS+=("$sid's already_done quote $w — quote a line of the code from before this change that already does it, or write its test")
    done <<< "$reply"
    return 0
}
