#!/usr/bin/env bash
# core/pipeline/input-resolve.sh — the previous-work index (ADR-055, amended).
#
# Every stage receives the latest output of every stage that has run, its own
# included — there is no "what a stage depends on". The index below lists them
# all, keyed by output id; a stage reads the ones it needs and checks for itself
# that what it needs is there.
#
# History:
# `manifest_graph_get_inputs` had four call sites and all four were static
# validators. No runtime path ever turned an input declaration into a PATH, so
# every declaration was inert and 25 of 37 plugin.sh files hardcoded artifact
# filenames instead. This module is the missing runtime half: it resolves a
# stage's declared inputs to concrete paths, writes them to an index file, and
# the engine hands that index to `run`.
#
# #1825 removed the ZBUILD_INPUTS_RESOLVE gate. #1826 shipped behind it so the
# engine could land inert, but an inert flag that stays inert is the pattern
# Phase 0 exists to end — the same reason #1865 un-held CYCLE_FB_UNWIRED.
# Resolution is unconditional; the functions themselves are pure.
#
# Index shape, written to ${state_dir}/stage-inputs/<stage>.json:
#
#   {"schema_version": 1, "stage": "build",
#    "inputs": {"design": "/abs/design.md", "lens_result": ["/a.json","/b.json"]}}
#
# A `map` producer yields a JSON ARRAY of its members' resolved paths under the
# one input id (ADR-055 §1.4) — that is what retires review-aggregator's
# `lens-*.json` wildcard.
#
# #2326 (ADR-050 §8): a path served from an earlier run's saved copy is also
# listed under `earlier_run` (the key is absent when there is none):
#
#   {..., "inputs": {"design": "/restored/design.md"},
#    "earlier_run": ["/restored/design.md"]}
#
# Sourced library: inherits the caller's pipefail settings; do NOT add set -euo.

[[ -n "${_ZBUILD_INPUT_RESOLVE_LOADED:-}" ]] && return 0
_ZBUILD_INPUT_RESOLVE_LOADED=1

_ZBUILD_IR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_IR_ROOT="$(cd "$_ZBUILD_IR_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/manifest-graph.sh
declare -F manifest_graph_get_inputs >/dev/null 2>&1 || \
    source "$_ZBUILD_IR_ROOT/scripts/lib/manifest-graph.sh"
# atomic_write lives in helpers.sh; core/state/atomic.sh only re-exports it.
# shellcheck source=../../scripts/lib/helpers.sh
declare -F atomic_write >/dev/null 2>&1 || \
    source "$_ZBUILD_IR_ROOT/scripts/lib/helpers.sh"
# _verdict_resolve_path is the engine's single path-interpolation helper.
# shellcheck source=./verdict.sh
declare -F _verdict_resolve_path >/dev/null 2>&1 || \
    source "$_ZBUILD_IR_ROOT/core/pipeline/verdict.sh"
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

