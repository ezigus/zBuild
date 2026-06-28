#!/usr/bin/env bash
# plugins/agent/review-aggregator — collapse N parallel lens outputs into ONE
# advisory merge-readiness report (ADR-040 §3/§4, EPIC #1129 C2; evolves ADR-038).
#
# Globs the lens group's lens-<name>.json results from the shared artifacts dir,
# de-dupes their findings by file + category + proximity, carries max severity +
# the union of contributing lenses + messages, and renders an advisory report
# (review-report.json + review-report.md). The dedup/severity/union jq is ported
# verbatim from review-report's _rr_aggregate so the collapsed report matches the
# legacy single-stage fan-out (the C3 cutover retires that fan-out).
#
# Does NO LLM call — it merges lens JSON only (no router, no ADR-004 redaction
# traffic). Advisory only: it never recommends a merge action and never gates the
# pipeline. _review_aggregator_run_inner ALWAYS writes review-report.json first
# and returns 0 (an empty / absent lens group degrades to an empty report).
#
# ADR refs: ADR-001 (plugin contract), ADR-038 (lens aggregation logic origin),
#           ADR-040 (composable gate+lens stages; advisory aggregator).
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_REVIEW_AGGREGATOR_LOADED:-}" ]] && return 0
_ZBUILD_REVIEW_AGGREGATOR_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_RA_DIR="$_ZBUILD_PLUGIN_DIR"; : "$_RA_DIR"
_RA_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_RA_ROOT/core/event-bus/event-bus.sh"
# render_review_report_md + atomic_write arrive via plugin-bootstrap (helpers.sh
# + artifact-render.sh); no explicit source needed.

# Severity ordinal map (jq-injected for max-severity selection in dedup). Ported
# from review-report/lib/lenses.sh (_RR_SEV_RANK) — keep the two in lockstep.
_RA_SEV_RANK='{"low":1,"medium":2,"high":3,"critical":4}'

# Proximity window (lines): two findings on the same file+category within this
# many lines de-dupe to one. Override with ZBUILD_RR_PROXIMITY_WINDOW (the same
# knob review-report honors). Clamped to a positive integer — a 0 or non-integer
# would be a jq division-by-zero / --argjson parse error that degrades the whole
# report to the fallback.
_ra_proximity_window() {
    local w="${ZBUILD_RR_PROXIMITY_WINDOW:-10}"
    [[ "$w" =~ ^[1-9][0-9]*$ ]] || w=10
    printf '%s' "$w"
}

