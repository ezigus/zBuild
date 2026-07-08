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

# ADR-047 §5: lint scope is DERIVED from the manifest graph, not a hardcoded roster.
# A manifest is in scope iff it is a node in the inter-stage data-dependency graph
# (`_lc_id_in_scope` below, keyed on `_LC_HAS_STAGE_INPUT` / `_LC_PRODUCER_REF` built
# during indexing). Backend services fall out for free (no stage inputs, not referenced
# as producers) — no stage naming required.
#
# The old CURATED SUBSET is retained ONLY as the strangler baseline: the parity test
# (tests/unit/preflight-lint-parity-test.sh) asserts the DERIVED set is a
# superset-or-equal of this list, so scope can never silently NARROW below what the
# hand-maintained list validated. Removed once the strangler window closes.
# shellcheck disable=SC2034  # strangler baseline: read by the scope-derivation test, not here
_LC_STAGE_IDS_TO_CHECK=(intake plan design build test test_assessment acceptance-gate cq-preflight cq-audit-plan cq-cycle cq-backtrack review pr deploy validate monitor security-lens)

# _lc_id_in_scope <manifest-key> — in scope iff a data-dependency-graph node (ADR-047 §5).
_lc_id_in_scope() {
    local id="$1"
    [[ -n "${_LC_HAS_STAGE_INPUT[$id]:-}" ]] && return 0
    [[ -n "${_LC_PRODUCER_REF[$id]:-}" ]] && return 0
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
declare -A _LC_STAGE_CONVERGENCE=()  # manifest id → convergence marker (gate|advisory|"") — ADR-040 §5
declare -A _LC_ROLE_CONVERGENCE=()   # provides.role → convergence marker — for role-bound template stages
# ADR-047 §5: contract-participation is DERIVED, not a hardcoded roster. A manifest
# participates in the inter-stage data contract iff it is a NODE in the data-dependency
# graph — it either declares an `inputs[].source: stage:X` (a consumer) OR is referenced
# as `stage:<self>` by some other manifest's input (a producer). Backend services
# (cache/memory/orchestrator/claim-coordinator/output) are neither and fall out with no
# stage naming. Keyed by the SAME resolution keys as _LC_STAGE_MANIFEST (id and role:<role>).
declare -A _LC_HAS_STAGE_INPUT=()    # manifest key → 1 if it consumes a stage:X input
declare -A _LC_PRODUCER_REF=()       # stage name → 1 if referenced as stage:<name> by some input
declare -A _LC_EXTERNAL_OK=()
for a in $(manifest_graph_external_allowlist); do
    _LC_EXTERNAL_OK["$a"]=1
done

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
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        IFS='|' read -r _in_id _in_type _in_source _in_required _in_path <<< "$rec"
        [[ -z "$_in_id" ]] && continue
        for _k in "${_keys[@]}"; do _LC_STAGE_INPUT_SOURCE["$_k:$_in_id"]="$_in_source"; done
        # ADR-047 §5 data-graph participation: record this manifest as a consumer and
        # the referenced stage as a producer.
        if [[ "$_in_source" == stage:* ]]; then
            for _k in "${_keys[@]}"; do _LC_HAS_STAGE_INPUT["$_k"]=1; done
            _LC_PRODUCER_REF["${_in_source#stage:}"]=1
        fi
    done < <(manifest_graph_get_inputs "$m")
done < <(find "$_PLUGINS_ROOT" -name manifest.yaml -not -path '*/tests/*' -print0 2>/dev/null)

_complain() {
    printf 'lint-contract: %s\n' "$*" >&2
    _offences=$((_offences + 1))
}

for id in "${!_LC_STAGE_MANIFEST[@]}"; do
    # Each manifest is indexed under BOTH its plugin id and a `role:<role>` alias
    # (for reference resolution). Enforce ONCE, via the id key — skip the role:
    # alias so a role-bound manifest isn't linted twice (duplicate diagnostics /
    # double-counted offences). _LC_HAS_STAGE_INPUT is set on every key, so the id
    # key carries the same in-scope decision.
    [[ "$id" == role:* ]] && continue
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
            ""|external|artifacts)
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
                # Output-id existence is enforced only for REQUIRED inputs, mirroring
                # the runtime validator (contract-validator.sh:317 treats required:false
                # as informational). An OPTIONAL input may be a glob fan-in over a
                # producer group (e.g. review-aggregator's lens_results globs
                # lens-*.json across the review-lens parallel members) — it names the
                # producer for ordering, not a single output id. #1279 (ADR-047 §5).
                if [[ "$eff_required" == "true" && -z "${_LC_STAGE_OUTPUTS[$producer:$in_id]:-}" ]]; then
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
    # Stage role binding: `  roles: [role, ...]`. Capture the FIRST role so a
    # feedback wire can resolve a stage whose plugin id != stage id via role
    # (mirrors the role-then-id rule in resolve_stage_plugin, ADR-042).
    in_section && /^[[:space:]]+roles:[[:space:]]*\[/ {
        r=$0
        sub(/^[[:space:]]+roles:[[:space:]]*\[/, "", r)
        sub(/[,\]].*$/, "", r)
        gsub(/[[:space:]"'"'"']/, "", r)
        if (r != "") printf "SR|%s|%s\n", section_id, r
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
        declare -A _tpl_stage_role=()     # stage_id -> bound role (first `roles:` entry)
        feedback_rows=()
        while IFS= read -r row; do
            case "$row" in
                ST\|*) _tpl_stages["${row#ST|}"]=1 ;;
                SR\|*)
                    rest="${row#SR|}"
                    _tpl_stage_role["${rest%%|*}"]="${rest#*|}"
                    ;;
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

        # _lc_stage_key <stage_id> — echo the _LC_STAGE_MANIFEST key that resolves
        # this template stage: the stage id when a plugin id matches, else
        # `role:<bound-role>` (role-then-id, mirroring dispatch). Empty = no plugin.
        _lc_stage_key() {
            local sid="$1" role
            if [[ -n "${_LC_STAGE_MANIFEST[$sid]:-}" ]]; then printf '%s' "$sid"; return; fi
            role="${_tpl_stage_role[$sid]:-}"
            if [[ -n "$role" && -n "${_LC_STAGE_MANIFEST[role:$role]:-}" ]]; then
                printf 'role:%s' "$role"; return
            fi
            printf '%s' "$sid"  # unresolved: return id so the existing complaint fires
        }

        for fbrow in "${feedback_rows[@]}"; do
            IFS='|' read -r fb_cid fb_fs fb_fo fb_ts fb_ti fb_line <<< "$fbrow"
            loc="$trel:$fb_line (cycle '$fb_cid')"

            # 1. from.stage must be in template's stage set.
            if [[ -z "${_tpl_stages[$fb_fs]:-}" ]]; then
                _complain "$loc: feedback.from.stage '$fb_fs' is not declared as a stage section in this template"
                continue
            fi
            # 2. from.stage manifest must declare from.output. Resolve the stage
            #    to its manifest key via role-then-id (plugin id may ≠ stage id).
            _fb_fkey="$(_lc_stage_key "$fb_fs")"
            if [[ -z "${_LC_STAGE_MANIFEST[$_fb_fkey]:-}" ]]; then
                _complain "$loc: feedback.from.stage '$fb_fs' has no plugin manifest (cannot verify output '$fb_fo')"
            elif [[ -z "${_LC_STAGE_OUTPUTS[$_fb_fkey:$fb_fo]:-}" ]]; then
                _complain "$loc: feedback.from references stage '$fb_fs' output '$fb_fo' but '$fb_fs' manifest does NOT declare that output id"
            fi
            # 3. to.stage must be in template's stage set.
            if [[ -z "${_tpl_stages[$fb_ts]:-}" ]]; then
                _complain "$loc: feedback.to.stage '$fb_ts' is not declared as a stage section in this template"
                continue
            fi
            # 4. to.stage manifest must declare to.input with source: cycle_feedback.
            _fb_tkey="$(_lc_stage_key "$fb_ts")"
            if [[ -z "${_LC_STAGE_MANIFEST[$_fb_tkey]:-}" ]]; then
                _complain "$loc: feedback.to.stage '$fb_ts' has no plugin manifest (cannot verify input '$fb_ti')"
                continue
            fi
            _src_key="$_fb_tkey:$fb_ti"
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
        #     target is a legacy/untyped cycle (not retro-checked).
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
