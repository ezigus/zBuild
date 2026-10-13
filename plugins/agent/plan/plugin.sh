#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/plan — Plan stage agent (issue #340)                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Stage: plan (ADR-013, T2, blocking)
# Produces: state/artifacts/plan.json — an ordered list of work items (#2363)
#
# The model writes plan.json itself, and updates it as it goes; this stage then
# reads it from disk. A valid plan the model wrote counts even when its call
# was cut off.
#
# Lifecycle:
#   plan_run         — inputs from the engine's index (lib/entry.sh)
#   _plan_run_inner  — prompt → model call → read and check plan.json
#   plan_cleanup     — no-op (the engine brackets the hook, #1705), return 0

[[ -n "${_ZBUILD_PLAN_LOADED:-}" ]] && return 0
_ZBUILD_PLAN_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_PLAN_DIR="$_ZBUILD_PLUGIN_DIR"
_PLAN_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_PLAN_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_PLAN_ROOT/core/router/route.sh"
# #721: strip OOS-marker tags and ANSI from goal text before LLM prompt.
# shellcheck source=../../../scripts/lib/test-output-sanitize.sh
source "$_PLAN_ROOT/scripts/lib/test-output-sanitize.sh"
# Router rc → the one disposition word for a failed call (#2225).
# shellcheck source=../../../scripts/lib/router-rc-classify.sh
source "$_PLAN_ROOT/scripts/lib/router-rc-classify.sh"
# shellcheck source=../../../core/plugin-registry/registry.sh
source "$_PLAN_ROOT/core/plugin-registry/registry.sh"

# The stage's entry point, its inputs and its result writer (#1835) live in
# lib/entry.sh — plan_run is defined there.
# shellcheck source=lib/entry.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/entry.sh"

