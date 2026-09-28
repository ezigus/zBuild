#!/usr/bin/env bash
# core/pipeline/finding-owner.sh — WHO owns a stage's finding (#2180, #1847,
# #1846). Sourced by input-resolve.sh; split out of it so the resolver stays
# readable (review #2217). Every answer is derived from what stages DECLARE —
# a result's `about`, a manifest's `outputs` and `under_review` inputs, the
# template's `route_back` edges — never from a stage name, and never a guess:
# anything ambiguous resolves to no owner.
#
# Callers: _summaries_collect (input-resolve.sh), which frames each finding for
# the reader about to run. Uses _inputs_* and _verdict_* from the resolver.

[[ -n "${_ZBUILD_FINDING_OWNER_LOADED:-}" ]] && return 0
_ZBUILD_FINDING_OWNER_LOADED=1

# ─── _summaries_result_about <stage> <plugins_root> <state_dir> ─────────────
# The artifact a stage's finding is ABOUT, as its primary result declares it
# (#2180). One fact, stated by the producer about its own work — never who
# should act on it, which is the engine's to resolve.
_summaries_result_about() {
    local stage="$1" plugins_root="$2" state_dir="$3" manifest raw resolved
    manifest="$(_inputs_stage_manifest "$stage" "$plugins_root" 2>/dev/null || true)"
    [[ -n "$manifest" ]] || return 0
    raw="$(_verdict_primary_output_path "$manifest" 2>/dev/null || true)"
    [[ -n "$raw" ]] || return 0
    resolved="$(_verdict_resolve_path "$raw" "$state_dir" 2>/dev/null || true)"
    [[ -s "$resolved" ]] || return 0
    case "$resolved" in *.json) ;; *) return 0 ;; esac
    jq -r '.about // empty' "$resolved" 2>/dev/null || true
}

# ─── _summaries_owner_of <about> <plugins_root> <state_dir> ─────────────────
# Which stage OWNS the named artifact(s), or "" when nothing declares them, or
# when the answer is not unambiguous (#2180). Two sources, both already in the
# tree, neither a list of stage names:
#   1. a manifest that declares the path as one of its `outputs`;
#   2. the authoring record for repo testfiles, whose header says which stage
#      wrote it (assertion-digests.txt).
# `about` may name several artifacts, one per line — a contract with several
# testfiles is one finding about all of them. They route together only when
# they share ONE owner.
#
# NEVER a guess (review #2181): two plugins may declare outputs with the same
# BASENAME, and handing the finding to whichever manifest was read first is
# wrong silently. An ambiguous name resolves to no owner, and the framing then
# falls back to the fault-class rule.
_summaries_owner_of() {
    local about="${1:-}" plugins_root="${2:-}" state_dir="${3:-}"
    [[ -n "$about" ]] || return 0
    local idx_root
    idx_root="$(_manifest_index_root "$plugins_root" 2>/dev/null || printf '%s' "$plugins_root")"
    manifest_index_load "$idx_root" 2>/dev/null || true
    local _midx_files
    _midx_files="${_ZBUILD_MIDX_FILES[$idx_root]:-}"

    local one amalgam="" owner
    while IFS= read -r one; do
        [[ -n "${one//[[:space:]]/}" ]] || continue
        owner="$(_summaries_owner_of_one "$one" "$_midx_files" "$state_dir")"
        # One unowned or ambiguous member makes the whole finding unowned: a
        # partial attribution would tell one stage it owns work it does not.
        [[ -n "$owner" ]] || return 0
        if [[ -z "$amalgam" ]]; then
            amalgam="$owner"
        elif [[ "$amalgam" != "$owner" ]]; then
            return 0
        fi
    done <<< "$about"
    printf '%s' "$amalgam"
}

