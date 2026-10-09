#!/usr/bin/env bash
# lib/cost/table-render.sh — formatted per-stage cost summary table
#
# Renders cost-breakdown.json as a fixed-width ASCII table with HIGH/LOW flags
# computed from baselines.sh. Two output modes:
#
#   render_cost_table         — terminal table with ANSI colors (red HIGH, dim LOW)
#   render_cost_table_plain   — same table without ANSI (for GitHub comments / files)
#
# Both consume the same cost-breakdown.json shape produced by
# cost_generate_breakdown (sw-cost.sh §cost_generate_breakdown). When the
# breakdown JSON is missing, malformed, or has no stages we print a single
# "no data" notice and return 0 (rendering is non-fatal).
[[ -n "${_COST_TABLE_RENDER_LOADED:-}" ]] && return 0
_COST_TABLE_RENDER_LOADED=1

# Source baselines.sh from the same directory if not already loaded.
if [[ -z "${_COST_BASELINES_LOADED:-}" ]]; then
    _CT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/cost/baselines.sh
    [[ -f "$_CT_DIR/baselines.sh" ]] && source "$_CT_DIR/baselines.sh"
fi

# Internal — format integer with thousand-separators (Bash 3.2 safe).
_ct_thousands() {
    local n="${1:-0}"
    # printf "%'d" needs a numeric LC_NUMERIC; degrade gracefully if absent.
    LC_ALL=C printf "%'d" "$n" 2>/dev/null || echo "$n"
}

# Internal — pad/clip a string to N visible chars (no ANSI inside the input).
_ct_pad_right() {
    local s="${1:-}" w="${2:-10}"
    local len="${#s}"
    if [[ "$len" -ge "$w" ]]; then
        echo "${s:0:$w}"
    else
        printf "%s%*s" "$s" $((w - len)) ""
    fi
}
_ct_pad_left() {
    local s="${1:-}" w="${2:-10}"
    local len="${#s}"
    if [[ "$len" -ge "$w" ]]; then
        echo "${s:0:$w}"
    else
        printf "%*s%s" $((w - len)) "" "$s"
    fi
}

# Internal — format USD with 4 decimals.
_ct_fmt_usd() {
    local c="${1:-0}"
    awk -v v="$c" 'BEGIN { printf "$%.4f", v+0 }' 2>/dev/null \
        || echo "\$${c}"
}

# Internal — render the flag column for a stage given classification.
# Args: <classification> <use_color>
_ct_render_flag() {
    local cls="${1:-NORMAL}" color="${2:-1}"
    local sym text
    case "$cls" in
        HIGH)   sym="↑"; text="HIGH" ;;
        LOW)    sym="↓"; text="low" ;;
        NEW)    sym="•"; text="new" ;;
        NORMAL|*) sym="↔"; text="avg" ;;
    esac
    local cell
    cell=$(printf " %s %-4s" "$sym" "$text")
    if [[ "$color" == "1" ]]; then
        case "$cls" in
            HIGH) printf '\033[31m%s\033[0m' "$cell" ;;
            LOW)  printf '\033[2m%s\033[0m'  "$cell" ;;
            NEW)  printf '\033[36m%s\033[0m' "$cell" ;;
            *)    printf '%s' "$cell" ;;
        esac
    else
        printf '%s' "$cell"
    fi
}

