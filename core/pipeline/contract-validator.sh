#!/usr/bin/env bash
# core/pipeline/contract-validator.sh — ADR-020 runtime pre-flight contract
# validator (issue #496).
#
# Reads the active template's stage list + each stage's manifest and checks
# what each stage declares it WRITES: unique output ids, a versioned type and a
# known format, exactly one summary, and the aggregator wiring. Declared inputs
# are retired (ADR-055 §1, amended 2026-10-12) — a manifest still carrying an
# `inputs:` block is refused (INPUTS_RETIRED).
#
# Integration: called from core/pipeline/runner.sh:~165 after load_template +
# init_state but before the --dry-run branch and before the stage loop.
#
# Rollout: gated by ZBUILD_CONTRACT_VALIDATOR=warn|enforce. As of Wave 12-E
# (#664), the default is `enforce` — manifest contracts were made honest by
# Wave 12-D so the validator is now safe to fail-closed by default. In
# `warn` mode (explicit opt-out), violations are reported on stderr and a
# `pipeline.preflight.fail` event is emitted, but the pipeline is allowed
# to proceed; in `enforce` mode (default) the function returns rc=1 (#1850: was 2) and
# the runner halts before any stage starts.
#
# Output-uniqueness rule (ADR-020 amendment §D, Wave 12-A): each output
# `id` value MUST be claimed by exactly one stage manifest across the
# template's resolved stage set. Duplicate producers are a hard violation.
#
# Bash 5+. Sourced library; do not add `set -euo pipefail`.

[[ -n "${_ZBUILD_CONTRACT_VALIDATOR_LOADED:-}" ]] && return 0
_ZBUILD_CONTRACT_VALIDATOR_LOADED=1

_ZBUILD_CV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_CV_ROOT="$(cd "$_ZBUILD_CV_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$_ZBUILD_CV_ROOT/scripts/lib/manifest-graph.sh"
# Defensive sources (validator is also invoked directly from unit tests).
if ! declare -F eb_emit_event >/dev/null 2>&1; then
    # shellcheck source=../event-bus/event-bus.sh
    source "$_ZBUILD_CV_ROOT/core/event-bus/event-bus.sh"
fi
if ! declare -F atomic_write >/dev/null 2>&1; then
    # shellcheck source=../../scripts/lib/helpers.sh
    source "$_ZBUILD_CV_ROOT/scripts/lib/helpers.sh"
fi
# yaml_get: minimal manifest scalar reader, used by the typed-aggregator preflight
# (ADR-040 §3/§5) to resolve a stage's `convergence:` marker — the same reader the
# roster-driven gate-aggregator uses, keeping the two views identical.
if ! declare -F yaml_get >/dev/null 2>&1; then
    # shellcheck source=../plugin-registry/manifest-validation.sh
    source "$_ZBUILD_CV_ROOT/core/plugin-registry/manifest-validation.sh"
fi

# Memo cache for _cv_stage_convergence, keyed "plugins_root|stage_id|role". A
# manifest's marker is immutable within a process, so caching avoids the
# repeated full `find` scans the typed-aggregator preflight would otherwise do
# inside its per-cycle / per-stage loops (Copilot #1178: O(stages × manifests)).
declare -gA _CV_CONVERGENCE_CACHE=()

# ─── _cv_stage_convergence <plugins_root> <stage_id> → gate|advisory|"" ─────────
# Resolve a template stage id to its plugin manifest's `convergence:` marker,
# mirroring gate-aggregator's _ga_member_manifest + the lint's _cv_convergence:
# an id-matching manifest is authoritative; otherwise bind by the stage's first
# declared role (_TPL_STAGE_ROLES_<safe>) to the manifest whose provides.role
# matches. Empty when the stage carries no marker (legacy / untyped). The cache
# key includes the role so a stage id reused with a different role across
# templates in one process never returns a stale marker.
_cv_stage_convergence() {
    local proot="$1" sid="$2" m val="" cand r
    local safe="${sid//-/_}"
    local roles_var="_TPL_STAGE_ROLES_${safe}"
    local role="${!roles_var:-}"; role="${role%%,*}"
    local key="$proot|$sid|$role"
    if [[ -n "${_CV_CONVERGENCE_CACHE[$key]+x}" ]]; then
        printf '%s' "${_CV_CONVERGENCE_CACHE[$key]}"
        return 0
    fi
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
    _CV_CONVERGENCE_CACHE[$key]="$val"
    printf '%s' "$val"
    return 0
}