# ─── _summaries_owner_of_one <path> <manifest_list> <state_dir> ─────────────
# The single stage that declares this one path, or "" when none or several do.
_summaries_owner_of_one() {
    local about="$1" manifests="$2" state_dir="$3"
    local base="${about##*/}" m _p found="" n=0
    while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        case "$m" in */tests/*) continue ;; esac
        while IFS= read -r _p; do
            [[ -n "$_p" ]] || continue
            [[ "${_p##*/}" == "$base" ]] || continue
            local _id; _id="$(manifest_index_get "$m" id 2>/dev/null || true)"
            [[ -n "$_id" ]] || continue
            # The same id twice (one manifest, two outputs of that name) is one
            # owner; two DIFFERENT ids is ambiguity.
            if [[ -z "$found" ]]; then found="$_id"; n=1
            elif [[ "$found" != "$_id" ]]; then n=2; fi
        done <<< "$(manifest_index_get "$m" outputs.path 2>/dev/null || true)"
    done <<< "$manifests"
    if [[ "$n" -eq 1 ]]; then printf '%s' "$found"; return 0; fi
    [[ "$n" -gt 1 ]] && return 0

    # A repo path: the authoring record names the stage that wrote it.
    local dig="$state_dir/artifacts/assertion-digests.txt"
    if [[ -s "$dig" ]] && grep -qF -- "$about" "$dig" 2>/dev/null; then
        local by
        by="$(sed -n 's/^#[[:space:]]*authored_by:[[:space:]]*//p' "$dig" 2>/dev/null || true)"
        by="${by%%$'\n'*}"
        [[ -n "$by" ]] && printf '%s' "$by"
    fi
    return 0
}

