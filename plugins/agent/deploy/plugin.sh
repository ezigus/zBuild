#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/deploy — deploy stage agent (issues #757, #1846)             ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Stage: deploy (ADR-013 kind:agent amendment, T2, ADR-018 Pattern 1 — one-shot)
# Produces: ZBUILD_ARTIFACT_DIR/deploy-result.json (v2 contract, ADR-054/055/060)
#
# ADR-018 Pattern 1 rationale: deploy is a deterministic side-effect — one
# pr-url input, one release action, done. No iteration loop needed.
# No LLM calls (no route_to_model); kind:agent for guard/orchestration parity
# with the pr-delivery (kind:agent) → pr-open (kind:tool) delegation pattern.
#
# Role: deploy_agent — guard pr-url input + gate verdict; delegate to deploy-release tool.
#
# Lifecycle:
#   deploy_agent_run        — validate env, delegate to _deploy_agent_run_inner
#   _deploy_agent_run_inner — read inputs via ZBUILD_STAGE_INPUTS, check gate,
#                             delegate to deploy-release tool
#
# legacy-citation: pipeline-stages-delivery.sh:950 (stage_deploy)

[[ -n "${_ZBUILD_DEPLOY_LOADED:-}" ]] && return 0
_ZBUILD_DEPLOY_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_DEPLOY_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_DEPLOY_ROOT/core/event-bus/event-bus.sh"
# #2366 (ADR-054 §6): the one writer of a contract-3 result.
# shellcheck source=../../../scripts/lib/stage-result.sh
source "$_DEPLOY_ROOT/scripts/lib/stage-result.sh"

# Write the contract-3 result to ZBUILD_ARTIFACT_DIR/deploy-result.json.
# Args: out_dir outcome reason [pr_url] [tag] [mode] [deployed]
# `deployed` (true|false) says whether a release was cut: a deploy the gate did
# not authorise still finished its job (outcome pass) and deployed nothing.
# Every result says it — false unless a release was cut — because that is how
# later stages know this output for a deploy result (#2364).
_deploy_write_result() {
    local out_dir="$1" outcome="$2" reason="$3"
    local pr_url="${4:-}" tag="${5:-}" mode="${6:-}" deployed="${7:-false}"
    mkdir -p "$out_dir"
    stage_result_write "$out_dir/deploy-result.json" "$outcome" "$reason" \
        "$(jq -nc --arg pr "$pr_url" --arg tag "$tag" --arg mode "$mode" --arg dep "$deployed" \
            '{} + (if $pr != "" then {pr_url:$pr} else {} end)
                + (if $tag != "" then {tag:$tag} else {} end)
                + (if $mode != "" then {mode:$mode} else {} end)
                + (if $dep != "" then {deployed:($dep == "true")} else {} end)')"
}

