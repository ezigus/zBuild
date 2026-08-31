#!/usr/bin/env bash
# core/pipeline/contract-validator.sh — ADR-020 runtime pre-flight contract
# validator (issue #496).
#
# Reads the active template's stage list + each stage's manifest, builds an
# O(1) lookup of available stage outputs in template order, then asserts that
# every required input of every stage has a producer ahead of it.
#
# Failure modes:
#   - missing required input from a stage NOT in the template → preflight_failed
#   - input declares `source: stage:X` but X declares no output with that id
#   - input declares `source: external` for an id outside the allowlist
#   - input path template references an unknown ${var}
#
# Integration: called from core/pipeline/runner.sh:~165 after load_template +
# init_state but before the --dry-run branch and before the stage loop.
#
# Rollout: gated by ZBUILD_CONTRACT_VALIDATOR=warn|enforce. As of Wave 12-E
# (#664), the default is `enforce` — manifest contracts were made honest by
# Wave 12-D so the validator is now safe to fail-closed by default. In
# `warn` mode (explicit opt-out), violations are reported on stderr and a
# `pipeline.preflight.fail` event is emitted, but the pipeline is allowed
# to proceed; in `enforce` mode (default) the function returns rc=2 and
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

# ─── _cv_var_in_canonical_set <var_name> ───────────────────────────────────────
# Returns 0 if the variable is in the closed templating-var set (decision #5).
_cv_var_in_canonical_set() {
    local v="$1"
    local allowed
    allowed="$(manifest_graph_canonical_vars)"
    for a in $allowed; do
        [[ "$a" == "$v" ]] && return 0
    done
    return 1
}

# ─── _cv_check_path_vars <path_template> → rc 0 ok, 1 unknown var ──────────────
# Scans the path template for ${var} references and rejects any not in the
# canonical set. Emits the first offender on stderr via $_CV_LAST_BAD_VAR.
_CV_LAST_BAD_VAR=""
_cv_check_path_vars() {
    local path="$1"
    _CV_LAST_BAD_VAR=""
    [[ -z "$path" ]] && return 0
    # Extract every "${name}" reference.
    local rest="$path" v
    while [[ "$rest" == *'${'*'}'* ]]; do
        v="${rest#*'${'}"
        v="${v%%'}'*}"
        if ! _cv_var_in_canonical_set "$v"; then
            _CV_LAST_BAD_VAR="$v"
            return 1
        fi
        rest="${rest#*'}'}"
    done
    return 0
}

