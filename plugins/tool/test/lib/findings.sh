#!/usr/bin/env bash
# plugins/tool/test/lib/findings.sh — what a failing suite asks someone to fix.
#
# The stage summary is an extraction of failing LINES. A reader still has to
# work out which file failed, why, and whose file is at fault — and when the
# answer sits in another file (a lint guard naming the line it objects to), the
# result used to say nothing about it. #1845 run 36274909946: the guard failed on
# a line test-author wrote, `about` was null, the finding went to build (which
# may not edit that file) and four rebuilds changed 0 files.
#
# So per failing file: a one-line reason, and the repo files its output names in
# the universal `path:line:` shape (compilers, linters, guards all print it).
# Those are what the failure POINTS AT, and they become the result's `about` —
# the engine resolves an owner from it (#2180) with no stage named here.
#
# Sourced library: inherits the caller's shell options; do NOT add set -euo.

[[ -n "${_ZBUILD_TEST_FINDINGS_LOADED:-}" ]] && return 0
_ZBUILD_TEST_FINDINGS_LOADED=1

# _test_failure_findings <raw_output> <staging_dir>
# Prints a JSON array: [{file, reason, points_at: [..]}], one entry per failing
# file, paths relative to <staging_dir>. `[]` when nothing failed.
_test_failure_findings() {
    local raw="${1:-}" tmp="${2:-}"
    [[ -n "$tmp" ]] || { printf '[]'; return 0; }
    # The suite prints paths as ITS cwd spells them: the logical form (a
    # doubled slash from a trailing-slash TMPDIR collapsed) or, on macOS, the
    # physical /private/var form. Match all three spellings of the prefix.
    local tmp_log tmp_phys
    tmp_log="$(cd "$tmp" 2>/dev/null && pwd -L)" || tmp_log=""
    tmp_phys="$(cd "$tmp" 2>/dev/null && pwd -P)" || tmp_phys=""

    # awk emits one TSV row per block line: kind \t file \t text. Kinds:
    #   F file-start (FAIL)   T timeout   X ✗ line   D the line after a ✗
    #   P a passing check     E a bash error shape   L path:line: candidate
    local rows
    rows="$(printf '%s\n' "$raw" | awk -v t="$tmp" -v tl="$tmp_log" -v tp="$tmp_phys" '
        function rel(p) {
            if (tp != "" && index(p, tp "/") == 1) return substr(p, length(tp) + 2)
            if (tl != "" && index(p, tl "/") == 1) return substr(p, length(tl) + 2)
            if (index(p, t "/") == 1) return substr(p, length(t) + 2)
            return ""
        }
        /^[a-z]+: (FAIL|TIMEOUT) / {
            # The path is the rest of the line, not $3: a staging dir with a
            # space would split it (claude-review on #2210).
            path = $0; sub(/^[a-z]+: (FAIL|TIMEOUT) /, "", path)
            f = rel(path); kind = ($2 == "TIMEOUT") ? "T" : "F"
            inblk = (f != ""); after_x = 0
            if (inblk) printf "%s\t%s\t\n", kind, f
            next
        }
        /^[a-z]+: [0-9]+\/[0-9]+ passed/ { inblk = 0; next }
        !inblk { next }
        {
            line = $0; sub(/^[[:space:]]+/, "", line)
            # A ✗ right after a ✗ is the next check, not the detail of the first.
            if (after_x && line != "" && line !~ /^(✗|✘)/) { printf "D\t%s\t%s\n", f, line; after_x = 0 }
            if (line ~ /^(✗|✘)/) { printf "X\t%s\t%s\n", f, line; after_x = 1; next }
            if (line ~ /^✓/) { printf "P\t%s\t%s\n", f, line; next }
            if (line ~ /line [0-9]+: |command not found|syntax error|unbound variable/) printf "E\t%s\t%s\n", f, line
            if (match(line, /^[^[:space:]:]+:[0-9]+:/)) {
                c = substr(line, 1, RLENGTH); sub(/:[0-9]+:$/, "", c)
                r = (substr(c, 1, 1) == "/") ? rel(c) : c
                if (r != "") printf "L\t%s\t%s\n", f, r
            }
        }' 2>/dev/null || true)"
    [[ -n "$rows" ]] || { printf '[]'; return 0; }

    # A pointed-at path must exist in the tree and must not be the failing file.
    local out="" kind file text
    local -A _seen_l=()
    while IFS=$'\t' read -r kind file text; do
        if [[ "$kind" == "L" ]]; then
            [[ "$text" == "$file" || "$text" == *".."* ]] && continue
            [[ -f "$tmp/$text" ]] || continue
            [[ -n "${_seen_l[$file|$text]:-}" ]] && continue
            _seen_l[$file|$text]=1
        fi
        out+="${kind}"$'\t'"${file}"$'\t'"${text}"$'\n'
    done <<< "$rows"

    jq -Rsc '
        split("\n") | map(select(length > 0) | split("\t") | {k: .[0], f: .[1], t: (.[2] // "")})
        | group_by(.f)
        | map(. as $r
            | ($r | map(select(.k == "X")) | .[0].t // "") as $x
            | ($r | map(select(.k == "D")) | .[0].t // "") as $d
            | ($r | map(select(.k == "E")) | .[0].t // "") as $e
            | ($r | map(select(.k == "P")) | last | .t // "") as $p
            | ($r | any(.k == "T")) as $timeout
            | {
                file: $r[0].f,
                reason: (
                    if $x != "" then $x + (if ($d | test("expected|got|found|Expected")) then " — " + $d else "" end)
                    elif $timeout then "timed out before finishing" + (if $p != "" then " (last check that passed: " + ($p | sub("^✓[[:space:]]*"; "")) + ")" else "" end)
                    elif $e != "" then $e
                    elif $p != "" then "exited non-zero without a failing check, after its last passing check: " + ($p | sub("^✓[[:space:]]*"; ""))
                    else "exited non-zero without printing a failing check" end),
                points_at: ($r | map(select(.k == "L") | .t) | unique)
              })' <<< "$out" 2>/dev/null || printf '[]'
}

# _test_findings_about <findings_json> — the newline-separated union of every
# failure's points_at, or empty. Empty leaves `about` unset: a failure that
# points at no other file is routed by fault class, as before.
_test_findings_about() {
    jq -r '[.[].points_at[]] | unique | join("\n")' <<< "${1:-[]}" 2>/dev/null || true
}

# _test_findings_markdown <findings_json> — the "Failing files" section of the
# stage summary, or empty when nothing failed.
_test_findings_markdown() {
    local md
    md="$(jq -r '.[] | "- \(.file) — \(.reason)"
        + (if (.points_at | length) > 0 then "\n  - points at: " + (.points_at | join(", ")) else "" end)' \
        <<< "${1:-[]}" 2>/dev/null || true)"
    [[ -n "$md" ]] || return 0
    printf '## Failing files\n\n%s\n' "$md"
}
