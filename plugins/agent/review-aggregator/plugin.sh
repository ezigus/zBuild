#!/usr/bin/env bash
# plugins/agent/review-aggregator — collapse N parallel lens outputs into ONE
# advisory merge-readiness report (ADR-040 §3/§4, EPIC #1129 C2; evolves ADR-038).
#
# INPUTS: the engine resolves the `lens_result` input — the `review_lenses` map
# group's set of member result paths (ADR-055 §1.4) — and hands it over in
# ZBUILD_STAGE_INPUTS. That set is the only place lenses come from: no roster
# lookup, no directory glob (#1842). Output goes to ZBUILD_ARTIFACT_DIR.
#
# It de-dupes the collected findings by file + category + proximity, carries max
# severity + the union of contributing lenses + messages, and renders an advisory
# report (review-report.json + review-report.md). The dedup/severity/union jq is
# ported verbatim from review-report's _rr_aggregate so the collapsed report
# matches the legacy single-stage fan-out (the C3 cutover retires that fan-out).
#
# Does NO LLM call — it merges lens JSON only (no router, no ADR-004 redaction
# traffic). Advisory only: it never recommends a merge action and never gates the
# pipeline. Every exit writes a v2 review-report.json and its .md summary. rc 0
# when it aggregated (an empty lens set reports needs_attention — no review
# happened — never ready, #1753); rc 1 when the engine gave it nothing to read
# or nowhere to write, or a signal stopped it.
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

