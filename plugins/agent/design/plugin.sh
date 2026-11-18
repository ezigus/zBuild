#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/design — Design stage agent (issue #754)                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Stage: design (ADR-013 T2, single-file artifact). One model call per run
# (ADR-068 §8): the engine re-runs the stage, never the stage itself.
# Produces: state/artifacts/design.md — its decisions and acceptance contract;
# it names no files (#2508, ADR-069 §11)
#
# Lifecycle:
#   design_stage_run         — derive paths, delegate to _design_stage_run_inner
#   _design_stage_run_inner  — one route_to_model call writes the working copy;
#                              a copy that passes design's checks becomes design.md
#   design_stage_cleanup     — no-op (the engine brackets the hook, #1705)
#
# legacy-citation: pipeline-stages-intake.sh:1004 (stage_design function)

[[ -n "${_ZBUILD_DESIGN_LOADED:-}" ]] && return 0
_ZBUILD_DESIGN_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/stage-summary.sh"
_DESIGN_DIR="$_ZBUILD_PLUGIN_DIR"
_DESIGN_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_DESIGN_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_DESIGN_ROOT/core/router/route.sh"
# shellcheck source=../../../core/output/stage-io.sh
source "$_DESIGN_ROOT/core/output/stage-io.sh"
# shellcheck source=../../../scripts/lib/prompt-overrides.sh
source "$_DESIGN_ROOT/scripts/lib/prompt-overrides.sh"
# shellcheck source=../../../scripts/lib/router-rc-classify.sh
source "$_DESIGN_ROOT/scripts/lib/router-rc-classify.sh"
# ADR-050 (#1581): unified prior-work seam — read prior design.md from an
# intra-cycle iter OR a prior run's restored/local artifact via one call.
# shellcheck source=../../../scripts/lib/prior-output-reader.sh
source "$_DESIGN_ROOT/scripts/lib/prior-output-reader.sh"
# Persona resolver + stage/lens composition seam (#1304, #1324).
# shellcheck source=../../../core/plugin-registry/registry.sh
source "$_DESIGN_ROOT/core/plugin-registry/registry.sh"
# ADR-059 §6 (#1930): one owner/repo derivation, shared with release-tarball.sh.
# shellcheck source=../../../scripts/lib/identity.sh
source "$_DESIGN_ROOT/scripts/lib/identity.sh"
# #963: read-only grammar lib from _ZBUILD_CONTRACT_LIB_DIR (self-host redirect).
# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_ZBUILD_CONTRACT_LIB_DIR/acceptance-block.sh"
# #2366: one outcome from the engine's list, through the one writer.
# shellcheck source=../../../scripts/lib/stage-result.sh
source "$_DESIGN_ROOT/scripts/lib/stage-result.sh"
# #2369: design checks its own design.md — by script, then by a second model call.
# shellcheck source=./lib/checks.sh
source "$_DESIGN_DIR/lib/checks.sh"
# shellcheck source=./lib/coverage.sh
source "$_DESIGN_DIR/lib/coverage.sh"
# shellcheck source=./lib/summary.sh
source "$_DESIGN_DIR/lib/summary.sh"
# shellcheck source=./lib/run.sh
source "$_DESIGN_DIR/lib/run.sh"
# #2364: earlier work is found by what it contains, never by which stage made it.
# shellcheck source=../../../scripts/lib/earlier-output.sh
source "$_DESIGN_ROOT/scripts/lib/earlier-output.sh"

