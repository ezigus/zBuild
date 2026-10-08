#!/usr/bin/env bash
# plugins/tool/pr-open/lib/advisory-section.sh — the PR body's advisory-review
# section, rendered from review-report.json. Split from plugin.sh to keep it
# under the 500-line guideline. Sourced library: no set -euo pipefail.

# Findings are LLM-authored free text rendered into a GitHub PR body: strip
# ANSI, flatten control chars, and escape markdown/HTML metacharacters so a
# finding cannot inject active markup. Messages are truncated to bound the
# body size - GitHub rejects a create over ~65 KB.
#
# Only \ [ ] < > are escaped, deliberately. Those are the ones that inject:
# escaping [ and ] already breaks "[text](url)" without touching the parens,
# and escaping < > blocks raw HTML. Backticks, _ and * are left alone
# because findings use them as prose formatting - escaping those too was
# measured and turned every message into backslash noise.
_PR_OPEN_FINDING_JQ_DEFS='
    def esc: tostring
        | gsub("\\e\\[[0-9;?]*[A-Za-z~]"; "")
        | gsub("\\p{Cntrl}"; " ")
        | gsub("(?<c>[\\\\\\[\\]<>])"; "\\" + .c);
    def rank: (. // "" | ascii_downcase) as $s
        | {"critical":0,"high":1,"medium":2,"low":3}[$s] // 4;
    def loc: (.file | esc)
        + (if (.line | type) == "number" then ":\(.line)" else "" end);
    def msg: (.messages // [])
        | if length > 0 then
              (.[0] | tostring
                | if length > 300 then .[0:300] + "..." else . end
                | esc)
          else "" end;
    def bullet: "- **[" + (.severity | esc) + "]** " + loc
        + (msg | if . == "" then "" else " - " + . end)
        + " _(" + ((.lenses // []) | map(esc) | join(", ")) + ")_";
'

# ─── _pr_open_render_advisory_section ────────────────────────────────────────
# Renders a markdown summary of review-report.json for the PR body.
# Absent file   -> "no advisory review ran"
# Unreadable    -> says so explicitly (never "no findings"; #1618)
# findings=[]   -> "no findings"
# otherwise     -> count/lens header + top-5 bullets sorted by severity
#                  + <details> block for any beyond the first five.
_pr_open_render_advisory_section() {
    local advisory_report="$1"
    if [[ ! -f "$advisory_report" ]]; then
        printf 'no advisory review ran'
        return 0
    fi

    # A report we cannot parse must not fall through to the "no findings"
    # wording: that claims a clean review we never actually read (#1618).
    local findings_count lenses_count
    if ! findings_count="$(jq -r '.findings | if type=="array" then length else "invalid" end' \
        "$advisory_report" 2>/dev/null)" || [[ ! "$findings_count" =~ ^[0-9]+$ ]]; then
        printf 'advisory review ran but its report could not be read - findings not rendered'
        return 0
    fi
    lenses_count="$(jq -r '.lenses | if type=="array" then length else 0 end' \
        "$advisory_report" 2>/dev/null || echo 0)"
    [[ "$lenses_count" =~ ^[0-9]+$ ]] || lenses_count=0

    # #1849: a lens that did not run reviewed nothing. Say so first — zero
    # findings from a review that never happened is not "no findings".
    local _nr_n _nr_names _nr_prefix=""
    _nr_n="$(jq -r '(.did_not_run // []) | length' "$advisory_report" 2>/dev/null || echo 0)"
    if [[ "$_nr_n" =~ ^[0-9]+$ && "$_nr_n" -gt 0 ]]; then
        _nr_names="$(jq -r '.did_not_run | join(", ")' "$advisory_report" 2>/dev/null || true)"
        _nr_prefix="${_nr_n} of ${lenses_count} lens(es) did not run (${_nr_names}) - their review is missing, not clean. "
    fi

    if [[ "$findings_count" -eq 0 ]]; then
        if [[ -n "$_nr_prefix" ]]; then
            printf '%sno findings from the lenses that ran' "$_nr_prefix"
        else
            printf 'no findings'
        fi
        return 0
    fi
    printf '%s' "$_nr_prefix"

    local _jq_defs="$_PR_OPEN_FINDING_JQ_DEFS"'
        def sorted: [ .findings[] ] | sort_by(.severity | rank);
    '

    printf '%d finding(s) across %d lens(es)\n' "$findings_count" "$lenses_count"

    jq -r "$_jq_defs"' sorted | .[0:5][] | bullet' "$advisory_report" 2>/dev/null || true

    if [[ "$findings_count" -gt 5 ]]; then
        local rest_count=$(( findings_count - 5 ))
        printf '\n<details><summary>%d more finding(s)</summary>\n\n' "$rest_count"
        jq -r "$_jq_defs"' sorted | .[5:][] | bullet' "$advisory_report" 2>/dev/null || true
        printf '\n</details>'
    fi
}

# ─── _pr_open_render_pre_existing_section ────────────────────────────────────
# Lists the report's pre_existing findings: problems the code had before this
# change. They do not count against the change, but every lens finding reaches
# the PR (ADR-040 2026-10-05, #2301). Prints nothing when there are none or the
# report cannot be read (the advisory section already says so). Bounded like
# the advisory list: five bullets inline, the rest in a <details> block.
_pr_open_render_pre_existing_section() {
    local advisory_report="$1" n
    [[ -f "$advisory_report" ]] || return 0
    n="$(jq -r '.pre_existing | if type=="array" then length else 0 end' \
        "$advisory_report" 2>/dev/null || true)"
    [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] || return 0

    local _jq_defs="$_PR_OPEN_FINDING_JQ_DEFS"'
        def sorted: [ .pre_existing[] ] | sort_by(.severity | rank);
    '
    printf '%d finding(s)\n' "$n"
    jq -r "$_jq_defs"' sorted | .[0:5][] | bullet' "$advisory_report" 2>/dev/null || true
    if [[ "$n" -gt 5 ]]; then
        printf '\n<details><summary>%d more pre-existing finding(s)</summary>\n\n' "$(( n - 5 ))"
        jq -r "$_jq_defs"' sorted | .[5:][] | bullet' "$advisory_report" 2>/dev/null || true
        printf '\n</details>'
    fi
}

# _pr_open_compose_body <issue> <plan_goal> <review_json> <review_verdict>
#   <advisory_report> <test_verdict> [unsettled_block] [forced_draft] — the PR
# body. #1799: when the run did not settle, its warning block comes first, right
# after the separator, and a forced draft carries zBuild's hidden marker at the
# end (lib/unsettled.sh). #2301: findings the lenses
# marked pre-existing get their own section, so every lens finding reaches the
# PR (ADR-040 2026-10-05). The advisory block is followed by a BLANK line: it
# can end in a closing </details>, and GitHub keeps consuming an HTML block
# until one appears. It is added here, not inside the renderers, because the
# command substitution strips every trailing newline they emit.
_pr_open_compose_body() {
    local issue_num="$1" plan_summary="$2" review_json_path="$3" review_verdict="$4"
    local advisory_report="$5" test_verdict="$6" unsettled="${7:-}" forced="${8:-false}"
    local advisory_block pre_existing_section lead="---" tail=""
    [[ -n "$unsettled" ]] && lead+=$'\n'"${unsettled}"$'\n'
    [[ "$forced" == "true" ]] && tail=$'\n'"$(_pr_open_forced_draft_marker)"
    advisory_block="**Advisory review (non-blocking, ADR-040):** $(_pr_open_render_advisory_section "$advisory_report")"
    pre_existing_section="$(_pr_open_render_pre_existing_section "$advisory_report")"
    if [[ -n "$pre_existing_section" ]]; then
        advisory_block+=$'\n\n'"**Already in the code before this change (not introduced here):** ${pre_existing_section}"
    fi
    if [[ -f "$review_json_path" ]]; then
        printf '%s\n\n%s\n%s\n%s\n%s\n\n%s\n%s\n%s%s' \
            "${issue_num:+Closes #${issue_num}}" "$lead" \
            "**Plan goal:** ${plan_summary:-N/A}" \
            "**Review verdict:** ${review_verdict:-N/A}" \
            "$advisory_block" "**Test verdict:** ${test_verdict:-N/A}" "" \
            "Generated by zBuild automation." "$tail"
    else
        printf '%s\n\n%s\n%s\n%s\n\n%s\n%s\n%s%s' \
            "${issue_num:+Closes #${issue_num}}" "$lead" \
            "**Plan goal:** ${plan_summary:-N/A}" \
            "$advisory_block" "**Test verdict:** ${test_verdict:-N/A}" "" \
            "Generated by zBuild automation." "$tail"
    fi
}
