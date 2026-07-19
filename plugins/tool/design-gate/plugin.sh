#!/usr/bin/env bash
# plugins/tool/design-gate/plugin.sh — Design Gate Stage (ADR-046, ADR-037 §1/§3, #1218)
#
# Kind: tool  Tier: T0  (NO LLM — ADR-037 §3 invariant)
# The PRE-build mechanical structural gate for the design stage. Pure grep over
# design.md; runs five structural checks (C1..C5), reports ALL violations in
# one pass, and writes verdict=pass|fail to design-gate-result.json. Always
# returns rc=0 — the verdict lives in the artifact (ADR-040 verdict-in-artifact
# convention); the design_verify_cycle's exit_when reads .verdict.
#
# Hook prefix: design_gate_
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_DESIGN_GATE_PLUGIN_LOADED:-}" ]] && return 0
_ZBUILD_DESIGN_GATE_PLUGIN_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_DG_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_DG_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_DG_ROOT/scripts/lib/acceptance-block.sh" 2>/dev/null || true

# Resilient emit — no-op when the event-bus is unavailable (unit-test isolation).
_dg_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# ─── design_gate_init ─────────────────────────────────────────────────────────
design_gate_init() {
    export ZBUILD_PLUGIN="design-gate"
    export ZBUILD_PLUGIN_KIND="tool"
    _dg_emit "plugin.init.start" "plugin=design-gate"
    _dg_emit "plugin.init.complete" "plugin=design-gate"
    return 0
}

# _dg_scope_nonempty <design_md>
# C1: returns 0 iff design.md carries a ```scope fence with ≥1 non-blank entry.
_dg_scope_nonempty() {
    local design_md="${1:-}"
    [[ -f "$design_md" ]] || return 1
    local in_scope=0 entries=0 line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        # #1227: tolerate a trailing-whitespace fence (mirrors the design
        # stage's grep -q prefix match) so a fence line with a trailing space
        # does not falsely trip SCOPE_MISSING.
        if [[ "$line" == '```scope' || "$line" == '```scope'[[:space:]]* ]]; then in_scope=1; continue; fi
        if [[ $in_scope -eq 1 && "$line" == '```'* ]]; then break; fi
        if [[ $in_scope -eq 1 && -n "${line//[[:space:]]/}" ]]; then entries=$((entries + 1)); fi
    done < "$design_md"
    [[ $entries -gt 0 ]]
}