# _design_write_outcome <artifact_dir> <outcome> <reason> [findings_json] [design]
# Writes design-verdict.json (#2366: one outcome from the engine's list).
# Called on every terminal exit path so the sidecar is always on disk. #2369:
# what design's checks still find is carried as numbered findings. [design] is
# the passing design it reports on (default: design.md).
# design's ANSWER lines from its last call (#2464), kept in its result.
_DESIGN_ANSWERS=()
_design_write_outcome() {
    local dir="$1" outcome="$2" reason="$3" findings="${4:-[]}" design="${5:-$1/design.md}"
    mkdir -p "$dir" 2>/dev/null || true
    # #2172: the design is stamped with WHEN and against WHICH commit it was
    # written, so a later run that inherits it can say what moved since. The
    # date is what the next run keys on — the work branch is rebased between
    # runs and old commits stop being reachable; a date survives that.
    local _at _sha
    _at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _sha="$(git -C "${ZBUILD_REPO_ROOT:-.}" rev-parse HEAD 2>/dev/null || true)"
    # #2189: the design REPORTS the files its contract wires, so the engine never
    # reads design.md by path to learn them.
    # Only a passing design is reported: on any other outcome design.md is the
    # last good design, not this run's.
    local _wiring="[]"
    if [[ "$outcome" == pass && -s "$design" ]] && declare -F acceptance_list_wiring >/dev/null 2>&1; then
        # Captured first: under pipefail a failing lister would otherwise append
        # a second '[]' to jq's and leave invalid JSON. `WIRING: none` is no file.
        local _wl; _wl="$(acceptance_list_wiring "$design" 2>/dev/null || true)"
        _wiring="$(jq -Rnc '[inputs | select(length > 0 and . != "none")] | unique' <<< "$_wl" 2>/dev/null || true)"
        [[ -n "$_wiring" ]] || _wiring="[]"
    fi
    # #2464 (ADR-068 §6): what design did about each finding it received.
    local _ans="[]"
    [[ ${#_DESIGN_ANSWERS[@]} -gt 0 ]] \
        && _ans="$(printf '%s\n' "${_DESIGN_ANSWERS[@]}" | jq -Rnc '[inputs | select(length > 0)]' 2>/dev/null || printf '[]')"
    local _data
    _data="$(jq -nc --arg at "$_at" --arg sha "$_sha" \
        --argjson w "${_wiring:-[]}" --argjson f "$findings" --argjson a "${_ans:-[]}" \
        --argjson fs "${_ZB_ANS_SHOWN:-0}" --arg un "${_ZB_ANS_MISSING:-}" \
        '{authored_at: $at, authored_at_commit: $sha, wiring_files: $w}
         + (if ($f | length) > 0 then {findings: $f} else {} end)
         + (if ($a | length) > 0 then {answers: $a} else {} end)
         + {findings_shown: $fs}
         + (if $un != "" then {unanswered: ($un | split("\n"))} else {} end)')"
    stage_result_write "$dir/design-verdict.json" "$outcome" "$reason" "$_data" 2>/dev/null \
        || warn "_design_write_outcome: failed to write design-verdict.json (outcome=$outcome)"
}

# ─── run ────────────────────────────────────────────────────────────────────
design_stage_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "design_stage_run: state_file argument required"
        stage_summary_write "${ZBUILD_ARTIFACT_DIR:+$ZBUILD_ARTIFACT_DIR/design-summary.md}" "design" "error" \
            "the engine dispatched this stage with no state file, so it could not run" \
            "No work was attempted. This is an engine contract violation, not a fault in the change."
        return 1
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifacts_dir="$state_dir/artifacts"
    mkdir -p "$artifacts_dir"

    # #2364: the scope manifest, found by what it contains among every earlier
    # output (ADR-055 §1). #2445: there is no plan stage; design writes the steps.
    local scope_manifest
    scope_manifest="$(earlier_scope_manifest "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"

    _design_stage_run_inner \
        "$scope_manifest" \
        "$artifacts_dir/design.md" \
        "$artifacts_dir"
}


# Design's prior design, to refine rather than re-create: its own latest
# design.md, whichever try or run wrote it — hydrate puts an earlier run's back
# in place (ADR-050, ADR-068 §8). _design_prior_design_path prints the path; the
# reader cats it.
_design_prior_design_path() {
    local own="${1:-}"
    [[ -n "$own" && -s "$own" ]] && printf '%s' "$own"
    return 0
}
_design_read_prior_design() {
    local f; f="$(_design_prior_design_path "${1:-}")"
    [[ -n "$f" ]] && cat "$f" 2>/dev/null
    return 0
}

# _design_one_line_specs_v <var> <design_text> — "- <id>" for each [code] or
# [done] SPEC of the design's acceptance block written on one line, with no
# parts under it (#2470). Read by the shell: the design is already in hand.
_design_one_line_specs_v() {
    local -n _dol="$1"; local _dol_l _dol_in=0 _dol_id="" _dol_re="^(${_ACCEPTANCE_ID_ERE})\\[(code|change|done|guard)\\]:"
    _dol=""
    while IFS= read -r _dol_l; do
        if (( ! _dol_in )); then [[ "$_dol_l" == '```acceptance'* ]] && _dol_in=1; continue; fi
        [[ "$_dol_l" == '```'* ]] && break
        [[ -n "$_dol_id" && "$_dol_l" =~ ^[[:space:]]+(Given|When|Then|And|Cleanup): ]] && { _dol_id=""; continue; }
        [[ -n "$_dol_id" ]] && _dol+="- $_dol_id"$'\n'
        _dol_id=""
        [[ "$_dol_l" =~ $_dol_re ]] && _dol_id="${BASH_REMATCH[1]}"
    done <<< "$2"
    [[ -n "$_dol_id" ]] && _dol+="- $_dol_id"$'\n'
    return 0
}

# _design_write_steps <design_md> <out_json> — the ```steps block as
# {title, steps:[{id, description, areas}]}. A design with no steps writes none
# (and removes an earlier one, so a stale list is never read as this design's).
# The steps are the code work (ADR-071 §1, 2026-11-14): design's check refuses a
# step on the test folders, which are test-author's.
_design_write_steps() {
    local design="$1" out="$2" line in_block=0 title
    local -a lines=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^'```steps'[[:space:]]*$ ]]; then in_block=1; continue; fi
        if [[ $in_block -eq 1 && "$line" =~ ^'```'[[:space:]]*$ ]]; then break; fi
        [[ $in_block -eq 1 ]] || continue
        if [[ "$line" =~ ^[[:space:]]*[-*0-9.]+[[:space:]]+(.*[^[:space:]]) ]]; then
            lines+=("${BASH_REMATCH[1]}")
        elif [[ -n "${line// }" && ${#lines[@]} -gt 0 ]]; then
            # #2460: a step whose words or areas carry on to the next line.
            local _c="${line#"${line%%[![:space:]]*}"}"
            lines[-1]+=" ${_c%"${_c##*[![:space:]]}"}"
        fi
    done < "$design"
    if [[ ${#lines[@]} -eq 0 ]]; then rm -f "$out" 2>/dev/null; return 0; fi
    title="$(grep -m1 -E '^# ' "$design" 2>/dev/null || true)"; title="${title#\# }"
    printf '%s\n' "${lines[@]}" | jq -Rsc --arg t "$title" '
        split("\n") | map(select(length > 0))
        | [.[] | split(" | areas:") as $p
            | {description: ($p[0] | gsub("^\\s+|\\s+$"; "")),
               areas: (($p[1] // "") | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))}]
        | {title: $t, steps: [to_entries[] | {id: "step-\(.key + 1)"} + .value]}' \
        | atomic_write "$out" || rm -f "$out" 2>/dev/null
    return 0
}

# _design_show <design> — one block of the stage's log holding the design the
# call wrote (stage-io trims it for the terminal). Best-effort: the log never
# changes the stage's fate.
_design_show() {
    local _st="${ZBUILD_CURRENT_STAGE:-design}"
    declare -F stage_io_begin >/dev/null 2>&1 || return 0
    stage_io_begin --stage "$_st" --kind computed \
        --input "the design this call wrote: $1" >/dev/null 2>&1 || return 0
    stage_io_end --stage "$_st" --kind computed --seq "${_STAGE_IO_LAST_SEQ:-}" \
        --output "$(cat "$1" 2>/dev/null)" >/dev/null 2>&1 || true
}

# _design_no_design <artifact_dir> <router_rc> <design_md> — the model call
# left no design to check. The call's rc says why (shared mapping, #2225);
# a call that ended normally and wrote nothing is `unusable`. design.md is
# untouched: it stays the last good design.
_design_no_design() {
    local artifact_dir="$1" rc="$2" design_md="$3" _rv="" _rr="" disp="unusable" reason="missing_design_md" head
    if [[ "$rc" -ne 0 ]]; then
        _router_rc_classify "$rc" _rv _rr
        reason="${_rr:-router_rc_nonzero}"
        disp="$(router_reason_disposition "$reason")"
        [[ -n "$disp" ]] || disp="unavailable"
    fi
    case "$disp" in
        timed_out)    head="Design ran out of time before writing a design." ;;
        out_of_turns) head="Design ran out of turns before writing a design." ;;
        rate_limited) head="the model call was rate-limited" ;;
        *)            head="no design was written ($reason)" ;;
    esac
    error "_design_stage_run_inner: $head"
    _design_write_outcome "$artifact_dir" "$disp" "$reason"
    stage_summary_write "$artifact_dir/design-summary.md" "design" "error" "$head" \
        "$(if [[ -s "$design_md" ]]; then printf 'design.md is unchanged: it stays the last good design.'; else printf 'There is no design yet.'; fi)"
    emit_event "plugin.result" "outcome=$disp" "plugin=design" "reason=$reason" "rc=$rc"
}

# ─── cleanup ────────────────────────────────────────────────────────────────
