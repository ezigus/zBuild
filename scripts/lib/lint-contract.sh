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

# ADR-020 lint scope: only stage-bound plugins participate in the inter-stage
# data contract. Backend services (cache/memory/orchestrator/claim-coordinator)
# don't read/produce stage artifacts and are intentionally excluded. The
# explicit allowlist below mirrors ADR-013's canonical stage set.
_LC_STAGE_IDS_TO_CHECK=(intake plan design build test test_assessment acceptance-gate cq-preflight cq-audit-plan cq-cycle cq-backtrack review pr deploy validate monitor security-lens)

_lc_id_in_scope() {
    local id="$1" s
    for s in "${_LC_STAGE_IDS_TO_CHECK[@]}"; do
        [[ "$s" == "$id" ]] && return 0
    done
    return 1
}

# Build {stage_id → manifest_path}, {stage_id:output_id → 1},
# {stage_id:input_id → source} indices (the last drives the Wave 18-C
# cycle-feedback wiring lint; the source value lets us distinguish a
# correctly-declared cycle_feedback input from a same-name input wired
# from stage:X).
declare -A _LC_STAGE_MANIFEST=()
declare -A _LC_STAGE_OUTPUTS=()
declare -A _LC_STAGE_INPUT_SOURCE=()
declare -A _LC_EXTERNAL_OK=()
for a in $(manifest_graph_external_allowlist); do
    _LC_EXTERNAL_OK["$a"]=1
done

_offences=0

while IFS= read -r -d '' m; do
    id="$(manifest_graph_get_stage_id "$m")"
    [[ -z "$id" ]] && continue
    _LC_STAGE_MANIFEST["$id"]="$m"
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        out_id="${rec%%|*}"
        [[ -n "$out_id" ]] && _LC_STAGE_OUTPUTS["$id:$out_id"]=1
    done < <(manifest_graph_get_outputs "$m")
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        IFS='|' read -r _in_id _in_type _in_source _in_required _in_path <<< "$rec"
        [[ -z "$_in_id" ]] && continue
        _LC_STAGE_INPUT_SOURCE["$id:$_in_id"]="$_in_source"
    done < <(manifest_graph_get_inputs "$m")
done < <(find "$_PLUGINS_ROOT" -name manifest.yaml -not -path '*/tests/*' -print0 2>/dev/null)

_complain() {
    printf 'lint-contract: %s\n' "$*" >&2
    _offences=$((_offences + 1))
}

