#!/usr/bin/env bash
# core/pipeline/input-resolve.sh — ADR-055 §1 / ADR-054 §2 (#1826).
#
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
# _verdict_resolve_path is the engine's single path-interpolation helper (#1879
# says so in stage-checkpoint.sh, and this module is its third consumer).
# shellcheck source=./verdict.sh
declare -F _verdict_resolve_path >/dev/null 2>&1 || \
    source "$_ZBUILD_IR_ROOT/core/pipeline/verdict.sh"

# The marker the injected prompt block opens with. Idempotence guard, exactly as
# _ZB_CHECKPOINT_MARKER is — the agentic loop redacts once per iteration against
# the same file, so a plain append would stack the block.
_ZB_STAGE_INPUTS_MARKER='## STAGE INPUTS (engine-resolved)'

# #1976: the summaries block's marker. Same idempotence contract as above — the
# agentic loop redacts the same file once per iteration, so a plain append would
# stack the block and reintroduce the ADR-029 growth this feature is bounded to
# avoid.
_ZB_STAGE_SUMMARIES_MARKER='## STAGE SUMMARIES (engine-collected)'

# Bounds (ADR-029). Per-iteration prompt growth caused three consecutive 900s
# max_turns timeouts; the block is capped and LATEST-WINS per stage so it stays
# flat in the number of stages, never in the number of iterations.
_ZB_SUMMARY_MAX_BYTES="${ZBUILD_SUMMARY_MAX_BYTES:-4096}"
_ZB_SUMMARY_TOTAL_MAX_BYTES="${ZBUILD_SUMMARY_TOTAL_MAX_BYTES:-24576}"

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
# to every dispatch. One find + one awk per manifest is ~40ms for the same data.
declare -gA _IR_BY_ID=()
declare -gA _IR_BY_ROLE=()
_IR_SCAN_KEY=""
_inputs_scan_manifests() {
    local plugins_root="$1"
    [[ "$plugins_root" == "$_IR_SCAN_KEY" ]] && return 0
    _IR_SCAN_KEY="$plugins_root"
    _IR_BY_ID=(); _IR_BY_ROLE=()
    local m id role platform rec
    while IFS= read -r -d '' m; do
        rec="$(awk '
            /^id:[[:space:]]*/            && !gi { l=$0; sub(/^id:[[:space:]]*/,"",l);       gi=1; i=l }
            /^platform:[[:space:]]*/      && !gp { l=$0; sub(/^platform:[[:space:]]*/,"",l); gp=1; p=l }
            /^provides:[[:space:]]*$/            { inp=1; next }
            inp && /^[a-zA-Z_]/                  { inp=0 }
            inp && /^[[:space:]]+role:[[:space:]]*/ && !gr {
                l=$0; sub(/^[[:space:]]+role:[[:space:]]*/,"",l); gr=1; r=l }
            END {
                sub(/[[:space:]]*#.*/,"",i); sub(/[[:space:]]*#.*/,"",r); sub(/[[:space:]]*#.*/,"",p)
                gsub(/^["'"'"']|["'"'"']$|[[:space:]]*$/,"",i)
                gsub(/^["'"'"']|["'"'"']$|[[:space:]]*$/,"",r)
                gsub(/^["'"'"']|["'"'"']$|[[:space:]]*$/,"",p)
                print i "|" r "|" p
            }' "$m" 2>/dev/null)"
        IFS='|' read -r id role platform <<< "$rec"
        [[ -n "$id" && -z "${_IR_BY_ID[$id]:-}" ]] && _IR_BY_ID["$id"]="$m"
        # Platform-specific plugins never win the generic slot; the engine's own
        # resolver prefers a platform match and this module has no platform.
        if [[ -n "$role" && ( -z "$platform" || "$platform" == "null" ) && -z "${_IR_BY_ROLE[$role]:-}" ]]; then
            _IR_BY_ROLE["$role"]="$m"
        fi
    done < <(find "$plugins_root" -name manifest.yaml -not -path '*/tests/*' -print0 2>/dev/null)
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
            # knows which manifest owns this id.
            _IR_FORMAT["$out_id"]="$(manifest_graph_output_format "$manifest" "$out_id" 2>/dev/null || true)"
            [[ "${!type_var:-}" == "map" ]] && _IR_ISMAP["$out_id"]=1
        done < <(manifest_graph_get_outputs "$manifest")
    done < <(_inputs_flow_stages)
}

# ─── _inputs_effective_path <live_path> [input_id] ───────────────────────────
# Per-input existence precedence, unchanged from prior-output-reader.sh:12-16 —
# the cycle-feedback copy (iteration >= 2) wins, then the restored cross-run
# copy, then the live artifact. Returns a PATH rather than the content, which is
# the only difference from _read_prior_output.
#
# The ORDER is reused; _read_prior_output itself is deliberately not called and
# not changed. Its `prior_<field>.txt` naming belongs to ADR-050 prior-run reuse,
# which ADR-055 §1.2 keeps OUTSIDE the input model ("the producer is the consuming
# stage itself in an earlier run"). Its four live call sites (plan.json,
# build-summary.json, impact.json, lens-<x>.json) match no template `to.input`
# today, so the two namespaces do not collide — but a template that ever wired
# `to.input: plan` would make them, and that is the seam to watch.
_inputs_effective_path() {
    local live="$1" in_id="${2:-}"
    local base="${live##*/}"
    local iter="${ZBUILD_CYCLE_ITER:-}" fb="${ZBUILD_CYCLE_FEEDBACK_DIR:-}"
    if [[ -n "$iter" && -n "$fb" && -n "$in_id" && "$iter" =~ ^[0-9]+$ ]] && (( iter >= 2 )); then
        # The orchestrator names the copy after the TEMPLATE's `to.input`
        # (cycle-orchestrator.sh:1196 — `dst="$fb_dir/${to_field}.txt"`), which
        # is this input's id. Deriving it from the producer's FILENAME instead
        # never matched: gate_feedback's producer writes `gate-feedback.md`, so
        # the old form looked for `prior_gate-feedback.txt` while the
        # orchestrator wrote `prior_gate_feedback.txt` — hyphen against
        # underscore, so the branch could not fire.
        # Latent while the feature was gated off; #1825 turns it on.
        local f="$fb/${in_id}.txt"
        [[ -s "$f" ]] && { printf '%s' "$f"; return 0; }
    fi
    local restored="${ZBUILD_RESTORED_ARTIFACTS_DIR:-}"
    [[ -n "$restored" && -s "$restored/$base" ]] && { printf '%s' "$restored/$base"; return 0; }
    printf '%s' "$live"
}

# ─── _inputs_declared <manifest> ─────────────────────────────────────────────
# The stage's declared inputs as "id|required", external sources dropped: an
# `external` input names something from outside the pipeline (ADR-055 §3) and
# has no producer and no artifact path to resolve.
_inputs_declared() {
    local manifest="$1" rec id req src
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        IFS='|' read -r id _ src req _ <<< "$rec"
        [[ -z "$id" ]] && continue
        [[ "$src" == "external" ]] && continue
        [[ -z "$req" ]] && req="true"
        printf '%s|%s\n' "$id" "$req"
    done < <(manifest_graph_get_inputs "$manifest")
}

# ─── _inputs_resolve_stage <stage> <plugins_root> <state_dir> [manifest] ─────
# PUBLIC ENTRY. Writes the index and echoes its path. The optional 4th argument
# is the consumer's own manifest — plugin_hook_call already holds it, and
# passing it removes any chance of the handover disagreeing with the plugin the
# engine actually dispatched.
_inputs_resolve_stage() {
    local stage="$1" plugins_root="$2" state_dir="$3" manifest="${4:-}"
    # The stage id is interpolated into a filesystem path. Same guard as
    # _verdict_read_stage_sidecar — a value with '/' or '..' must never traverse.
    [[ "$stage" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || return 1
    [[ -n "$state_dir" ]] || return 1
    if [[ -z "$manifest" ]]; then
        manifest="$(_inputs_stage_manifest "$stage" "$plugins_root" 2>/dev/null || true)"
    fi
    [[ -n "$manifest" && -f "$manifest" ]] || return 1

    _inputs_build_producer_index "$plugins_root" "$state_dir"

    local id req paths line eff tsv=""
    while IFS='|' read -r id req; do
        [[ -z "$id" ]] && continue
        paths="${_IR_PATHS[$id]:-}"
        [[ -z "$paths" ]] && continue
        if [[ -n "${_IR_ISMAP[$id]:-}" ]]; then
            local joined=""
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                eff="$(_inputs_effective_path "$line" "$id")"
                # A map input is a SET, and the per-element rule is the same one
                # the scalar branch applies: a damaged member is not a usable
                # member. Passing it through because its siblings are healthy is
                # the silent degrade #1894 exists to close — the consumer cannot
                # tell a truncated lens result from a complete one.
                if _inputs_damaged "$eff" "$id"; then
                    if declare -F eb_emit_event >/dev/null 2>&1; then
                        eb_emit_event "stage.input.degraded" \
                            "stage=$stage" "input=$id" "reason=damaged_member" \
                            "format=$(_inputs_format_for "$eff" "$id")" "path=$eff" 2>/dev/null || true
                    fi
                    continue
                fi
                joined+="${eff}"$'\x1f'
            done <<< "$paths"
            tsv+="${id}"$'\t'"A"$'\t'"${joined}"$'\n'
        else
            eff="$(_inputs_effective_path "${paths%%$'\n'*}" "$id")"
            # #1894: an OPTIONAL input that is present but damaged is omitted
            # from the index, so the consumer sees it exactly as it sees an
            # absent one — a missing key, not an empty read. Degrading in
            # silence is the failure shape this rule exists to close, so the
            # omission is announced. A REQUIRED damaged input never reaches
            # here; _inputs_check_required refuses the dispatch first.
            if [[ "$req" != "true" ]] && _inputs_damaged "$eff" "$id"; then
                if declare -F eb_emit_event >/dev/null 2>&1; then
                    eb_emit_event "stage.input.degraded" \
                        "stage=$stage" "input=$id" "reason=damaged" \
                        "format=$(_inputs_format_for "$eff" "$id")" "path=$eff" 2>/dev/null || true
                fi
                continue
            fi
            tsv+="${id}"$'\t'"S"$'\t'"${eff}"$'\n'
        fi
    done < <(_inputs_declared "$manifest")

    local index="${state_dir}/stage-inputs/${stage}.json"
    mkdir -p "${state_dir}/stage-inputs" 2>/dev/null || return 1
    # Built into a variable first: piping jq straight into atomic_write would let
    # a jq failure write a zero-byte index and still return 0 — a silent empty
    # handover that reads as "this stage declared nothing".
    local json
    json="$(printf '%s' "$tsv" | jq -nR --arg stage "$stage" '
        {schema_version: 1, stage: $stage,
         inputs: ([inputs | split("\t")
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

# ─── _inputs_check_required <stage> <plugins_root> <state_dir> [manifest] ────
# The PRE-DISPATCH presence check. A missing `required: true` input means the
# stage is never launched; the message names producer, output id and consumer so
# the operator does not have to reconstruct the wire. rc 0 clean, 1 violations.
_inputs_check_required() {
    local stage="$1" plugins_root="$2" state_dir="$3" manifest="${4:-}"
    if [[ -z "$manifest" ]]; then
        manifest="$(_inputs_stage_manifest "$stage" "$plugins_root" 2>/dev/null || true)"
    fi
    [[ -n "$manifest" && -f "$manifest" ]] || return 0
    _inputs_build_producer_index "$plugins_root" "$state_dir"

    local -a violations=()
    local id req paths line eff producer present damaged
    while IFS='|' read -r id req; do
        [[ "$req" == "true" ]] || continue
        paths="${_IR_PATHS[$id]:-}"
        producer="${_IR_PRODUCER[$id]:-}"
        if [[ -z "$paths" ]]; then
            violations+=("$stage|INPUT_UNRESOLVED|$id|no stage in the resolved flow declares an output named '$id', which stage '$stage' requires (ADR-055 §1.5)")
            continue
        fi
        present=0; damaged=""
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            eff="$(_inputs_effective_path "$line" "$id")"
            # Damage is tested BEFORE presence, and this order is the whole
            # point: a truncated file is non-empty, so `-s` accepts it and the
            # stage receives half an artifact as though it were whole. That is
            # the case #1894 opened with, and testing presence first silently
            # restores it.
            if _inputs_damaged "$eff" "$id"; then damaged="$eff"; continue; fi
            # A map input is a SET, so the loop does NOT stop at the first healthy
            # member — one good element must not excuse a broken sibling. For a
            # scalar there is only ever one path, so breaking is correct.
            if [[ -s "$eff" ]]; then
                present=1
                [[ -z "${_IR_ISMAP[$id]:-}" ]] && break
            fi
        done <<< "$paths"
        # N-1 broken lens results would otherwise ride in on the strength of one.
        [[ -n "${_IR_ISMAP[$id]:-}" && -n "$damaged" ]] && present=0
        if [[ $present -eq 0 && -n "$damaged" ]]; then
            violations+=("$stage|INPUT_DAMAGED|$id|producer '$producer' wrote output '$id' but it is unusable ($(_inputs_format_for "$damaged" "$id"), $(wc -c < "$damaged" 2>/dev/null | tr -d ' ') bytes); consumer '$stage' requires it: $damaged")
        elif [[ $present -eq 0 ]]; then
            violations+=("$stage|INPUT_MISSING|$id|producer '$producer' declares output '$id' but its artifact is absent; consumer '$stage' requires it (looked for: ${paths//$'\n'/, })")
        fi
    done < <(_inputs_declared "$manifest")

    [[ ${#violations[@]} -eq 0 ]] && return 0
    _inputs_render_violations \
        "Stage '$stage' will not be launched: a required declared input is unavailable:" \
        "Fix: run the producing stage first, or mark the input \`required: false\` in
     $manifest.
     See docs/adr/ADR-055-inter-stage-data-contract-v2.md §1." \
        "${violations[@]}"
    return 1
}

# ─── stage_inputs_prompt_block <index_path> ──────────────────────────────────
# Env vars do not survive to the model: _zbuild_make_fresh_shell unsets the whole
# ZBUILD_* namespace before every claude spawn (env-scrub.sh, ADR-024/#671), so
# ZBUILD_STAGE_INPUTS is invisible to an agent stage by construction. The paths
# therefore go into the prompt as LITERAL text — the same answer #1879 reached.
# Empty output when the stage declares no resolvable inputs, so a non-declaring
# stage's prompt stays byte-identical.
stage_inputs_prompt_block() {
    local idx="${1:-}"
    [[ -n "$idx" && -s "$idx" ]] || return 0
    jq -e '(.inputs // {}) | length > 0' "$idx" >/dev/null 2>&1 || return 0

    printf '%s\n\n' "$_ZB_STAGE_INPUTS_MARKER"
    printf 'The engine resolved every input this stage declared. These are the\n'
    printf 'literal paths — read them with your normal file tools. Do NOT guess a\n'
    printf 'filename, and do NOT search the tree for these artifacts.\n\n'
    jq -r '.inputs | to_entries[]
           | if (.value | type) == "array"
             then "  \(.key):\n" + ([.value[] | "    - \(.)"] | join("\n"))
             else "  \(.key): \(.value)" end' "$idx" 2>/dev/null
    printf '\n'
    printf 'A path listed here may not exist yet if its producer declared it\n'
    printf 'optional; treat an absent optional input as empty.\n'
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

# ─── _summaries_stage_marker <stage> <plugins_root> <key> ────────────────────
# A top-level scalar from the stage's manifest (`convergence:` / `aggregates:`),
# or empty. Read rather than inferred: ADR-040 §5 makes `convergence:` the
# authoritative mechanical-vs-advisory discriminator precisely because inferring
# it from `kind:` mis-classified acceptance-gate.
_summaries_stage_marker() {
    local stage="$1" plugins_root="$2" key="$3" manifest
    manifest="$(_inputs_stage_manifest "$stage" "$plugins_root" 2>/dev/null || true)"
    [[ -n "$manifest" && -f "$manifest" ]] || return 0
    awk -v k="$key" '
        $0 ~ "^" k ":[[:space:]]*" {
            sub("^" k ":[[:space:]]*", ""); sub(/[[:space:]]*#.*/, "")
            gsub(/^["\047]|["\047]$/, ""); print; exit
        }
    ' "$manifest" 2>/dev/null || true
}

# ─── stage_summaries_prompt_block <state_file> [plugins_root] ────────────────
# Renders every completed stage's declared summary, in COMPLETION order, each
# annotated with that stage's verdict.
#
# Completion order is the key order of .stage_statuses — jq preserves insertion
# order, so the engine needs no separate bookkeeping. A stage that re-ran keeps
# its first-run position and its LATEST body, which is what makes the block flat
# in stage count rather than iteration count (ADR-029).
#
# Empty output when no completed stage declares a summary, so a repo that has
# not adopted the marker keeps byte-identical prompts.
stage_summaries_prompt_block() {
    local state_file="${1:-}" plugins_root="${2:-${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_ROOT/plugins}}"
    [[ -n "$state_file" && -s "$state_file" ]] || return 0
    local state_dir; state_dir="$(dirname "$state_file")"

    # #1986: an aggregator declares the roster it COVERS (`aggregates: <marker>`).
    # Where one is present, its members' own summaries are suppressed and only
    # the aggregate ships — otherwise the prompt carries a member's detail AND
    # the aggregator's rendering of that same detail, which is the contradiction
    # #1979 removed, arriving from the other side. Removing it by construction
    # rather than by convention is the point.
    local _covered=" " _agg_of
    while IFS= read -r stage; do
        [[ -z "$stage" ]] && continue
        _agg_of="$(_summaries_stage_marker "$stage" "$plugins_root" aggregates)"
        [[ -n "$_agg_of" ]] && _covered="${_covered}${_agg_of} "
    done < <(jq -r '(.stage_statuses // {}) | keys_unsorted[]' "$state_file" 2>/dev/null || true)

    local stage path body verdict chunk _conv _aggregates
    local -a _chunks=()
    while IFS= read -r stage; do
        [[ -z "$stage" ]] && continue
        # An aggregator is never suppressed by the roster it covers — it is the
        # one shipping the aggregate, and matching naively would delete it.
        _aggregates="$(_summaries_stage_marker "$stage" "$plugins_root" aggregates)"
        if [[ -z "$_aggregates" ]]; then
            _conv="$(_summaries_stage_marker "$stage" "$plugins_root" convergence)"
            [[ -n "$_conv" && "$_covered" == *" $_conv "* ]] && continue
        fi
        path="$(_summaries_stage_summary_path "$stage" "$plugins_root" "$state_dir")"
        [[ -n "$path" && -s "$path" ]] || continue
        verdict="$(jq -r --arg s "$stage" '.stage_verdicts[$s] // "unknown"' "$state_file" 2>/dev/null || echo unknown)"
        body="$(head -c "$_ZB_SUMMARY_MAX_BYTES" "$path" 2>/dev/null || true)"
        if [[ "$(wc -c < "$path" 2>/dev/null || echo 0)" -gt "$_ZB_SUMMARY_MAX_BYTES" ]]; then
            body="${body}"$'\n'"[… truncated at ${_ZB_SUMMARY_MAX_BYTES}B —"
            body="${body} read the artifact directly for the full text]"
        fi
        # #1979: framing follows the VERDICT. The retired per-plugin readers
        # framed gate feedback as "resolve every finding above"; losing that
        # imperative with the wire would have downgraded a directive into
        # passive context. Applied by verdict rather than by naming two stages,
        # so a third gate needs no new prose.
        case "$verdict" in
            fail|failed) chunk="$(printf '### %s (verdict: %s) — RESOLVE these findings before completing\n%s\n' "$stage" "$verdict" "$body")" ;;
            *)           chunk="$(printf '### %s (verdict: %s)\n%s\n' "$stage" "$verdict" "$body")" ;;
        esac
        _chunks+=("$chunk")
    done < <(jq -r '(.stage_statuses // {}) | keys_unsorted[]' "$state_file" 2>/dev/null || true)

    # #2011: keep the NEWEST. This used to accumulate in completion order and
    # break on the cap, which retained the summaries FURTHEST from the stage
    # about to run and discarded its most recent findings. Latent while a handful
    # of gates declared summaries; #2000 took the tree to 28 producers (114,688B
    # potential against a 24,576B cap), making overflow the normal path.
    # Raising the cap is not the fix — ADR-029 records that per-iteration prompt
    # growth caused three consecutive 900s max_turns timeouts. Which END is
    # dropped is the defect.
    local total=0 _keep_from=${#_chunks[@]} _i
    for (( _i=${#_chunks[@]}-1; _i>=0; _i-- )); do
        total=$(( total + ${#_chunks[_i]} ))
        [[ "$total" -gt "$_ZB_SUMMARY_TOTAL_MAX_BYTES" ]] && break
        _keep_from=$_i
    done
    # The newest always ships, even alone and even if it alone exceeds the
    # budget: it is already per-summary capped, and a block that drops the very
    # findings it exists to carry is worse than one slightly over budget.
    [[ ${#_chunks[@]} -gt 0 && "$_keep_from" -ge ${#_chunks[@]} ]] && _keep_from=$(( ${#_chunks[@]} - 1 ))

    local rendered=""
    # Marked, and counted, so an elision stays distinguishable from a stage that
    # produced nothing — the property the per-summary marker already gets right.
    if [[ "$_keep_from" -gt 0 ]]; then
        rendered="[… ${_keep_from} earlier stage summaries truncated at"
        rendered="${rendered} ${_ZB_SUMMARY_TOTAL_MAX_BYTES}B total]"$'\n'
    fi
    for (( _i=_keep_from; _i<${#_chunks[@]}; _i++ )); do
        rendered="${rendered}${_chunks[_i]}"$'\n'
    done

    [[ -n "$rendered" ]] || return 0
    printf '%s\n\n' "$_ZB_STAGE_SUMMARIES_MARKER"
    printf 'What each completed stage reported, newest content per stage. A stage\n'
    printf 'marked RESOLVE blocks convergence — address its findings before you\n'
    printf 'finish. The rest is context.\n\n'
    printf '%s' "$rendered"
}
