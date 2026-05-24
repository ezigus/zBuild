#!/usr/bin/env bash
# lib/cost/share.sh — cross-machine cost-breakdown.json merging
#
# Issue #460: enables cross-machine optimization by folding cost-breakdown.json
# artifacts gathered from multiple pipeline runs (and machines) into a single
# merged breakdown that the rolling baseline machinery can consume.
#
# The artifact contract is documented in docs/cost-sharing.md. Each run uploads
# `cost-breakdown.json` under the artifact name `cost-breakdown-issue-<N>-run-<RUN_ID>`.
# The optimize workflow downloads the N most-recent artifacts, expands each into
# its own subdirectory, then calls cost_merge_breakdowns to aggregate them.
#
# Public API:
#   cost_merge_breakdowns <input_dir> <out_file>
#     Recursively finds cost-breakdown.json files under <input_dir>, validates
#     each against the schema (must contain .summary.total_cost_usd), groups
#     .by_stage[] entries by stage name, sums input_tokens / output_tokens /
#     cost_usd / count, writes the merged result atomically to <out_file>.
#     Malformed or schema-invalid files are skipped (warn, not fatal).
#
#   cost_apply_merged_to_baselines <merged_file>
#     Folds every stage in a merged file into the all-issues rolling baseline
#     via baseline_update_stage. Quiet on success; non-fatal on bad input.
#
#   cost_share_validate_breakdown <file>
#     Returns 0 if file passes schema check, 1 otherwise. Cheap pre-merge
#     guard so callers can decide whether to include a candidate.
#
# Bash 3.2 compatible. No associative arrays, no readarray.

[[ -n "${_COST_SHARE_LOADED:-}" ]] && return 0
_COST_SHARE_LOADED=1