# ─── _cv_redact_path <abs_path> <state_dir> ────────────────────────────────────
# Per decision #12: pre-flight errors render paths as $ZBUILD_STATE_DIR/...
# rather than absolute paths. Pre-flight runs before scope-manifest is final,
# so we can't use the redaction chokepoint; we strip the state_dir prefix
# manually here as a best-effort.
_cv_redact_path() {
    local path="$1" state_dir="$2"
    if [[ -n "$state_dir" && "$path" == "$state_dir"* ]]; then
        echo "\$ZBUILD_STATE_DIR${path#$state_dir}"
    else
        printf '%s' "$path"
    fi
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
    local state_dir; state_dir="$(dirname "${state_file:-/dev/null}")"

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
            return 2
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

    # External allowlist (decision #6)
    local allowlist
    allowlist="$(manifest_graph_external_allowlist)"
    local -A _CV_EXTERNAL_OK=()
    local a
    for a in $allowlist; do
        _CV_EXTERNAL_OK["$a"]=1
    done

    # Build cumulative available-outputs map: key="stage:output_id" → 1
    declare -A _CV_AVAILABLE=()
    # Also build per-stage available list to check `stage:X` references
    declare -A _CV_STAGE_OUTPUTS_OK=()  # key="stage:id" → 1 if stage X has output id
    # Pass 3 (OUTPUT_UNCONSUMED): every input id seen across all stages in the flow.
    local -A _CV_INPUT_NAMES_SEEN=()

    # Pass 1: collect every stage's outputs into _CV_STAGE_OUTPUTS_OK.
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
            _CV_STAGE_OUTPUTS_OK["$stage:$out_id"]=1
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
        # #1895: a consumer declares no format either — the producer owns how its
        # artifact is checked, for the same reason it owns the type. Checked once
        # over the inputs BLOCK because the field would not appear in the input
        # record at all, so a per-input lookup could never see it.
        if awk '/^inputs:[[:space:]]*$/{i=1;next} /^[a-zA-Z_]/{i=0} i && /^[[:space:]]+format:/{found=1} END{exit !found}' "$manifest" 2>/dev/null; then
            violations+=("$stage|INPUT_FORMAT||an input declares format: — the producer owns it (ADR-055 §1, #1895)")
            fail_count=$((fail_count + 1))
        fi
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

    # Pass 2: walk stages in order; for each, validate inputs against the
    # cumulative _CV_AVAILABLE map, then merge this stage's outputs into it.

    for stage in "${stages[@]}"; do
        manifest="${_CV_STAGE_MANIFEST[$stage]:-}"
        [[ -z "$manifest" ]] && continue

        # Decision #1: an absent `inputs:` block is malformed. An explicit
        # `inputs: []` is required to declare zero inputs. (For agent
        # plugins specifically; tool/orchestrator that haven't migrated yet
        # are warned but not failed during the warn-default rollout.)
        if ! manifest_graph_inputs_block_present "$manifest"; then
            printf '  WARNING: manifest for stage %s has no inputs: block — declare `inputs: []` for zero-input plugins (ADR-020)\n' \
                "$stage" >&2
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

        # Collect inputs and sort by id for stable error ordering (decision: stable ordering)
        local -a input_lines=()
        local rec
        while IFS= read -r rec; do
            [[ -z "$rec" ]] && continue
            input_lines+=("$rec")
        done < <(manifest_graph_get_inputs "$manifest" | LC_ALL=C sort)

        local in_rec in_id in_source in_required in_path
        for in_rec in "${input_lines[@]}"; do
            # ADR-055 §8: the type position is READ PAST, not captured. It held
            # `in_type` from 2026-05-30 to #1827 "for future schema-aware checks"
            # that could never be written — §1 removed the consumer-declared type,
            # so there is no second declaration to compare against. Removed rather
            # than implemented, which is what the ADR asks for.
            IFS='|' read -r in_id _ in_source in_required in_path <<< "$in_rec"
            [[ -z "$in_id" ]] && continue
            _CV_INPUT_NAMES_SEEN["$in_id"]=1

            # Default required=true if absent at parse time (decision #1).
            # Empty `required:` value (key present but no value) is malformed.
            if [[ -z "$in_required" ]]; then
                in_required="true"
            fi
            case "$in_required" in
                true|false) ;;
                *)
                    violations+=("$stage|MALFORMED|$in_id|invalid required: value '$in_required' (must be true|false)")
                    fail_count=$((fail_count + 1))
                    continue
                    ;;
            esac

            # Check path template variables (decision #5)
            if [[ -n "$in_path" ]]; then
                if ! _cv_check_path_vars "$in_path"; then
                    violations+=("$stage|BAD_VAR|$in_id|path template references unknown variable \${${_CV_LAST_BAD_VAR}} (allowed: $(manifest_graph_canonical_vars))|$in_path")
                    fail_count=$((fail_count + 1))
                    continue
                fi
            fi

            # #1768: the switch below runs for EVERY input, matching the CI lint
            # (lint-contract.sh), which has never gated it. This gate used to
            # skip the whole switch for `required: false` — 33 of 50 inputs —
            # so an unrecognised or malformed source on an optional input was
            # invisible, and CYCLE_FB_DIR / CYCLE_FB_UNWIRED could never fire.
            # Only the TEMPLATE-AWARE checks stay gated (see the stage:* arm).
            local _in_optional=0
            [[ "$in_required" == "false" ]] && _in_optional=1

            # ADR-055 §1.2 leaves exactly TWO input kinds, so this switch has
            # two live arms. `stage:<name>`, `artifacts` and `cycle_feedback`
            # are gone: a consumer no longer names a producer, restates a path
            # or restates a type, and the four CYCLE_FB_* codes retire with
            # them (§4). What they protected is now §1.5's single rule, checked
            # in the default arm below — and it covers EVERY input, where the
            # old template-aware checks were skipped for `required: false`.
            case "$in_source" in
                external)
                    # The one kind that survives: it names something from
                    # OUTSIDE the pipeline, so there is no producer to resolve
                    # and the allowlist is the only thing that can validate it.
                    if [[ -z "${_CV_EXTERNAL_OK[$in_id]:-}" ]]; then
                        violations+=("$stage|BAD_EXTERNAL|$in_id|source: external used for id not in allowlist (allowed: $(manifest_graph_external_allowlist))")
                        fail_count=$((fail_count + 1))
                    fi
                    ;;
                "")
                    # A stage output, named and nothing else (ADR-055 §1.5).
                    # The name must resolve to EXACTLY ONE producer in the
                    # resolved flow; zero or two is a refused template, not a
                    # runtime surprise. Two is what OUTPUT_DUP already prevents,
                    # so it is reported here only if that guard is ever relaxed.
                    local _prods="${_CV_OUTPUT_PRODUCERS[$in_id]:-}"
                    if [[ -z "$_prods" ]]; then
                        # ADR-055 §1.5 says zero producers is a refused template.
                        # That holds for a REQUIRED input. For an optional one it
                        # is too strict, and gate-aggregator is why: it declares
                        # lint_result / coverage_result / mutation_result so it
                        # adapts to whichever gates a template includes, and
                        # simple.yaml includes none of those three. Refusing that
                        # would forbid a plugin from working across templates,
                        # which is the portability ADR-042 exists to protect.
                        # Optional means "this may not exist in this flow" — the
                        # engine already omits it from the index (#1894).
                        if [[ "$in_required" != "false" ]]; then
                            violations+=("$stage|INPUT_UNRESOLVED|$in_id|required input '$in_id' names an artifact no stage in the resolved flow produces (ADR-055 §1.5)")
                            fail_count=$((fail_count + 1))
                        fi
                    else
                        local -a _pl=()
                        # shellcheck disable=SC2206
                        _pl=( $_prods )
                        if [[ ${#_pl[@]} -gt 1 ]]; then
                            violations+=("$stage|INPUT_AMBIGUOUS|$in_id|input name '$in_id' resolves to ${#_pl[@]} producers: ${_prods// /, } — a name must identify exactly one (ADR-055 §1.5)")
                            fail_count=$((fail_count + 1))
                        elif [[ "${_pl[0]}" == "$stage" ]]; then
                            # A self-edge is legal ONLY as a declared re-entry
                            # (ADR-055 §1.3): a cycle re-runs its own members, so
                            # design consuming its own prior design.md is fine.
                            # Outside a cycle it is a stage waiting on itself.
                            if ! _cv_stage_in_any_cycle "$stage"; then
                                violations+=("$stage|SELF_REF|$in_id|input '$in_id' resolves to this stage's own output, and '$stage' is not a cycle member — no re-entry can deliver it (ADR-055 §1.3)")
                                fail_count=$((fail_count + 1))
                            fi
                        fi
                    fi
                    ;;
                *)
                    violations+=("$stage|BAD_SOURCE|$in_id|source: '$in_source' is not a recognised kind — a consumer declares 'external' or nothing at all (ADR-055 §1.2)")
                    fail_count=$((fail_count + 1))
                    ;;
            esac
        done

        # Mark this stage as available for downstream consumers.
        _CV_AVAILABLE["$stage"]=1
    done

    # ── ADR-021 amendment (#511): cycle_feedback_undeclared check ──────────
    # For every cycles[].feedback.to.input=<X>, the consumer's manifest MUST
    # declare an input with id==X and source==cycle_feedback. Otherwise the
    # template wires data the consumer never reads — silent failure class.
    local _cyc_count2=0
    if declare -p _TPL_CYCLES >/dev/null 2>&1; then
        _cyc_count2="${#_TPL_CYCLES[@]}"
    fi
    if [[ $_cyc_count2 -gt 0 ]]; then
        local _cyc
        for _cyc in "${_TPL_CYCLES[@]}"; do
            local _safe="${_cyc//-/_}"
            local _fb_var="_TPL_CYCLE_FEEDBACK_${_safe}"
            local _fb_blob="${!_fb_var:-}"
            [[ -z "$_fb_blob" ]] && continue
            local _fb_line
            while IFS= read -r _fb_line; do
                [[ -z "$_fb_line" ]] && continue
                local _to_part="${_fb_line#*|}"
                local _to_stage="${_to_part%%:*}"
                local _rest="${_to_part#*:}"
                local _to_field="${_rest%%:*}"
                local _to_manifest="${_CV_STAGE_MANIFEST[$_to_stage]:-}"
                [[ -z "$_to_manifest" ]] && continue
                local _has_input=0 _irec _iid _isrc _ireq _ipath
                while IFS= read -r _irec; do
                    [[ -z "$_irec" ]] && continue
                    # type position read past, not captured — #1827, same as :365
                    IFS='|' read -r _iid _ _isrc _ireq _ipath <<< "$_irec"
                    # ADR-055 §4: the `cycle_feedback` source kind is retired,
                    # so the edge's target is an ordinary declared input. What
                    # still matters — and is all that ever mattered — is that
                    # the input EXISTS; keying on the source made this check
                    # unenforceable the moment the kind went away.
                    if [[ "$_iid" == "$_to_field" ]]; then
                        _has_input=1; break
                    fi
                done < <(manifest_graph_get_inputs "$_to_manifest")
                if [[ $_has_input -eq 0 ]]; then
                    violations+=("$_to_stage|CYCLE_FB_UNDECLARED|$_to_field|cycle[$_cyc].feedback.to wires input '$_to_field' but stage '$_to_stage' declares no input by that name (ADR-055 §4)")
                    fail_count=$((fail_count + 1))
                fi
            done <<< "$_fb_blob"
        done
    fi

    # ── Pass 3 pre-work: mark cycle exit_when stage outputs as consumed ─────────
    # The cycle mechanism itself reads the exit_when stage's primary output (the
    # verdict artifact) to decide convergence — this is not a manifest input but
    # IS a form of consumption. Without this, gate_aggregator_result (or any other
    # convergence aggregator output) would be false-alarmed in templates where no
    # subsequent stage declares it as a direct input (e.g. simple.yaml after the
    # build_test_cycle, which flows to pr-delivery, not merge/deploy).
    local _ew_c _ew_safe _ew_var _ew_stage _ew_mf _ew_orec _ew_oid
    if declare -p _TPL_CYCLES >/dev/null 2>&1 && [[ ${#_TPL_CYCLES[@]} -gt 0 ]]; then
        for _ew_c in "${_TPL_CYCLES[@]}"; do
            _ew_safe="${_ew_c//-/_}"
            _ew_var="_TPL_CYCLE_UNTIL_STAGE_${_ew_safe}"
            _ew_stage="${!_ew_var:-}"
            [[ -z "$_ew_stage" ]] && continue
            _ew_mf="${_CV_STAGE_MANIFEST[$_ew_stage]:-}"
            [[ -z "$_ew_mf" ]] && continue
            while IFS= read -r _ew_orec; do
                [[ -z "$_ew_orec" ]] && continue
                _ew_oid="${_ew_orec%%|*}"
                [[ -n "$_ew_oid" ]] && _CV_INPUT_NAMES_SEEN["$_ew_oid"]=1
            done < <(manifest_graph_get_outputs "$_ew_mf")
        done
    fi

    # #1980: Pass 3 (OUTPUT_UNCONSUMED) is retired. It asked a PRODUCER whether
    # anyone consumes its output — a property of the TEMPLATE, so the same plugin
    # in a different flow needed a different answer. The mirror direction (a
    # required input naming no producer) is a real error and is still enforced
    # above.

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
    #     NO marker are legacy/untyped (standard.yaml's test_assessment/impact/
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
        printf '✗ Pipeline cannot start — inputs missing for declared stages:\n\n'
        local v sstage scode sid smsg spath
        for v in "${violations[@]}"; do
            IFS='|' read -r sstage scode sid smsg spath <<< "$v"
            local rendered_path=""
            if [[ -n "$spath" ]]; then
                rendered_path="$(_cv_redact_path "$spath" "$state_dir")"
            fi
            case "$scode" in
                MISSING_STAGE)
                    printf '  %s: expects %s%s\n' "$sstage" "'$sid'" \
                        "$( [[ -n "$rendered_path" ]] && printf ' (path: %s)' "$rendered_path" )"
                    printf '    %s\n\n' "$smsg" | sed 's/|/\n    /g'
                    ;;
                MISORDERED)
                    printf '  %s: expects %s\n    %s\n\n' "$sstage" "'$sid'" "$smsg"
                    ;;
                MISSING_OUTPUT|BAD_EXTERNAL|BAD_SOURCE|SELF_REF|MALFORMED|BAD_VAR|INPUT_UNRESOLVED|INPUT_AMBIGUOUS|FORMAT_MISSING|FORMAT_UNKNOWN|INPUT_FORMAT|TYPE_UNVERSIONED|CYCLE_FB_UNDECLARED|OUTPUT_DUP|SUMMARY_MISSING|SUMMARY_DUP|CYCLE_AGG_NOT_MEMBER|CYCLE_AGG_TYPE|PARALLEL_NO_AGG)
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
            "reason=missing_input" \
            "violation_count=$fail_count" \
            "mode=$mode" 2>/dev/null || true
    fi

    # Mode-specific resolution
    if [[ "$mode" == "warn" ]]; then
        printf '  ZBUILD_CONTRACT_VALIDATOR=warn — continuing despite violations. Set =enforce to fail-fast.\n\n' >&2
        return 0
    fi

    # enforce: write preflight_failed status and return 2
    if [[ -n "$state_file" ]]; then
        local sdir; sdir="$(dirname "$state_file")"
        mkdir -p "$sdir" 2>/dev/null || true
        if declare -F atomic_write >/dev/null 2>&1; then
            jq -n \
                --arg status "preflight_failed" \
                --arg reason "missing_input" \
                --argjson count "$fail_count" \
                '{schema_version: 1, status: $status, reason: $reason, violation_count: $count}' \
                2>/dev/null | atomic_write "$state_file" 2>/dev/null || true
        fi
    fi
    return 2
}