# ─── _ra_normalize_files <out_file> <name|file> [<name|file>...] ─────────────
# Normalize a set of per-lens result files into the single JSON array
# _ra_aggregate consumes: [{name, score, findings[]}, ...]. Each pair is
# "<fallback_name>|<file_path>"; the fallback name is used when the file declares
# no .name. Each file is normalized independently so one malformed file can't
# sink the whole array; a malformed file degrades to an empty entry (advisory —
# never fatal). Echoes the count of files collected.
_ra_normalize_files() {
    local out_file="$1"; shift
    local -a pairs=("$@")
    if [[ "${#pairs[@]}" -eq 0 ]]; then
        printf '[]' > "$out_file"
        printf '0'
        return 0
    fi
    local tmp="${out_file}.tmp"
    : > "$tmp"
    local pair name f
    for pair in "${pairs[@]}"; do
        name="${pair%%|*}"
        f="${pair#*|}"
        jq -c --arg n "$name" '
            {
              name: ((.name // $n) | tostring),
              score: ((.score // 0) | if type=="number" then floor else 0 end),
              # #1849: a lens whose v2 result says it did not complete reviewed
              # nothing. A file with no disposition (v1) ran.
              ran: ((.disposition // "complete") == "complete"),
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
                  message: (.message // (.|tostring)),
                  # Did the change introduce it? A lens that does not say is
                  # counted — silence must not hide a finding.
                  introduced: (if .introduced == false then false else true end)
                } else {
                  file: "unknown", category: "general", severity: "low",
                  line: null, message: (.|tostring), introduced: true
                } end ]
            }' "$f" 2>/dev/null \
            >> "$tmp" \
            || jq -nc --arg n "$name" '{name:$n, score:0, findings:[]}' >> "$tmp"
        printf '\n' >> "$tmp"
    done
    # Stable order: sort lenses by name so the report is deterministic regardless
    # of discovery/filesystem ordering across the parallel group.
    jq -sc 'sort_by(.name)' "$tmp" > "$out_file"
    rm -f "$tmp"
    printf '%s' "${#pairs[@]}"
}

# ─── _ra_collect_lenses <out_lenses_file> ────────────────────────────────────
# The engine's lens_result set from ZBUILD_STAGE_INPUTS, normalized. A map input
# is an array; a lone path is accepted as a set of one. Each file's fallback name
# is its basename minus the `lens-` prefix. Echoes the count.
_ra_collect_lenses() {
    local out_file="$1"
    local -a pairs=()
    local f name
    while IFS= read -r f; do
        [[ -n "$f" && -f "$f" ]] || continue
        name="$(basename "$f" .json)"; name="${name#lens-}"
        pairs+=("$name|$f")
    done < <(jq -r '.inputs.lens_result // [] | if type == "array" then .[] else . end' \
        "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)
    _ra_normalize_files "$out_file" "${pairs[@]}"
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
        | [ $lenses[] as $l | ($l.findings // [])[] | . + {lens: $l.name} ] as $every
        # Pre-existing problems (the code before the change did the same) are
        # listed, not counted: this change does not answer for them.
        | [ $every[] | select(.introduced != false) ] as $all
        | [ $every[] | select(.introduced == false) ] as $old
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
            pre_existing: ( $old
                | group_by([.file, .category, ((.line // 0) / $win | floor)])
                | map({file: .[0].file, category: .[0].category,
                       line: ([ .[].line | select(. != null) ] | min),
                       severity: ( max_by($rank[.severity] // 0) | .severity ),
                       lenses: ([ .[].lens ] | unique),
                       messages: ([ .[].message ] | unique)}) ),
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

# Set by _review_aggregator_run_inner before the signal guard goes up.
_ra_out_json_ref=""
_ra_out_md_ref=""

# _ra_write_result <out_json> <verdict> <disposition> <reason> [summary]
# A report with no aggregation behind it (no inputs, or stopped by a signal):
# empty lens/finding lists, the v2 envelope, and a summary saying why.
_ra_write_result() {
    local out="$1" verdict="$2" disp="$3" reason="$4"
    local summary="${5:-No review report: $reason.}"
    jq -nc --arg v "$verdict" --arg d "$disp" --arg r "$reason" --arg s "$summary" \
        '{result_contract:2, verdict:$v, disposition:$d, reason:$r,
          schema_version:1, merge_readiness:"needs_attention", lenses:[], findings:[],
          did_not_run:[], summary:$s}' | atomic_write "$out"
}

_ra_render_md() {
    render_review_report_md "$(cat "$_ra_out_json_ref" 2>/dev/null || printf '{}')" \
        | atomic_write "$_ra_out_md_ref" 2>/dev/null || true
}

# A signal stops the stage: record it in the words the shared guard passes.
_ra_on_signal() {
    _ra_write_result "$_ra_out_json_ref" "degraded" "$1" "$2" \
        "Review aggregation stopped by a signal; this report is incomplete." 2>/dev/null || true
    _ra_render_md
    stage_signal_end
    exit 1
}

# ─── review_aggregator_run ──────────────────────────────────────────────────
# Hook: review_aggregator_run(stage, state_file). Writes where the engine says
# (ZBUILD_ARTIFACT_DIR) — never into a directory derived from the state file.
review_aggregator_run() {
    local out_dir="${ZBUILD_ARTIFACT_DIR:-}"
    if [[ -z "$out_dir" ]]; then
        error "review_aggregator_run: ZBUILD_ARTIFACT_DIR is not set — the engine gave the aggregator nowhere to write its report"
        return 1
    fi
    mkdir -p "$out_dir"
    _review_aggregator_run_inner "$out_dir" "$out_dir/review-report.json" "$out_dir/review-report.md"
}

# Inner implementation — unit-testable with explicit paths.
# Args: $1=work dir (the combined lens array lands here)  $2=out .json  $3=out .md
_review_aggregator_run_inner() {
    local work_dir="$1" out_json="$2" out_md="$3"
    mkdir -p "$work_dir"
    _ra_out_json_ref="$out_json"
    _ra_out_md_ref="$out_md"
    stage_signal_begin _ra_on_signal

    if [[ -z "${ZBUILD_STAGE_INPUTS:-}" || ! -f "${ZBUILD_STAGE_INPUTS:-}" ]]; then
        error "review-aggregator: no stage inputs (ZBUILD_STAGE_INPUTS='${ZBUILD_STAGE_INPUTS:-}') — the engine did not hand over the lens results"
        _ra_write_result "$out_json" "degraded" "misconfigured" "stage_inputs_missing" \
            "No review report: the engine did not hand this stage its lens results."
        _ra_render_md
        emit_event "plugin.result" "plugin=review-aggregator" \
            "merge_readiness=needs_attention" "lens_count=0"
        stage_signal_end
        return 1
    fi

    local lenses_file="$work_dir/review-aggregator-lenses.json"
    local lens_count
    lens_count="$(_ra_collect_lenses "$lenses_file")"
    if [[ "${lens_count:-0}" -eq 0 ]]; then
        emit_event "review_aggregator.no_lenses" "artifact_dir=$(basename "$work_dir")"
    fi

    # Aggregate + de-dupe into the advisory report. The manifest's primary output
    # (review-report.json) is written atomically first — #507 atomicity contract.
    _ra_aggregate "$lenses_file" | atomic_write "$out_json"

    # What _ra_aggregate cannot see stays out of it (it is byte-for-byte with
    # review-report's _rr_aggregate): #1849 — a lens that did not run is named
    # and makes the report needs_attention; #1753 — no lens at all is no review,
    # never `ready` (all() over an empty score list is true). Then the envelope.
    local _nr
    _nr="$(jq -c '[.[] | select(.ran == false) | .name]' "$lenses_file" 2>/dev/null || printf '[]')"
    jq --argjson nr "${_nr:-[]}" --argjson total "${lens_count:-0}" '
        . + {did_not_run: $nr}
        | if $total == 0 then
            .merge_readiness = "needs_attention"
            | .summary = "No lens results reached this stage — no review happened. " + (.summary // "")
            | .escalation_note = "No lens ran, so nothing was reviewed; re-run the review before merging. Advisory only — this does not block the pipeline."
          elif ($nr | length) > 0 then
            .merge_readiness = "needs_attention"
            | .summary = ("\($nr | length) of \($total) lens(es) did not run (\($nr | join(", "))) — "
                          + "their review is missing, not clean. " + .summary)
            | .escalation_note = "Some lenses did not run, so this report is incomplete; re-run the review before merging. Advisory only — this does not block the pipeline."
          else . end
        | . + {result_contract: 2, verdict: "complete", disposition: "complete",
               reason: "aggregated \($total) lens result(s)"}' \
        "$out_json" 2>/dev/null | atomic_write "$out_json" || true

    local merge_readiness
    merge_readiness="$(jq -r '.merge_readiness // "advisory"' "$out_json" 2>/dev/null || echo advisory)"

    # The summary is written on every exit (ADR-055 §9).
    _ra_render_md

    # Issue OUT (ADR-038): surface the merge-readiness report to the operator as
    # PROSE — io-gated on this stage's own destinations so a file-only install
    # stays quiet. Reuses the already-rendered .md (no re-render). The lens
    # members are file-only, so this is the ONE human-readable review summary the
    # operator sees on the terminal (raw JSON stays in artifacts).
    if [[ -s "$out_md" ]] && declare -F template_stage_io_dests >/dev/null 2>&1; then
        local _dests
        _dests="$(template_stage_io_dests "${ZBUILD_CURRENT_STAGE:-review-aggregator}" 2>/dev/null || true)"
        if grep -qx stdout <<< "$_dests"; then
            local _io_fd="${ZBUILD_STAGE_IO_FD:-2}"
            # shellcheck disable=SC2261
            { printf '\n'; cat "$out_md"; printf '\n'; } >&"$_io_fd" 2>/dev/null || true
        fi
    fi

    emit_event "plugin.result" \
        "plugin=review-aggregator" \
        "merge_readiness=$merge_readiness" \
        "lens_count=$lens_count"
    stage_signal_end
    return 0
}
