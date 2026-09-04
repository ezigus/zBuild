#!/usr/bin/env bash
# plugins/tool/design-gate/plugin.sh — Design Gate Stage (ADR-046, ADR-037 §1/§3, #1218)
#
# Kind: tool  Tier: T0  (NO LLM — ADR-037 §3 invariant)
# The PRE-build mechanical structural gate for the design stage. Runs six checks
# (C1..C6), reports ALL violations in one pass, and writes verdict=pass|fail to
# design-gate-result.json. C1..C5 are pure grep over design.md; C6 (#1777) is
# the one check that executes anything — it runs each [guard] SPEC's assertion
# at the merge-base, and fails open on every infrastructure signal. Always
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
# shellcheck source=../../../scripts/lib/stage-summary.sh
# NOT `|| true`: this helper is how the gate's findings reach a prompt at
# all. Swallowing a failed load would leave stage_summary_write undefined and
# every finding silently unpublished — the exact shape #1991 guards.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_DG_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_DG_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
# #1783: source the grammar lib from the contract-reader seam, not from the
# engine root. This gate parses the design's acceptance block, so a run that
# edits the block grammar must be gated by ITS copy, not the installed one.
# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_ZBUILD_CONTRACT_LIB_DIR/acceptance-block.sh" 2>/dev/null || true
# #1777: C6 runs each [guard] SPEC's assertion at the merge-base, reusing the
# acceptance gate's own machinery rather than a second implementation of it.
# Same contract-lib seam and same reason as acceptance-block.sh above.
# shellcheck source=../../../scripts/lib/acceptance-negctl.sh
source "$_ZBUILD_CONTRACT_LIB_DIR/acceptance-negctl.sh" 2>/dev/null || true