# ─── _ra_collect_lenses <artifact_dir> <out_lenses_file> ────────────────────
# Glob the lens group's lens-<name>.json results into a single JSON array (the
# shape _ra_aggregate consumes: [{name, score, findings[]}, ...]). Each lens
# file is normalized to {name, score, findings[]}; a malformed lens degrades to
# an empty entry (advisory — never fatal). Echoes the count of lenses collected.
_ra_collect_lenses() {
    local artifact_dir="$1" out_file="$2"
    local -a files=()
    local f
    shopt -s nullglob
    for f in "$artifact_dir"/lens-*.json; do
        files+=("$f")
    done
    shopt -u nullglob

    if [[ "${#files[@]}" -eq 0 ]]; then
        printf '[]' > "$out_file"
        printf '0'
        return 0
    fi

    # Normalize each lens file independently so one malformed file can't sink the
    # whole array; then jq -s the per-lens objects into the combined array.
    local tmp="${out_file}.tmp"
    : > "$tmp"
    for f in "${files[@]}"; do
        local name; name="$(basename "$f" .json)"; name="${name#lens-}"
        jq -c --arg n "$name" '
            {
              name: ((.name // $n) | tostring),
              score: ((.score // 0) | if type=="number" then floor else 0 end),
              findings: [ (.findings // [])[] |
                if type=="object" then {
                  file: (.file // "unknown"),
                  category: (.category // "general"),
                  severity: (if (.severity|tostring|ascii_downcase) as $s
                             | ["low","medium","high","critical"] | index($s)
                             then (.severity|tostring|ascii_downcase) else "low" end),
                  line: (.line | if type=="number" then floor
                                 elif type=="string" then (tonumber? // null)
                                 else null end),
                  message: (.message // (.|tostring))
                } else {
                  file: "unknown", category: "general", severity: "low",
                  line: null, message: (.|tostring)
                } end ]
            }' "$f" 2>/dev/null \
            >> "$tmp" \
            || jq -nc --arg n "$name" '{name:$n, score:0, findings:[]}' >> "$tmp"
        printf '\n' >> "$tmp"
    done
    # Stable order: sort lenses by name so the report is deterministic regardless
    # of glob/filesystem ordering across the parallel group.
    jq -sc 'sort_by(.name)' "$tmp" > "$out_file"
    rm -f "$tmp"
    printf '%s' "${#files[@]}"
}

# ─── _ra_aggregate <lenses_json_file> ───────────────────────────────────────
# Aggregate per-lens results into the advisory merge-readiness report. Flat
# findings are de-duped by file + category + proximity bucket, carrying the max
# severity, the union of contributing lenses, and the union of messages. Ported
# verbatim from review-report/lib/lenses.sh _rr_aggregate (ADR-038) so the
# collapsed report is byte-for-byte equivalent to the legacy fan-out.
_ra_aggregate() {
    local lenses_file="$1" window; window="$(_ra_proximity_window)"
    jq -c \
        --argjson rank "$_RA_SEV_RANK" \
        --argjson win "$window" '
        . as $lenses
        | [ $lenses[] as $l | ($l.findings // [])[] | . + {lens: $l.name} ] as $all
        | ( $all
            | group_by([.file, .category, ((.line // 0) / $win | floor)])
            | map({
                file: .[0].file,
                category: .[0].category,
                line: ([ .[].line | select(. != null) ] | min),
                severity: ( max_by($rank[.severity] // 0) | .severity ),
                lenses: ([ .[].lens ] | unique),
                messages: ([ .[].message ] | unique)
              })
          ) as $flat
        | ( [ $lenses[].score ] ) as $scores
        | ( [ $flat[].severity ] ) as $sevs
        | (
            if ($sevs | any(. == "critical")) then "needs_attention"
            elif ($scores | any(. <= 3)) then "needs_attention"
            elif ($flat | length) == 0 and ($scores | all(. >= 7)) then "ready"
            else "advisory" end
          ) as $readiness
        | {
            schema_version: 1,
            merge_readiness: $readiness,
            lenses: $lenses,
            findings: $flat,
            summary: (
              "\($flat | length) merge-readiness finding(s) across "
              + "\($lenses | length) lens(es)"
              + " (\([ $sevs[] | select(. == "critical") ] | length) critical, "
              + "\([ $sevs[] | select(. == "high") ] | length) high)."
            ),
            escalation_note: (
              if $readiness == "needs_attention" then
                "One or more lenses scored <=3 or found a critical-severity issue; consider requesting a tier-2 expert review or escalating to a senior reviewer before merging. Advisory only — this does not block the pipeline."
              else null end
            )
          }' "$lenses_file" 2>/dev/null \
    || printf '{"schema_version":1,"merge_readiness":"advisory","lenses":[],"findings":[],"summary":"Report unavailable: aggregation error."}'
}

# ─── review_aggregator_init ─────────────────────────────────────────────────
review_aggregator_init() {
    export ZBUILD_PLUGIN="review-aggregator"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=review-aggregator"
    return 0
}

# ─── review_aggregator_run ──────────────────────────────────────────────────
# Hook: review_aggregator_run(stage, state_file). Derives artifact paths and
# delegates to the unit-testable inner function.
review_aggregator_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "review_aggregator_run: state_file argument required"
        return 2
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifact_dir="$state_dir/artifacts"
    mkdir -p "$artifact_dir"

    _review_aggregator_run_inner \
        "$artifact_dir" \
        "$artifact_dir/review-report.json" \
        "$artifact_dir/review-report.md"
}

# Inner implementation — unit-testable with explicit paths.
# Args: $1=artifact_dir (globbed for lens-*.json)  $2=out review-report.json  $3=out .md
_review_aggregator_run_inner() {
    local artifact_dir="$1" out_json="$2" out_md="$3"
    if [[ -z "$out_json" ]]; then
        error "_review_aggregator_run_inner: output path required"
        return 2
    fi
    mkdir -p "$artifact_dir"

    # Collect the parallel lens group's lens-<name>.json results into one array.
    local lenses_file="$artifact_dir/review-aggregator-lenses.json"
    local lens_count
    lens_count="$(_ra_collect_lenses "$artifact_dir" "$lenses_file")"
    if [[ "${lens_count:-0}" -eq 0 ]]; then
        emit_event "review_aggregator.no_lenses" "artifact_dir=$(basename "$artifact_dir")"
    fi

    # Aggregate + de-dupe into the advisory report. The manifest's primary output
    # (review-report.json) is written atomically first — #507 atomicity contract.
    _ra_aggregate "$lenses_file" | atomic_write "$out_json"

    local merge_readiness
    merge_readiness="$(jq -r '.merge_readiness // "advisory"' "$out_json" 2>/dev/null || echo advisory)"

    # Render markdown via the shared renderer (reused from review-report / ADR-038).
    if [[ -s "$out_json" ]]; then
        render_review_report_md "$(cat "$out_json")" | atomic_write "$out_md" 2>/dev/null || true
    fi

    emit_event "plugin.run.complete" \
        "plugin=review-aggregator" \
        "merge_readiness=$merge_readiness" \
        "lens_count=$lens_count"
    return 0
}

# ─── review_aggregator_finalize ─────────────────────────────────────────────
review_aggregator_finalize() {
    emit_event "plugin.finalize.complete" "plugin=review-aggregator"
    return 0
}