# Fallback shims — let this lib be sourced standalone (eg in test envs) without
# requiring helpers.sh to be loaded first.
[[ "$(type -t info 2>/dev/null)"    == "function" ]] || info()    { echo "▸ $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo "✓ $*"; }
[[ "$(type -t warn 2>/dev/null)"    == "function" ]] || warn()    { echo "⚠ $*" >&2; }
[[ "$(type -t error 2>/dev/null)"   == "function" ]] || error()   { echo "✗ $*" >&2; }
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() { :; }

# Default cap on the number of input artifacts the optimize workflow will fold
# in a single run. Bounded to keep jq memory usage predictable and protect the
# cron from a runaway artifact list.
COST_SHARE_MAX_INPUTS="${COST_SHARE_MAX_INPUTS:-50}"

# cost_share_validate_breakdown <file>
# Returns 0 if the file parses as JSON AND has a numeric .summary.total_cost_usd
# AND a .by_stage array. Quiet — emits nothing on stdout/stderr.
cost_share_validate_breakdown() {
    local file="${1:-}"
    [[ -z "$file" || ! -f "$file" ]] && return 1
    jq -e '
        (.summary.total_cost_usd | type == "number")
        and (.by_stage | type == "array")
    ' "$file" >/dev/null 2>&1
}

# cost_merge_breakdowns <input_dir> <out_file>
# Aggregates every valid cost-breakdown.json under <input_dir> into <out_file>.
# Atomic write via tmp + mv. Empty input dir → valid-but-empty merged JSON
# (summary.total_cost_usd == 0). Malformed individual files are skipped, not
# fatal — see test 2 in sw-cost-share-test.sh.
cost_merge_breakdowns() {
    local input_dir="${1:-}"
    local out_file="${2:-}"
    if [[ -z "$input_dir" || -z "$out_file" ]]; then
        warn "cost_merge_breakdowns: usage: <input_dir> <out_file>"
        return 1
    fi
    if [[ ! -d "$input_dir" ]]; then
        warn "cost_merge_breakdowns: input_dir does not exist: ${input_dir}"
        return 1
    fi

    local out_dir
    out_dir=$(dirname "$out_file")
    mkdir -p "$out_dir" 2>/dev/null || {
        error "cost_merge_breakdowns: cannot create out_dir ${out_dir}"
        return 1
    }

    # Collect candidate files. Each downloaded artifact unpacks into its own
    # subdir, so a single cost-breakdown.json may live one or two levels deep.
    # Bash 3.2: no readarray — use a temp list file to survive subshells.
    local list_file
    list_file=$(mktemp "${out_file}.list.XXXXXX" 2>/dev/null) || {
        error "cost_merge_breakdowns: mktemp failed"
        return 1
    }
    # -L follows symlinks (download-artifact@v4 may use them); -type f keeps
    # the result file-only. 2>/dev/null swallows permission-denied chatter.
    find -L "$input_dir" -type f -name 'cost-breakdown.json' 2>/dev/null \
        > "$list_file" || true

    local valid_list
    valid_list=$(mktemp "${out_file}.valid.XXXXXX" 2>/dev/null) || {
        rm -f "$list_file"
        error "cost_merge_breakdowns: mktemp failed"
        return 1
    }

    local total_found=0 valid_count=0 skipped_count=0
    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        total_found=$((total_found + 1))
        if [[ "$valid_count" -ge "$COST_SHARE_MAX_INPUTS" ]]; then
            skipped_count=$((skipped_count + 1))
            continue
        fi
        if cost_share_validate_breakdown "$f"; then
            printf '%s\n' "$f" >> "$valid_list"
            valid_count=$((valid_count + 1))
        else
            skipped_count=$((skipped_count + 1))
        fi
    done < "$list_file"
    rm -f "$list_file"

    local tmp_out
    tmp_out=$(mktemp "${out_file}.XXXXXX" 2>/dev/null) || {
        rm -f "$valid_list"
        error "cost_merge_breakdowns: mktemp failed"
        return 1
    }
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if [[ "$valid_count" -eq 0 ]]; then
        # Empty-but-valid merged JSON — downstream consumers should not crash
        # on a quiet week with no input artifacts.
        jq -n --arg ts "$ts" --argjson sources 0 '{
            version: 1,
            generated_at: $ts,
            sources: $sources,
            summary: {
                total_input_tokens: 0,
                total_output_tokens: 0,
                total_cost_usd: 0,
                stage_count: 0,
                source_count: 0
            },
            by_stage: []
        }' > "$tmp_out" 2>/dev/null || {
            rm -f "$tmp_out" "$valid_list"
            error "cost_merge_breakdowns: failed to write empty merged JSON"
            return 1
        }
        mv "$tmp_out" "$out_file" || {
            rm -f "$tmp_out" "$valid_list"
            return 1
        }
        rm -f "$valid_list"
        info "cost_merge_breakdowns: no valid inputs (found=${total_found} skipped=${skipped_count}); wrote empty merged file"
        emit_event "cost.breakdown_merged" "sources=0" "found=${total_found}" "skipped=${skipped_count}"
        return 0
    fi

    # Stream every validated breakdown into a single jq invocation. `jq -s`
    # collects each file's top-level JSON value into one array; the filter
    # then flattens .by_stage[] across all sources, groups by stage, and sums
    # the metrics. Cost is rounded back to 6dp to avoid float drift.
    #
    # We feed file contents via stdin (cat) so file paths with spaces are safe
    # — passing $(cat "$valid_list") as positional args is unsafe under
    # word-splitting. NB: `xargs -a <file>` is a GNU extension absent on BSD
    # xargs (macOS); redirect stdin from the list file for portability.
    local merged_json
    if ! merged_json=$(xargs -I{} cat {} < "$valid_list" 2>/dev/null \
        | jq -s --arg ts "$ts" --argjson sources "$valid_count" '
        ([ .[] | (.by_stage // [])[] ]
         | group_by(.stage)
         | map({
             stage:         .[0].stage,
             input_tokens:  ([.[].input_tokens  // 0] | add),
             output_tokens: ([.[].output_tokens // 0] | add),
             cost_usd:      ([.[].cost_usd      // 0] | add | . * 1000000 | round / 1000000),
             count:         ([.[].count         // 0] | add),
             models:        ([.[].models        // [] | .[]] | unique),
             sources:       length
         })
         | sort_by(-.input_tokens)) as $stages
        | {
            version: 1,
            generated_at: $ts,
            sources: $sources,
            summary: {
                total_input_tokens:  ([$stages[].input_tokens]  | add // 0),
                total_output_tokens: ([$stages[].output_tokens] | add // 0),
                total_cost_usd:      ([$stages[].cost_usd]      | add // 0 | . * 1000000 | round / 1000000),
                stage_count:         ($stages | length),
                source_count:        $sources
            },
            by_stage: $stages
        }
    ' 2>/dev/null); then
        rm -f "$tmp_out" "$valid_list"
        error "cost_merge_breakdowns: jq aggregation failed"
        return 1
    fi
    rm -f "$valid_list"

    printf '%s\n' "$merged_json" > "$tmp_out" || {
        rm -f "$tmp_out"
        error "cost_merge_breakdowns: failed to write tmp output"
        return 1
    }
    mv "$tmp_out" "$out_file" || {
        rm -f "$tmp_out"
        return 1
    }

    success "cost_merge_breakdowns: ${valid_count} sources merged (found=${total_found} skipped=${skipped_count}) → ${out_file}"
    emit_event "cost.breakdown_merged" \
        "sources=${valid_count}" \
        "found=${total_found}" \
        "skipped=${skipped_count}" \
        "out=${out_file}"
    return 0
}

# cost_apply_merged_to_baselines <merged_file>
# Reuses baseline_update_stage() to fold every stage in a merged file into the
# all-issues rolling baseline. Each stage's averaged cost is treated as one
# observation; the rolling-average machinery in baselines.sh smooths it into
# the historical record. Zero-cost stages are skipped to avoid pulling the
# floor down.
cost_apply_merged_to_baselines() {
    local merged="${1:-}"
    if [[ -z "$merged" || ! -f "$merged" ]]; then
        warn "cost_apply_merged_to_baselines: missing or invalid merged file"
        return 1
    fi
    if ! type baseline_update_stage >/dev/null 2>&1; then
        warn "cost_apply_merged_to_baselines: baselines.sh not loaded"
        return 1
    fi

    local rows
    rows=$(jq -r '.by_stage // [] | .[]
        | "\(.stage)\t\(.cost_usd // 0)\t\(.input_tokens // 0)\t\(.output_tokens // 0)\t\(.count // 1)"' \
        "$merged" 2>/dev/null) || return 1

    local stage cost in_tok out_tok cnt updated=0
    while IFS=$'\t' read -r stage cost in_tok out_tok cnt; do
        [[ -z "$stage" ]] && continue
        # Skip zero-cost — same rule as baseline_update_from_breakdown.
        awk -v c="$cost" 'BEGIN { exit !(c+0 > 0) }' 2>/dev/null || continue
        # Average the merged totals across the observation count so the rolling
        # baseline sees one "typical run" observation rather than a stack of
        # superimposed sums.
        local avg_cost avg_in avg_out
        avg_cost=$(awk -v c="$cost" -v n="$cnt" 'BEGIN { if (n+0 == 0) n = 1; printf "%.6f", c / n }')
        avg_in=$(awk  -v t="$in_tok"  -v n="$cnt" 'BEGIN { if (n+0 == 0) n = 1; printf "%d", t / n }')
        avg_out=$(awk -v t="$out_tok" -v n="$cnt" 'BEGIN { if (n+0 == 0) n = 1; printf "%d", t / n }')
        if baseline_update_stage "$stage" "$avg_cost" "$avg_in" "$avg_out" ""; then
            updated=$((updated + 1))
        fi
    done <<< "$rows"

    echo "$updated"
    emit_event "cost.baseline_merged_applied" "stages=${updated}" "merged=${merged}"
    return 0
}
