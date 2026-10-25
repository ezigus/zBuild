#!/usr/bin/env bash
# core/pipeline/input-resolve.sh — the previous-work index (ADR-055, amended).
#
# Every stage gets the latest output of every stage that has run, its own
# included; stages declare no inputs (ADR-055, amended 2026-10-12). The index,
# ${state_dir}/stage-inputs/<stage>.json, lists every output id in the flow whose
# file exists — {"schema_version": 2, "stage": "build", "inputs": {"design":
# "/abs/design.md", "lens_result": ["/a.json", "/b.json"]}} — a `map` producer's
# id listing its members' paths (ADR-055 §1.4).
#
# Sourced library: inherits the caller's pipefail settings; do NOT add set -euo.

[[ -n "${_ZBUILD_INPUT_RESOLVE_LOADED:-}" ]] && return 0
_ZBUILD_INPUT_RESOLVE_LOADED=1

_ZBUILD_IR_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)"
_ZBUILD_IR_ROOT="$(cd "$_ZBUILD_IR_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/manifest-graph.sh
declare -F manifest_graph_get_outputs >/dev/null 2>&1 || \
    source "$_ZBUILD_IR_ROOT/scripts/lib/manifest-graph.sh"
# atomic_write lives in helpers.sh; core/state/atomic.sh only re-exports it.
# shellcheck source=../../scripts/lib/helpers.sh
declare -F atomic_write >/dev/null 2>&1 || \
    source "$_ZBUILD_IR_ROOT/scripts/lib/helpers.sh"
# _verdict_resolve_path is the engine's single path-interpolation helper.
# shellcheck source=./verdict.sh
declare -F _verdict_resolve_path >/dev/null 2>&1 || \
    source "$_ZBUILD_IR_ROOT/core/pipeline/verdict.sh"
# shellcheck source=../plugin-registry/output-paths.sh  # _inputs_manifest_formats
declare -F _inputs_manifest_formats >/dev/null 2>&1 || \
    source "$_ZBUILD_IR_ROOT/core/plugin-registry/output-paths.sh"
# #2152: the manifest index _inputs_scan_manifests reads from.
# shellcheck source=../plugin-registry/manifest-index.sh
declare -F manifest_index_rows >/dev/null 2>&1 || \
    source "$_ZBUILD_IR_ROOT/core/plugin-registry/manifest-index.sh"

# Bounds (ADR-029). Per-iteration prompt growth caused three consecutive 900s
# max_turns timeouts; the block is capped and LATEST-WINS per stage so it stays
# flat in the number of stages, never in the number of iterations.
# #2124: 8192, matching the largest producer (the test stage caps its own summary
# there and puts the extracted ✗ lines LAST) — at 4096 the cut landed on the
# one part the builder needed.
_ZB_SUMMARY_MAX_BYTES="${ZBUILD_SUMMARY_MAX_BYTES:-8192}"
# #2183: the bound on a stage's declared error output. Smaller than a summary —
# it rides ALONGSIDE one, and ADR-029 records what unbounded prompt growth costs.
_ZB_ERRORS_MAX_BYTES="${ZBUILD_ERRORS_MAX_BYTES:-4096}"

