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

# Write a v2 result envelope to ZBUILD_ARTIFACT_DIR/deploy-result.json.
# Args: out_dir verdict disposition reason [pr_url] [tag] [mode]
# The data block is built in the same jq call (one fork per write), and the
# envelope reaches atomic_write through a here-string, not a pipe (SIGPIPE rule).
_deploy_write_result() {
    local out_dir="$1" verdict="$2" disposition="$3" reason="$4"
    local pr_url="${5:-}" tag="${6:-}" mode="${7:-}" env
    mkdir -p "$out_dir"
    env="$(jq -n --arg v "$verdict" --arg d "$disposition" --arg r "$reason" \
        --arg pr "$pr_url" --arg tag "$tag" --arg mode "$mode" \
        '{result_contract:2, verdict:$v, disposition:$d, reason:$r,
          data:({} + (if $pr != "" then {pr_url:$pr} else {} end)
                   + (if $tag != "" then {tag:$tag} else {} end)
                   + (if $mode != "" then {mode:$mode} else {} end))}')"
    atomic_write "$out_dir/deploy-result.json" <<< "$env"
}

# _deploy_input_path <id> <root> — the engine-resolved path of input <id>, or
# "" when it is not declared. rc 1 when the path lies OUTSIDE <root> (the run's
# state directory): the engine's index only ever points inside the run, so any
# other path is a defect or a forged index, and it is never opened (review #2219).
_deploy_input_path() {
    local id="$1" root="$2" p dir
    p="${_DEPLOY_INPUTS[$id]:-}"
    [[ -n "$p" ]] || return 0
    dir="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || { printf '%s' "$p"; return 0; }
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
        && _deploy_write_result "$ZBUILD_ARTIFACT_DIR" "error" "interrupted" "signal_interrupt"
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
    trap '_deploy_on_signal' TERM INT
    local rc=0
    _deploy_agent_run_inner "$stage_id" "$state_file" || rc=$?
    trap - TERM INT
    if [[ "$_DEPLOY_INTERRUPTED" == "1" ]]; then
        _deploy_write_result "$artifacts_dir" "error" "interrupted" "signal_interrupt"
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
    local pr_url_in="" gate_result_in="" _id _p
    for _id in pr_url gate_aggregator_result; do
        if ! _p="$(_deploy_input_path "$_id" "$root")"; then
            error "deploy: input $_id resolves outside the run's state directory — refusing it"
            emit_event "deploy.input.refused" "plugin=deploy" "input=$_id"
            _deploy_write_result "$artifacts_dir" "error" "broken" \
                "input $_id resolves outside the run's state directory"
            stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "error" \
                "refused input $_id: it points outside this run" \
                "The engine's input index only points inside the run; this is a defect, not a deploy failure."
            return 1
        fi
        case "$_id" in pr_url) pr_url_in="$_p" ;; *) gate_result_in="$_p" ;; esac
    done

    # Guard: pr_url input must exist (required input from pr-delivery stage)
    if [[ ! -f "$pr_url_in" ]]; then
        error "deploy: missing required input pr_url"
        emit_event "deploy.input.missing" "plugin=deploy" "input=pr_url"
        _deploy_write_result "$artifacts_dir" "error" "broken" "missing pr_url input"
        stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "error" \
            "no pr_url input, so there was nothing to deploy" \
            "The pr-delivery stage produced no PR; no release was attempted."
        return 1
    fi

    local pr_url; pr_url="$(tr -d '[:space:]' < "$pr_url_in")"

    # Dry-run mode: write sentinel artifact without executing the release side-effect.
    # (checked BEFORE the gate guard so isolation/dry-run needs no gate result)
    if [[ "${ZBUILD_DRY_RUN:-0}" == "1" ]]; then
        _deploy_write_result "$artifacts_dir" "deployed" "complete" \
            "dry run — no release side-effect was executed" "$pr_url" "" "dry_run"
        stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "skip" \
            "dry run — no release side-effect was executed" \
            "Nothing was deployed. This verdict asserts nothing about a real deploy."
        return 0
    fi

    # Guard: gate-aggregator verdict — FAIL-CLOSED. The deploy side-effect must not
    # run without a gate decision: a MISSING gate result is refused, not silently
    # skipped (#757 review finding — gate bypass). (When wired in #1328 the gate is a
    # required upstream input; here we enforce its presence at runtime, outside dry-run.)
    if [[ ! -f "$gate_result_in" ]]; then
        error "deploy: gate-aggregator result missing — refusing deploy (fail-closed)"
        emit_event "deploy.gate.missing" "plugin=deploy"
        _deploy_write_result "$artifacts_dir" "error" "broken" \
            "gate-aggregator-result missing"
        stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "error" \
            "refused to deploy: no gate-aggregator verdict was present" \
            "Fail-closed. An absent gate decision is not an approval to deploy."
        return 1
    fi

    local gate_verdict
    gate_verdict="$(jq -r '.verdict // empty' "$gate_result_in" 2>/dev/null || true)"

    # Fail-closed ALLOWLIST: proceed ONLY on an explicit pass. Any other verdict —
    # fail, route_<target>, an empty verdict, or a jq parse error (→ empty) — skips
    # the deploy side-effect rather than proceeding (#757 review / Copilot: a
    # skip-only-on-fail denylist would let route_design or a malformed gate proceed).
    if [[ "$gate_verdict" != "pass" ]]; then
        warn "deploy: gate-aggregator verdict='${gate_verdict:-<none>}' is not pass — skipping deploy"
        emit_event "deploy.skipped" "plugin=deploy" "reason=gate_not_pass"
        _deploy_write_result "$artifacts_dir" "skipped" "complete" \
            "gate-aggregator verdict not pass: ${gate_verdict:-<none>}" "$pr_url"
        stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "skip" \
            "skipped the deploy: the gate verdict was ${gate_verdict:-<none>}, not pass" \
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
        _deploy_write_result "$artifacts_dir" "error" "broken" \
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
        _d="$(jq -r '.disposition // empty' "$result" 2>/dev/null || true)"
        _r="$(jq -r '.reason // empty' "$result" 2>/dev/null || true)"
        if [[ -z "$_d" ]]; then
            _deploy_write_result "$artifacts_dir" "error" "broken" \
                "deploy-release failed (rc=$_rc) without writing a result" "$pr_url"
            _d="broken"; _r="deploy-release wrote no result"
        fi
        stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "fail" \
            "the release step failed: ${_r:-rc=$_rc}" \
            "The gate authorised a deploy but the release did not complete (disposition: $_d). See deploy-release-summary.md."
        return 1
    fi

    local tag
    tag="$(jq -r '.data.tag // empty' "$result" 2>/dev/null || true)"
    _deploy_write_result "$artifacts_dir" "deployed" "complete" \
        "deployed ${pr_url}" "$pr_url" "$tag"
    stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "pass" \
        "deployed the change" \
        "$(printf -- '- pr: %s\n- tag: %s' "$pr_url" "${tag:-<none>}")"
    return 0
}

# ─── cleanup ─────────────────────────────────────────────────────────────────
