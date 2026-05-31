#!/usr/bin/env bash
# Shared helpers for GitHub-automation scripts. Used by deferred-tracker
# and manifest-sync. Scoped per #540 review: extract only genuinely shared
# logic (idempotency-log row check + append); single-caller helpers stay
# in their owning script.

[[ -n "${_ZBUILD_GHA_LOADED:-}" ]] && return 0
_ZBUILD_GHA_LOADED=1

_ZBUILD_GHA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
source "$_ZBUILD_GHA_DIR/helpers.sh"

# Returns 0 if PR number is present in a `| #N |`-style markdown log.
gha_is_already_scanned() {
    local pr_num="$1"
    local log_path="$2"
    [[ -f "$log_path" ]] || return 1
    grep -qE "^\| #${pr_num} \|" "$log_path"
}

# Appends a row to a markdown idempotency log if not already present.
# Bootstraps the file via the provided header callback when missing.
# Args:
#   $1 — log path
#   $2 — header callback name (function taking $log_path as arg, writes header)
#   $3 — column-3 value (date or status; positional)
#   $4… — entries in "pr_num|title" format
gha_append_scanned_log() {
    local log_path="$1"
    local header_fn="$2"
    local col3_value="$3"
    shift 3
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ ! -f "$log_path" ]]; then
        mkdir -p "$(dirname "$log_path")"
        "$header_fn" "$log_path" "$now"
    else
        zbuild_sed_inplace "s|^_Last updated:.*|_Last updated: ${now}_|" "$log_path"
    fi
    local entry pr_num title
    for entry in "$@"; do
        IFS='|' read -r pr_num title <<< "$entry"
        [[ -z "$pr_num" ]] && continue
        if grep -qE "^\| #${pr_num} \|" "$log_path"; then
            continue
        fi
        printf '| #%s | %s | %s |\n' "$pr_num" "$title" "$col3_value" >> "$log_path"
    done
}

# Jaccard token-similarity for issue-dedup scans (#558 / ADR-020 v2).
# Returns 0.00–1.00 on stdout via printf '%.2f'. Bash 3.2 + POSIX awk.
gha_compute_similarity() {
    local text_a="${1:-}"
    local text_b="${2:-}"
    local score
    score="$(printf '%s\n__ZBUILD_SEP__\n%s\n' "$text_a" "$text_b" | awk '
        BEGIN {
            split("the and that this with from when what where will should " \
                  "would could into also just more some like such these those " \
                  "after before while about then than have been they their " \
                  "there which", sw, " ")
            for (i in sw) stop[sw[i]] = 1
            side = "A"
        }
        /^__ZBUILD_SEP__$/ { side = "B"; next }
        {
            line = tolower($0)
            n = split(line, toks, /[^[:alnum:]]+/)
            for (i = 1; i <= n; i++) {
                t = toks[i]
                if (length(t) < 4) continue
                if (t in stop) continue
                if (side == "A") setA[t] = 1
                else             setB[t] = 1
            }
        }
        END {
            inter = 0; union = 0
            for (t in setA) { union++; if (t in setB) inter++ }
            for (t in setB) if (!(t in setA)) union++
            if (union == 0) { printf "0.00"; exit }
            printf "%.4f", inter / union
        }
    ')" || score="0.00"
    [[ -z "$score" ]] && score="0.00"
    printf '%.2f\n' "$score"
}

# True (rc=0) when $score >= $threshold; both are %.2f decimal strings.
# Avoids bash integer-compare on decimals.
gha_score_meets_threshold() {
    local score="$1"
    local threshold="$2"
    awk -v s="$score" -v t="$threshold" 'BEGIN{exit !(s>=t)}'
}
