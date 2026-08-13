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
            # Unknown mode: degrade to warn but log it.
            mode="warn"
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
        manifest="$(manifest_graph_collect "$plugins_root" "$stage" 2>/dev/null || true)"
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

        # Collect inputs and sort by id for stable error ordering (decision: stable ordering)
        local -a input_lines=()
        local rec
        while IFS= read -r rec; do
            [[ -z "$rec" ]] && continue
            input_lines+=("$rec")
        done < <(manifest_graph_get_inputs "$manifest" | LC_ALL=C sort)

        local in_rec in_id in_type in_source in_required in_path
        for in_rec in "${input_lines[@]}"; do
            # shellcheck disable=SC2034  # in_type captured for future schema-aware checks
            IFS='|' read -r in_id in_type in_source in_required in_path <<< "$in_rec"
            [[ -z "$in_id" ]] && continue

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

            # #1768: the source switch below runs for EVERY input, matching the
            # CI lint (scripts/lib/lint-contract.sh), which has never gated it.
            #
            # This gate used to skip the whole switch for `required: false`, so
            # 33 of 50 inputs — two thirds of the tree — reached no source check
            # at all. Three consequences, all live before this change:
            #   - `source: artifacts` was unrecognised AND unvalidated: it would
            #     have hard-failed as BAD_SOURCE, and escaped only because every
            #     use is optional.
            #   - CYCLE_FB_DIR and CYCLE_FB_UNWIRED could never fire, since
            #     cycle_feedback is REQUIRED to be optional. lint-contract.sh
            #     :236-239 delegates the unwired check here ("runtime validator
            #     owns that"), so it was enforced by neither.
            #   - a malformed source on an optional input was invisible.
            #
            # Only the output-id existence check stays gated on required, in the
            # stage:* arm below. That one is load-bearing: an optional input may
            # be a glob fan-in over a producer GROUP, naming the producer for
            # ordering rather than a single output id (review-aggregator's
            # lens_results globs lens-*.json across the review-lens members).
            # lint-contract.sh:225-231 documents the same carve-out.
            local _in_optional=0
            [[ "$in_required" == "false" ]] && _in_optional=1

            # A required input must declare a source. An optional one need not —
            # but if it declares one, it is validated like any other.
            if [[ -z "$in_source" ]]; then
                if [[ $_in_optional -eq 1 ]]; then
                    continue
                fi
                violations+=("$stage|MISSING_SOURCE|$in_id|required input has no source: declared|$in_path")
                fail_count=$((fail_count + 1))
                continue
            fi

            case "$in_source" in
                external)
                    if [[ -z "${_CV_EXTERNAL_OK[$in_id]:-}" ]]; then
                        violations+=("$stage|BAD_EXTERNAL|$in_id|source: external used for id not in allowlist (allowed: $(manifest_graph_external_allowlist))")
                        fail_count=$((fail_count + 1))
                    fi
                    ;;
                artifacts)
                    # #1768: recognised here so the gate above can be opened
                    # without refusing 9 live inputs (2 in design, 7 in
                    # gate-aggregator) and halting every run at pre-flight.
                    # The CI lint has always tolerated this value
                    # (lint-contract.sh:194); only this validator did not, which
                    # is the divergence #1768 is about.
                    #
                    # TRANSITIONAL. ADR-055 §1 retires this kind: the reads it
                    # covers become ordinary name-matched inputs, and a backwards
                    # edge is legalised by the template's declared re-entry
                    # (§1.3) rather than by an untyped read of the shared
                    # artifact directory. #1825 removes it. Validating the path
                    # shape here is deliberately NOT added — it would pick a
                    # convention (7 of the 9 use a bare filename, 2 use
                    # ${artifact_dir}/) for a kind that is being deleted, and
                    # every one of these paths is decorative today because the
                    # plugin rebuilds it in code.
                    :
                    ;;
                cycle_feedback)
                    # ADR-020 amendment (#511 / F2): cycle_feedback inputs are
                    # OPTIONAL by construction (cross-iter only meaningful when
                    # the cycle runs more than once).
                    #
                    # #1768: the note that used to sit here — "required:true is a
                    # contradiction caught above; an unreachable branch here" —
                    # was half right and hid the larger problem. The branch was
                    # unreachable, but so was this ENTIRE case: the required-only
                    # gate above meant an input that must be optional could never
                    # reach its own validation. CYCLE_FB_DIR and CYCLE_FB_UNWIRED
                    # were dead, and lint-contract.sh:236-239 delegates UNWIRED
                    # here, so nothing enforced it. Opening the gate revives all
                    # three; the CYCLE_FB_REQUIRED branch below stays genuinely
                    # unreachable, and stays as the explicit statement of the rule.
                    if [[ "$in_required" == "true" ]]; then
                        violations+=("$stage|CYCLE_FB_REQUIRED|$in_id|source: cycle_feedback cannot be required:true (#511)")
                        fail_count=$((fail_count + 1))
                        continue
                    fi
                    if [[ -n "$in_path" && "$in_path" == *'${artifact_dir}'* ]]; then
                        violations+=("$stage|CYCLE_FB_DIR|$in_id|source:cycle_feedback path uses \${artifact_dir} (use \${cycle_feedback_dir}) [#511]|$in_path")
                        fail_count=$((fail_count + 1))
                        continue
                    fi
                    # Wiring check: input MUST be referenced by some
                    # cycles[].feedback.to.input==<in_id> AND the consumer
                    # stage MUST be a member of that cycle. Wiring data lives
                    # in template-parser side-channel vars (_TPL_CYCLE_*).
                    # Only enforced when template-parser state is loaded;
                    # otherwise warn-skip (lint catches the static side).
                    local _cyc_count=0
                    if declare -p _TPL_CYCLES >/dev/null 2>&1; then
                        _cyc_count="${#_TPL_CYCLES[@]}"
                    fi
                    if [[ $_cyc_count -gt 0 ]]; then
                        local _wired=0 _cyc
                        for _cyc in "${_TPL_CYCLES[@]}"; do
                            local _safe="${_cyc//-/_}"
                            local _fb_var="_TPL_CYCLE_FEEDBACK_${_safe}"
                            local _fb_blob="${!_fb_var:-}"
                            [[ -z "$_fb_blob" ]] && continue
                            local _fb_line
                            while IFS= read -r _fb_line; do
                                [[ -z "$_fb_line" ]] && continue
                                # "from_stage:from_output|to_stage:to_field:required"
                                local _to_part="${_fb_line#*|}"
                                local _to_stage="${_to_part%%:*}"
                                local _rest="${_to_part#*:}"
                                local _to_field="${_rest%%:*}"
                                if [[ "$_to_stage" == "$stage" && "$_to_field" == "$in_id" ]]; then
                                    _wired=1; break
                                fi
                            done <<< "$_fb_blob"
                            [[ $_wired -eq 1 ]] && break
                        done
                        if [[ $_wired -eq 0 ]]; then
                            violations+=("$stage|CYCLE_FB_UNWIRED|$in_id|input declares source:cycle_feedback but no cycles[].feedback.to wires it [#511]")
                            fail_count=$((fail_count + 1))
                        fi
                    fi
                    ;;
                stage:*)
                    local producer="${in_source#stage:}"
                    # Self-reference check
                    if [[ "$producer" == "$stage" ]]; then
                        violations+=("$stage|SELF_REF|$in_id|source: stage:$producer refers to itself")
                        fail_count=$((fail_count + 1))
                        continue
                    fi
                    # Is producer in the template?
                    local in_template=0 ts
                    for ts in "${stages[@]}"; do
                        [[ "$ts" == "$producer" ]] && { in_template=1; break; }
                    done
                    if [[ "$in_template" -eq 0 ]]; then
                        violations+=("$stage|MISSING_STAGE|$in_id|source declared: stage:$producer; status: stage '$producer' is NOT in template — add it before '$stage'|$in_path")
                        fail_count=$((fail_count + 1))
                        continue
                    fi
                    # Is producer ordered before consumer? (Misordered)
                    if [[ -z "${_CV_AVAILABLE[$producer]:-}" ]]; then
                        # producer is in template but not yet seen → misordered
                        violations+=("$stage|MISORDERED|$in_id|source declared: stage:$producer; status: stage '$producer' runs AFTER '$stage' in template")
                        fail_count=$((fail_count + 1))
                        continue
                    fi
                    # Does producer declare this output id?
                    #
                    # #1768: this is the ONE check that stays gated on required,
                    # and the gate is load-bearing rather than an oversight. An
                    # OPTIONAL input may be a glob fan-in over a producer GROUP —
                    # review-aggregator's `lens_results` globs `lens-*.json`
                    # across the review-lens map members — naming the producer
                    # for ordering, not a single output id. Enforcing id-match
                    # there is a false positive: review-lens declares
                    # `lens_result` (one file per member) and the consumer names
                    # `lens_results` (the set). Mirrors the same carve-out and
                    # rationale at lint-contract.sh:225-231 (#1279, ADR-047 §5).
                    if [[ $_in_optional -eq 0 && -z "${_CV_STAGE_OUTPUTS_OK[$producer:$in_id]:-}" ]]; then
                        violations+=("$stage|MISSING_OUTPUT|$in_id|source declared: stage:$producer; status: stage '$producer' does NOT declare output id '$in_id'")
                        fail_count=$((fail_count + 1))
                        continue
                    fi
                    ;;
                *)
                    # #1768: the message used to read "must be 'stage:<name>' or
                    # 'external'", omitting two kinds the switch accepts seven
                    # and thirty lines above it. An author hitting this was told
                    # their valid value was not an option.
                    violations+=("$stage|BAD_SOURCE|$in_id|source: '$in_source' is not a recognised kind (must be 'stage:<name>', 'external', 'artifacts' or 'cycle_feedback')")
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
                local _has_input=0 _irec _iid _itype _isrc _ireq _ipath
                while IFS= read -r _irec; do
                    [[ -z "$_irec" ]] && continue
                    IFS='|' read -r _iid _itype _isrc _ireq _ipath <<< "$_irec"
                    if [[ "$_iid" == "$_to_field" && "$_isrc" == "cycle_feedback" ]]; then
                        _has_input=1; break
                    fi
                done < <(manifest_graph_get_inputs "$_to_manifest")
                if [[ $_has_input -eq 0 ]]; then
                    violations+=("$_to_stage|CYCLE_FB_UNDECLARED|$_to_field|cycle[$_cyc].feedback.to wires input '$_to_field' but stage '$_to_stage' declares no matching input with source:cycle_feedback [#511]")
                    fail_count=$((fail_count + 1))
                fi
            done <<< "$_fb_blob"
        done
    fi

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
                MISSING_OUTPUT|BAD_EXTERNAL|BAD_SOURCE|MISSING_SOURCE|SELF_REF|MALFORMED|BAD_VAR|CYCLE_FB_REQUIRED|CYCLE_FB_DIR|CYCLE_FB_UNWIRED|CYCLE_FB_UNDECLARED|OUTPUT_DUP|CYCLE_AGG_NOT_MEMBER|CYCLE_AGG_TYPE|PARALLEL_NO_AGG)
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