# ─── _summaries_under_review_inputs <manifest> ──────────────────────────────
# The ids of the inputs a stage marks `under_review: true` — what it JUDGES, as
# opposed to what it judges AGAINST (#1847). One per line.
_summaries_under_review_inputs() {
    local mf="${1:-}"
    [[ -n "$mf" && -f "$mf" ]] || return 0
    # Flushed at the entry BOUNDARY (the next `- ` or the end of the block), so
    # `under_review:` may sit before or after `id:` — both are valid YAML, and
    # an order-dependent reader would silently make no owner (review #2217; the
    # same rule _summaries_stage_errors_path follows, review #2184).
    awk '
        function flush() { if (cur != "" && ur) print cur; cur = ""; ur = 0 }
        /^inputs:[[:space:]]*(#.*)?$/ { inb = 1; next }
        inb && /^[^[:space:]#]/       { flush(); inb = 0 }
        inb && /^[[:space:]]+-[[:space:]]/ { flush() }
        inb && /^[[:space:]]+(-[[:space:]]+)?id:[[:space:]]*/ {
            l = $0
            sub(/^[[:space:]]+(-[[:space:]]+)?id:[[:space:]]*/, "", l)
            sub(/[[:space:]]*#.*$/, "", l); gsub(/["\047[:space:]]/, "", l)
            cur = l
        }
        inb && /^[[:space:]]+(-[[:space:]]+)?under_review:[[:space:]]*true[[:space:]]*(#.*)?$/ { ur = 1 }
        END { flush() }' "$mf" 2>/dev/null || true
}

# ─── _summaries_under_review_owner <stage> <plugins_root> [state_dir] ───────
# The stage that PRODUCED what this stage judges, or "" (#1847). A judge whose
# result names no `about` still said, in its manifest, which input is under
# review; the author of that input is the one stage that can act on the
# finding — whether or not it writes the repository. design writes design.md,
# not the repository, and was told spec-coverage's findings were "context only"
# three times running while it argued with them.
#
# Within a flow the producer index answers (output ids are unique per flow,
# ADR-055 §5). With no flow, the whole tree answers only when exactly one
# plugin declares the output — deploy and deploy-release both produce
# deploy_result, and picking one would be a guess. Several judged inputs share
# an owner or make none, as `about` does.
_summaries_under_review_owner() {
    local stage="${1:-}" plugins_root="${2:-}" state_dir="${3:-${ZBUILD_STATE_DIR:-}}"
    local mf ids
    mf="$(_inputs_stage_manifest "$stage" "$plugins_root" 2>/dev/null || true)"
    [[ -n "$mf" ]] || return 0
    ids="$(_summaries_under_review_inputs "$mf")"
    [[ -n "$ids" ]] || return 0

    local flow=""
    flow="$(_inputs_flow_stages 2>/dev/null || true)"
    [[ -n "$flow" ]] && _inputs_build_producer_index "$plugins_root" "$state_dir" 2>/dev/null

    local id owner amalgam=""
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        if [[ -n "$flow" ]]; then
            owner="${_IR_PRODUCER[$id]:-}"
        else
            owner="$(_summaries_sole_producer "$id" "$plugins_root")"
        fi
        [[ -n "$owner" ]] || return 0
        if [[ -z "$amalgam" ]]; then amalgam="$owner"
        elif [[ "$amalgam" != "$owner" ]]; then return 0; fi
    done <<< "$ids"
    printf '%s' "$amalgam"
}

# ─── _summaries_fault_owner <fault> <plugins_root> [state_dir] ──────────────
# The stage a routed fault belongs to, or "" (#1846). The template's route_back
# edges say which fault classes rewind to which unit; inside that unit, the
# members that judge (an `under_review` input) name the author they judge. That
# author is the one stage the rewind exists to re-run.
#
# #1846 run 20260928110313-2244: acceptance-gate found a specification fault,
# the edge rewound to design_verify_cycle, and design re-ran being told the
# fault was "the engine's to route, not yours to fix". Several edges or authors
# that disagree make no owner; no template loaded makes none.
_summaries_fault_owner() {
    local fault="${1:-}" plugins_root="${2:-}" state_dir="${3:-${ZBUILD_STATE_DIR:-}}"
    [[ -n "$fault" ]] || return 0
    local v cid field op value unit members_var m author owner=""
    for v in $(compgen -v _TPL_CYCLE_ROUTE_BACK_TO_ 2>/dev/null || true); do
        cid="${v#_TPL_CYCLE_ROUTE_BACK_TO_}"
        field="_TPL_CYCLE_ROUTE_BACK_FIELD_${cid}"; op="_TPL_CYCLE_ROUTE_BACK_OP_${cid}"
        value="_TPL_CYCLE_ROUTE_BACK_VALUE_${cid}"
        [[ "${!field:-}" == "fault" ]] || continue
        case "${!op:-}" in
            eq) [[ "${!value:-}" == "$fault" ]] || continue ;;
            in) [[ " ${!value//,/ } " == *" $fault "* ]] || continue ;;
            *)  continue ;;
        esac
        unit="${!v:-}"; members_var="_TPL_CYCLE_STAGES_${unit//-/_}"
        [[ -n "${!members_var:-}" ]] || continue
        for m in ${!members_var//,/ }; do
            author="$(_summaries_under_review_owner "$m" "$plugins_root" "$state_dir")"
            [[ -n "$author" ]] || continue
            if [[ -z "$owner" ]]; then owner="$author"
            elif [[ "$owner" != "$author" ]]; then return 0; fi
        done
    done
    printf '%s' "$owner"
}

# The id of the ONE plugin in the tree whose manifest outputs <output_id>, or "".
# One awk over every manifest, not one per manifest (ADR-065: the suite is
# fork-bound).
_summaries_sole_producer() {
    local want="$1" plugins_root="$2" hits
    _inputs_scan_manifests "$plugins_root"
    local -a mfs=()
    mapfile -t mfs < <(printf '%s\n' "${_IR_BY_ID[@]}" | sort -u)
    [[ ${#mfs[@]} -gt 0 ]] || return 0
    hits="$(awk -v want="$want" '
        FNR == 1 { outb = 0 }
        /^outputs:[[:space:]]*(#.*)?$/ { outb = 1; next }
        /^[^[:space:]#]/               { outb = 0 }
        outb && /^[[:space:]]+-[[:space:]]+id:[[:space:]]*/ {
            l = $0; sub(/^[[:space:]]+-[[:space:]]+id:[[:space:]]*/, "", l)
            sub(/[[:space:]]*#.*$/, "", l); gsub(/["\047[:space:]]/, "", l)
            if (l == want) print FILENAME
        }' "${mfs[@]}" 2>/dev/null | sort -u)"
    [[ -n "$hits" && "$hits" != *$'\n'* ]] || return 0
    manifest_graph_get_stage_id "$hits" 2>/dev/null || true
}
