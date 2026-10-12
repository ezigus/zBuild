#!/usr/bin/env bash
# scripts/lib/lint-contract.sh — ADR-020 CI lint (issue #496).
#
# Statically validates every plugin manifest's inputs[]/outputs[] block
# against the inter-stage data contract:
#
#   - Every input with `source: stage:X` requires:
#       (a) X to exist in plugins/ tree
#       (b) X to declare an output with the referenced id
#   - Every input with `source: external` requires its id to be on the
#     hardcoded allowlist (decision #6).
#   - Empty `inputs:` block (missing or value-only) is rejected; explicit
#     `inputs: []` is required for zero-input plugins.
#   - `required:` must be true|false; empty value is malformed.
#
# Exit codes:
#   0 — clean
#   1 — at least one offending manifest (printed to stderr)
#
# Wired into `npm run lint`. Uses the shared manifest-graph.sh parser so
# the lint view and the runtime validator view are identical (parity test
# in tests/unit/preflight-lint-parity-test.sh asserts this).
set -euo pipefail

_LINT_CONTRACT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LINT_CONTRACT_REPO="$(cd "$_LINT_CONTRACT_DIR/../.." && pwd)"

# shellcheck source=./manifest-graph.sh
source "$_LINT_CONTRACT_DIR/manifest-graph.sh"

_PLUGINS_ROOT="${ZBUILD_PLUGINS_ROOT:-$_LINT_CONTRACT_REPO/plugins}"

# ADR-047 §5: lint scope is DERIVED from the manifests, not a hardcoded roster. A
# manifest is in scope iff it is a stage: it writes a stage result
# (provides.result_contract). A backend service (orchestrator, cache, memory,
# persona, output destination) writes none. Declared inputs are retired
# (ADR-055 §1, amended 2026-10-12), so the old graph built from them would leave
# nothing in scope.
#
# The old CURATED SUBSET is retained ONLY as the strangler baseline: the parity test
# (tests/unit/preflight-lint-parity-test.sh) asserts the DERIVED set is a
# superset-or-equal of this list, so scope can never silently NARROW below what the
# hand-maintained list validated. Removed once the strangler window closes.
# shellcheck disable=SC2034  # strangler baseline: read by the scope-derivation test, not here
_LC_STAGE_IDS_TO_CHECK=(intake plan design build test acceptance-gate pr deploy validate monitor security-lens)

# _lc_id_in_scope <manifest-key> — in scope iff a data-dependency-graph node (ADR-047 §5).
_lc_id_in_scope() {
    [[ -n "${_LC_IS_STAGE[$1]:-}" ]]
}