# ─── _inputs_flow_stages ─────────────────────────────────────────────────────
# The resolved flow, one stage per line.
#
# _TPL_STAGES is a bash ARRAY, so it cannot be exported — and the `map:` dispatch
# arm runs a generated standalone script (strategies/common.sh) that sources only
# helpers/event-bus/registry. ZBUILD_INPUTS_FLOW is the scalar the runner exports
# for exactly that arm; it is set only when the flag is on.
_inputs_flow_stages() {
    if declare -p _TPL_STAGES >/dev/null 2>&1 && [[ ${#_TPL_STAGES[@]} -gt 0 ]]; then
        printf '%s\n' "${_TPL_STAGES[@]}"
        return 0
    fi
    local s
    for s in ${ZBUILD_INPUTS_FLOW:-}; do printf '%s\n' "$s"; done
}

# _inputs_scan_manifests, _inputs_stage_manifest(_v): the id/role → manifest
# maps, built from the manifest index (core/plugin-registry/manifest-index.sh).

# ─── _inputs_output_paths <stage> <raw_path> <state_dir> ─────────────────────
# The resolved path(s) a stage's declared output resolves to, one per line. A
# `map` group yields one line per element: the group's `as:` var is substituted
# into the raw path before interpolation, which is how lens-${ZBUILD_REVIEW_LENS_ID}.json
# becomes six concrete filenames.
_inputs_output_paths() {
    local stage="$1" raw="$2" state_dir="$3"
    local safe="${stage//-/_}"
    local type_var="_TPL_STAGE_TYPE_${safe}"
    if [[ "${!type_var:-}" != "map" ]]; then
        _verdict_resolve_path "$raw" "$state_dir"; printf '\n'
        return 0
    fi
    local as_var="_TPL_MAP_AS_${safe}" elems_var="_TPL_MAP_ELEMENTS_${safe}"
    local as="${!as_var:-}" elems="${!elems_var:-}"
    if [[ -z "$elems" ]]; then
        _verdict_resolve_path "$raw" "$state_dir"; printf '\n'
        return 0
    fi
    local e p
    local -a elist=()
    IFS=',' read -r -a elist <<< "$elems"
    for e in "${elist[@]}"; do
        [[ -z "$e" ]] && continue
        p="$raw"
        [[ -n "$as" ]] && p="${p//\$\{$as\}/$e}"
        _verdict_resolve_path "$p" "$state_dir"; printf '\n'
    done
}

# ─── _inputs_build_producer_index <plugins_root> <state_dir> ─────────────────
# Populates the three globals below, keyed by OUTPUT ID. Legal because ADR-055
# §5 requires each output id to be claimed by exactly one stage per resolved
# flow (OUTPUT_DUP), which is the whole reason a consumer need not name a stage.
declare -gA _IR_PRODUCER=()   # output_id → producing stage
declare -gA _IR_PATHS=()      # output_id → newline-joined resolved paths
declare -gA _IR_ISMAP=()                    # output_id → 1 when the producer is a map group
declare -gA _IR_FORMAT=()                   # output_id → the producer's declared format (#1895)
# Memo key. Building the index costs one `find` per stage (resolve_stage_plugin),
# and both the resolver and the presence check need it within one dispatch —
# without this the flag doubles that scan on every stage.
_IR_INDEX_KEY=""
_inputs_build_producer_index() {
    local plugins_root="$1" state_dir="$2"
    local flow="" key s
    # _inputs_flow_stages' list, each stage then a space, joined by the shell:
    # this runs before the memo check on every call (ADR-065 §5).
    if declare -p _TPL_STAGES >/dev/null 2>&1 && [[ ${#_TPL_STAGES[@]} -gt 0 ]]; then
        for s in "${_TPL_STAGES[@]}"; do flow+="$s "; done
    else
        for s in ${ZBUILD_INPUTS_FLOW:-}; do flow+="$s "; done
    fi
    key="${plugins_root}|${state_dir}|${flow}"
    [[ "$key" == "$_IR_INDEX_KEY" ]] && return 0
    _IR_INDEX_KEY="$key"
    _IR_PRODUCER=(); _IR_PATHS=(); _IR_ISMAP=(); _IR_FORMAT=()
    local stage manifest rec out_id out_path paths safe type_var
    while IFS= read -r stage; do
        [[ -z "$stage" ]] && continue
        _inputs_stage_manifest_v manifest "$stage" "$plugins_root" 2>/dev/null || true
        [[ -n "$manifest" ]] || continue
        safe="${stage//-/_}"; type_var="_TPL_STAGE_TYPE_${safe}"
        local -A _fmts=()
        local _fid _ffmt
        while IFS=$'\t' read -r _fid _ffmt; do
            [[ -n "$_fid" ]] && _fmts[$_fid]="$_ffmt"
        done < <(_inputs_manifest_formats "$manifest")
        while IFS= read -r rec; do
            [[ -z "$rec" ]] && continue
            out_id="${rec%%|*}"; out_path="${rec##*|}"
            [[ -z "$out_id" || -z "$out_path" ]] && continue
            # First producer wins; a second is an OUTPUT_DUP the validator owns.
            [[ -n "${_IR_PRODUCER[$out_id]:-}" ]] && continue
            paths="$(_inputs_output_paths "$stage" "$out_path" "$state_dir")"
            _IR_PRODUCER["$out_id"]="$stage"
            _IR_PATHS["$out_id"]="$paths"
            # #1895: the producer DECLARES how its artifact is checked. Captured
            # here because the producer index is the only place that already
            # knows which manifest owns this id — all of a manifest's formats in
            # one read (_inputs_manifest_formats), not one read per output.
            _IR_FORMAT["$out_id"]="${_fmts[$out_id]:-}"
            [[ "${!type_var:-}" == "map" ]] && _IR_ISMAP["$out_id"]=1
        done < <(manifest_graph_get_outputs "$manifest")
    done < <(_inputs_flow_stages)
}

# ─── _inputs_resolve_stage <stage> <plugins_root> <state_dir> [manifest] ─────
# PUBLIC ENTRY. Writes the index of every stage's latest output — every output
# id in the flow whose file is there, the stage's own included — and echoes its
# path. A map producer's id lists the members that are there.
#
# Only the latest output is listed: the live file, whichever try or run wrote
# it (ADR-068 §8). A file that is there but unusable (#1894: empty, or JSON
# that does not parse) is left out and the omission is announced, so a reader
# sees it exactly as it sees an absent one.
_inputs_resolve_stage() {
    local stage="$1" plugins_root="$2" state_dir="$3"
    # The stage id is interpolated into a filesystem path: a value with '/' or
    # '..' must never traverse.
    [[ "$stage" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || return 1
    [[ -n "$state_dir" ]] || return 1

    _inputs_build_producer_index "$plugins_root" "$state_dir"

    local id paths line tsv="" joined
    for id in "${!_IR_PATHS[@]}"; do
        paths="${_IR_PATHS[$id]}"
        joined=""
        while IFS= read -r line; do
            [[ -n "$line" && -e "$line" ]] || continue
            if _inputs_damaged "$line" "$id" "$state_dir/runtime/form-ok"; then
                if declare -F eb_emit_event >/dev/null 2>&1; then
                    local _why="damaged"; [[ -n "${_IR_ISMAP[$id]:-}" ]] && _why="damaged_member"
                    eb_emit_event "stage.input.degraded" \
                        "stage=$stage" "input=$id" "reason=$_why" \
                        "format=$(_inputs_format_for "$line" "$id")" "path=$line" 2>/dev/null || true
                fi
                continue
            fi
            joined+="${line}"$'\x1f'
        done <<< "$paths"
        [[ -n "$joined" ]] || continue
        if [[ -n "${_IR_ISMAP[$id]:-}" ]]; then
            tsv+="${id}"$'\t'"A"$'\t'"${joined}"$'\n'
        else
            tsv+="${id}"$'\t'"S"$'\t'"${joined%%$'\x1f'*}"$'\n'
        fi
    done

    local index="${state_dir}/stage-inputs/${stage}.json"
    mkdir -p "${state_dir}/stage-inputs" 2>/dev/null || return 1
    # Built into a variable first: piping jq straight into atomic_write would let
    # a jq failure write a zero-byte index and still return 0.
    local json
    json="$(printf '%s' "$tsv" | jq -nR --arg stage "$stage" '
        {schema_version: 2, stage: $stage,
         inputs: ([inputs | select(length > 0) | split("\t")
                   | {key: .[0],
                      value: (if .[1] == "A"
                              then (.[2] | split("\u001f") | map(select(length > 0)))
                              else .[2] end)}]
                  | from_entries)}' 2>/dev/null)"
    [[ -n "$json" ]] || return 1
    printf '%s\n' "$json" | atomic_write "$index" || return 1
    printf '%s\n' "$index"
}

# ─── _inputs_render_violations <header> <fix_text> <violation...> ────────────
# The shared render-all-at-once renderer. Each violation is "stage|CODE|id|msg".
# Extracted from _runner_validate_startup_preflight (#1318) so the pre-dispatch
# presence check below is not a third aggregation loop; that function now
# delegates here and its output is unchanged.
_inputs_render_violations() {
    local header="$1" fix="$2"; shift 2
    {
        printf '\n'
        printf '⚠ %s\n\n' "$header"
        local v vs vc vid vmsg
        for v in "$@"; do
            IFS='|' read -r vs vc vid vmsg <<< "$v"
            printf '  %s: %s (id=%s)\n    %s\n\n' "$vs" "$vc" "$vid" "$vmsg"
        done
        [[ -n "$fix" ]] && printf '%s\n' "$fix"
    } >&2
}

# ─── _inputs_format_for <path> [output_id] ───────────────────────────────────
# The artifact's FORMAT — what kind of check applies — as distinct from its
# type, which is what artifact it is. #1895 splits those into two declared
# fields; until it lands the format is inferred from the extension, which is why
# this is one function rather than an inline test: when `format:` becomes a
# declared field there is exactly one site to change.
_inputs_format_for() { local _iff; _inputs_format_for_v _iff "${1-}" "${2-}"; printf '%s' "$_iff"; }
_inputs_format_for_v() {
    local _iffv="$1" pth="${2-}" in_id="${3-}"
    # #1895: the producer's DECLARED format wins. The extension fallback below is
    # what #1826 shipped as an interim and is kept only for an artifact whose
    # producer declares none — it guesses, and a name not ending in a recognised
    # extension would silently get no check at all, which is why the field exists.
    if [[ -n "$in_id" && -n "${_IR_FORMAT[$in_id]:-}" ]]; then
        printf -v "$_iffv" '%s' "${_IR_FORMAT[$in_id]}"
        return 0
    fi
    case "${pth##*.}" in
        json)      printf -v "$_iffv" json ;;
        md)        printf -v "$_iffv" markdown ;;
        patch|diff) printf -v "$_iffv" patch ;;
        *)         printf -v "$_iffv" text ;;
    esac
}

# ─── _inputs_damaged <path> [output_id] [mark_dir] ───────────────────────────
# rc 0 when the artifact is present but UNUSABLE (#1894). Damage is judged by
# FORM, never by meaning — a syntactically valid file whose contents are wrong
# stays the consumer's business.
#
#   any format : zero bytes            -> damaged (empty or a failed write)
#   json       : `jq empty` rejects it -> damaged (truncated / partial write)
#
# With <mark_dir>, JSON is parsed once per change (ADR-065 §5): a passing check
# leaves a mark made BEFORE its read; while the mark is strictly newer than the
# file, nothing has written it since. A failed check removes its mark.
#
# An ABSENT file is not damaged; absence is the caller's separate case, and
# conflating them is what #1894 opened with.
_inputs_damaged() {
    local pth="${1-}" in_id="${2-}" marks="${3-}"
    [[ -e "$pth" ]] || return 1
    [[ -s "$pth" ]] || return 0
    local mark="" key fmt
    _inputs_format_for_v fmt "$pth" "$in_id"; [[ "$fmt" == json ]] || return 1
    if [[ -n "$marks" ]]; then
        key="${pth//%/%25}"; key="${key//\//%2F}"
        if (( ${#key} <= 240 )); then
            mark="$marks/$key"
            [[ "$mark" -nt "$pth" ]] && return 1
            { [[ -d "$marks" ]] || mkdir -p "$marks"; : > "$mark"; } 2>/dev/null || mark=""
        fi
    fi
    jq empty "$pth" >/dev/null 2>&1 && return 1
    [[ -z "$mark" ]] || rm -f "$mark"
    return 0
}

# ─── _summaries_stage_summary_path <stage> <plugins_root> <state_dir> ────────
# The resolved path of the ONE output <stage> marks `summary: true`, or empty.
_summaries_stage_summary_path() {
    local stage="$1" plugins_root="$2" state_dir="$3"
    local manifest rec out_id
    _inputs_stage_manifest_v manifest "$stage" "$plugins_root" 2>/dev/null || true
    [[ -n "$manifest" && -f "$manifest" ]] || return 0
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        out_id="${rec%%|*}"
        [[ -n "$out_id" ]] || continue
        [[ "$(manifest_graph_output_summary "$manifest" "$out_id")" == "true" ]] || continue
        _inputs_output_paths "$stage" "${rec##*|}" "$state_dir"
        return 0
    done < <(manifest_graph_get_outputs "$manifest")
}

# ─── _summaries_collect <state_file> <plugins_root> ──────────────────────────
# One `stage|verdict|path` line per completed stage whose declared summary is
# present and non-empty, in completion order (the key order of .stage_statuses).
# Every stage is listed, the asking stage and aggregated members included: each
# stage's latest output reaches every later stage (ADR-068 §8).
_summaries_collect() {
    local state_file="$1" plugins_root="$2"
    local state_dir; zb_dirname_v state_dir "$state_file"
    local stage path verdict
    while IFS= read -r stage; do
        [[ -z "$stage" ]] && continue
        path="$(_summaries_stage_summary_path "$stage" "$plugins_root" "$state_dir")"
        path="${path%%$'\n'*}"
        [[ -n "$path" && -s "$path" ]] || continue
        verdict="$(jq -r --arg s "$stage" '.stage_verdicts[$s] // "unknown"' "$state_file" 2>/dev/null || echo unknown)"
        printf '%s|%s|%s\n' "$stage" "$verdict" "$path"
    done < <(jq -r '(.stage_statuses // {}) | keys_unsorted[]' "$state_file" 2>/dev/null || true)
}

# _summaries_result_path <stage> <plugins_root> <state_dir> — the stage's
# primary (v2 result) file, resolved, when it exists; else "".
_summaries_result_path() {
    local stage="$1" plugins_root="$2" state_dir="$3" manifest raw res
    _inputs_stage_manifest_v manifest "$stage" "$plugins_root" 2>/dev/null || true
    [[ -n "$manifest" ]] || return 0
    _verdict_primary_output_path_v raw "$manifest" 2>/dev/null || true
    [[ -n "$raw" ]] || return 0
    _verdict_resolve_path_v res "$raw" "$state_dir"
    [[ "$res" == *.json && -s "$res" ]] && printf '%s' "$res"
    return 0
}

# ─── _summaries_stage_errors_path <stage> <plugins_root> <state_dir> ───────
# The resolved path of the output this stage declares as its ERROR CHANNEL
# (`errors: true`), or "" (#2183). A stage writes whatever error output it has
# — a subprocess's stderr, a tool's diagnostic — and the engine carries it. The
# engine classifies nothing: it does not parse, match or interpret the content,
# because error shapes are unbounded and a parser would only ever cover the
# ones we have already seen.
#
# #1841 run 35802918016: the test stage told every downstream stage
# "expected: 0, got: 1" while the nested runner's own stderr — the thing that
# said WHY — was written to a file and dropped. Six model calls went into
# rediscovering it.
_summaries_stage_errors_path() {
    local stage="$1" plugins_root="$2" state_dir="$3" manifest raw resolved
    _inputs_stage_manifest_v manifest "$stage" "$plugins_root" 2>/dev/null || true
    [[ -n "$manifest" && -f "$manifest" ]] || return 0
    # Review #2184: the entry is flushed at its BOUNDARY, so `errors: true` may
    # sit before or after `path:` — both are valid YAML, and an order-dependent
    # reader would silently skip the channel for a manifest that wrote them the
    # other way round.
    raw="$(awk '
        function flush() {
            if (want && cur != "") { print cur; found = 1 }
            cur = ""; want = 0
        }
        /^outputs:[[:space:]]*$/ { in_block = 1; next }
        in_block && /^[a-zA-Z_]/  { flush(); in_block = 0 }
        in_block && found        { next }
        in_block && /^[[:space:]]*-[[:space:]]/ { flush() }
        in_block && /^[[:space:]]+path:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+path:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            cur = line; next
        }
        in_block && /^[[:space:]]+errors:[[:space:]]*true[[:space:]]*$/ { want = 1; next }
        END { flush() }
    ' "$manifest" 2>/dev/null || true)"
    [[ -n "$raw" ]] || return 0
    _verdict_resolve_path_v resolved "$raw" "$state_dir"
    [[ -s "$resolved" ]] && printf '%s' "$resolved"
    return 0
}


# ─── stage_declares_repo_writes <manifest> ──────────────────────────────────
# rc 0 when the manifest declares capabilities.writes_repository: true — the
# one fact (#2174) that says a stage may change the repository, and therefore
# may be asked to fix something. Its own reader, not yaml_get: route.sh calls it
# where the registry is not necessarily loaded. Same rule as
# _wb_declares_repo_writes (core/pipeline/write-boundary-repo.sh) — keep the two
# in step; they are separate only because neither file may source the other.
stage_declares_repo_writes() {
    local mf="${1:-}"
    [[ -n "$mf" && -f "$mf" ]] || return 1
    awk '
        /^[^[:space:]#]/ { inblk = ($0 ~ /^capabilities:[[:space:]]*(#.*)?$/); next }
        inblk && /^[[:space:]]+writes_repository:[[:space:]]*true[[:space:]]*(#.*)?$/ { found = 1 }
        END { exit(found ? 0 : 1) }' "$mf" 2>/dev/null
}


# ─── stage_summaries_count <state_file> [plugins_root] ───────────────────────
# "<stages> <failing>": how many stage summaries the next prompt carries, and
# how many of those stages failed. The cycle banner prints it (#2124).
stage_summaries_count() {
    local state_file="${1:-}" plugins_root="${2:-${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_IR_ROOT/plugins}}"
    local n=0 r=0 rec verdict
    if [[ -n "$state_file" && -s "$state_file" ]]; then
        while IFS= read -r rec; do
            [[ -n "$rec" ]] || continue
            IFS='|' read -r _ verdict _ <<< "$rec"
            n=$((n + 1))
            case "$verdict" in fail|failed) r=$((r + 1)) ;; esac
        done < <(_summaries_collect "$state_file" "$plugins_root")
    fi
    printf '%s %s' "$n" "$r"
}
