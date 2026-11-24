#!/usr/bin/env bash
# plugins/agent/test-author/lib/handoff.sh — test-author's "not mine" answers
# handed to the stage that can fix them (#2599, ADR-068 §6, ADR-071 §1).
#
# #2532 run 45231040380: test-author answered a lens finding "not mine — the
# fix is in docs/adr/ADR-009…; the code stage must reference it" and passed;
# nothing handed it on, and the lens found it again the next round.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_TA_HANDOFF_LOADED:-}" ]] && return 0
_ZBUILD_TA_HANDOFF_LOADED=1
# shellcheck source=../../../../scripts/lib/test-paths.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/test-paths.sh"
# shellcheck source=../../../../scripts/lib/stage-handoff.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/stage-handoff.sh" 2>/dev/null || true

# _ta_write_code_findings <artifact_dir> <reply> — each "not mine" that says
# the code can fix it (zb_not_mine_target_v) as a finding for build
# (test-author-code-result.json, topic code-findings); none leaves no file.
# One that says design must, or answers a finding build handed to test-author
# (build's id code) — never handed back — goes to design
# (test-author-design-result.json). Each keeps its id and the finding's text.
_ta_write_code_findings() {
    local art="${1%/}" a why t bcode="" lines="" back="" ft=""
    local -a ans=()
    zb_finding_code_v bcode "${BASH_SOURCE[0]%/*}/../../build/manifest.yaml"
    zb_answers_collect_v ans "${2:-}"
    for a in ${ans[@]+"${ans[@]}"}; do
        why="${a#*:}"; why="${why#"${why%%[![:space:]]*}"}"
        [[ "$why" =~ ^[Nn]ot[[:space:]]+mine ]] || continue
        # Its own check's findings are the old path's (stage_handoff_unchanged).
        [[ -n "${_TA_FCODE:-}" && "${a%%:*}" == "$_TA_FCODE"-* ]] && continue
        why="${why:9}"; why="${why#"${why%%[![:space:]—-]*}"}"
        ft="${_ZB_ANS_FINDING[${a%%:*}]:-}"; ft="${ft:+ — the finding: ${ft//$'\n'/ }}"
        zb_not_mine_target_v t "$why"
        if [[ "$t" == design || ( -n "$bcode" && "${a%%:*}" == "$bcode"-* ) ]]; then
            back+="${a%%:*}: test-author answered not mine: $why$ft"$'\n'
        elif [[ "$t" == code ]]; then
            lines+="${a%%:*}: test-author answered not mine: $why$ft"$'\n'
        fi
    done
    if [[ -n "$lines" ]]; then
        stage_result_write "$art/test-author-code-result.json" fail "test-author says these are the code's to fix" \
            "{\"findings\":$(printf '%s' "$lines" | stage_findings_json "$art" "${_TA_FCODE:-}")}" 2>/dev/null || true
    elif [[ -e "$art/test-author-code-result.json" ]]; then
        rm -f "$art/test-author-code-result.json" 2>/dev/null || true
    fi
    if [[ -n "$back" ]] && declare -F stage_findings_add >/dev/null 2>&1; then
        stage_findings_add "$art/test-author-design-result.json" \
            "$(printf '%s' "$back" | jq -Rnc '[inputs | select(length > 0) | {text: .}]')" "${_TA_FCODE:-}" || true
    fi
    return 0
}