# ─── _cv_stage_in_any_cycle <stage> ──────────────────────────────────────────
# rc 0 when the stage is a member of some `type: cycle` group. ADR-055 §1.3
# legalises a backwards data edge only where the template declares a re-entry
# that reaches the consumer again, and shared cycle membership is one of the two
# forms of that. It is what makes design consuming its own prior design.md legal
# while a straight-line stage waiting on itself stays a defect.
_cv_stage_in_any_cycle() {
    local _s="${1-}" _c _safe _var _stages
    [[ -n "$_s" ]] || return 1
    declare -p _TPL_CYCLES >/dev/null 2>&1 || return 1
    for _c in "${_TPL_CYCLES[@]}"; do
        _safe="${_c//-/_}"
        _var="_TPL_CYCLE_STAGES_${_safe}"
        # _TPL_CYCLE_STAGES_<x> is COMMA-separated ("design,design-gate"),
        # so normalise before matching — a space-delimited test silently never
        # matches and every cycle member reads as a straight-line stage.
        _stages="${!_var:-}"
        [[ ",${_stages// /}," == *",$_s,"* ]] && return 0
    done
    return 1
}


# ─── _contract_validate_pipeline <template_stage_list> <plugins_root> <state_file>
# Public entry. The template_stage_list is a space-delimited ordered list of
# stage ids (the runner's `active_stages`). plugins_root is the directory
# containing kind/plugin/manifest.yaml. state_file is the path the runner
# will use as the resume target — used to write a `status: preflight_failed`
# stub on hard failure (decision #4).
#
# Returns:
#   0  — all required inputs satisfied OR mode=warn (warn always returns 0)
#   2  — contract violation detected AND mode=enforce
#
# Side-effects:
#   - Emits `pipeline.preflight.fail` event on violation (mode-agnostic).
#   - Writes a minimal state.json with `status: preflight_failed` on enforce.
#   - Prints structured error to stderr per ADR-020 (stable ordering: by
#     template position, alphabetical by input id within stage).
_contract_validate_pipeline() {
    local template_stages_csv="$1" plugins_root="$2" state_file="$3"

    # Mode (decision #2). Default `enforce` as of Wave 12-E (#664) —
    # contracts are honest after Wave 12-D so fail-closed is safe.
    # Operators can opt out with ZBUILD_CONTRACT_VALIDATOR=warn.
    local mode="${ZBUILD_CONTRACT_VALIDATOR:-enforce}"
    case "$mode" in
        warn|enforce|off) ;;
        *)
            # #1888: FAIL CLOSED, and say so. This used to silently become
            # `warn` under a comment promising a log line that was never
            # written — so `ZBUILD_CONTRACT_VALIDATOR=enfoce` (or `Enforce`, or
            # a trailing space from a CI yaml value) handed an operator the
            # PERMISSIVE mode while they believed they had hardened the gate,
            # with nothing in the run distinguishing that from a deliberate
            # `warn`. A validator that cannot understand its own configuration
            # is in no position to pick the weaker option on the operator's
            # behalf. Same shape as #1760, opposite resolution: there the
            # unmatched case silently never matched; here it silently downgraded.
            error "contract-validator: unrecognised ZBUILD_CONTRACT_VALIDATOR='${mode}' (expected: enforce | warn | off)"
            eb_emit_event "pipeline.preflight.config_invalid" \
                "reason=unknown_validator_mode" "value=$mode" \
                "accepted=enforce|warn|off" 2>/dev/null || true
            return 1
            ;;
    esac

    # Skip entirely if explicitly disabled (escape hatch for ops emergencies).
    if [[ "$mode" == "off" ]]; then return 0; fi

    # Parse stage list (newline-delimited input from runner)
    local -a stages=()
    local s
    while IFS= read -r s; do
        [[ -n "$s" ]] && stages+=("$s")
    done <<< "$template_stages_csv"
    [[ ${#stages[@]} -eq 0 ]] && return 0

    # Pass 1: collect every stage's outputs.
    # Also track producers-per-output-id for the output-uniqueness check
    # (ADR-020 amendment §D, Wave 12-E #664): each output id MUST be
    # claimed by exactly one stage manifest across the resolved stage set.
    local -A _CV_STAGE_MANIFEST=()
    local -A _CV_OUTPUT_PRODUCERS=()   # key=output_id  → space-delimited list of stages
    local -a violations=()
    local fail_count=0
    local stage manifest
    for stage in "${stages[@]}"; do
        # Role-aware, matching dispatch: manifest_graph_collect is id-only, so
        # `acceptance-gate` (role spec-acceptance) and the `review_lenses` map
        # group resolved to NO manifest and their outputs never reached the
        # producer index — which the ADR-055 §1.5 name check depends on.
        manifest="$(manifest_graph_resolve_member "$plugins_root" "$stage" 2>/dev/null || true)"
        [[ -n "$manifest" ]] || manifest="$(manifest_graph_collect "$plugins_root" "$stage" 2>/dev/null || true)"
        if [[ -z "$manifest" ]]; then
            # No manifest for this stage. NOT a contract violation by itself
            # (runner has its own fail-closed "no plugin registered" path);
            # we just skip output enumeration for this stage and let any
            # downstream stage that depends on it surface the violation.
            continue
        fi
        if ! manifest_graph_probe_sentinel "$manifest"; then
            # Manifest present but unparseable — distinguish from absent.
            printf '  WARNING: manifest for stage %s is present but missing top-level id: (unparseable)\n' \
                "$stage" >&2
            continue
        fi
        _CV_STAGE_MANIFEST["$stage"]="$manifest"
        local outrec
        while IFS= read -r outrec; do
            [[ -z "$outrec" ]] && continue
            local out_id="${outrec%%|*}"
            [[ -z "$out_id" ]] && continue
            # Append this stage to the producer list for output-uniqueness.
            local _prev="${_CV_OUTPUT_PRODUCERS[$out_id]:-}"
            if [[ -z "$_prev" ]]; then
                _CV_OUTPUT_PRODUCERS["$out_id"]="$stage"
            else
                _CV_OUTPUT_PRODUCERS["$out_id"]="$_prev $stage"
            fi
            # #1895: `format:` says HOW to check the artifact, as distinct from
            # `type:`, which says WHAT it is. It must name a check the engine
            # implements, so it is a closed set — free text would silently mean
            # "no check", which is the fail-open this epic exists to close.
            # #1827: `type:` is <schema-id>@<version>. A bare type cannot say WHICH
            # generation of an artifact it is, which is what #1824 put the pipeline
            # into versioned coexistence to need. Enforced at load because a version
            # nobody checks is the decoration this epic exists to remove.
            # field 2 of id|type|source|required|path, via expansion rather than a
            # pipe — `printf | cut` is the SIGPIPE antipattern #1886 removed.
            # TWO statements: in a single `local a=.. b="${a..}"`, b is expanded
            # before a is assigned, so _otype would silently come out empty and
            # the check below would never fire. The ablation caught exactly that.
            local _orest="${outrec#*|}"
            local _otype="${_orest%%|*}"
            # An ABSENT type is not versioned either. Guarding on -n skipped it
            # entirely, so deleting the line passed while mangling it failed —
            # the check refused the smaller mistake and allowed the larger one.
            if [[ -z "$_otype" ]]; then
                violations+=("$stage|TYPE_UNVERSIONED|$out_id|output declares no type: (ADR-055 §8, #1827)")
                fail_count=$((fail_count + 1))
            elif [[ "$_otype" != *"@"* ]]; then
                violations+=("$stage|TYPE_UNVERSIONED|$out_id|type: '$_otype' carries no @version (ADR-055 §8, #1827)")
                fail_count=$((fail_count + 1))
            fi
            local _ofmt; _ofmt="$(manifest_graph_output_format "$manifest" "$out_id" 2>/dev/null || true)"
            if [[ -z "$_ofmt" ]]; then
                violations+=("$stage|FORMAT_MISSING|$out_id|output declares no format: — the engine cannot decide how to check it (ADR-055 §1, #1895)")
                fail_count=$((fail_count + 1))
            elif [[ " $(manifest_graph_formats) " != *" $_ofmt "* ]]; then
                violations+=("$stage|FORMAT_UNKNOWN|$out_id|format: '$_ofmt' is not a check the engine implements (allowed: $(manifest_graph_formats))")
                fail_count=$((fail_count + 1))
            fi
        done < <(manifest_graph_get_outputs "$manifest")
    done

    # Output-uniqueness check (ADR-020 amendment §D, Wave 12-E #664):
    # any output id claimed by >1 stage is a hard contract violation.
    # Iterate keys in sorted order — Bash assoc-array iteration order is
    # implementation-defined; sorting guarantees stable error rendering.
    local _uniq_id
    while IFS= read -r _uniq_id; do
        [[ -z "$_uniq_id" ]] && continue
        local _producers="${_CV_OUTPUT_PRODUCERS[$_uniq_id]}"
        local -a _plist=()
        # shellcheck disable=SC2206
        _plist=( $_producers )
        if [[ ${#_plist[@]} -gt 1 ]]; then
            # Report against the FIRST producer for stable ordering;
            # name all producers in the message.
            violations+=("${_plist[0]}|OUTPUT_DUP|$_uniq_id|output id '$_uniq_id' is declared by multiple stages: ${_producers// /, } — each output id MUST be claimed by exactly one stage (ADR-020 §D)")
            fail_count=$((fail_count + 1))
        fi
    done < <(printf '%s\n' "${!_CV_OUTPUT_PRODUCERS[@]}" | LC_ALL=C sort)

    # Pass 2: per stage, what it declares about itself.

    for stage in "${stages[@]}"; do
        manifest="${_CV_STAGE_MANIFEST[$stage]:-}"
        [[ -z "$manifest" ]] && continue

        # Declared inputs are retired (ADR-055 §1, amended 2026-10-12): every
        # stage gets every stage's latest output (ADR-068 §8), so a declaration
        # would promise something nothing reads. Refused, not ignored, so a
        # stage written for the old contract is told rather than misled.
        if grep -qE '^inputs:' "$manifest" 2>/dev/null; then
            violations+=("$stage|INPUTS_RETIRED|-|the manifest declares inputs:, which are retired — every stage gets every stage's latest output under Previous work (ADR-068 §8); remove the block")
            fail_count=$(( fail_count + 1 ))
        fi

        # ADR-055 §9 (#2000): every stage-bound plugin declares EXACTLY ONE
        # summary output. A stage that publishes nothing is indistinguishable
        # from one that had nothing to say, and the pipeline cannot tell those
        # apart — so the second silently absorbs the first.
        #
        # Checked HERE and not only in the tree lint because this walks the
        # RESOLVED flow against the configured plugins_root: a stage may be
        # authored outside this repository, which a lint over plugins/ cannot
        # see. It would report a clean tree while a third-party stage published
        # nothing.
        #
        # Refused, not warned: the failure mode is silence, and a warning about
        # silence is easy to not hear.
        local _sum_n=0 _sum_rec
        while IFS= read -r _sum_rec; do
            [[ -n "$_sum_rec" ]] || continue
            [[ "$(manifest_graph_output_summary "$manifest" "${_sum_rec%%|*}")" == "true" ]] \
                && _sum_n=$(( _sum_n + 1 ))
        done < <(manifest_graph_get_outputs "$manifest")
        if [[ "$_sum_n" -eq 0 ]]; then
            violations+=("$stage|SUMMARY_MISSING|-|stage declares no summary output — every stage-bound plugin must state what it did (ADR-055 §9)")
            fail_count=$(( fail_count + 1 ))
        elif [[ "$_sum_n" -gt 1 ]]; then
            violations+=("$stage|SUMMARY_DUP|-|stage declares $_sum_n summary outputs — exactly one (ADR-055 §9)")
            fail_count=$(( fail_count + 1 ))
        fi
    done

    # #1980: Pass 3 (OUTPUT_UNCONSUMED) is retired; with declared inputs
    # retired too, so is the mirror check (an input naming no producer).

    # ── ADR-040 §3/§5/§7 (Phase 1): typed-aggregator preflight ─────────────
    # Make "aggregator" an explicit, PREFLIGHT-ENFORCED concept. The `convergence:`
    # manifest marker is the aggregator/gate TYPE (gate = blocking convergence,
    # advisory = non-blocking review). Aggregators stay EXPLICITLY named in the
    # template — nothing is auto-injected; we only assert the named wiring is
    # present and type-correct, and fail LOUD when it is not.
    #
    # (A) Every cycle whose exit_when target resolves to a convergence marker must
    #     bind to a cycle MEMBER declaring `convergence: gate` (the gate aggregator,
    #     e.g. gate-aggregator). A convergence:advisory target, or a target that is
    #     not a member, is a hard violation. Cycles whose exit_when target carries
    #     NO marker are legacy or untyped (standard.yaml's test_assessment/impact/
    #     review convergence) and are intentionally NOT retro-checked.
    local _cyc_n3=0
    if declare -p _TPL_CYCLES >/dev/null 2>&1; then _cyc_n3="${#_TPL_CYCLES[@]}"; fi
    if [[ $_cyc_n3 -gt 0 ]]; then
        local _c _csafe _ew _ew_conv _mem_csv
        for _c in "${_TPL_CYCLES[@]}"; do
            _csafe="${_c//-/_}"
            local _ews_var="_TPL_CYCLE_UNTIL_STAGE_${_csafe}"
            _ew="${!_ews_var:-}"
            [[ -z "$_ew" ]] && continue
            _ew_conv="$(_cv_stage_convergence "$plugins_root" "$_ew")"
            # Discriminator: only typed (marker-bearing) exit_when targets are
            # checked — an untyped target is a legacy cycle, left alone.
            [[ -z "$_ew_conv" ]] && continue
            local _mems_var="_TPL_CYCLE_STAGES_${_csafe}"
            _mem_csv="${!_mems_var:-}"
            local _is_mem=0 _mm
            local _IFS_s="$IFS"; IFS=','
            # shellcheck disable=SC2206
            local -a _mems=($_mem_csv)
            IFS="$_IFS_s"
            for _mm in "${_mems[@]}"; do [[ "$_mm" == "$_ew" ]] && { _is_mem=1; break; }; done
            if [[ $_is_mem -eq 0 ]]; then
                violations+=("$_c|CYCLE_AGG_NOT_MEMBER|$_ew|cycle '$_c': exit_when.stage '$_ew' is not a member of the cycle — the convergence aggregator must be a cycle member [ADR-040 §5]")
                fail_count=$((fail_count + 1))
            elif [[ "$_ew_conv" != "gate" ]]; then
                violations+=("$_c|CYCLE_AGG_TYPE|$_ew|cycle '$_c': exit_when.stage '$_ew' is convergence:$_ew_conv but a cycle requires a convergence:gate aggregator [ADR-040 §5]")
                fail_count=$((fail_count + 1))
            fi
        done
    fi

    # (B) Every parallel group declaring `aggregate: advisory` must have an
    #     EXPLICIT advisory aggregator present — a stage declaring
    #     `convergence: advisory` that is NOT a member of the group (e.g.
    #     simple.yaml's review_lenses → review-aggregator). Missing → hard
    #     violation. Blocking groups (aggregate: all_pass / gate) converge via
    #     their own exit_when predicate (checked in (A) / the ADR-040 §5 lint
    #     guard) and need no separate aggregator stage.
    local _pg_n3=0
    if declare -p _TPL_PARALLEL_GROUPS >/dev/null 2>&1; then _pg_n3="${#_TPL_PARALLEL_GROUPS[@]}"; fi
    if [[ $_pg_n3 -gt 0 ]]; then
        local _g _gsafe _gagg _gflow
        for _g in "${_TPL_PARALLEL_GROUPS[@]}"; do
            _gsafe="${_g//-/_}"
            local _gagg_var="_TPL_PARALLEL_AGGREGATE_${_gsafe}"
            _gagg="${!_gagg_var:-}"
            [[ "$_gagg" == "advisory" ]] || continue
            local _gflow_var="_TPL_PARALLEL_FLOW_${_gsafe}"
            _gflow="${!_gflow_var:-}"
            local -A _gmember=()
            local _IFS_s2="$IFS"; IFS=','
            # shellcheck disable=SC2206
            local -a _gms=($_gflow)
            IFS="$_IFS_s2"
            local _gm; for _gm in "${_gms[@]}"; do [[ -n "$_gm" ]] && _gmember["$_gm"]=1; done
            # Search the resolved stage set for a non-member convergence:advisory
            # aggregator. The group members themselves are convergence:advisory
            # lenses — they are excluded so the bind resolves to the dedicated
            # aggregator, not a sibling lens.
            local _found_agg="" _st _st_conv
            for _st in "${stages[@]}"; do
                [[ -n "${_gmember[$_st]:-}" ]] && continue
                _st_conv="$(_cv_stage_convergence "$plugins_root" "$_st")"
                if [[ "$_st_conv" == "advisory" ]]; then _found_agg="$_st"; break; fi
            done
            if [[ -z "$_found_agg" ]]; then
                violations+=("$_g|PARALLEL_NO_AGG|$_g|parallel group '$_g' declares aggregate:advisory but no explicit convergence:advisory aggregator stage is present — add the aggregator (e.g. review-aggregator) to the template [ADR-040 §3]")
                fail_count=$((fail_count + 1))
            fi
        done
    fi

    # No violations → success
    if [[ $fail_count -eq 0 ]]; then
        return 0
    fi

    # ── Render structured error ────────────────────────────────────────────
    {
        printf '\n'
        printf '✗ Pipeline cannot start — stage manifests break the contract:\n\n'
        local v sstage scode sid smsg
        for v in "${violations[@]}"; do
            IFS='|' read -r sstage scode sid smsg _ <<< "$v"
            case "$scode" in
                FORMAT_MISSING|FORMAT_UNKNOWN|TYPE_UNVERSIONED|INPUTS_RETIRED|OUTPUT_DUP|SUMMARY_MISSING|SUMMARY_DUP|CYCLE_AGG_NOT_MEMBER|CYCLE_AGG_TYPE|PARALLEL_NO_AGG)
                    printf '  %s: %s (id=%s)\n    %s\n\n' "$sstage" "$scode" "$sid" "$smsg"
                    ;;
                *)
                    printf '  %s: %s (id=%s): %s\n\n' "$sstage" "$scode" "$sid" "$smsg"
                    ;;
            esac
        done
        printf 'Fix: edit the relevant plugin manifest (plugins/*/manifest.yaml)\n'
        printf '     or the active template (config/templates/<id>.yaml).\n'
        printf '     See docs/adr/ADR-020-inter-stage-data-contract.md.\n\n'
    } >&2

    # Emit event (best-effort; do not fail the validator on event-bus errors)
    if declare -F eb_emit_event >/dev/null 2>&1; then
        eb_emit_event "pipeline.preflight.fail" \
            "reason=contract_violation" \
            "violation_count=$fail_count" \
            "mode=$mode" 2>/dev/null || true
    fi

    # Mode-specific resolution
    if [[ "$mode" == "warn" ]]; then
        printf '  ZBUILD_CONTRACT_VALIDATOR=warn — continuing despite violations. Set =enforce to fail-fast.\n\n' >&2
        return 0
    fi

    # enforce: write preflight_failed status and return 1 (#1850: was 2 — the
    # status and the pipeline.preflight.* events say why)
    if [[ -n "$state_file" ]]; then
        local sdir; sdir="$(dirname "$state_file")"
        mkdir -p "$sdir" 2>/dev/null || true
        if declare -F atomic_write >/dev/null 2>&1; then
            jq -n \
                --arg status "preflight_failed" \
                --arg reason "contract_violation" \
                --argjson count "$fail_count" \
                '{schema_version: 1, status: $status, reason: $reason, violation_count: $count}' \
                2>/dev/null | atomic_write "$state_file" 2>/dev/null || true
        fi
    fi
    return 1
}