# ─── _inputs_scan_manifests <plugins_root> ───────────────────────────────────
# ONE pass over the plugin tree, building the id→manifest and role→manifest maps
# _inputs_stage_manifest resolves against.
#
# Why not just call resolve_stage_plugin per stage: it goes through
# discover_plugins, which costs ~8s per call on this tree. The index needs a
# manifest for EVERY stage in the flow, so a per-stage call would add ~2 minutes
# to every dispatch. One find + one awk for the whole tree (#2152) is ~40ms.
# #2152 (ADR-065 §3): every reader of these maps is a `$( )` — the fill has to
# happen in the PARENT shell, at the runner's prewarm seam, or it happens on
# every call. Bare `declare -gA` (no `=()`): route.sh re-sources this file
# lazily inside a function, and an initialiser there would wipe the fill.
declare -gA _IR_BY_ID
declare -gA _IR_BY_ROLE
[[ -n "${_IR_SCAN_KEY+x}" ]] || _IR_SCAN_KEY=""
_inputs_scan_manifests() {
    local plugins_root; plugins_root="$(_manifest_index_root "$1")"
    [[ "$plugins_root" == "$_IR_SCAN_KEY" ]] && return 0
    _IR_SCAN_KEY="$plugins_root"
    _IR_BY_ID=(); _IR_BY_ROLE=()
    # #2152: read from the manifest index — no awk per manifest. Rows arrive
    # file by file; a file's `__file__` marker precedes its keys, so the
    # previous file is complete when the next marker (or the end) arrives.
    manifest_index_load "$plugins_root"
    # Collect per file, commit in marker order at the end: the rows' order is
    # not a contract (the memo streams them per file, a fresh build emits every
    # `__file__` marker first — review on #2155), and first-occurrence-wins
    # needs the files in the order they were enumerated.
    local -a _files=()
    local -A _id=() _role=() _plat=()
    local m p k v
    while IFS=$'\034' read -r p k v; do
        if [[ "$k" == "__file__" ]]; then _files+=("$p"); continue; fi
        # the old per-file awk also trimmed trailing whitespace
        v="${v%"${v##*[![:space:]]}"}"
        case "$k" in
            id) _id["$p"]="$v" ;; platform) _plat["$p"]="$v" ;; provides.role) _role["$p"]="$v" ;;
        esac
    done < <(manifest_index_rows "$plugins_root")
    for m in "${_files[@]+"${_files[@]}"}"; do
        [[ "$m" != */tests/* ]] || continue
        [[ -n "${_id[$m]:-}" && -z "${_IR_BY_ID[${_id[$m]}]:-}" ]] && _IR_BY_ID["${_id[$m]}"]="$m"
        # Platform-specific plugins never win the generic slot; the engine's own
        # resolver prefers a platform match and this module has no platform.
        if [[ -n "${_role[$m]:-}" && ( -z "${_plat[$m]:-}" || "${_plat[$m]:-}" == "null" ) && -z "${_IR_BY_ROLE[${_role[$m]}]:-}" ]]; then
            _IR_BY_ROLE["${_role[$m]}"]="$m"
        fi
    done
}

# ─── _inputs_stage_manifest <stage> <plugins_root> ───────────────────────────
# The manifest DISPATCH would actually use — role-THEN-id, the resolve_stage_plugin
# rule (dispatch.sh), applied to the single-scan maps above.
#
# NOT manifest_graph_collect: that is id-only, and against the live simple.yaml
# stage list it resolves `acceptance-gate` and `review_lenses` to no manifest at
# all — they are silently skipped by contract-validator.sh:213 today. NOT
# manifest_graph_resolve_member either: it tries id-match FIRST, so `pr` lands on
# plugins/tool/pr-open, the manifest whose own header documents it as deliberately
# unreachable at dispatch (the real plugin is plugins/agent/pr-delivery, bound by
# role). Role-first is the only rule that agrees with dispatch on all three.
#
# Fail-closed on a declared-but-unresolved role, matching resolve_stage_plugin:
# no id-match fallback once roles are declared.
_inputs_stage_manifest() {
    local stage="$1" plugins_root="$2"
    _inputs_scan_manifests "$plugins_root"
    local safe="${stage//-/_}"
    local roles_var="_TPL_STAGE_ROLES_${safe}"
    local roles="${!roles_var:-}" role
    if [[ -n "$roles" ]]; then
        local -a rlist=()
        IFS=',' read -r -a rlist <<< "$roles"
        for role in "${rlist[@]}"; do
            [[ -z "$role" ]] && continue
            if [[ -n "${_IR_BY_ROLE[$role]:-}" ]]; then
                printf '%s\n' "${_IR_BY_ROLE[$role]}"; return 0
            fi
        done
        return 1
    fi
    [[ -n "${_IR_BY_ID[$stage]:-}" ]] || return 1
    printf '%s\n' "${_IR_BY_ID[$stage]}"
}

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

# ─── _inputs_manifest_formats <manifest> ─────────────────────────────────────
# "id<TAB>format" for every output the manifest declares, in one read.
_inputs_manifest_formats() {
    awk '
        function flush() { if (id != "") print id "\t" fmt; id = ""; fmt = "" }
        /^outputs:[[:space:]]*$/ { inb = 1; next }
        inb && /^[a-zA-Z_]/ { flush(); inb = 0 }
        inb && /^[[:space:]]*-[[:space:]]+id:[[:space:]]*/ {
            flush(); l = $0; sub(/^[[:space:]]*-[[:space:]]+id:[[:space:]]*/, "", l)
            sub(/[[:space:]]*#.*/, "", l); gsub(/^["\047]|["\047]$/, "", l); id = l; next }
        inb && /^[[:space:]]+format:[[:space:]]*/ {
            l = $0; sub(/^[[:space:]]+format:[[:space:]]*/, "", l); sub(/[[:space:]]*#.*/, "", l)
            gsub(/^["\047]|["\047]$/, "", l); fmt = l }
        END { flush() }' "$1" 2>/dev/null
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
    local flow key
    flow="$(_inputs_flow_stages | tr '\n' ' ')"
    key="${plugins_root}|${state_dir}|${flow}"
    [[ "$key" == "$_IR_INDEX_KEY" ]] && return 0
    _IR_INDEX_KEY="$key"
    _IR_PRODUCER=(); _IR_PATHS=(); _IR_ISMAP=(); _IR_FORMAT=()
    local stage manifest rec out_id out_path paths safe type_var
    while IFS= read -r stage; do
        [[ -z "$stage" ]] && continue
        manifest="$(_inputs_stage_manifest "$stage" "$plugins_root" 2>/dev/null || true)"
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
            if _inputs_damaged "$line" "$id"; then
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
_inputs_format_for() {
    local pth="${1-}" in_id="${2-}"
    # #1895: the producer's DECLARED format wins. The extension fallback below is
    # what #1826 shipped as an interim and is kept only for an artifact whose
    # producer declares none — it guesses, and a name not ending in a recognised
    # extension would silently get no check at all, which is why the field exists.
    if [[ -n "$in_id" && -n "${_IR_FORMAT[$in_id]:-}" ]]; then
        printf '%s' "${_IR_FORMAT[$in_id]}"
        return 0
    fi
    case "${pth##*.}" in
        json)      printf 'json' ;;
        md)        printf 'markdown' ;;
        patch|diff) printf 'patch' ;;
        *)         printf 'text' ;;
    esac
}

# ─── _inputs_damaged <path> [output_id] ──────────────────────────────────────
# rc 0 when the artifact is present but UNUSABLE (#1894). Damage is judged by
# FORM, never by meaning — a syntactically valid file whose contents are wrong
# stays the consumer's business.
#
#   any format : zero bytes            -> damaged (empty or a failed write)
#   json       : `jq empty` rejects it -> damaged (truncated / partial write)
#
# An ABSENT file is not damaged; absence is the caller's separate case, and
# conflating them is what #1894 opened with.
_inputs_damaged() {
    local pth="${1-}" in_id="${2-}"
    [[ -e "$pth" ]] || return 1
    [[ -s "$pth" ]] || return 0
    if [[ "$(_inputs_format_for "$pth" "$in_id")" == "json" ]]; then
        jq empty "$pth" >/dev/null 2>&1 || return 0
    fi
    return 1
}

# ─── _summaries_stage_summary_path <stage> <plugins_root> <state_dir> ────────
# The resolved path of the ONE output <stage> marks `summary: true`, or empty.
# Only a mechanical (`convergence: gate`) stage contributes: whether an advisory
# LLM stage's output may reach the build loop is #1898's open decision, and
# auto-collection must not answer it by accident (ADR-040 §4).
_summaries_stage_summary_path() {
    local stage="$1" plugins_root="$2" state_dir="$3"
    local manifest rec out_id
    manifest="$(_inputs_stage_manifest "$stage" "$plugins_root" 2>/dev/null || true)"
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
    local state_dir; state_dir="$(dirname "$state_file")"
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
    manifest="$(_inputs_stage_manifest "$stage" "$plugins_root" 2>/dev/null || true)"
    [[ -n "$manifest" ]] || return 0
    raw="$(_verdict_primary_output_path "$manifest" 2>/dev/null || true)"
    [[ -n "$raw" ]] || return 0
    res="$(_verdict_resolve_path "$raw" "$state_dir" 2>/dev/null || true)"
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
    manifest="$(_inputs_stage_manifest "$stage" "$plugins_root" 2>/dev/null || true)"
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
    resolved="$(_verdict_resolve_path "$raw" "$state_dir" 2>/dev/null || true)"
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