# render_cost_table <breakdown_file> [--issue N] [--no-color] [--baseline-context]
# Prints the formatted table to stdout. Exit 0 on success or no-data.
render_cost_table() {
    local breakdown=""
    local issue=""
    local use_color=1
    local show_context=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue)            issue="${2:-}"; shift 2 ;;
            --issue=*)          issue="${1#--issue=}"; shift ;;
            --no-color)         use_color=0; shift ;;
            --baseline-context) show_context=1; shift ;;
            -*)                 shift ;;
            *)
                if [[ -z "$breakdown" ]]; then breakdown="$1"; fi
                shift ;;
        esac
    done

    if [[ -z "$breakdown" || ! -f "$breakdown" ]]; then
        echo "  (no cost-breakdown.json found — skipping summary table)"
        return 0
    fi

    # Validate JSON shape minimally before rendering.
    local stage_count
    stage_count=$(jq '.by_stage | length // 0' "$breakdown" 2>/dev/null) \
        || stage_count=0
    if [[ "${stage_count:-0}" -eq 0 ]]; then
        echo "  (cost-breakdown.json has no stage data — skipping summary table)"
        return 0
    fi

    # Column widths (fixed for predictable rendering)
    local W_STAGE=20 W_IN=11 W_OUT=10 W_COST=11 W_FLAG=8

    # Header
    local sep
    sep=$(printf '─%.0s' $(seq 1 $((W_STAGE + W_IN + W_OUT + W_COST + W_FLAG + 14))) 2>/dev/null)
    echo "┌$(printf '─%.0s' $(seq 1 $((W_STAGE + 2))))┬$(printf '─%.0s' $(seq 1 $((W_IN + 2))))┬$(printf '─%.0s' $(seq 1 $((W_OUT + 2))))┬$(printf '─%.0s' $(seq 1 $((W_COST + 2))))┬$(printf '─%.0s' $(seq 1 $((W_FLAG + 2))))┐"
    printf "│ %s │ %s │ %s │ %s │ %s │\n" \
        "$(_ct_pad_right "Stage"     $W_STAGE)" \
        "$(_ct_pad_left  "In tokens" $W_IN)" \
        "$(_ct_pad_left  "Out tok"   $W_OUT)" \
        "$(_ct_pad_left  "Cost USD"  $W_COST)" \
        "$(_ct_pad_right "vs avg"    $W_FLAG)"
    echo "├$(printf '─%.0s' $(seq 1 $((W_STAGE + 2))))┼$(printf '─%.0s' $(seq 1 $((W_IN + 2))))┼$(printf '─%.0s' $(seq 1 $((W_OUT + 2))))┼$(printf '─%.0s' $(seq 1 $((W_COST + 2))))┼$(printf '─%.0s' $(seq 1 $((W_FLAG + 2))))┤"

    # Rows — read each stage and classify against baseline.
    local rows
    rows=$(jq -r '.by_stage[]
        | "\(.stage)\t\(.input_tokens // 0)\t\(.output_tokens // 0)\t\(.cost_usd // 0)"' \
        "$breakdown" 2>/dev/null) || rows=""

    local stage in_tok out_tok cost cls flag
    while IFS=$'\t' read -r stage in_tok out_tok cost; do
        [[ -z "$stage" ]] && continue
        cls=$(baseline_classify "$stage" "$cost" "$issue")
        flag=$(_ct_render_flag "$cls" "$use_color")
        # Compose row. Note: ANSI in flag means we cannot rely on _ct_pad on the
        # flag cell width; instead we right-pad the rendered flag text manually
        # with spaces sized to W_FLAG (text inside the ANSI is ≤ 6 visible chars).
        printf "│ %s │ %s │ %s │ %s │ %s%s │\n" \
            "$(_ct_pad_right "$stage" $W_STAGE)" \
            "$(_ct_pad_left  "$(_ct_thousands "$in_tok")"  $W_IN)" \
            "$(_ct_pad_left  "$(_ct_thousands "$out_tok")" $W_OUT)" \
            "$(_ct_pad_left  "$(_ct_fmt_usd  "$cost")"     $W_COST)" \
            "$flag" \
            "$(printf '%*s' $((W_FLAG - 7)) '')"
    done <<< "$rows"

    # Total row
    local t_in t_out t_cost
    t_in=$(jq   '.summary.total_input_tokens  // 0' "$breakdown" 2>/dev/null || echo 0)
    t_out=$(jq  '.summary.total_output_tokens // 0' "$breakdown" 2>/dev/null || echo 0)
    t_cost=$(jq '.summary.total_cost_usd      // 0' "$breakdown" 2>/dev/null || echo 0)

    echo "├$(printf '─%.0s' $(seq 1 $((W_STAGE + 2))))┼$(printf '─%.0s' $(seq 1 $((W_IN + 2))))┼$(printf '─%.0s' $(seq 1 $((W_OUT + 2))))┼$(printf '─%.0s' $(seq 1 $((W_COST + 2))))┼$(printf '─%.0s' $(seq 1 $((W_FLAG + 2))))┤"

    # Total flag against synthetic "TOTAL" baseline (skip — no per-pipeline-total
    # baseline by design; comparing totals across heterogeneous runs is noise).
    printf "│ %s │ %s │ %s │ %s │ %s │\n" \
        "$(_ct_pad_right "TOTAL" $W_STAGE)" \
        "$(_ct_pad_left  "$(_ct_thousands "$t_in")"  $W_IN)" \
        "$(_ct_pad_left  "$(_ct_thousands "$t_out")" $W_OUT)" \
        "$(_ct_pad_left  "$(_ct_fmt_usd  "$t_cost")" $W_COST)" \
        "$(_ct_pad_right "—"     $W_FLAG)"

    echo "└$(printf '─%.0s' $(seq 1 $((W_STAGE + 2))))┴$(printf '─%.0s' $(seq 1 $((W_IN + 2))))┴$(printf '─%.0s' $(seq 1 $((W_OUT + 2))))┴$(printf '─%.0s' $(seq 1 $((W_COST + 2))))┴$(printf '─%.0s' $(seq 1 $((W_FLAG + 2))))┘"

    # Optional: baseline context footer
    if [[ "$show_context" == "1" ]]; then
        local file n_max
        file=$(baseline_file "$issue")
        if [[ -f "$file" ]]; then
            n_max=$(jq '[.stages | to_entries[] | .value.n // 0] | max // 0' \
                "$file" 2>/dev/null || echo 0)
            local context
            if [[ -n "$issue" ]]; then
                context="vs ${n_max} prior runs of issue #${issue}"
            else
                context="vs ${n_max} prior pipeline runs (all issues)"
            fi
            echo ""
            echo "  Comparison baseline: ${context}"
        fi
    fi

    echo "  HIGH = >${BASELINE_HIGH_RATIO:-1.5}× stage avg  |  low = <${BASELINE_LOW_RATIO:-0.5}× stage avg  |  ↔ avg = within range  |  • new = no baseline yet"

    return 0
}

# render_cost_table_plain — same as render_cost_table with --no-color forced.
# Useful for piping into GitHub issue comments where ANSI is not rendered.
render_cost_table_plain() {
    render_cost_table "$@" --no-color
}
