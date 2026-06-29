#!/usr/bin/env bash
# plugins/agent/review-aggregator — collapse N parallel lens outputs into ONE
# advisory merge-readiness report (ADR-040 §3/§4, EPIC #1129 C2; evolves ADR-038).
#
# ROSTER-DRIVEN discovery (Phase 2, naming-agnostic): the aggregator runs as a
# separate, non-member stage, so it SELF-RESOLVES which parallel group it serves
# via Phase 1's binding — the `aggregate: advisory` group whose bound non-member
# `convergence: advisory` aggregator (first such stage in canonical order) is
# THIS stage. It then reads that group's members from _TPL_PARALLEL_FLOW_<group>
# and, for each member, resolves the member's manifest (id-first then
# provides.role) and its DECLARED result artifact — exactly like gate-aggregator's
# _ga_member_manifest / _ga_manifest_result_file — collecting those files instead
# of a `lens-*.json` filename glob. A LEGACY GLOB FALLBACK (lens-<name>.json) is
# kept for cycle-less / standalone invocation (unit tests), mirroring
# gate-aggregator's fallback pattern.
#
# It de-dupes the collected findings by file + category + proximity, carries max
# severity + the union of contributing lenses + messages, and renders an advisory
# report (review-report.json + review-report.md). The dedup/severity/union jq is
# ported verbatim from review-report's _rr_aggregate so the collapsed report
# matches the legacy single-stage fan-out (the C3 cutover retires that fan-out).
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

# Manifest libs for ROSTER-DRIVEN member discovery (Phase 2): member id →
# manifest (manifest_graph_collect) + manifest → declared result file
# (manifest_graph_primary_output) + convergence/role scalar reads (yaml_get).
# Mirrors gate-aggregator's sourcing. Best-effort: a missing lib degrades to the
# legacy glob fallback (the env arrays will simply be absent in that case).
# shellcheck source=../../../scripts/lib/manifest-graph.sh
source "$_RA_ROOT/scripts/lib/manifest-graph.sh" 2>/dev/null || true
# shellcheck source=../../../core/plugin-registry/manifest-validation.sh
source "$_RA_ROOT/core/plugin-registry/manifest-validation.sh" 2>/dev/null || true

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
    # of discovery/filesystem ordering across the parallel group.
    jq -sc 'sort_by(.name)' "$tmp" > "$out_file"
    rm -f "$tmp"
    printf '%s' "${#pairs[@]}"
}

# ─── _ra_collect_lenses_glob <artifact_dir> <out_lenses_file> ────────────────
# LEGACY FALLBACK (cycle-less / standalone invocation, e.g. unit tests): glob the
# shared artifacts dir for lens-<name>.json and normalize. The per-file fallback
# name is the basename minus the `lens-` prefix.
_ra_collect_lenses_glob() {
    local artifact_dir="$1" out_file="$2"
    local -a pairs=()
    local f name
    shopt -s nullglob
    for f in "$artifact_dir"/lens-*.json; do
        name="$(basename "$f" .json)"; name="${name#lens-}"
        pairs+=("$name|$f")
    done
    shopt -u nullglob
    _ra_normalize_files "$out_file" "${pairs[@]}"
}

# ─── _ra_member_manifest <plugins_root> <member> ─────────────────────────────
# Resolve a parallel-group member stage id to its plugin manifest path. Mirrors
# gate-aggregator's _ga_member_manifest: id-match first (manifest_graph_collect),
# else bind by the member's first declared role (_TPL_STAGE_ROLES_<safe>) to the
# manifest whose provides.role matches. Echoes the manifest path; rc 1 if unresolved.
_ra_member_manifest() {
    local plugins_root="$1" member="$2" m
    declare -f manifest_graph_collect >/dev/null 2>&1 || return 1
    m="$(manifest_graph_collect "$plugins_root" "$member" 2>/dev/null)"
    if [[ -n "$m" && -f "$m" ]]; then printf '%s\n' "$m"; return 0; fi
    local safe="${member//-/_}" roles_var roles role cand r
    roles_var="_TPL_STAGE_ROLES_${safe}"
    roles="${!roles_var:-}"
    role="${roles%%,*}"            # first declared role
    [[ -z "$role" ]] && return 1
    while IFS= read -r -d '' cand; do
        r="$(yaml_get "$cand" "provides.role" 2>/dev/null)"
        if [[ "$r" == "$role" ]]; then printf '%s\n' "$cand"; return 0; fi
    done < <(find "$plugins_root" -name manifest.yaml -not -path '*/tests/*' -print0 2>/dev/null)
    return 1
}

