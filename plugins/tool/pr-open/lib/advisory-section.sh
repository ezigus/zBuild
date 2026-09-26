#!/usr/bin/env bash
# plugins/tool/pr-open/lib/advisory-section.sh — the PR body's advisory-review
# section, rendered from review-report.json. Split from plugin.sh to keep it
# under the 500-line guideline. Sourced library: no set -euo pipefail.

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
    local _jq_defs='
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