# ─── design_gate_run ──────────────────────────────────────────────────────────
# Runs C1..C5, collects ALL violations, writes verdict-in-artifact, emits
# design_gate.{pass,fail}. Always rc=0.
# Args: $1 = stage_id, $2 = state_file
design_gate_run() {
    local stage_id="${1:-design-gate}"; : "$stage_id"
    local state_file="${2:-}"

    local artifacts_dir
    if [[ -n "$state_file" && -d "$(dirname "$state_file")" ]]; then
        artifacts_dir="$(dirname "$state_file")/artifacts"
    else
        artifacts_dir="${ZBUILD_ARTIFACT_DIR:-${TMPDIR:-/tmp}/zbuild-design-gate-artifacts}"
    fi
    mkdir -p "$artifacts_dir"

    local design_md="$artifacts_dir/design.md"
    local result_path="$artifacts_dir/design-gate-result.json"
    local feedback_path="$artifacts_dir/design-gate-feedback.md"
    # repo_root = the working tree where declared TESTFILES / WIRING paths live.
    local repo_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$_DG_ROOT")}"

    _dg_emit "plugin.run.start" "plugin=design-gate"

    local -a violations=()

    # ── C1 SCOPE: non-empty ```scope block ──────────────────────────────────
    if ! _dg_scope_nonempty "$design_md"; then
        violations+=("SCOPE_MISSING (design.md has no non-empty \`\`\`scope block)")
    fi

    # ── C2 ACCEPTANCE: block present + parseable ─────────────────────────────
    local _accept_ok=0
    if [[ -f "$design_md" ]] && extract_acceptance_block "$design_md" >/dev/null 2>&1; then
        _accept_ok=1
    else
        violations+=("ACCEPTANCE_MISSING (design.md has no parseable \`\`\`acceptance block)")
    fi

    # ── C3 CLASSIFIED + C4 CHANGE-HAS-TESTFILE (need the SPEC list) ──────────
    local _has_change=0 _spec
    if [[ $_accept_ok -eq 1 ]]; then
        while IFS= read -r _spec; do
            [[ -z "$_spec" ]] && continue
            local _cls; _cls="$(acceptance_spec_classifier "$design_md" "$_spec")"
            case "$_cls" in
                change) _has_change=1 ;;
                guard)  : ;;
                *)      violations+=("UNCLASSIFIED $_spec (SPEC lacks a [change]|[guard] classifier)") ;;
            esac
        done < <(acceptance_list_spec_ids "$design_md" 2>/dev/null || true)

        # C4: only enforced when the change set is non-empty (a guard-only design
        # need declare no testfile). Each [change] SPEC must have ≥1 testfile
        # via its per-SPEC binding or the global pool, and each path must exist.
        if [[ $_has_change -eq 1 ]]; then
            local _spec_c4
            while IFS= read -r _spec_c4; do
                [[ -z "$_spec_c4" ]] && continue
                acceptance_spec_is_change "$design_md" "$_spec_c4" || continue
                local _stf _stf_count=0
                while IFS= read -r _stf; do
                    [[ -z "$_stf" ]] && continue
                    _stf_count=$((_stf_count + 1))
                    [[ -f "$repo_root/$_stf" ]] || violations+=("MISSING_TESTFILE $_stf (declared testfile absent on disk)")
                done < <(acceptance_list_testfiles_for_spec "$design_md" "$_spec_c4" 2>/dev/null || true)
                [[ $_stf_count -eq 0 ]] && violations+=("MISSING_TESTFILE_FOR_SPEC $_spec_c4 (no testfile declared for [change] SPEC)")
            done < <(acceptance_list_spec_ids "$design_md" 2>/dev/null || true)
        fi
    fi

    # ── C5 WIRING: section present ("none" ok); each concrete path exists ────
    if [[ $_accept_ok -eq 1 ]]; then
        if ! acceptance_list_wiring "$design_md" >/dev/null 2>&1; then
            violations+=("WIRING_MISSING (design.md acceptance block has no WIRING: section)")
        else
            local _w
            while IFS= read -r _w; do
                [[ -z "$_w" || "$_w" == "none" ]] && continue
                [[ -e "$repo_root/$_w" ]] || violations+=("WIRING_MISSING $_w (declared wiring path absent on disk)")
            done < <(acceptance_list_wiring "$design_md" 2>/dev/null || true)
        fi
    fi

    # ── Verdict + artifact ───────────────────────────────────────────────────
    local verdict violations_json
    if [[ ${#violations[@]} -eq 0 ]]; then
        verdict="pass"
        violations_json="[]"
    else
        verdict="fail"
        violations_json="$(printf '%s\n' "${violations[@]}" | jq -R . | jq -s .)"
    fi

    jq -n --arg v "$verdict" --argjson viol "$violations_json" \
        '{"schema_version":1,"verdict":$v,"violations":$viol}' | atomic_write "$result_path"

    if [[ "$verdict" == "fail" ]]; then
        {
            printf '# Design-gate: structural violations\n\n'
            printf 'The design contract is not build-ready. Fix these and re-emit design.md:\n\n'
            printf -- '- %s\n' "${violations[@]}"
        } | atomic_write "$feedback_path"
        _dg_emit "design_gate.fail" "plugin=design-gate" "violations=${#violations[@]}"
    else
        # Never leave a stale feedback file from a prior failing iteration.
        rm -f "$feedback_path" 2>/dev/null || true
        _dg_emit "design_gate.pass" "plugin=design-gate"
    fi

    _dg_emit "plugin.run.complete" "plugin=design-gate" "verdict=$verdict"
    return 0
}

# ─── design_gate_finalize ─────────────────────────────────────────────────────
design_gate_finalize() {
    _dg_emit "plugin.finalize.start" "plugin=design-gate"
    _dg_emit "plugin.finalize.complete" "plugin=design-gate"
    return 0
}

# ─── design_gate_cleanup ──────────────────────────────────────────────────────
design_gate_cleanup() {
    _dg_emit "plugin.cleanup.start" "plugin=design-gate"
    _dg_emit "plugin.cleanup.complete" "plugin=design-gate"
    return 0
}
