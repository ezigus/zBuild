#!/usr/bin/env bash
# plugins/agent/review-lens — ONE advisory review lens as an isolated LLM stage.
#
# ADR-040 §3 (EPIC #1129 C1). Each advisory lens becomes its own first-class
# `kind: agent` stage so lenses are add/subtract-able and run as members of the
# ADR-039 `aggregate: advisory` parallel group. This evolves ADR-038's hand-rolled
# single-stage fan-out into composable lens stages while preserving its core
# discipline: ONE isolated LLM call per lens (ADR-038 §2 — not one prompt with N
# sections), fed redacted evidence through the ADR-004 chokepoint.
#
# Advisory only: a failed/unparseable lens degrades to an empty normalized result
# and the stage still returns 0 — a lens never blocks merge (ADR-040 §4).
#
# ADR refs: ADR-001 (plugin contract), ADR-003/017 (models-as-data, per-stage
#           tier), ADR-004 (redaction chokepoint), ADR-018 (JSON envelope),
#           ADR-038 (lens content + isolated-call), ADR-040 (lens taxonomy).

[[ -n "${_ZBUILD_REVIEW_LENS_LOADED:-}" ]] && return 0
_ZBUILD_REVIEW_LENS_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_RL_DIR="$_ZBUILD_PLUGIN_DIR"
_RL_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_RL_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_RL_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_RL_ROOT/core/router/route.sh"
# #721: strip stage-io banners and ANSI from input before the LLM prompt.
# shellcheck source=../../../scripts/lib/test-output-sanitize.sh
source "$_RL_ROOT/scripts/lib/test-output-sanitize.sh"
# shellcheck source=lib/charters.sh
source "$_RL_DIR/lib/charters.sh"

# ─── _review_lens_id ─────────────────────────────────────────────────────────
# Resolve the lens identity: explicit override, else the running stage id, else
# the manifest default. A leading "lens-"/"lens_"/"review-lens-" prefix on a
# stage id is stripped so a stage `lens_security` maps to the `security` charter.
_review_lens_id() {
    local lens="${ZBUILD_REVIEW_LENS_ID:-${ZBUILD_CURRENT_STAGE:-}}"
    lens="${lens#review-lens-}"; lens="${lens#lens-}"; lens="${lens#lens_}"
    printf '%s' "$lens"
}

# ─── _review_lens_evidence_path <lens> <artifact_dir> ───────────────────────
# Pick the lens's preferred mechanical evidence artifact (ADR-038 §2: a lens
# reads a *different artifact*), falling back to the shared diff bundle. Returns
# a path that may not exist; the caller checks readability + redacts it.
_review_lens_evidence_path() {
    local lens="$1" artifact_dir="$2" candidate
    case "$lens" in
        design-conformance) candidate="$artifact_dir/reachability-ablation.json" ;;
        test-coverage)      candidate="$artifact_dir/coverage-map.json" ;;
        architecture|correctness) candidate="$artifact_dir/call-graph.json" ;;
        *)                  candidate="" ;;
    esac
    if [[ -n "$candidate" && -s "$candidate" ]]; then
        printf '%s' "$candidate"
    else
        printf '%s' "$artifact_dir/diff.patch"
    fi
}

# ─── _review_lens_empty <lens> <out> ────────────────────────────────────────
# Write the normalized empty result. Advisory degrade path — never fatal.
_review_lens_empty() {
    jq -nc --arg n "$1" '{schema_version:1, name:$n, score:0, findings:[]}' \
        | atomic_write "$2"
}

# ─── review_lens_init ────────────────────────────────────────────────────────
review_lens_init() {
    export ZBUILD_PLUGIN="review-lens"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=review-lens"
    return 0
}

# ─── review_lens_run ──────────────────────────────────────────────────────────
# Hook: review_lens_run(stage, state_file). Derives the lens id + artifact paths
# and delegates to the unit-testable inner function.
review_lens_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "review_lens_run: state_file argument required"
        return 2
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifact_dir="$state_dir/artifacts"
    mkdir -p "$artifact_dir"

    local lens; lens="$(_review_lens_id)"
    if [[ -z "$lens" ]]; then
        lens="${1#review-lens-}"; lens="${lens#lens-}"; lens="${lens#lens_}"
    fi
    [[ -n "$lens" ]] || lens="correctness"

    local evidence; evidence="$(_review_lens_evidence_path "$lens" "$artifact_dir")"
    _review_lens_run_inner \
        "$lens" \
        "$state_dir/scope-manifest.md" \
        "$evidence" \
        "$artifact_dir/lens-$lens.json" \
        "$artifact_dir"
}