for id in "${!_LC_STAGE_MANIFEST[@]}"; do
    m="${_LC_STAGE_MANIFEST[$id]}"
    rel="${m#"$_LINT_CONTRACT_REPO"/}"

    # Only enforce on stage-bound plugins (ADR-020 scope).
    _lc_id_in_scope "$id" || continue

    if ! manifest_graph_inputs_block_present "$m"; then
        _complain "$rel: missing inputs: block (declare 'inputs: []' for zero-input plugins) [ADR-020 decision 1]"
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

    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        # shellcheck disable=SC2034  # in_type/in_path read for parity with validator parser
        IFS='|' read -r in_id in_type in_source in_required in_path <<< "$rec"
        [[ -z "$in_id" ]] && continue

        # required: must be true|false (if explicitly set)
        if [[ -n "$in_required" && "$in_required" != "true" && "$in_required" != "false" ]]; then
            _complain "$rel: input '$in_id' has malformed required: '$in_required' (must be true|false)"
            continue
        fi
        # Optional inputs may skip source declaration.
        eff_required="${in_required:-true}"

        if [[ "$eff_required" == "true" && -z "$in_source" ]]; then
            _complain "$rel: input '$in_id' is required but has no source: (use 'source: stage:<X>' or 'source: external')"
            continue
        fi

        case "$in_source" in
            ""|external)
                if [[ "$in_source" == "external" && -z "${_LC_EXTERNAL_OK[$in_id]:-}" ]]; then
                    _complain "$rel: input '$in_id' uses source: external for id NOT in allowlist [$(manifest_graph_external_allowlist)] [ADR-020 decision 6]"
                fi
                ;;
            cycle_feedback)
                # ADR-020 amendment (#511 / F2): cycle_feedback inputs are
                # wired by `cycles[].feedback.to.input==<id>`. Constraints:
                #   - required:true is a contradiction (feedback is best-effort)
                #   - path MUST use ${cycle_feedback_dir}, not ${artifact_dir}
                if [[ "$eff_required" == "true" ]]; then
                    _complain "$rel: input '$in_id' source:cycle_feedback cannot be required:true (#511; cross-iter feedback is best-effort)"
                fi
                if [[ -n "$in_path" && "$in_path" == *'${artifact_dir}'* ]]; then
                    _complain "$rel: input '$in_id' source:cycle_feedback uses \${artifact_dir} in path (use \${cycle_feedback_dir}; cross-iter data must not pollute artifact namespace) [#511]"
                fi
                # Cross-template wiring (unwired/undeclared) is enforced by the
                # runtime contract-validator when the active template + plugin
                # set are known together. CI lint operates on plugins alone, so
                # it cannot decide unwired here — runtime validator owns that.
                ;;
            stage:*)
                producer="${in_source#stage:}"
                if [[ "$producer" == "$id" ]]; then
                    _complain "$rel: input '$in_id' is self-referential (source: stage:$producer == self)"
                    continue
                fi
                if [[ -z "${_LC_STAGE_MANIFEST[$producer]:-}" ]]; then
                    _complain "$rel: input '$in_id' references unknown stage '$producer' (no plugin manifest with id: $producer)"
                    continue
                fi
                if [[ -z "${_LC_STAGE_OUTPUTS[$producer:$in_id]:-}" ]]; then
                    _complain "$rel: input '$in_id' references stage:$producer but $producer does NOT declare output id '$in_id'"
                fi
                ;;
            *)
                _complain "$rel: input '$in_id' has malformed source: '$in_source' (must be 'stage:<X>' or 'external')"
                ;;
        esac
    done < <(manifest_graph_get_inputs "$m")
done

# ─── Wave 18-C (#708): cycle-feedback wiring lint ───────────────────────────
# Every cycle definition's `feedback:` wire is statically verified against
# the producer + consumer manifests:
#   - from.stage exists in the template's resolved stage set
#   - from.stage's manifest declares an output with id == from.output
#   - to.stage   exists in the template's resolved stage set
#   - to.stage's manifest declares an input with id == to.input AND
#     source == cycle_feedback (a same-name input wired from stage:X is a
#     stale-feedback bug, not a valid match).
#
# Scope: default scans config/templates/*.yaml when running against the
# real plugins tree. Callers that scope the lint to a custom plugins root
# via ZBUILD_PLUGINS_ROOT (test fixtures, in-development overrides) must
# explicitly opt-in to template linting via ZBUILD_TEMPLATES_ROOTS — the
# default real-repo template set would otherwise flag wires whose stages
# don't exist in the test's narrow plugin fixture.
_LC_TEMPLATES_ROOTS_DEFAULT="$_LINT_CONTRACT_REPO/config/templates"
if [[ -n "${ZBUILD_TEMPLATES_ROOTS:-}" ]]; then
    _LC_TEMPLATES_ROOTS="$ZBUILD_TEMPLATES_ROOTS"
elif [[ -n "${ZBUILD_PLUGINS_ROOT:-}" && "$_PLUGINS_ROOT" != "$_LINT_CONTRACT_REPO/plugins" ]]; then
    _LC_TEMPLATES_ROOTS=""
else
    _LC_TEMPLATES_ROOTS="$_LC_TEMPLATES_ROOTS_DEFAULT"
fi