# Resilient emit — no-op when the event-bus is unavailable (unit-test isolation).
_dg_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

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

    local design_md=""
    if [[ -n "${ZBUILD_STAGE_INPUTS:-}" ]]; then
        design_md="$(jq -r '.inputs.design // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)"
    fi
    [[ -n "$design_md" ]] || design_md="$artifacts_dir/design.md"
    local result_path="$artifacts_dir/design-gate-result.json"
    local feedback_path="$artifacts_dir/design-gate-feedback.md"
    # repo_root = the working tree where declared TESTFILES / WIRING paths live.
    local repo_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$_DG_ROOT")}"

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
        # need declare no testfile). Each [change] SPEC must declare ≥1 testfile
        # via its per-SPEC binding or the global pool, and each declared path must
        # be a sane repo-relative path.
        #
        # #1649: existence is deliberately NOT checked — design runs before build,
        # so requiring the file forced every design off its own proposed test file
        # and onto a crowded one. The promise is enforced at the acceptance-gate,
        # after build could have kept it. Traversal is already handled by
        # acceptance-block.sh, so a guard here would be unreachable.
        if [[ $_has_change -eq 1 ]]; then
            local _spec_c4
            while IFS= read -r _spec_c4; do
                [[ -z "$_spec_c4" ]] && continue
                acceptance_spec_is_change "$design_md" "$_spec_c4" || continue
                local _stf _stf_count=0
                while IFS= read -r _stf; do
                    [[ -z "$_stf" ]] && continue
                    _stf_count=$((_stf_count + 1))
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

    # ── C6 GUARD-BASELINE: a [guard] SPEC must hold at the merge-base ───────
    # The number is free — the original C6 (tag-presence) was deleted by #1477.
    #
    # A [guard] SPEC asserts an invariant, so its assertion holds at the baseline
    # by definition. One that FAILS there is a mislabelled [change], or an
    # assertion inverted relative to its own SPEC text. The acceptance gate
    # already rejects this (`guard_regressed`), but only AFTER build has spent
    # its whole iteration budget on the design: #1789 burned 5 iterations and
    # 2h06m, #1809 burned 2 more and was aborted manually, and both wanted the
    # same two-word correction. Catching it here costs one design turn.
    #
    # FAIL-OPEN, and LOUD ABOUT IT. acceptance_negctl_guard_precheck emits GUARD
    # SKIP — never GUARD FAIL — for a missing baseline, an unresolvable worktree,
    # a timeout, an unparseable file, or an untagged guard (#1255), so a design is
    # never rejected because the check could not run. But a gate that skips
    # SILENTLY is indistinguishable from a gate that works: that is the
    # green-but-inert shape this repo keeps paying for (#845, #1044, and the
    # vacuous `asserts: <none found>` in #1777's own second occurrence). So the
    # coverage is recorded in the artifact — declared vs verified, with a reason
    # per unverified SPEC. "verified 0 of 3, testfiles absent" is a fact an
    # operator can read; "verified 0 of 3, worktree_failed" is visibly a bug and
    # not a pass.
    local _gp_declared=0 _gp_verified=0 _gp_failed=0
    local -a _gp_skips=()
    if [[ $_accept_ok -eq 1 ]] && declare -f acceptance_negctl_guard_precheck >/dev/null 2>&1; then
        local _g_line _g_spec _g_reason
        while IFS= read -r _g_line; do
            case "$_g_line" in
                "GUARD FAIL "*)
                    _g_spec="${_g_line#GUARD FAIL }"; _g_spec="${_g_spec%% *}"
                    _gp_declared=$((_gp_declared + 1)); _gp_failed=$((_gp_failed + 1))
                    violations+=("GUARD_REGRESSED_AT_BASELINE $_g_spec (tagged [guard] but its assertion FAILS at the merge-base — a guard holds there by definition; if this SPEC describes a change, tag it [change])")
                    ;;
                "GUARD PASS "*)
                    _gp_declared=$((_gp_declared + 1)); _gp_verified=$((_gp_verified + 1))
                    ;;
                "GUARD SKIP "*)
                    _g_spec="${_g_line#GUARD SKIP }"
                    _g_reason="${_g_spec#* }"; _g_spec="${_g_spec%% *}"
                    _gp_declared=$((_gp_declared + 1))
                    # TAB, not ':' — a reason is free text and the day one
                    # carries a colon, splitting on the first would silently
                    # truncate it. A tab cannot appear in either field.
                    _gp_skips+=("$_g_spec"$'\t'"$_g_reason")
                    ;;
            esac
        done < <(acceptance_negctl_guard_precheck "$design_md" "$repo_root" 2>/dev/null || true)
    fi

    # ── Verdict + artifact ───────────────────────────────────────────────────
    local verdict violations_json reason
    if [[ ${#violations[@]} -eq 0 ]]; then
        verdict="pass"
        violations_json="[]"
        reason="all structural checks cleared"
    else
        verdict="fail"
        violations_json="$(printf '%s\n' "${violations[@]}" | jq -R . | jq -s .)"
        reason="design structural violations: ${#violations[@]} found"
    fi

    # Coverage block, present ONLY when the design declares a [guard] SPEC — a
    # guard-less design keeps today's exact artifact shape (same absent-when-empty
    # convention as route_target).
    local _gp_json="null"
    if [[ $_gp_declared -gt 0 ]]; then
        local _gp_skips_json="[]"
        if [[ ${#_gp_skips[@]} -gt 0 ]]; then
            _gp_skips_json="$(printf '%s\n' "${_gp_skips[@]}" \
                | jq -R 'select(length>0) | split("\t") | {spec: .[0], reason: (.[1:] | join("\t"))}' \
                | jq -sc .)"
        fi
        _gp_json="$(jq -nc --argjson d "$_gp_declared" --argjson v "$_gp_verified" \
            --argjson f "$_gp_failed" --argjson s "$_gp_skips_json" \
            '{declared:$d,verified:$v,failed:$f,skipped:$s}')"
    fi

    jq -n --arg v "$verdict" --argjson viol "$violations_json" --argjson gp "$_gp_json" --arg r "$reason" \
        '{"result_contract":2,"schema_version":1,"verdict":$v,"disposition":"complete","reason":$r,"violations":$viol}
         + (if $gp==null then {} else {"guard_precheck":$gp} end)' | atomic_write "$result_path"

    if [[ "$verdict" == "fail" ]]; then
        {
            printf '# Design-gate: structural violations\n\n'
            printf 'The design contract is not build-ready. Fix these and re-emit design.md:\n\n'
            printf -- '- %s\n' "${violations[@]}"
            # Say what C6 actually managed to check, so a design author is never
            # left inferring coverage from silence.
            if [[ $_gp_declared -gt 0 ]]; then
                printf '\n## Guard baseline coverage\n\n'
                printf -- '- %d [guard] SPEC(s) declared; %d verified at the merge-base, %d failed.\n' \
                    "$_gp_declared" "$_gp_verified" "$_gp_failed"
                [[ ${#_gp_skips[@]} -gt 0 ]] && printf -- '- not verified: %s\n' "${_gp_skips[*]}"
            fi
        } | atomic_write "$feedback_path"
        _dg_emit "design_gate.fail" "plugin=design-gate" "violations=${#violations[@]}"
    else
        # ADR-055 §9: written on every terminal verdict; absence is never legitimate.
        printf '# Design-gate: all structural checks cleared\n\nThe design is build-ready.\n' \
            | atomic_write "$feedback_path"
        _dg_emit "design_gate.pass" "plugin=design-gate"
    fi

    _dg_emit "plugin.result" "plugin=design-gate" "verdict=$verdict"
    return 0
}

# ─── design_gate_cleanup ──────────────────────────────────────────────────────