# _plan_is_valid <file> — rc 0 when <file> holds a plan: one object with
# schema_version 1 and at least one work item, each with an id and a
# description; areas and open_questions, when present, are lists of strings.
_plan_is_valid() {
    [[ -s "$1" ]] || return 1
    jq -e 'type == "object" and .schema_version == 1
        and (.steps | type == "array" and length > 0)
        and (.steps | all(type == "object"
                and (.id | type == "string" and length > 0)
                and (.description | type == "string" and length > 0)
                and ((.areas // []) | type == "array" and all(type == "string"))))
        and ((.open_questions // []) | type == "array" and all(type == "string"))' \
        "$1" >/dev/null 2>&1
}

# _plan_prompt <goal> <plan-path> — plan's own three parts: What you own, What
# you judge against, What you must not do.
_plan_prompt() {
    local goal="$1" plan_path="$2"
    cat <<PLAN_PROMPT
## What you own
Your job: split the issue into an ordered list of work items, the plan.json described below. Each item says what changes and why, in one or two sentences, and names the areas it touches. Do not say how: no function names, no code, no line counts. If your earlier plan is under Previous work, keep the items that still stand, and change or add an item for each open finding, in one sentence that names it. Do not read code to diagnose a finding.

Write the plan to this file, and update it as you go — a plan on disk when your
time runs out still counts:
  ${plan_path}

It is one JSON object in this shape:
{
  "schema_version": 1,
  "title": "<short title>",
  "goal": "<the goal in one line>",
  "steps": [
    {"id": "step-1", "description": "<what changes and why, in one or two sentences>", "areas": ["<a directory or file the issue names>"]}
  ],
  "open_questions": ["<one line: something the issue leaves unclear>"]
}
- \`steps\` is not empty; ids are "step-1", "step-2", … in order.
- Keep each item small enough to build and test on its own.
- \`open_questions\` holds only what the issue leaves unclear, one line each; it
  is empty when nothing is.

When the file is written, answer with one line saying how many work items it has.

## What you judge against
The issue below, in its own words.

A section of the issue that records a decision (for example "Decision:") is
binding: follow it. Anything else it proposes, such as an approach or a file
list, is a starting point: follow it unless it contradicts a decision.

If the issue has a "Definition of done", "Acceptance criteria", "Anti-patterns"
or "5-test trial" section, or a similar checklist:
1. Every Definition-of-done item is covered by at least one work item.
2. No work item does what an Anti-pattern names. If one seems to, you have
   misread the issue: add an open question instead.
3. Do not invent permissions the issue does not grant. Nothing is "optional",
   "gated by config" or a "future follow-up" unless the issue says so.
4. If the issue moves behaviour from one place to another, include the item that
   makes the running program use the new code, not only new files beside the old.

The issue:
${goal}

## What you must not do
- Do not write any file other than the plan above and your notes file.
PLAN_PROMPT
}

# Inner implementation — unit-testable with explicit paths.
# Args:
#   $1 = scope manifest path (kept for the entry's call; the prompt no longer
#        carries it — the work items name areas, not a scope)
#   $2 = goal text (raw string)
#   $3 = output plan.json path
#   $4 = artifact dir for intermediate files
_plan_run_inner() {
    local goal_text="$2"
    local output_plan_json="$3"
    local artifact_dir="${4:-$(dirname "$output_plan_json")}"

    if [[ -z "$goal_text" || -z "$output_plan_json" ]]; then
        error "_plan_run_inner: requires <scope_manifest> <goal_text> <output_plan_json> [artifact_dir]"
        return 1
    fi
    mkdir -p "$artifact_dir"

    # ADR-043: redaction is owned by the router (route_to_model) — it redacts the
    # assembled prompt by construction.
    local goal_content
    goal_content="$(printf '%s' "$goal_text" | _zbuild_sanitize_for_llm)"

    # ADR-067 §8: the stage's three parts and the engine's blocks, in the one
    # prompt order. Plan's own latest plan reaches it under Previous work.
    local prompt
    if ! prompt="$(stage_prompt_compose_parts "$(_plan_prompt "$goal_content" "$output_plan_json")")"; then
        error "plan_run: the prompt could not be composed — the engine's blocks are missing"
        return 1
    fi

    # What plan.json held before the call: a valid plan the call did not write
    # is not this call's work when the call failed.
    local before="absent" after="absent"
    [[ -e "$output_plan_json" ]] && before="$(cksum 2>/dev/null < "$output_plan_json" || printf 'unreadable')"

    local tier; tier="$(resolve_tier plan "$_PLAN_DIR")" || return 1
    local router_rc=0 _reply
    # #491: do NOT redirect route_to_model's stderr — the stage-io input banner
    # writes to fd 2. The reply is one line; the plan is the file.
    _reply="$(route_to_model "$tier" "$prompt")" || router_rc=$?

    [[ -e "$output_plan_json" ]] && after="$(cksum 2>/dev/null < "$output_plan_json" || printf 'unreadable')"
    local wrote=0; [[ "$after" != "absent" && "$after" != "$before" ]] && wrote=1

    # A valid plan counts when the call ended normally, or when this call wrote
    # it before it was cut off (#2363: a valid output wins even on failure).
    if _plan_is_valid "$output_plan_json" && { [[ $router_rc -eq 0 ]] || (( wrote )); }; then
        _plan_finish "$output_plan_json" "$artifact_dir"
        return
    fi

    local _reason="no_plan_written" _disp="unusable"
    if (( wrote )) || [[ $router_rc -eq 0 && "$after" != "absent" ]]; then
        _reason="schema_violation"
    fi
    if [[ $router_rc -ne 0 && "$_reason" == "no_plan_written" ]]; then
        # A failed router CALL is named by the shared mapping, never by this
        # plugin (#1835; #2225 "chosen once, not per plugin").
        local _rc_verdict="" _rc_reason="" _rc_disp=""
        _router_rc_classify "$router_rc" _rc_verdict _rc_reason
        _rc_disp="$(router_reason_disposition "${_rc_reason:-}")"
        if [[ -n "$_rc_disp" ]]; then
            _disp="$_rc_disp"
        else
            warn "plan: router_reason_disposition returned nothing for rc=$router_rc reason=${_rc_reason:-<none>} — recording 'unusable'"
        fi
    fi
    _plan_write_result "$output_plan_json" "error" "$_disp" "$_reason"
    error "_plan_run_inner: no valid plan.json (reason=$_reason, router_rc=$router_rc)"
    stage_summary_write "$artifact_dir/plan-summary.md" "plan" "error" \
        "no valid plan.json ($_reason)" \
        "The issue was not split into work items."
    emit_event "plugin.result" "verdict=error" "plugin=plan" "reason=$_reason"
    return 1
}

# _plan_finish <plan.json> <artifact_dir> — the plan with its result fields,
# and its summary.
_plan_finish() {
    local out="$1" artifact_dir="$2" n q v2
    n="$(jq '.steps | length' "$out" 2>/dev/null || echo 0)"
    q="$(jq '(.open_questions // []) | length' "$out" 2>/dev/null || echo 0)"
    # v2 contract (#1835): plan.json is the sole result file. Fields an earlier
    # plan carried that this one does not own are dropped.
    if ! v2="$(jq -c --arg r "plan has ${n} work item(s)" \
            'del(.scope_files) + {result_contract:2,verdict:"pass",disposition:"complete",reason:$r}' "$out")" \
        || ! atomic_write "$out" <<< "$v2"; then
        error "_plan_run_inner: could not write $out"
        return 1
    fi
    _PLAN_RESULT_WRITTEN=1
    # ADR-055 §9: state what this stage DID.
    stage_summary_write "$artifact_dir/plan-summary.md" "plan" "pass" \
        "split the issue into $n work item(s)" \
        "$(printf -- '- open questions: %s\n- artifact: plan.json' "$q")"
    emit_event "plugin.result" "stage=plan" "plugin=plan" "step_count=$n" "artifact=plan.json"
    return 0
}
