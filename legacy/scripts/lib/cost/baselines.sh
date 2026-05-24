#!/usr/bin/env bash
# lib/cost/baselines.sh — rolling per-stage cost baselines
#
# Stores rolling-average cost data per pipeline stage so the cost breakdown
# table can flag HIGH (>1.5×) and LOW (<0.5×) runs vs the historical norm.
#
# Storage layout:
#   ${HOME}/.shipwright/baselines/stage-costs.json        — all-issues baseline
#   ${HOME}/.shipwright/baselines/issue-<N>-costs.json    — per-issue baseline
#
# Schema:
#   {
#     "version": 1,
#     "updated_at": "<iso>",
#     "stages": {
#       "plan":  { "avg_usd": 0.028, "n": 23, "min_usd": 0.018, "max_usd": 0.045,
#                  "avg_input_tokens": 38500, "avg_output_tokens": 4100 },
#       "build": { ... }
#     }
#   }
#
# Rolling-average update: avg_new = (avg_old × n + cost) / (n + 1)
# Sample cap: n is bounded at BASELINE_MAX_N (default 50) to prevent runaway
# accumulation while still smoothing burst noise. Past the cap, the average
# updates with weight 1/cap (effectively exponential).
[[ -n "${_COST_BASELINES_LOADED:-}" ]] && return 0
_COST_BASELINES_LOADED=1

BASELINE_VERSION=1
BASELINE_DIR_DEFAULT="${HOME}/.shipwright/baselines"
BASELINE_MAX_N="${BASELINE_MAX_N:-50}"
BASELINE_HIGH_RATIO="${BASELINE_HIGH_RATIO:-1.5}"
BASELINE_LOW_RATIO="${BASELINE_LOW_RATIO:-0.5}"

# baseline_dir — resolve baseline directory (overridable for tests)
baseline_dir() {
    echo "${SW_BASELINE_DIR:-$BASELINE_DIR_DEFAULT}"
}

# baseline_file [issue]
# Resolves the baseline file path. Empty issue → all-issues baseline.
baseline_file() {
    local issue="${1:-}"
    local dir
    dir=$(baseline_dir)
    if [[ -n "$issue" ]]; then
        # Sanitize issue: digits only, prevent path traversal
        issue=$(printf '%s' "$issue" | tr -cd '0-9')
        [[ -z "$issue" ]] && { echo "${dir}/stage-costs.json"; return 0; }
        echo "${dir}/issue-${issue}-costs.json"
    else
        echo "${dir}/stage-costs.json"
    fi
}

# baseline_init [issue]
# Creates an empty baseline file if one does not exist. Idempotent.
baseline_init() {
    local issue="${1:-}"
    local dir file
    dir=$(baseline_dir)
    file=$(baseline_file "$issue")
    mkdir -p "$dir" 2>/dev/null || return 1
    if [[ ! -f "$file" ]]; then
        local ts
        ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        jq -n --argjson v "$BASELINE_VERSION" --arg ts "$ts" \
            '{version: $v, updated_at: $ts, stages: {}}' > "$file" 2>/dev/null \
            || return 1
    fi
    return 0
}

# baseline_get_stage <stage> [issue]
# Echoes JSON object for one stage, or "null" if no baseline exists. Quiet.
baseline_get_stage() {
    local stage="${1:-}"
    local issue="${2:-}"
    [[ -z "$stage" ]] && { echo "null"; return 0; }
    local file
    file=$(baseline_file "$issue")
    [[ -f "$file" ]] || { echo "null"; return 0; }
    jq --arg s "$stage" '.stages[$s] // null' "$file" 2>/dev/null || echo "null"
}

