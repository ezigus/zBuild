#!/usr/bin/env bash
# scripts/lib/framework-result.sh — shared test-framework result (ADR-040, #1133)
#
# Generalizes the retired gate's lint/coverage/mutation read-out into reusable
# functions the `test` stage calls so a single run records suite + lint +
# coverage + mutation into test-results.json. Later read-out gates then consume
# ONE result instead of re-running the framework.
#
# Generic across targets (ADR-032/033): every command comes from a ZBUILD_*_CMD
# env var. zBuild's defaults are applied only when the var is UNSET; setting the
# var to the empty string is an explicit "skip" for a target that lacks that
# tool. Each function echoes a single JSON object on stdout — never mutates
# shared state — so callers can fold the blocks into test-results.json.
#
# Sourced library: no `set -euo pipefail`.

[[ -n "${_ZBUILD_FRAMEWORK_RESULT_LOADED:-}" ]] && return 0
_ZBUILD_FRAMEWORK_RESULT_LOADED=1

# ─── _fr_emit_lint ────────────────────────────────────────────────────────────
# Render the lint block: {status, exit_code, summary}. exit_code is JSON null
# unless a bare integer was passed (fail-closed, never crashes jq).
# Usage: _fr_emit_lint <status> <exit_code> <summary>
_fr_emit_lint() {
    local status="$1" ec="$2" summary="$3"
    local ec_json="null"
    [[ "$ec" =~ ^-?[0-9]+$ ]] && ec_json="$ec"
    jq -n --arg s "$status" --argjson ec "$ec_json" --arg sum "$summary" \
        '{status: $s, exit_code: $ec, summary: $sum}' 2>/dev/null
}

# ─── _fr_emit_coverage ────────────────────────────────────────────────────────
# Render the coverage block: {status, pct, floor}. pct/floor become JSON null
# when not a number (the skipped/error paths pass empty pct).
# Usage: _fr_emit_coverage <status> <pct> <floor>
_fr_emit_coverage() {
    local status="$1" pct="$2" floor="$3"
    local pct_json="null" floor_json="null"
    [[ "$pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] && pct_json="$pct"
    [[ "$floor" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && floor_json="$floor"
    jq -n --arg s "$status" --argjson pct "$pct_json" --argjson floor "$floor_json" \
        '{status: $s, pct: $pct, floor: $floor}' 2>/dev/null
}

# ─── _fr_emit_mutation ────────────────────────────────────────────────────────
# Render the mutation block: {status, score, floor}. score is the "N/M" string
# (null when skipped); floor becomes JSON null when not an integer.
# Usage: _fr_emit_mutation <status> <score> <floor>
_fr_emit_mutation() {
    local status="$1" score="$2" floor="$3"
    local floor_json="null"
    [[ "$floor" =~ ^-?[0-9]+$ ]] && floor_json="$floor"
    jq -n --arg s "$status" --arg score "$score" --argjson floor "$floor_json" \
        '{status: $s, score: (if $score == "" then null else $score end), floor: $floor}' 2>/dev/null
}

# ─── framework_run_lint ───────────────────────────────────────────────────────
# Runs ZBUILD_LINT_CMD (zbuild default `npm run lint`). An explicitly empty
# command (ZBUILD_LINT_CMD="") is an intentional skip on a target with no
# linter. rc==0 → pass; rc!=0 → fail (with the captured exit_code + a short
# tail-of-output summary). Echoes the lint JSON block.
# Usage: framework_run_lint
framework_run_lint() {
    # `${VAR-default}` (no colon): unset → default; set-empty → "" → skip.
    local cmd="${ZBUILD_LINT_CMD-npm run lint}"
    if [[ -z "$cmd" ]]; then
        _fr_emit_lint "skipped" "" ""
        return 0
    fi

    local out rc=0
    out="$(bash -c "$cmd" 2>&1)" || rc=$?
    if [[ $rc -eq 0 ]]; then
        _fr_emit_lint "pass" 0 "lint clean"
    else
        # Keep the tail (where most linters print the error count) within 200 bytes.
        local summary
        summary="$(printf '%s\n' "$out" | tail -n 3 | tr '\n' ' ')"
        summary="${summary:0:200}"
        _fr_emit_lint "fail" "$rc" "$summary"
    fi
}

# ─── framework_run_coverage ───────────────────────────────────────────────────
# Runs ZBUILD_COVERAGE_CMD, or (when unset) the in-tree scripts/check-coverage.sh
# relative to the current directory. An explicitly empty ZBUILD_COVERAGE_CMD="",
# or an absent default script, is a skip. Reuses the retired gate's `Total:`-line
# percentage parse. The script's exit code drives the status: 0 → measured,
# 1 → below_floor, 2 → error (instrumentation), anything else → error.
# Echoes the coverage JSON block. Usage: framework_run_coverage
framework_run_coverage() {
    local floor="${ZBUILD_COVERAGE_FLOOR:-29}"
    local out="" rc=0

    if [[ -z "${ZBUILD_COVERAGE_CMD+x}" ]]; then
        # Unset → zbuild default: the in-tree coverage script when present.
        if [[ -f scripts/check-coverage.sh ]]; then
            out="$(COVERAGE_FLOOR="$floor" bash scripts/check-coverage.sh 2>&1)" || rc=$?
        else
            _fr_emit_coverage "skipped" "" "$floor"
            return 0
        fi
    else
        local cmd="$ZBUILD_COVERAGE_CMD"
        if [[ -z "$cmd" ]]; then
            _fr_emit_coverage "skipped" "" "$floor"
            return 0
        fi
        out="$(bash -c "$cmd" 2>&1)" || rc=$?
    fi

    # Parse the OVERALL coverage % from the `Total: ... (NN.N%)` summary line —
    # never a per-file table row. Fall back to the LAST % seen, then to empty.
    local pct
    pct="$(printf '%s\n' "$out" | grep -iE '^Total:' | grep -o '[0-9][0-9]*\.[0-9]*%' | tail -1 | tr -d '%')"
    [[ -z "$pct" ]] && pct="$(printf '%s\n' "$out" | grep -o '[0-9][0-9]*\.[0-9]*%' | tail -1 | tr -d '%')"

    case "$rc" in
        0) _fr_emit_coverage "measured" "$pct" "$floor" ;;
        1) _fr_emit_coverage "below_floor" "$pct" "$floor" ;;
        *) _fr_emit_coverage "error" "$pct" "$floor" ;;
    esac
}

# ─── framework_parse_mutation ─────────────────────────────────────────────────
# Parses the suite's `mutation: N/M passed` line out of already-captured test
# output (no extra run). Absent line → skipped. floor comes from
# ZBUILD_MUTATION_FLOOR (default 0). Echoes the mutation JSON block.
# Usage: framework_parse_mutation <raw_output>
framework_parse_mutation() {
    local raw="$1"
    local floor="${ZBUILD_MUTATION_FLOOR:-0}"
    local line
    line="$(printf '%s\n' "$raw" | grep -E '^mutation: [0-9]+/[0-9]+ passed' | tail -n1)"
    if [[ -z "$line" ]]; then
        _fr_emit_mutation "skipped" "" "$floor"
        return 0
    fi
    local score
    score="$(grep -m1 -oE '[0-9]+/[0-9]+' <<< "$line")"
    _fr_emit_mutation "measured" "$score" "$floor"
}
