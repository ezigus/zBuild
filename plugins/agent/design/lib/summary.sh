#!/usr/bin/env bash
# plugins/agent/design/lib/summary.sh — what a passing design says it produced
# (#2476, ADR-064 §4).
#
# The summary's line is the row a reader sees on the issue: it names the SPECs,
# and each SPEC's line says what it covers, never only how many there are.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_DESIGN_SUMMARY_LOADED:-}" ]] && return 0
_ZBUILD_DESIGN_SUMMARY_LOADED=1

# _design_pass_summary_write <artifact_dir> <design_md> — design-summary.md for
# a passing design. The block is read once; each SPEC by the shell.
_design_pass_summary_write() {
    local dir="$1" design="$2" block line ids="" body="" sid
    local -a order=()
    block="$(extract_acceptance_block "$design" 2>/dev/null || true)"
    while IFS= read -r line; do
        [[ "$line" == "TESTFILES:" ]] && break
        [[ "$line" =~ $_ACCEPTANCE_SPEC_RE ]] && order+=("${BASH_REMATCH[1]}")
    done <<< "$block"
    for sid in ${order[@]+"${order[@]}"}; do
        _acceptance_spec_line "$block" "$sid" || continue
        ids+="${ids:+, }$sid"
        body+="- ${sid}${_ACC_SPEC_COVERS:+ (covers ${_ACC_SPEC_COVERS})}: ${_ACC_SPEC_TEXT}"$'\n'
    done
    local scope; scope="$(_extract_scope_from_design "$design" 2>/dev/null || true)"
    [[ -n "$scope" ]] && body+="- the files it may change: ${scope//,/, }"$'\n'
    # ADR-068 §6: what it did about each finding it was given.
    local _dpa=""; zb_answers_summary_v _dpa _DESIGN_ANSWERS; body+="$_dpa"$'\n'
    stage_summary_write "$dir/design-summary.md" "design" "pass" \
        "${#order[@]} SPEC(s)${ids:+: $ids}" "${body%$'\n'}"
}