# Parse one template file: emit lines like
#   FB|<cycle_id>|<from_stage>|<from_output>|<to_stage>|<to_input>|<line>
#   ST|<stage_id>           (every top-level section, leaf or cycle)
#   CM|<cycle_id>|<member_id>   (every member listed in a cycle's flow:)
# AWK is forgiving about ordering — it tracks the *most-recent* opened
# cycle section and accumulates `feedback:` items until the section closes
# or the file ends. Mirrors core/pipeline/template.sh's v2 parser shape,
# kept independent so a lint regression can't be silenced by orchestrator
# drift.
_lc_parse_template() {
    local tfile="$1"
    awk -v F="$tfile" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function flush_fb() {
        if (fb_cid != "" && fb_fs != "" && fb_fo != "" && fb_ts != "" && fb_ti != "") {
            printf "FB|%s|%s|%s|%s|%s|%d\n", fb_cid, fb_fs, fb_fo, fb_ts, fb_ti, fb_line
        }
        fb_fs=""; fb_fo=""; fb_ts=""; fb_ti=""; fb_line=0
        in_from=0; in_to=0
    }
    function close_section() {
        flush_fb()
        in_section=0; section_id=""; section_is_cycle=0
        in_feedback=0; in_cflow=0
    }
    BEGIN {
        in_section=0; section_id=""; section_is_cycle=0
        in_feedback=0; in_cflow=0; in_from=0; in_to=0
        fb_cid=""; fb_fs=""; fb_fo=""; fb_ts=""; fb_ti=""; fb_line=0
    }
    # Strip trailing comments for parsing simplicity (keep line numbers).
    { raw=$0; sub(/[[:space:]]*#.*/, "", $0) }
    # Top-level section header: `<id>:` at col 0.
    /^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ {
        # Close prior section bookkeeping first.
        if (in_section) close_section()
        sid=$0; sub(/:.*$/, "", sid)
        section_id=sid
        in_section=1
        section_is_cycle=0
        printf "ST|%s\n", sid
        next
    }
    # Inside a section: detect `type: cycle`.
    in_section && /^[[:space:]]+type:[[:space:]]*cycle([[:space:]]|$)/ {
        section_is_cycle=1
        next
    }
    # Cycle flow block opener: `  flow:` (col >0).
    in_section && section_is_cycle && /^[[:space:]]+flow:[[:space:]]*$/ {
        in_cflow=1; in_feedback=0; flush_fb()
        next
    }
    # Cycle flow members: `    - <id>` while in_cflow.
    in_section && section_is_cycle && in_cflow && /^[[:space:]]+-[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*$/ {
        mid=$0
        sub(/^[[:space:]]+-[[:space:]]+/, "", mid)
        mid=trim(mid)
        printf "CM|%s|%s\n", section_id, mid
        next
    }
    # Any non-list-item line at flow-indent or shallower closes in_cflow.
    in_section && section_is_cycle && in_cflow && /^[[:space:]]+[A-Za-z_]/ {
        in_cflow=0
        # Fall through to other matchers below.
    }
    # Cycle feedback block opener.
    in_section && section_is_cycle && /^[[:space:]]+feedback:[[:space:]]*$/ {
        in_feedback=1; in_cflow=0
        fb_cid=section_id
        next
    }
    # New feedback item: `    - from:`
    in_section && section_is_cycle && in_feedback && /^[[:space:]]+-[[:space:]]+from:[[:space:]]*$/ {
        flush_fb()
        fb_cid=section_id
        fb_line=NR
        in_from=1; in_to=0
        next
    }
    # Inside `from:` block — stage/output.
    in_section && section_is_cycle && in_feedback && in_from && /^[[:space:]]+stage:[[:space:]]*/ {
        v=$0; sub(/^[[:space:]]+stage:[[:space:]]*/, "", v); v=trim(v); fb_fs=v; next
    }
    in_section && section_is_cycle && in_feedback && in_from && /^[[:space:]]+output:[[:space:]]*/ {
        v=$0; sub(/^[[:space:]]+output:[[:space:]]*/, "", v); v=trim(v); fb_fo=v; next
    }
    # `to:` opener — closes `from:` parsing.
    in_section && section_is_cycle && in_feedback && /^[[:space:]]+to:[[:space:]]*$/ {
        in_from=0; in_to=1
        next
    }
    in_section && section_is_cycle && in_feedback && in_to && /^[[:space:]]+stage:[[:space:]]*/ {
        v=$0; sub(/^[[:space:]]+stage:[[:space:]]*/, "", v); v=trim(v); fb_ts=v; next
    }
    in_section && section_is_cycle && in_feedback && in_to && /^[[:space:]]+input:[[:space:]]*/ {
        v=$0; sub(/^[[:space:]]+input:[[:space:]]*/, "", v); v=trim(v); fb_ti=v; next
    }
    END {
        if (in_section) close_section()
    }
    ' "$tfile"
}

# Walk every templates root (space- or colon-delimited) and lint each
# template found.
_LC_TPL_ROOTS_NORMALIZED="${_LC_TEMPLATES_ROOTS//:/ }"
# shellcheck disable=SC2086  # intentional word-splitting on roots list
for _tpl_root in $_LC_TPL_ROOTS_NORMALIZED; do
    [[ -d "$_tpl_root" ]] || continue
    while IFS= read -r -d '' tfile; do
        trel="${tfile#"$_LINT_CONTRACT_REPO"/}"
        # First pass: collect stage set + member-of-cycle relationships
        # so a feedback wire can see both the cycle's own flow members AND
        # any sibling stage section in the template.
        declare -A _tpl_stages=()
        declare -A _tpl_cycle_members=()  # "cycle_id:member_id" -> 1
        feedback_rows=()
        while IFS= read -r row; do
            case "$row" in
                ST\|*) _tpl_stages["${row#ST|}"]=1 ;;
                CM\|*)
                    rest="${row#CM|}"
                    cid="${rest%%|*}"; mid="${rest#*|}"
                    _tpl_cycle_members["$cid:$mid"]=1
                    # Cycle members are also valid stage references.
                    _tpl_stages["$mid"]=1
                    ;;
                FB\|*) feedback_rows+=("${row#FB|}") ;;
            esac
        done < <(_lc_parse_template "$tfile")

        for fbrow in "${feedback_rows[@]}"; do
            IFS='|' read -r fb_cid fb_fs fb_fo fb_ts fb_ti fb_line <<< "$fbrow"
            loc="$trel:$fb_line (cycle '$fb_cid')"

            # 1. from.stage must be in template's stage set.
            if [[ -z "${_tpl_stages[$fb_fs]:-}" ]]; then
                _complain "$loc: feedback.from.stage '$fb_fs' is not declared as a stage section in this template"
                continue
            fi
            # 2. from.stage manifest must declare from.output.
            if [[ -z "${_LC_STAGE_MANIFEST[$fb_fs]:-}" ]]; then
                _complain "$loc: feedback.from.stage '$fb_fs' has no plugin manifest (cannot verify output '$fb_fo')"
            elif [[ -z "${_LC_STAGE_OUTPUTS[$fb_fs:$fb_fo]:-}" ]]; then
                _complain "$loc: feedback.from references stage '$fb_fs' output '$fb_fo' but '$fb_fs' manifest does NOT declare that output id"
            fi
            # 3. to.stage must be in template's stage set.
            if [[ -z "${_tpl_stages[$fb_ts]:-}" ]]; then
                _complain "$loc: feedback.to.stage '$fb_ts' is not declared as a stage section in this template"
                continue
            fi
            # 4. to.stage manifest must declare to.input with source: cycle_feedback.
            if [[ -z "${_LC_STAGE_MANIFEST[$fb_ts]:-}" ]]; then
                _complain "$loc: feedback.to.stage '$fb_ts' has no plugin manifest (cannot verify input '$fb_ti')"
                continue
            fi
            _src_key="$fb_ts:$fb_ti"
            if [[ -z "${_LC_STAGE_INPUT_SOURCE[$_src_key]+x}" ]]; then
                _complain "$loc: feedback.to references stage '$fb_ts' input '$fb_ti' but '$fb_ts' manifest does NOT declare that input id"
                continue
            fi
            _src_val="${_LC_STAGE_INPUT_SOURCE[$_src_key]}"
            if [[ "$_src_val" != "cycle_feedback" ]]; then
                _complain "$loc: feedback.to references stage '$fb_ts' input '$fb_ti' but its declared source is '${_src_val:-<empty>}' (must be 'cycle_feedback' for cycle-feedback wires)"
            fi
        done

        unset _tpl_stages _tpl_cycle_members
    done < <(find "$_tpl_root" -maxdepth 2 -name '*.yaml' -type f -print0 2>/dev/null)
done

if [[ $_offences -gt 0 ]]; then
    printf '\nlint-contract: %d violation(s). See docs/adr/ADR-020-inter-stage-data-contract.md.\n' "$_offences" >&2
    exit 1
fi

exit 0
