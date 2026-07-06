#!/usr/bin/env bash
# core/pipeline/verdict.sh — verdict-driven stage indicator resolver (issue #507).
#
# Resolves a stage's verdict by reading the plugin's manifest-declared
# primary output artifact. Used by runner.sh to choose the glyph + color
# of the per-stage indicator line (was: hardcoded green ✓ for every rc=0
# stage; now reflects the plugin's actual verdict).
#
# Verdict table (PINNED — see ADR-019 / ADR-020 amendment):
#   pass, approve                                 → ✓ GREEN
#   request_changes                               → ⚠ YELLOW
#   fail, error, block, scope_violation,
#   corrupt_diff                                  → ✗ RED
#   missing/malformed on declared-primary         → ⚠ YELLOW + stage.verdict.missing
#   rc != 0 (any cause)                           → ✗ RED  (rc always wins)
#
# Public API:
#   runner_read_stage_verdict <state_dir> <manifest_path> <stage> <rc>
#       echoes one of: pass | warn | fail | unknown
#         OR (#550 structural-failure pass-through): error | corrupt_diff | block
#       The structural-failure raw verdicts bypass classification so the
#       cycle blocked predicate can distinguish them from generic "fail".
#       side-effects: may emit stage.verdict.missing event
#
#   verdict_glyph <verdict_class>     → ✓ | ⚠ | ✗
#   verdict_color <verdict_class>     → ANSI escape (or empty if NO_COLOR)
#
# Bash 5+. Sourced library; do not add set -euo pipefail.

[[ -n "${_ZBUILD_VERDICT_LOADED:-}" ]] && return 0
_ZBUILD_VERDICT_LOADED=1

_ZBUILD_VERDICT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_VERDICT_ROOT="$(cd "$_ZBUILD_VERDICT_DIR/../.." && pwd)"

# Defensive sources so the file is usable in isolation (unit tests).
if ! declare -F eb_emit_event >/dev/null 2>&1; then
    # shellcheck source=../event-bus/event-bus.sh
    source "$_ZBUILD_VERDICT_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
fi
if [[ -z "${GREEN:-}${YELLOW:-}${RED:-}" ]]; then
    # shellcheck source=../../scripts/lib/helpers.sh
    source "$_ZBUILD_VERDICT_ROOT/scripts/lib/helpers.sh" 2>/dev/null || true
fi

# ─── verdict_classify <raw_verdict> → pass|warn|fail|unknown ──────────────────
# Maps a raw verdict string (from a plugin's primary-output JSON) into one of
# four indicator classes per the verdict table above.
verdict_classify() {
    local raw="${1:-}"
    case "$raw" in
        pass|approve)
            echo "pass" ;;
        # #775: `incomplete` is impact's "cycle has not converged yet" verdict
        # (analogous to review's `request_changes`) — iterating, not done.
        # Maps to warn, not fail. Without this, every impact-incomplete fired
        # a `pipeline.indicator.unknown_verdict` event 1× per iter.
        # #1208: `did_not_finish` is build's mid-flight verdict (router_timeout /
        # error). Non-terminal (iterating, not done, not a structural fail) → warn.
        # It is deliberately NOT in the structural-failure pass-through set
        # (error/corrupt_diff/block) so _cycle_detect_blocked never halts on it —
        # a timeout iterates, it does not block the cycle.
        request_changes|incomplete|did_not_finish)
            echo "warn" ;;
        fail|error|block|scope_violation|corrupt_diff|empty_diff|scope_too_large)
            echo "fail" ;;
        # #1219 (ADR-045): a gate-aggregator route verdict (route_design, or any
        # future route_<target>) is a NON-pass, non-convergent outcome — classify
        # it as fail so the indicator/glyph is ✗ (not an unknown_verdict warn).
        # The cycle predicates read the RAW channel, so this is purely cosmetic;
        # route_<target> stays distinct from plain `fail` in the raw verdict.
        route_*)
            echo "fail" ;;
        ""|null)
            echo "unknown" ;;
        *)
            echo "unknown" ;;
    esac
}

# ─── verdict_glyph <class> ─────────────────────────────────────────────────────
verdict_glyph() {
    case "${1:-}" in
        pass)  echo "✓" ;;
        warn)  echo "⚠" ;;
        fail)  echo "✗" ;;
        *)     echo "⚠" ;;
    esac
}