# _deploy_input_path <id> <root> — the engine-resolved path of input <id>, or
# "" when it is not declared. rc 1 when the path lies OUTSIDE <root> (the run's
# state directory): the engine's index only ever points inside the run, so any
# other path is a defect or a forged index, and it is never opened (review #2219).
_deploy_input_path() {
    local id="$1" root="$2" p dir
    p="${_DEPLOY_INPUTS[$id]:-}"
    [[ -n "$p" ]] || return 0
    # No resolvable run root means nothing can be checked — refuse rather than
    # let "$root"/* collapse to /* and match every path (review #2219, round 2).
    [[ -n "$root" ]] || return 1
    # A directory that does not exist cannot be resolved; judge the path as
    # written. It is refused unless it already names a place inside the run.
    dir="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || dir="$(dirname "$p")"
    case "$dir/" in
        "$root"/*) printf '%s' "$p" ;;
        *) return 1 ;;
    esac
}

# SIGTERM/SIGINT mid-release: the engine stopped the stage. Record it; the run
# path rewrites the envelope once the interrupted command returns.
_deploy_on_signal() {
    _DEPLOY_INTERRUPTED=1
    [[ -n "${ZBUILD_ARTIFACT_DIR:-}" ]] \
        && _deploy_write_result "$ZBUILD_ARTIFACT_DIR" \
            "${1:-$STAGE_SIGNAL_DISPOSITION}" "${2:-$STAGE_SIGNAL_REASON}"
}

# ─── run ─────────────────────────────────────────────────────────────────────
# Args (engine dispatch): $1 = stage id, $2 = state file — passed through to
# deploy-release, whose contract takes both (review #2219: dropping them made
# every real deploy fail while a permissive mock kept the tests green).
deploy_agent_run() {
    local stage_id="${1:-deploy}" state_file="${2:-}"
    local artifacts_dir="${ZBUILD_ARTIFACT_DIR:-}"
    if [[ -z "$artifacts_dir" ]]; then
        # Nowhere to write an envelope: the event is the record (review #2219).
        error "deploy_agent_run: ZBUILD_ARTIFACT_DIR not set — nowhere to write a result"
        emit_event "deploy.result.unwritable" "plugin=deploy" "disposition=broken" \
            "reason=no ZBUILD_ARTIFACT_DIR"
        return 1
    fi
    mkdir -p "$artifacts_dir"
    _DEPLOY_INTERRUPTED=0
    stage_signal_begin _deploy_on_signal
    local rc=0
    _deploy_agent_run_inner "$stage_id" "$state_file" || rc=$?
    stage_signal_end
    if [[ "$_DEPLOY_INTERRUPTED" == "1" ]]; then
        _deploy_write_result "$artifacts_dir" interrupted "signal_interrupt"
        stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "error" \
            "interrupted by a signal before the deploy finished" \
            "The release may or may not have been pushed; check the tag before retrying."
        return 1
    fi
    return "$rc"
}

# ADR-018 Pattern 1 (one-shot): guard → dry-run/deploy-release → done.
_deploy_agent_run_inner() {
    local stage_id="$1" state_file="$2"
    local artifacts_dir="${ZBUILD_ARTIFACT_DIR:-}"

    # Resolve inputs via ZBUILD_STAGE_INPUTS (ADR-055 §1) — one jq for both.
    declare -gA _DEPLOY_INPUTS=()
    local _k _v
    if [[ -n "${ZBUILD_STAGE_INPUTS:-}" && -f "${ZBUILD_STAGE_INPUTS:-}" ]]; then
        while IFS=$'\t' read -r _k _v; do
            [[ -n "$_k" ]] && _DEPLOY_INPUTS["$_k"]="$_v"
        done < <(jq -r '.inputs // {} | to_entries[] | select(.value|type=="string") | "\(.key)\t\(.value)"' \
            "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true)
    fi
    # The run's state directory: the index lives at <state>/stage-inputs/<stage>.json.
    local root=""
    [[ -n "${ZBUILD_STAGE_INPUTS:-}" ]] \
        && root="$(cd "$(dirname "$ZBUILD_STAGE_INPUTS")/.." 2>/dev/null && pwd -P || true)"
    local pr_url_in=""
    if ! pr_url_in="$(_deploy_input_path pr_url "$root")"; then
        error "deploy: input pr_url resolves outside the run's state directory — refusing it"
        emit_event "deploy.input.refused" "plugin=deploy" "input=pr_url"
        _deploy_write_result "$artifacts_dir" broken \
            "input pr_url resolves outside the run's state directory"
        stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "error" \
            "refused input pr_url: it points outside this run" \
            "The engine's input index only points inside the run; this is a defect, not a deploy failure."
        return 1
    fi

    # Guard: pr_url input must exist (required input from pr-delivery stage)
    if [[ ! -f "$pr_url_in" ]]; then
        error "deploy: missing required input pr_url"
        emit_event "deploy.input.missing" "plugin=deploy" "input=pr_url"
        _deploy_write_result "$artifacts_dir" broken "missing pr_url input"
        stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "error" \
            "no pr_url input, so there was nothing to deploy" \
            "The pr-delivery stage produced no PR; no release was attempted."
        return 1
    fi

    local pr_url; pr_url="$(tr -d '[:space:]' < "$pr_url_in")"

    # Dry-run mode: write sentinel artifact without executing the release side-effect.
    # (checked BEFORE the gate guard so isolation/dry-run needs no gate result)
    if [[ "${ZBUILD_DRY_RUN:-0}" == "1" ]]; then
        _deploy_write_result "$artifacts_dir" pass \
            "dry run — no release side-effect was executed" "$pr_url" "" "dry_run" true
        stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "skip" \
            "dry run — no release side-effect was executed" \
            "Nothing was deployed. This verdict asserts nothing about a real deploy."
        return 0
    fi

    # Guard: did every loop that ran pass? FAIL-CLOSED (#757): the engine says
    # so (ZBUILD_RUN_LOOPS_PASSED, #2368). No word at all is refused — an absent
    # decision is not an approval to deploy; anything but "yes" skips.
    local gate_verdict="${ZBUILD_RUN_LOOPS_PASSED:-}"
    if [[ -z "$gate_verdict" ]]; then
        error "deploy: the engine has not said whether the run's loops passed — refusing deploy (fail-closed)"
        emit_event "deploy.gate.missing" "plugin=deploy"
        _deploy_write_result "$artifacts_dir" broken \
            "no word on whether the run's loops passed"
        stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "error" \
            "refused to deploy: the engine has not said whether the run's loops passed" \
            "Fail-closed. An absent decision is not an approval to deploy."
        return 1
    fi
    [[ "$gate_verdict" == "yes" ]] && gate_verdict="pass"
    if [[ "$gate_verdict" != "pass" ]]; then
        warn "deploy: the run's loops did not all pass (${gate_verdict:-not set}) — skipping deploy"
        emit_event "deploy.skipped" "plugin=deploy" "reason=gate_not_pass"
        _deploy_write_result "$artifacts_dir" pass \
            "nothing deployed: the run's loops did not all pass" "$pr_url" "" "" false
        stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "skip" \
            "skipped the deploy: the run's loops did not all pass" \
            "Nothing was deployed. Only an explicit pass authorises the release side-effect."
        return 0
    fi

    # Delegate to the deploy-release tool plugin (git tag + push). Always the
    # real plugin: its include guard is cleared first, so a preset
    # _ZBUILD_DEPLOY_RELEASE_LOADED cannot leave some other deploy_release_run in
    # place (review #2219).
    local release_plugin="$_DEPLOY_ROOT/plugins/tool/deploy-release/plugin.sh"
    if [[ ! -f "$release_plugin" ]]; then
        error "deploy: deploy-release plugin not found at: $release_plugin"
        _deploy_write_result "$artifacts_dir" broken \
            "deploy-release plugin missing"
        stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "error" \
            "the deploy-release plugin is missing, so nothing was deployed" \
            "This is an installation fault, not a pipeline one."
        return 1
    fi
    unset _ZBUILD_DEPLOY_RELEASE_LOADED
    # shellcheck source=../../tool/deploy-release/plugin.sh
    source "$release_plugin"

    local _rc=0
    deploy_release_run "$stage_id" "$state_file" || _rc=$?
    [[ "$_DEPLOY_INTERRUPTED" == "1" ]] && return 1
    local result="$artifacts_dir/deploy-result.json"
    if [[ "$_rc" -ne 0 ]]; then
        # deploy-release has already written its own result — `broken` for a tag
        # it could not create, `unavailable` for a push that did not land. That
        # word is what the engine must act on; overwriting it with a blanket
        # `unavailable` sent structural faults into the retry loop (review #2219).
        emit_event "deploy.tool.failed" "plugin=deploy" "rc=$_rc"
        local _d _r
        # deploy-release's own ending: its outcome.
        _d="$(jq -r '.outcome // empty' "$result" 2>/dev/null || true)"
        _r="$(jq -r '.reason // empty' "$result" 2>/dev/null || true)"
        if [[ -z "$_d" ]]; then
            _deploy_write_result "$artifacts_dir" broken \
                "deploy-release failed (rc=$_rc) without writing a result" "$pr_url"
            _d="broken"; _r="deploy-release wrote no result"
        fi
        stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "fail" \
            "the release step failed: ${_r:-rc=$_rc}" \
            "The gate authorised a deploy but the release did not complete (disposition: $_d). See the release step's summary."
        return 1
    fi

    local tag
    tag="$(jq -r '.data.tag // empty' "$result" 2>/dev/null || true)"
    _deploy_write_result "$artifacts_dir" pass \
        "deployed ${pr_url}" "$pr_url" "$tag" "" true
    stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "pass" \
        "deployed the change" \
        "$(printf -- '- pr: %s\n- tag: %s' "$pr_url" "${tag:-<none>}")"
    return 0
}

# ─── cleanup ─────────────────────────────────────────────────────────────────