# baseline_update_stage <stage> <cost_usd> <input_tokens> <output_tokens> [issue]
# Updates rolling average for one stage. Atomic write via tmp file + mv.
# Rejects non-numeric or negative values; returns 1 on bad input.
baseline_update_stage() {
    local stage="${1:-}"
    local cost="${2:-}"
    local input_tokens="${3:-0}"
    local output_tokens="${4:-0}"
    local issue="${5:-}"

    [[ -z "$stage" ]] && return 1
    [[ "$stage" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    # Validate cost is non-negative number
    awk -v c="$cost" 'BEGIN { exit !(c ~ /^[0-9]+(\.[0-9]+)?$/ && c+0 >= 0) }' \
        2>/dev/null || return 1
    awk -v t="$input_tokens" 'BEGIN { exit !(t ~ /^[0-9]+$/) }' 2>/dev/null \
        || return 1
    awk -v t="$output_tokens" 'BEGIN { exit !(t ~ /^[0-9]+$/) }' 2>/dev/null \
        || return 1

    baseline_init "$issue" || return 1
    local file
    file=$(baseline_file "$issue")

    local tmp
    tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 1
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Capped rolling-average update. When n < cap, true mean. When n >= cap,
    # weight = 1/cap (exponential-ish smoothing for older data).
    jq \
        --arg s "$stage" \
        --argjson cost "$cost" \
        --argjson in "$input_tokens" \
        --argjson out "$output_tokens" \
        --arg ts "$ts" \
        --argjson cap "$BASELINE_MAX_N" \
        --argjson v "$BASELINE_VERSION" '
        .version = $v
        | .updated_at = $ts
        | .stages[$s] = (
            (.stages[$s] // {avg_usd: 0, n: 0, min_usd: $cost, max_usd: $cost,
                             avg_input_tokens: 0, avg_output_tokens: 0}) as $cur
            | ($cur.n // 0) as $n
            | (if $n < $cap then $n else $cap - 1 end) as $w_n
            | (1 / ($w_n + 1)) as $w
            | {
                avg_usd:   ((($cur.avg_usd // 0) * (1 - $w) + $cost * $w) * 1000000 | round / 1000000),
                n:         ($n + 1),
                min_usd:   (if $n == 0 then $cost else ([$cur.min_usd, $cost] | min) end),
                max_usd:   (if $n == 0 then $cost else ([$cur.max_usd, $cost] | max) end),
                avg_input_tokens:  ((($cur.avg_input_tokens  // 0) * (1 - $w) + $in  * $w) | round),
                avg_output_tokens: ((($cur.avg_output_tokens // 0) * (1 - $w) + $out * $w) | round)
            }
        )' "$file" > "$tmp" 2>/dev/null && mv "$tmp" "$file" || {
        rm -f "$tmp" 2>/dev/null
        return 1
    }
    return 0
}

# baseline_update_from_breakdown <breakdown_json_file> [issue]
# Reads cost-breakdown.json and updates baselines for every stage in by_stage[].
# Skips stages with zero cost (they made no Claude calls). Also updates the
# all-issues baseline regardless of [issue]; if [issue] is given it ALSO
# updates the per-issue baseline.
baseline_update_from_breakdown() {
    local breakdown="${1:-}"
    local issue="${2:-}"
    [[ -z "$breakdown" || ! -f "$breakdown" ]] && return 1

    local rows
    rows=$(jq -r '.by_stage // [] | .[]
        | "\(.stage)\t\(.cost_usd // 0)\t\(.input_tokens // 0)\t\(.output_tokens // 0)"' \
        "$breakdown" 2>/dev/null) || return 1

    local stage cost in_tok out_tok updated=0
    while IFS=$'\t' read -r stage cost in_tok out_tok; do
        [[ -z "$stage" ]] && continue
        # Skip zero-cost stages — they would skew the floor down.
        awk -v c="$cost" 'BEGIN { exit !(c+0 > 0) }' 2>/dev/null || continue
        if baseline_update_stage "$stage" "$cost" "$in_tok" "$out_tok" ""; then
            updated=$((updated + 1))
        fi
        if [[ -n "$issue" ]]; then
            baseline_update_stage "$stage" "$cost" "$in_tok" "$out_tok" "$issue" \
                >/dev/null 2>&1 || true
        fi
    done <<< "$rows"

    # Surface count for callers that want progress info; never fail on 0
    # (first run with no costs is valid).
    echo "$updated"
    return 0
}

# baseline_classify <stage> <cost_usd> [issue]
# Echoes one of: HIGH | LOW | NORMAL | NEW
#   HIGH   — cost > BASELINE_HIGH_RATIO × avg
#   LOW    — cost < BASELINE_LOW_RATIO × avg
#   NORMAL — within range
#   NEW    — no baseline (first run for this stage)
# Bootstrap: if n < 3, returns NORMAL (insufficient sample, avoid alarms).
baseline_classify() {
    local stage="${1:-}"
    local cost="${2:-0}"
    local issue="${3:-}"
    [[ -z "$stage" ]] && { echo "NEW"; return 0; }

    local stage_json
    stage_json=$(baseline_get_stage "$stage" "$issue")
    if [[ "$stage_json" == "null" || -z "$stage_json" ]]; then
        echo "NEW"
        return 0
    fi

    local n avg
    n=$(echo "$stage_json"   | jq -r '.n // 0' 2>/dev/null)
    avg=$(echo "$stage_json" | jq -r '.avg_usd // 0' 2>/dev/null)

    # Bootstrap guard — need ≥3 samples for a reliable comparison.
    if [[ "${n:-0}" -lt 3 ]]; then
        echo "NORMAL"
        return 0
    fi

    awk -v c="$cost" -v a="$avg" \
        -v hi="$BASELINE_HIGH_RATIO" -v lo="$BASELINE_LOW_RATIO" '
        BEGIN {
            if (a+0 == 0) { print "NEW"; exit }
            ratio = c / a
            if (ratio > hi)      print "HIGH"
            else if (ratio < lo) print "LOW"
            else                  print "NORMAL"
        }' 2>/dev/null
}