# ─── verdict_color <class> ─────────────────────────────────────────────────────
verdict_color() {
    case "${1:-}" in
        pass)  printf '%s' "${GREEN:-}" ;;
        warn)  printf '%s' "${YELLOW:-}" ;;
        fail)  printf '%s' "${RED:-}" ;;
        *)     printf '%s' "${YELLOW:-}" ;;
    esac
}

# ─── _verdict_primary_output_path <manifest> ──────────────────────────────────
# Returns the path: value of the FIRST outputs[] entry marked `primary: true`.
# Empty string if none. Mirrors the awk in contracts.sh but scoped to the
# primary-flagged row.
_verdict_primary_output_path() {
    local manifest="$1"
    [[ -f "$manifest" ]] || return 0
    awk '
        BEGIN { in_out=0; cur_path=""; cur_primary=""; emitted=0 }
        /^outputs:/ { in_out=1; next }
        in_out && /^[a-zA-Z_]/ { in_out=0 }
        in_out && /^[[:space:]]*-[[:space:]]*id:/ {
            # New entry — if previous one was primary, emit and exit.
            # #550: set emitted=1 BEFORE exit so the END block does not
            # double-print (awk runs END even after exit).
            if (cur_primary == "true" && cur_path != "") {
                print cur_path; emitted=1; exit
            }
            cur_path=""; cur_primary=""
            next
        }
        in_out && /^[[:space:]]+path:/ {
            line=$0
            sub(/^[[:space:]]+path:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            gsub(/[[:space:]]*$/, "", line)
            cur_path=line; next
        }
        in_out && /^[[:space:]]+primary:/ {
            line=$0
            sub(/^[[:space:]]+primary:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            gsub(/[[:space:]]*$/, "", line)
            cur_primary=line; next
        }
        END {
            if (!emitted && cur_primary == "true" && cur_path != "") print cur_path
        }
    ' "$manifest" 2>/dev/null
}

# ─── _verdict_resolve_path <raw_path> <state_dir> ─────────────────────────────
# Expands ${state_dir} / ${artifact_dir} / ${artifacts_dir} placeholders and
# anchors relative paths under state_dir.
_verdict_resolve_path() {
    local raw="$1" state_dir="$2"
    local artifact_dir="${state_dir}/artifacts"
    local p="$raw"
    p="${p//\$\{state_dir\}/$state_dir}"
    p="${p//\$\{artifact_dir\}/$artifact_dir}"
    p="${p//\$\{artifacts_dir\}/$artifact_dir}"
    if [[ "$p" != /* ]]; then
        p="$state_dir/$p"
    fi
    printf '%s' "$p"
}

# ─── _verdict_extract_from_build_summary ──────────────────────────────────────
# Build plugin emits .verdict (added in #507) but legacy artifacts may carry
# only .scope_violation. Derive the verdict string for the indicator:
#   .verdict present  → use as-is
#   .scope_violation==true → "scope_violation"
#   else → "pass"
_verdict_extract_from_build_summary() {
    local path="$1"
    local v sv
    v="$(jq -r '.verdict // empty' "$path" 2>/dev/null || true)"
    if [[ -n "$v" && "$v" != "null" ]]; then
        printf '%s' "$v"; return 0
    fi
    sv="$(jq -r '.scope_violation // empty' "$path" 2>/dev/null || true)"
    if [[ "$sv" == "true" ]]; then
        printf 'scope_violation'
    else
        printf 'pass'
    fi
}

# ─── _verdict_read_design_sidecar <state_dir> ─────────────────────────────────
# #1261: design's PRIMARY output is design.md (non-JSON → presence==pass), so a
# router-timeout mid-flight verdict cannot travel on the primary artifact. The
# design plugin instead writes a `design-verdict.json` sidecar (mirroring build's
# #1208 build-summary verdict) carrying {verdict:did_not_finish}. Returns the
# sidecar's .verdict (empty when absent/malformed). Cleared by design at the
# start of every run, so a present sidecar always reflects THIS run's timeout.
_verdict_read_design_sidecar() {
    local state_dir="$1"
    local sc; sc="$(_verdict_resolve_path '${artifact_dir}/design-verdict.json' "$state_dir")"
    [[ -s "$sc" ]] || return 0
    jq empty "$sc" >/dev/null 2>&1 || return 0
    jq -r '.verdict // empty' "$sc" 2>/dev/null || true
}

# ─── runner_read_stage_verdict <state_dir> <manifest> <stage> <rc> ───────────
# Returns the verdict class. Side-effect: emits stage.verdict.missing when a
# manifest declares a primary output but the artifact is missing/malformed.
runner_read_stage_verdict() {
    local state_dir="$1" manifest="$2" stage="$3" rc="$4"

    # rc always wins.
    if [[ "$rc" -ne 0 ]]; then
        echo "fail"; return 0
    fi

    # #1261: design's router-timeout did_not_finish verdict rides a JSON sidecar
    # (its primary design.md is non-JSON → presence==pass and cannot carry it).
    # Honor it before the primary-artifact read so the indicator + cycle see the
    # timeout honestly. did_not_finish → warn (non-terminal; the cycle keys on
    # the RAW channel below for its exhaustion halt).
    if [[ "$stage" == "design" ]]; then
        local _dv; _dv="$(_verdict_read_design_sidecar "$state_dir")"
        if [[ -n "$_dv" ]]; then verdict_classify "$_dv"; return 0; fi
    fi

    # No manifest at all → contract-bypass path; caller decides indicator.
    if [[ -z "$manifest" || ! -f "$manifest" ]]; then
        echo "unknown"; return 0
    fi

    local prim_path
    prim_path="$(_verdict_primary_output_path "$manifest")"
    if [[ -z "$prim_path" ]]; then
        # No primary declared — fall back to pass for rc=0 (rc-fallback path).
        echo "pass"; return 0
    fi

    local resolved
    resolved="$(_verdict_resolve_path "$prim_path" "$state_dir")"

    if [[ ! -s "$resolved" ]]; then
        eb_emit_event "stage.verdict.missing" \
            "stage=$stage" "reason=artifact_absent" "path=$resolved" 2>/dev/null || true
        echo "warn"; return 0
    fi

    # Non-JSON primary (intake.md, pr-url.txt, scope-manifest.md, diff.patch):
    # presence == pass (rc-fallback semantics).
    case "$resolved" in
        *.json)
            ;;
        *)
            echo "pass"; return 0 ;;
    esac

    # Parse JSON; malformed → warn + event.
    if ! jq empty "$resolved" >/dev/null 2>&1; then
        eb_emit_event "stage.verdict.missing" \
            "stage=$stage" "reason=malformed_json" "path=$resolved" 2>/dev/null || true
        echo "warn"; return 0
    fi

    local raw_verdict=""
    case "$stage" in
        build)
            raw_verdict="$(_verdict_extract_from_build_summary "$resolved")" ;;
        security-lens)
            # ADR-019 informational role: findings.json present == pass.
            raw_verdict="pass" ;;
        *)
            raw_verdict="$(jq -r '.verdict // empty' "$resolved" 2>/dev/null || true)"
            # plan.json carries no .verdict — pass when artifact is well-formed.
            [[ -z "$raw_verdict" || "$raw_verdict" == "null" ]] && raw_verdict="pass"
            ;;
    esac

    local cls
    cls="$(verdict_classify "$raw_verdict")"
    # #550: preserve structural-failure raw verdicts so the cycle blocked
    # predicate (_cycle_detect_blocked) can distinguish them from generic
    # "fail" (which means "test ran and failed — keep iterating").
    # error/corrupt_diff/block all mean "stage could not complete its work"
    # and the cycle must abort early. Without this pass-through, verdict_classify
    # collapses all three to "fail" and _cycle_detect_blocked never fires.
    case "$raw_verdict" in
        error|corrupt_diff|block)
            echo "$raw_verdict"; return 0 ;;
    esac
    if [[ "$cls" == "unknown" ]]; then
        eb_emit_event "pipeline.indicator.unknown_verdict" \
            "stage=$stage" "raw_verdict=$raw_verdict" "path=$resolved" 2>/dev/null || true
        # Unknown verdict on a declared primary → warn (informational drift).
        echo "warn"; return 0
    fi
    echo "$cls"
}

# ─── runner_read_stage_verdict_raw <state_dir> <manifest> <stage> <rc> ───────
# Wave 19-A (#717): returns the RAW verdict string from the plugin's primary
# output JSON (e.g. "approve", "request_changes", "block", "pass"), without
# collapsing approve→pass / request_changes→warn.
#
# Why a sibling of runner_read_stage_verdict: the original function returns
# the CLASSIFIED verdict (pass|warn|fail|unknown + structural-failure
# pass-through) which is correct for the operator-facing indicator glyph,
# but the cycle orchestrator's exit_when/abort_when/until predicates compare
# against the RAW value declared in the template (e.g. `value: approve`).
# Without the raw read, exit_when on review.verdict==approve never matches
# because the dispatch blob stores "pass" not "approve" — the dogfood
# 20260605055348-2232 symptom: review approved, but pipeline ran to
# max_iterations instead of converging via exit_when.
#
# Side-effects: NONE here (no events). Callers are expected to ALSO call
# runner_read_stage_verdict in the same dispatch pass (which is what
# cycle_dispatch_stage at runner.sh:~1115 does today: populates
# _CYCLE_DISPATCH_VERDICT via the classified call AND
# _CYCLE_DISPATCH_VERDICT_RAW via this raw call). That ordering ensures
# diagnostic events (stage.verdict.missing, pipeline.indicator.unknown_verdict)
# fire exactly once for the artifact — emitting them here too would double-
# count.
# ─── runner_read_stage_reason <state_dir> <manifest> <stage> <rc> ───────────
# ADR-029 G2 (#810): when a stage produced verdict=error, return the .reason
# string from its primary output JSON. Used by the cycle orchestrator's
# G2 fast-abandon: a reason of `router_timeout` / `router_oom_kill` from
# `_router_rc_classify` is the signal that this dispatch was infra-failed
# (not a recoverable model error).
#
# Side-effects: NONE here. No events emitted; the classified verdict reader
# already covered diagnostic events for this dispatch pass.
runner_read_stage_reason() {
    local state_dir="$1" manifest="$2" stage="$3" rc="$4"
    if [[ "$rc" -ne 0 ]]; then echo ""; return 0; fi
    if [[ -z "$manifest" || ! -f "$manifest" ]]; then echo ""; return 0; fi
    local prim_path resolved
    prim_path="$(_verdict_primary_output_path "$manifest")"
    [[ -z "$prim_path" ]] && { echo ""; return 0; }
    resolved="$(_verdict_resolve_path "$prim_path" "$state_dir")"
    [[ ! -s "$resolved" ]] && { echo ""; return 0; }
    case "$resolved" in
        *.json) ;;
        *)      echo ""; return 0 ;;
    esac
    jq empty "$resolved" >/dev/null 2>&1 || { echo ""; return 0; }
    jq -r '.reason // empty' "$resolved" 2>/dev/null || echo ""
}

runner_read_stage_verdict_raw() {
    local state_dir="$1" manifest="$2" stage="$3" rc="$4"

    # rc != 0 → no verdict semantics; mirror the classified path's "fail"
    # so cycle predicates evaluating `verdict == fail` still match.
    if [[ "$rc" -ne 0 ]]; then
        echo "fail"; return 0
    fi

    # #1261: design's router-timeout did_not_finish RAW verdict rides a JSON
    # sidecar (design.md is non-JSON → would read "pass"). The cycle orchestrator
    # reads THIS raw channel for its reason-aware exhaustion halt, so surfacing
    # did_not_finish here is what makes a persistent design timeout HALT the
    # pipeline instead of falling through to build with an empty design.
    if [[ "$stage" == "design" ]]; then
        local _dv; _dv="$(_verdict_read_design_sidecar "$state_dir")"
        if [[ -n "$_dv" ]]; then printf '%s' "$_dv"; return 0; fi
    fi

    if [[ -z "$manifest" || ! -f "$manifest" ]]; then
        echo ""; return 0
    fi

    local prim_path
    prim_path="$(_verdict_primary_output_path "$manifest")"
    if [[ -z "$prim_path" ]]; then
        # No primary declared — rc-fallback semantics: pass.
        echo "pass"; return 0
    fi

    local resolved
    resolved="$(_verdict_resolve_path "$prim_path" "$state_dir")"

    if [[ ! -s "$resolved" ]]; then
        echo ""; return 0
    fi

    # Non-JSON primary: presence == pass (rc-fallback semantics).
    case "$resolved" in
        *.json) ;;
        *) echo "pass"; return 0 ;;
    esac

    if ! jq empty "$resolved" >/dev/null 2>&1; then
        echo ""; return 0
    fi

    local raw_verdict=""
    case "$stage" in
        build)
            raw_verdict="$(_verdict_extract_from_build_summary "$resolved")" ;;
        security-lens)
            raw_verdict="pass" ;;
        *)
            raw_verdict="$(jq -r '.verdict // empty' "$resolved" 2>/dev/null || true)"
            [[ -z "$raw_verdict" || "$raw_verdict" == "null" ]] && raw_verdict="pass"
            ;;
    esac
    printf '%s' "$raw_verdict"
}