# ─── _ra_manifest_result_file <manifest> <member> ────────────────────────────
# The member's recorded result artifact FILENAME: provides.artifact_type, else
# the basename of the primary output's declared path (mirrors gate-aggregator's
# _ga_manifest_result_file). The lens members share ONE manifest whose primary
# output path is PER-MEMBER parameterized (lens-${ZBUILD_REVIEW_LENS_ID}.json);
# any leftover ${...} placeholder is expanded to the member's derived lens id —
# the member stage id minus the `review-lens-`/`lens-`/`lens_` prefix, exactly
# how the review-lens plugin derives its id and writes lens-<id>.json.
_ra_manifest_result_file() {
    local manifest="$1" member="$2" at row path base
    at="$(yaml_get "$manifest" "provides.artifact_type" 2>/dev/null)"
    if [[ -n "$at" ]]; then printf '%s\n' "$at"; return 0; fi
    declare -f manifest_graph_primary_output >/dev/null 2>&1 || return 1
    row="$(manifest_graph_primary_output "$manifest" 2>/dev/null)" || return 1
    path="${row##*|}"
    [[ -z "$path" ]] && return 1
    base="${path##*/}"
    if [[ "$base" == *'${'* ]]; then
        local sid="$member"
        sid="${sid#review-lens-}"; sid="${sid#lens-}"; sid="${sid#lens_}"
        while [[ "$base" == *'${'* ]]; do
            base="${base%%'${'*}${sid}${base#*\}}"
        done
    fi
    printf '%s\n' "$base"
}

# ─── _ra_stage_convergence <plugins_root> <stage_id> → gate|advisory|"" ───────
# Resolve a template stage id to its plugin manifest's `convergence:` marker,
# mirroring contract-validator's _cv_stage_convergence: id-matching manifest is
# authoritative, else bind by the stage's first declared role. Empty when the
# stage carries no marker (legacy / untyped).
_ra_stage_convergence() {
    local proot="$1" sid="$2" m val="" cand r
    declare -f manifest_graph_collect >/dev/null 2>&1 || return 0
    local safe="${sid//-/_}" roles_var role
    roles_var="_TPL_STAGE_ROLES_${safe}"
    role="${!roles_var:-}"; role="${role%%,*}"
    m="$(manifest_graph_collect "$proot" "$sid" 2>/dev/null || true)"
    if [[ -n "$m" && -f "$m" ]]; then
        val="$(yaml_get "$m" convergence 2>/dev/null)"
    elif [[ -n "$role" ]]; then
        while IFS= read -r -d '' cand; do
            r="$(yaml_get "$cand" "provides.role" 2>/dev/null)"
            if [[ "$r" == "$role" ]]; then
                val="$(yaml_get "$cand" convergence 2>/dev/null)"
                break
            fi
        done < <(find "$proot" -name manifest.yaml -not -path '*/tests/*' -print0 2>/dev/null)
    fi
    printf '%s' "$val"
}

# ─── _ra_resolve_group <plugins_root> <self_stage> ───────────────────────────
# SELF-RESOLVE which `aggregate: advisory` parallel group THIS aggregator serves
# (Phase 1 binding). For each advisory group, the bound aggregator is the FIRST
# non-member `convergence: advisory` stage in canonical (_TPL_STAGES) order —
# the same rule contract-validator/lint enforce. Echoes the group id whose bound
# aggregator is <self_stage>; rc 1 when no template/group env is in scope or no
# group binds to this stage (→ caller uses the legacy glob fallback).
_ra_resolve_group() {
    local plugins_root="$1" self_stage="$2"
    [[ -z "$self_stage" ]] && return 1
    declare -p _TPL_PARALLEL_GROUPS >/dev/null 2>&1 || return 1
    [[ "${#_TPL_PARALLEL_GROUPS[@]}" -eq 0 ]] && return 1
    declare -p _TPL_STAGES >/dev/null 2>&1 || return 1
    local g gsafe agg_var flow_var flow
    for g in "${_TPL_PARALLEL_GROUPS[@]}"; do
        gsafe="${g//-/_}"
        agg_var="_TPL_PARALLEL_AGGREGATE_${gsafe}"
        [[ "${!agg_var:-}" == "advisory" ]] || continue
        flow_var="_TPL_PARALLEL_FLOW_${gsafe}"
        flow="${!flow_var:-}"
        local -A members=()
        local IFS_s="$IFS"; IFS=','
        # shellcheck disable=SC2206
        local -a ms=($flow)
        IFS="$IFS_s"
        local m; for m in "${ms[@]}"; do [[ -n "$m" ]] && members["$m"]=1; done
        # Bound aggregator = first non-member convergence:advisory stage.
        local st bound=""
        for st in "${_TPL_STAGES[@]}"; do
            [[ -n "${members[$st]:-}" ]] && continue
            if [[ "$(_ra_stage_convergence "$plugins_root" "$st")" == "advisory" ]]; then
                bound="$st"; break
            fi
        done
        if [[ "$bound" == "$self_stage" ]]; then printf '%s' "$g"; return 0; fi
    done
    return 1
}