# Build {stage_id → manifest_path} and {stage_id:output_id → 1} indices.
declare -A _LC_STAGE_MANIFEST=()
declare -A _LC_STAGE_OUTPUTS=()
declare -A _LC_IS_STAGE=()   # manifest key → 1 if it writes a stage result
declare -A _LC_STAGE_CONVERGENCE=()  # manifest id → convergence marker (gate|advisory|"") — ADR-040 §5
declare -A _LC_ROLE_CONVERGENCE=()   # provides.role → convergence marker — for role-bound template stages
# _lc_manifest_field <manifest> <top-level-key> — echo a top-level scalar value.
_lc_manifest_field() {
    awk -v k="$2" '
        $0 ~ "^" k ":[[:space:]]*" {
            sub("^" k ":[[:space:]]*", ""); sub(/[[:space:]]*#.*/, "")
            gsub(/^["'"'"']|["'"'"']$/, ""); print; exit
        }
    ' "$1" 2>/dev/null
}

# _lc_manifest_role <manifest> — echo provides.role (nested one level under provides:).
_lc_manifest_role() {
    awk '
        /^provides:/ { inp=1; next }
        inp && /^[A-Za-z_]/ { inp=0 }
        inp && /^[[:space:]]+role:[[:space:]]*/ {
            sub(/^[[:space:]]+role:[[:space:]]*/, ""); sub(/[[:space:]]*#.*/, "")
            gsub(/^["'"'"']|["'"'"']$/, ""); print; exit
        }
    ' "$1" 2>/dev/null
}

_offences=0

while IFS= read -r -d '' m; do
    id="$(manifest_graph_get_stage_id "$m")"
    [[ -z "$id" ]] && continue
    _role="$(_lc_manifest_role "$m")"
    # Index the manifest maps by BOTH the plugin id AND a `role:<role>` key, so a
    # template reference (feedback.from.stage / input source:stage:X) whose stage
    # id ≠ plugin id can still resolve via role-then-id — mirroring dispatch's
    # resolve_stage_plugin (ADR-042). E.g. the `acceptance-gate` stage binds role
    # `acceptance_gate`, served by the method-named `spec-acceptance` plugin.
    _keys=("$id")
    [[ -n "$_role" ]] && _keys+=("role:$_role")
    if grep -qE '^[[:space:]]+result_contract:' "$m" 2>/dev/null; then
        for _k in "${_keys[@]}"; do _LC_IS_STAGE["$_k"]=1; done
    fi
    for _k in "${_keys[@]}"; do _LC_STAGE_MANIFEST["$_k"]="$m"; done
    # ADR-040 §5: convergence marker is the AUTHORITATIVE mechanical-vs-advisory
    # discriminator (supersedes kind:-inference; e.g. acceptance-gate is kind:agent
    # but convergence:gate).
    _conv="$(_lc_manifest_field "$m" convergence)"
    [[ -n "$_conv" ]] && _LC_STAGE_CONVERGENCE["$id"]="$_conv"
    [[ -n "$_role" && -n "$_conv" ]] && _LC_ROLE_CONVERGENCE["$_role"]="$_conv"
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        out_id="${rec%%|*}"
        [[ -n "$out_id" ]] && for _k in "${_keys[@]}"; do _LC_STAGE_OUTPUTS["$_k:$out_id"]=1; done
    done < <(manifest_graph_get_outputs "$m")
done < <(find "$_PLUGINS_ROOT" -name manifest.yaml -not -path '*/tests/*' -print0 2>/dev/null)

_complain() {
    printf 'lint-contract: %s\n' "$*" >&2
    _offences=$((_offences + 1))
}

for id in "${!_LC_STAGE_MANIFEST[@]}"; do
    # Each manifest is indexed under BOTH its plugin id and a `role:<role>` alias
    # (for reference resolution). Enforce ONCE, via the id key — skip the role:
    # alias so a role-bound manifest isn't linted twice (duplicate diagnostics /
    # double-counted offences). _LC_IS_STAGE is set on every key, so the id
    # key carries the same in-scope decision.
    [[ "$id" == role:* ]] && continue
    m="${_LC_STAGE_MANIFEST[$id]}"
    rel="${m#"$_LINT_CONTRACT_REPO"/}"

    # Only enforce on stage-bound plugins (ADR-020 scope).
    _lc_id_in_scope "$id" || continue

    if grep -qE '^inputs:' "$m" 2>/dev/null; then
        _complain "$rel: declares inputs:, which are retired — every stage gets every stage's latest output (ADR-055 §1, ADR-068 §8) [INPUTS_RETIRED]"
    fi

    # ── ADR-020 amendment (#507): exactly-one outputs[].primary: true ──────
    primary_count=$(awk '
        BEGIN { in_out=0; n=0 }
        /^outputs:/ { in_out=1; next }
        in_out && /^[a-zA-Z_]/ { in_out=0 }
        in_out && /^[[:space:]]+primary:[[:space:]]*true([[:space:]]|$|#)/ { n++ }
        END { print n }
    ' "$m" 2>/dev/null)
    if [[ "$primary_count" -eq 0 ]]; then
        _complain "$rel: no outputs[] entry declares 'primary: true' (#507; pick the canonical artifact)"
    elif [[ "$primary_count" -gt 1 ]]; then
        _complain "$rel: $primary_count outputs[] entries declare 'primary: true' (must be exactly one) [#507]"
    fi

    # ── ADR-055 §9 (#2000): EXACTLY ONE outputs[].summary: true ───────────
    # A stage that publishes nothing is indistinguishable from one that had
    # nothing to say, so zero is no longer legal. This is the tree-wide echo of
    # the pre-flight SUMMARY_MISSING check — the validator is the AUTHORITY,
    # because it walks the resolved flow and can see a stage authored outside
    # this repository, which this scan structurally cannot.
    summary_count=$(awk '
        BEGIN { in_out=0; n=0 }
        /^outputs:/ { in_out=1; next }
        in_out && /^[a-zA-Z_]/ { in_out=0 }
        in_out && /^[[:space:]]+summary:[[:space:]]*true([[:space:]]|$|#)/ { n++ }
        END { print n }
    ' "$m" 2>/dev/null)
    if [[ "$summary_count" -eq 0 ]]; then
        _complain "$rel: declares no outputs[] entry with 'summary: true' — every stage-bound plugin must state what it did [ADR-055 §9 SUMMARY_MISSING]"
    elif [[ "$summary_count" -gt 1 ]]; then
        _complain "$rel: $summary_count outputs[] entries declare 'summary: true' (exactly one) [ADR-055 §9 SUMMARY_DUP]"
    fi

done

# #1980: the OUTPUT_UNCONSUMED check is retired. It asked a PRODUCER to declare
# whether anyone consumes its output — a property of the TEMPLATE, not of the
# plugin, so the same plugin in a different flow needed a different answer. The
# 24 `terminal:`/`advisory:` annotations it forced were written to pass a gate,
# not to describe an artifact. The mirror check (a required input naming no
# producer) went with declared inputs (ADR-055 §1, amended 2026-10-12).

# Templates to check. Default: config/templates/*.yaml against the real plugins
# tree. A caller that scopes the lint to a custom plugins root (test fixtures)
# opts in to template linting via ZBUILD_TEMPLATES_ROOTS — the real template set
# would otherwise name stages the fixture does not have.
_LC_TEMPLATES_ROOTS_DEFAULT="$_LINT_CONTRACT_REPO/config/templates"
if [[ -n "${ZBUILD_TEMPLATES_ROOTS:-}" ]]; then
    _LC_TEMPLATES_ROOTS="$ZBUILD_TEMPLATES_ROOTS"
elif [[ -n "${ZBUILD_PLUGINS_ROOT:-}" && "$_PLUGINS_ROOT" != "$_LINT_CONTRACT_REPO/plugins" ]]; then
    _LC_TEMPLATES_ROOTS=""
else
    _LC_TEMPLATES_ROOTS="$_LC_TEMPLATES_ROOTS_DEFAULT"
fi
_LC_TPL_ROOTS_NORMALIZED="${_LC_TEMPLATES_ROOTS//:/ }"

# ─── ADR-040 §5: convergence-path invariant guard ───────────────────────────
# "No advisory stage may appear in the must-pass set or in any exit_when
# predicate." Keys on the `convergence:` MARKER (ADR-040 §5), not `kind:`: a
# `convergence: gate` stage is the mechanical one (even when it is kind:agent,
# e.g. acceptance-gate, whose verdict is mechanical / no model.route); a
# `convergence: advisory` stage NEVER blocks and must not sit on the path. An
# undeclared-marker stage that is kind:agent is treated as illegal too (an LLM
# stage that was not explicitly declared a gate must not gate convergence —
# fail-closed). Promotes ADR-037 §3's prose spot-check to a STRUCTURAL property
# of the resolved template.
#
# Scope (the discriminator): the invariant applies only to templates that adopt
# the decomposed gate taxonomy — those declaring at least one `type: parallel`
# group with a BLOCKING aggregate (anything other than `advisory`). Legacy
# templates with no parallel group (e.g. standard.yaml's review/impact/
# test_assessment cycles, simple.yaml's build_test_cycle) keep their
# existing convergence semantics and are NOT retro-checked — ADR-040 recomposes
# the new pipeline, it does not break the production template. When a template is
# later recomposed onto the gate-aggregator parallel group, this guard activates
# for it automatically.

# Parse one template into convergence records:
#   ST|<sid>            TYPE|<sid>|<type>      AG|<sid>|<aggregate>
#   ROLE|<sid>|<role>   MEMBER|<sid>|<member>  EW|<sid>|<exit/abort_when target>
# `stage:` keys inside feedback blocks are NOT captured as EW: in_ew is armed
# only by an exit_when:/abort_when: opener and disarmed the moment its single
# `stage:` is read (or any sibling key intervenes).
_lc_parse_convergence() {
    awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    BEGIN { sid=""; in_ew=0; in_flow=0 }
    { sub(/[[:space:]]*#.*/, "", $0) }
    /^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ {
        sid=$0; sub(/:.*$/, "", sid); in_ew=0; in_flow=0
        printf "ST|%s\n", sid; next
    }
    sid=="" { next }
    /^[[:space:]]+type:[[:space:]]*/ {
        v=$0; sub(/^[[:space:]]+type:[[:space:]]*/, "", v)
        printf "TYPE|%s|%s\n", sid, trim(v); in_ew=0; in_flow=0; next
    }
    /^[[:space:]]+aggregate:[[:space:]]*/ {
        v=$0; sub(/^[[:space:]]+aggregate:[[:space:]]*/, "", v)
        printf "AG|%s|%s\n", sid, trim(v); in_ew=0; in_flow=0; next
    }
    /^[[:space:]]+roles:[[:space:]]*\[/ {
        v=$0; sub(/^[^[]*\[/, "", v); sub(/\].*/, "", v)
        n=split(v, a, ","); r=trim(a[1])
        if (r != "") printf "ROLE|%s|%s\n", sid, r
        in_ew=0; in_flow=0; next
    }
    /^[[:space:]]+(exit_when|abort_when):[[:space:]]*$/ { in_ew=1; in_flow=0; next }
    /^[[:space:]]+flow:[[:space:]]*$/ { in_flow=1; in_ew=0; next }
    in_flow && /^[[:space:]]+-[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*$/ {
        m=$0; sub(/^[[:space:]]+-[[:space:]]+/, "", m)
        printf "MEMBER|%s|%s\n", sid, trim(m); next
    }
    in_ew && /^[[:space:]]+stage:[[:space:]]*/ {
        v=$0; sub(/^[[:space:]]+stage:[[:space:]]*/, "", v)
        printf "EW|%s|%s\n", sid, trim(v); in_ew=0; next
    }
    in_flow && /^[[:space:]]+[A-Za-z_]/ { in_flow=0 }
    in_ew && /^[[:space:]]+[A-Za-z_]/ { in_ew=0 }
    ' "$1" 2>/dev/null
}

declare -A _cv_type=() _cv_agg=() _cv_role=() _cv_members=() _cv_stage_set=()

# _cv_convergence <stage_id> — resolve a template stage to its `convergence:`
# marker (gate|advisory|""). Prefers the section's role binding, falls back to a
# manifest whose id == stage id. Empty when unresolvable or absent.
_cv_convergence() {
    local s="$1" role="${_cv_role[$1]:-}"
    if [[ -n "$role" && -n "${_LC_ROLE_CONVERGENCE[$role]:-}" ]]; then
        printf '%s\n' "${_LC_ROLE_CONVERGENCE[$role]}"; return 0
    fi
    printf '%s\n' "${_LC_STAGE_CONVERGENCE[$s]:-}"
}

# _cv_illegal_on_path <stage_id> — returns 0 if this leaf must NOT sit on a
# merge-blocking convergence path (ADR-040 §5/§7). Fail-closed: legal ONLY when
# explicitly `convergence: gate` (even kind:agent, e.g. acceptance-gate). An
# advisory marker OR a MISSING marker (of any kind, incl. kind:tool) is illegal —
# every convergence-feeding stage must DECLARE itself a gate, else a forgotten
# marker silently de-scopes a mechanical gate from the roster-driven must-pass
# set (the gate-aggregator keys on the same `convergence: gate` marker).
_cv_illegal_on_path() {
    local s="$1" conv
    conv="$(_cv_convergence "$s")"
    [[ "$conv" == "gate" ]] && return 1
    return 0
}

# _cv_expand <stage_id> [visited] — echo the effective LEAF stage ids of a target:
# a parallel/cycle group expands to its members (transitively); a leaf is itself.
_cv_expand() {
    local t="$1" seen="${2:-}"
    case " $seen " in *" $t "*) return 0 ;; esac
    seen="$seen $t"
    local mems="${_cv_members[$t]:-}" ty="${_cv_type[$t]:-}"
    if [[ -n "$mems" && ( "$ty" == "parallel" || "$ty" == "cycle" ) ]]; then
        local mm
        while IFS= read -r mm; do
            [[ -z "$mm" ]] && continue
            _cv_expand "$mm" "$seen"
        done <<< "$mems"
    else
        printf '%s\n' "$t"
    fi
}

for _tpl_root in $_LC_TPL_ROOTS_NORMALIZED; do
    [[ -d "$_tpl_root" ]] || continue
    while IFS= read -r -d '' tfile; do
        trel="${tfile#"$_LINT_CONTRACT_REPO"/}"
        _cv_type=(); _cv_agg=(); _cv_role=(); _cv_members=(); _cv_stage_set=()
        _cv_ew_pairs=()
        while IFS= read -r _row; do
            case "$_row" in
                ST\|*)     _cv_stage_set["${_row#ST|}"]=1 ;;
                TYPE\|*)   _r="${_row#TYPE|}";   _cv_type["${_r%%|*}"]="${_r#*|}" ;;
                AG\|*)     _r="${_row#AG|}";     _cv_agg["${_r%%|*}"]="${_r#*|}" ;;
                ROLE\|*)   _r="${_row#ROLE|}";   _cv_role["${_r%%|*}"]="${_r#*|}" ;;
                MEMBER\|*) _r="${_row#MEMBER|}"; _cv_members["${_r%%|*}"]+="${_r#*|}"$'\n'
                           _cv_stage_set["${_r#*|}"]=1 ;;
                EW\|*)     _cv_ew_pairs+=("${_row#EW|}") ;;
            esac
        done < <(_lc_parse_convergence "$tfile")

        # Discriminator: does this template adopt the decomposed gate taxonomy?
        _cv_strict=0
        for _s in "${!_cv_type[@]}"; do
            [[ "${_cv_type[$_s]}" == "parallel" ]] || continue
            [[ "${_cv_agg[$_s]:-all_pass}" != "advisory" ]] && _cv_strict=1
        done
        if [[ $_cv_strict -eq 1 ]]; then
            # RULE A — must-pass set: members of a blocking parallel group must be
            # convergence:gate (mechanical). An advisory (or undeclared-LLM) member
            # on the must-pass path is illegal.
            for _s in "${!_cv_type[@]}"; do
                [[ "${_cv_type[$_s]}" == "parallel" ]] || continue
                _agg="${_cv_agg[$_s]:-all_pass}"
                [[ "$_agg" == "advisory" ]] && continue
                while IFS= read -r _leaf; do
                    [[ -z "$_leaf" ]] && continue
                    if _cv_illegal_on_path "$_leaf"; then
                        _complain "$trel: parallel group '$_s' (aggregate: $_agg) is on the must-pass/convergence path but member '$_leaf' is not convergence:gate (advisory or undeclared); convergence-feeding stages must be declared convergence:gate [ADR-040 §5]"
                    fi
                done < <(_cv_expand "$_s")
            done
            # RULE B — exit_when/abort_when: target must not be (or contain) an
            # advisory/undeclared-LLM stage.
            for _pair in "${_cv_ew_pairs[@]}"; do
                _ows="${_pair%%|*}"; _tgt="${_pair#*|}"
                if [[ "${_cv_type[$_tgt]:-}" == "parallel" && "${_cv_agg[$_tgt]:-all_pass}" == "advisory" ]]; then
                    _complain "$trel: exit_when/abort_when in '$_ows' targets parallel group '$_tgt' whose aggregate is 'advisory' (an advisory group never drives convergence) [ADR-040 §5]"
                fi
                while IFS= read -r _leaf; do
                    [[ -z "$_leaf" ]] && continue
                    if _cv_illegal_on_path "$_leaf"; then
                        _complain "$trel: exit_when/abort_when in '$_ows' references '$_tgt' which resolves to leaf '$_leaf' that is not convergence:gate (advisory or undeclared); no non-gate stage may sit on a merge-blocking convergence path [ADR-040 §5]"
                    fi
                done < <(_cv_expand "$_tgt")
            done
        fi

        # ── ADR-040 §3/§5/§7 (Phase 1): typed-aggregator presence (CI mirror) ──
        # Mirrors core/pipeline/contract-validator.sh's typed-aggregator preflight
        # so a misconfigured template fails in CI lint as well as at runtime. NOT
        # gated by _cv_strict — these checks key on the per-stage `convergence:`
        # marker / per-group `aggregate:` declaration, independent of whether the
        # template adopts a blocking parallel group.
        #
        # (A) Cycle exit_when must bind to a MEMBER declaring convergence: gate.
        #     A marked target that is advisory or not-a-member fails; an UNMARKED
        #     target is a legacy or untyped cycle (not retro-checked).
        for _pair in "${_cv_ew_pairs[@]}"; do
            _ows="${_pair%%|*}"; _tgt="${_pair#*|}"
            [[ "${_cv_type[$_ows]:-}" == "cycle" ]] || continue
            _ew_conv="$(_cv_convergence "$_tgt")"
            [[ -z "$_ew_conv" ]] && continue
            _is_mem=0
            while IFS= read -r _m; do
                [[ -z "$_m" ]] && continue
                [[ "$_m" == "$_tgt" ]] && { _is_mem=1; break; }
            done <<< "${_cv_members[$_ows]:-}"
            if [[ $_is_mem -eq 0 ]]; then
                _complain "$trel: cycle '$_ows': exit_when.stage '$_tgt' is not a member of the cycle — the convergence aggregator must be a cycle member [ADR-040 §5]"
            elif [[ "$_ew_conv" != "gate" ]]; then
                _complain "$trel: cycle '$_ows': exit_when.stage '$_tgt' is convergence:$_ew_conv but a cycle requires a convergence:gate aggregator [ADR-040 §5]"
            fi
        done

        # (B) Parallel group with aggregate:advisory needs an explicit
        #     convergence:advisory aggregator stage that is NOT a group member.
        for _s in "${!_cv_type[@]}"; do
            [[ "${_cv_type[$_s]}" == "parallel" ]] || continue
            [[ "${_cv_agg[$_s]:-}" == "advisory" ]] || continue
            declare -A _gmem=()
            while IFS= read -r _m; do
                [[ -n "$_m" ]] && _gmem["$_m"]=1
            done <<< "${_cv_members[$_s]:-}"
            _found_agg=""
            for _cand in "${!_cv_stage_set[@]}"; do
                [[ -n "${_gmem[$_cand]:-}" ]] && continue
                if [[ "$(_cv_convergence "$_cand")" == "advisory" ]]; then _found_agg="$_cand"; break; fi
            done
            unset _gmem
            if [[ -z "$_found_agg" ]]; then
                _complain "$trel: parallel group '$_s' declares aggregate:advisory but no explicit convergence:advisory aggregator stage is present — add the aggregator (e.g. review-aggregator) to the template [ADR-040 §3]"
            fi
        done
    done < <(find "$_tpl_root" -maxdepth 2 -name '*.yaml' -type f -print0 2>/dev/null)
done

if [[ $_offences -gt 0 ]]; then
    printf '\nlint-contract: %d violation(s). See docs/adr/ADR-020-inter-stage-data-contract.md.\n' "$_offences" >&2
    exit 1
fi

exit 0