# Inner implementation — unit-testable with explicit paths.
# Args: $1=lens  $2=scope_manifest  $3=evidence(file)  $4=out lens-<name>.json
#       $5=(optional) artifact dir for the intermediate redacted prompt
_review_lens_run_inner() {
    local lens="$1" scope_manifest="$2" evidence="$3" out="$4"
    local artifact_dir="${5:-$(dirname "$out")}"

    if [[ -z "$lens" || -z "$out" ]]; then
        error "_review_lens_run_inner: requires <lens> <scope_manifest> <evidence> <out>"
        return 2
    fi
    mkdir -p "$artifact_dir"

    # Resolve evidence; an absent/empty bundle yields a clean empty result.
    local evidence_content="(no change bundle available)"
    if [[ -s "$evidence" ]]; then
        # ─── Redaction chokepoint (ADR-004 — refuse to send raw text) ──────
        local redacted="$artifact_dir/lens-$lens-evidence.redacted.txt"
        if apply_scope_redaction "$evidence" "$redacted" "$scope_manifest" "" "0"; then
            evidence_content="$(cat "$redacted")"
            # #721: strip OOS-marker tags + ANSI fragments from terminal capture.
            evidence_content="$(printf '%s' "$evidence_content" | _zbuild_sanitize_for_llm)"
        else
            emit_event "review_lens.redaction_failed" "lens=$lens"
            _review_lens_empty "$lens" "$out"
            emit_event "plugin.run.complete" "plugin=review-lens" "lens=$lens" "score=0"
            return 0
        fi
    fi

    # ─── Build the single-lens prompt ──────────────────────────────────────
    local prompt; prompt="$(_rl_build_lens_prompt "$lens" "$evidence_content")"

    # ─── ONE route_to_model call (ADR-017 per-stage tier; ADR-003 by tier) ──
    # ADR-018 Pattern 1: JSON envelope mode so reasoning turns don't leak as a
    # prose preamble that breaks the strict-JSON parse. Save/restore the env so
    # an outer caller's intent is preserved.
    local tier="${ZBUILD_REVIEW_LENS_TIER:-T2}"
    local raw_response="" router_rc=0
    local _prev_json_env="${ZBUILD_ROUTER_JSON_OUTPUT-__UNSET__}"
    local _prev_artifact_env="${ZBUILD_ROUTER_ARTIFACT_ID-__UNSET__}"
    export ZBUILD_ROUTER_JSON_OUTPUT=1
    export ZBUILD_ROUTER_ARTIFACT_ID="review-lens"
    raw_response="$(route_to_model "$tier" "$prompt")" || router_rc=$?
    if [[ "$_prev_json_env" == "__UNSET__" ]]; then
        unset ZBUILD_ROUTER_JSON_OUTPUT
    else
        export ZBUILD_ROUTER_JSON_OUTPUT="$_prev_json_env"
    fi
    if [[ "$_prev_artifact_env" == "__UNSET__" ]]; then
        unset ZBUILD_ROUTER_ARTIFACT_ID
    else
        export ZBUILD_ROUTER_ARTIFACT_ID="$_prev_artifact_env"
    fi

    # ─── Parse + normalize into {schema_version, name, score, findings[]} ───
    # A failed or unparseable lens degrades to empty (advisory — never fatal).
    if [[ $router_rc -ne 0 || -z "$raw_response" ]]; then
        emit_event "review_lens.failed" "lens=$lens" "router_rc=$router_rc"
        _review_lens_empty "$lens" "$out"
        emit_event "plugin.run.complete" "plugin=review-lens" "lens=$lens" "score=0"
        return 0
    fi

    local json
    json="$(printf '%s' "$raw_response" | extract_first_json_object 2>/dev/null || true)"
    if [[ -z "$json" ]] || ! printf '%s' "$json" | jq empty >/dev/null 2>&1; then
        emit_event "review_lens.unparseable" "lens=$lens"
        _review_lens_empty "$lens" "$out"
        emit_event "plugin.run.complete" "plugin=review-lens" "lens=$lens" "score=0"
        return 0
    fi

    # Coerce to the normalized shape; tolerate string or object findings.
    local normalized
    normalized="$(printf '%s' "$json" | jq -c --arg n "$lens" '
        {
          schema_version: 1,
          name: $n,
          score: ((.score // 0) | if type=="number" then floor else 0 end),
          findings: [ (.findings // [])[] |
            if type=="object" then {
              file: (.file // "unknown"),
              category: (.category // "general"),
              severity: (if (.severity|tostring|ascii_downcase) as $s
                         | ["low","medium","high","critical"] | index($s)
                         then (.severity|tostring|ascii_downcase) else "low" end),
              line: (.line // null),
              message: (.message // (.|tostring))
            } else {
              file: "unknown", category: "general", severity: "low",
              line: null, message: (.|tostring)
            } end ]
        }' 2>/dev/null || true)"
    if [[ -z "$normalized" ]]; then
        emit_event "review_lens.unparseable" "lens=$lens"
        _review_lens_empty "$lens" "$out"
        emit_event "plugin.run.complete" "plugin=review-lens" "lens=$lens" "score=0"
        return 0
    fi

    # Primary output (manifest provides.outputs, primary:true) is
    # lens-${ZBUILD_REVIEW_LENS_ID}.json — here "$out" resolves to
    # $artifact_dir/lens-$lens.json (same file; $lens is the resolved id). Written
    # atomically below to satisfy the #507 primary-output atomicity contract.
    printf '%s' "$normalized" | atomic_write "$out"
    local score findings_count
    score="$(printf '%s' "$normalized" | jq -r '.score // 0' 2>/dev/null || echo 0)"
    findings_count="$(printf '%s' "$normalized" | jq '.findings | length' 2>/dev/null || echo 0)"
    emit_event "plugin.run.complete" "plugin=review-lens" \
        "lens=$lens" "score=$score" "findings_count=$findings_count" \
        "router_rc=$router_rc"
    return 0
}

# ─── review_lens_finalize ──────────────────────────────────────────────────────
review_lens_finalize() {
    emit_event "plugin.finalize.complete" "plugin=review-lens"
    return 0
}

# ─── review_lens_cleanup ───────────────────────────────────────────────────────
review_lens_cleanup() {
    emit_event "plugin.cleanup.complete" "plugin=review-lens"
    return 0
}