# ─── _ra_collect_lenses_roster <plugins_root> <group> <artifact_dir> <out> ───
# ROSTER discovery: read the group's members from _TPL_PARALLEL_FLOW_<group>,
# resolve each member's manifest + declared result file, and normalize the files
# present in <artifact_dir> (naming-agnostic — NOT a lens-*.json glob). The
# per-file fallback name is the member's derived lens id. Echoes the count.
_ra_collect_lenses_roster() {
    local plugins_root="$1" group="$2" artifact_dir="$3" out_file="$4"
    local gsafe="${group//-/_}"
    local flow_var="_TPL_PARALLEL_FLOW_${gsafe}"
    local flow="${!flow_var:-}"
    local IFS_s="$IFS"; IFS=','
    # shellcheck disable=SC2206
    local -a member_list=($flow)
    IFS="$IFS_s"
    local -a pairs=()
    local member manifest rf f name
    for member in "${member_list[@]}"; do
        [[ -z "$member" ]] && continue
        manifest="$(_ra_member_manifest "$plugins_root" "$member")" || continue
        rf="$(_ra_manifest_result_file "$manifest" "$member")" || continue
        [[ -z "$rf" ]] && continue
        f="$artifact_dir/$rf"
        [[ -f "$f" ]] || continue
        name="${member#review-lens-}"; name="${name#lens-}"; name="${name#lens_}"
        pairs+=("$name|$f")
    done
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
# Args: $1=artifact_dir  $2=out review-report.json  $3=out .md
_review_aggregator_run_inner() {
    local artifact_dir="$1" out_json="$2" out_md="$3"
    if [[ -z "$out_json" ]]; then
        error "_review_aggregator_run_inner: output path required"
        return 2
    fi
    mkdir -p "$artifact_dir"

    # Collect the parallel group's per-lens results into one array. ROSTER-DRIVEN
    # when this stage self-resolves to an `aggregate: advisory` group (Phase 2);
    # otherwise the LEGACY lens-*.json glob (standalone / unit-test invocation).
    local lenses_file="$artifact_dir/review-aggregator-lenses.json"
    local lens_count group="" discovery="glob"
    local self_stage="${ZBUILD_CURRENT_STAGE:-}"
    local plugins_root="${ZBUILD_PLUGINS_ROOT:-$_RA_ROOT/plugins}"
    if [[ -n "$self_stage" ]]; then
        group="$(_ra_resolve_group "$plugins_root" "$self_stage")" || group=""
    fi
    if [[ -n "$group" ]]; then
        discovery="roster"
        lens_count="$(_ra_collect_lenses_roster "$plugins_root" "$group" "$artifact_dir" "$lenses_file")"
    else
        lens_count="$(_ra_collect_lenses_glob "$artifact_dir" "$lenses_file")"
    fi
    if [[ "${lens_count:-0}" -eq 0 ]]; then
        emit_event "review_aggregator.no_lenses" \
            "artifact_dir=$(basename "$artifact_dir")" "discovery=$discovery"
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
        "lens_count=$lens_count" \
        "discovery=$discovery"
    return 0
}

# ─── review_aggregator_finalize ─────────────────────────────────────────────
review_aggregator_finalize() {
    emit_event "plugin.finalize.complete" "plugin=review-aggregator"
    return 0
}
