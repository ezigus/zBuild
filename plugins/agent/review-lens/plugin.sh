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
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_RL_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_RL_ROOT/core/router/route.sh"
# #896/#952: shared merge-base change-bundle resolver — the lens judges the same
# full-branch diff as `review`, not the (often empty) incremental build diff.patch.
# shellcheck source=../../../scripts/lib/merge-base.sh
source "$_RL_ROOT/scripts/lib/merge-base.sh"
# #721: strip stage-io banners and ANSI from input before the LLM prompt.
# shellcheck source=../../../scripts/lib/test-output-sanitize.sh
source "$_RL_ROOT/scripts/lib/test-output-sanitize.sh"
# ADR-050 (#1581): unified prior-work seam — seed from this lens's prior finding.
# shellcheck source=../../../scripts/lib/prior-output-reader.sh
source "$_RL_ROOT/scripts/lib/prior-output-reader.sh"
# registry.sh is idempotent (guard flag); makes resolve_persona_charter available
# when _rl_lens_charter is called. Established precedent: plan/plugin.sh:44.
# shellcheck source=../../../core/plugin-registry/registry.sh
source "$_RL_ROOT/core/plugin-registry/registry.sh"
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

# ─── _review_lens_evidence_path <lens> <artifact_dir> [<bundle_fallback>] ────
# Pick the lens's preferred mechanical evidence artifact (ADR-038 §2: a lens
# reads a *different artifact*), falling back to the shared change bundle. The
# fallback defaults to the full-branch merge-base bundle (resolved by the caller
# via zbuild_change_bundle, #896/#952) so a lens without a per-lens artifact
# judges the same basis as `review`; an empty <bundle_fallback> degrades to the
# incremental diff.patch. Returns a path that may not exist; the caller checks
# readability + redacts it.
_review_lens_evidence_path() {
    local lens="$1" artifact_dir="$2" bundle_fallback="${3:-}" candidate
    [[ -n "$bundle_fallback" ]] || bundle_fallback="$artifact_dir/diff.patch"
    case "$lens" in
        design-conformance) candidate="$artifact_dir/reachability-ablation.json" ;;
        test-coverage)      candidate="$artifact_dir/coverage-map.json" ;;
        architecture|correctness) candidate="$artifact_dir/call-graph.json" ;;
        *)                  candidate="" ;;
    esac
    if [[ -n "$candidate" && -s "$candidate" ]]; then
        printf '%s' "$candidate"
    else
        printf '%s' "$bundle_fallback"
    fi
}

# ─── _review_lens_empty <lens> <out> ────────────────────────────────────────
# Write the normalized empty result. Advisory degrade path — never fatal.
_review_lens_empty() {
    jq -nc --arg n "$1" '{schema_version:1, name:$n, score:0, findings:[]}' \
        | atomic_write "$2"
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

    # #896/#952: resolve the full-branch merge-base change bundle (falls back to
    # the incremental diff.patch when no base resolves) so a lens without a
    # per-lens artifact judges the same basis as `review`.
    local bundle; bundle="$(zbuild_change_bundle "$artifact_dir")"
    local evidence; evidence="$(_review_lens_evidence_path "$lens" "$artifact_dir" "$bundle")"
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
    # $2 (scope_manifest) is accepted for call-compat but no longer read: ADR-043
    # makes the router redact the assembled prompt by construction.
    local lens="$1" evidence="$3" out="$4"
    local artifact_dir="${5:-$(dirname "$out")}"

    if [[ -z "$lens" || -z "$out" ]]; then
        error "_review_lens_run_inner: requires <lens> <scope_manifest> <evidence> <out>"
        return 2
    fi
    mkdir -p "$artifact_dir"

    # Resolve evidence. ADR-043: the router redacts the assembled prompt by
    # construction, so we pass RAW evidence and ALWAYS route (the former
    # empty-evidence guard that skipped redaction — and thus tripped the router
    # C6 precondition on an empty change bundle, #952 — is gone).
    local evidence_content="(no change bundle available)"
    if [[ -s "$evidence" ]]; then
        # #721: strip OOS-marker tags + ANSI fragments from terminal capture.
        evidence_content="$(printf '%s' "$(cat "$evidence")" | _zbuild_sanitize_for_llm)"
    fi

    # ─── Build the single-lens prompt ──────────────────────────────────────
    local prompt; prompt="$(_rl_build_lens_prompt "$lens" "$evidence_content")"

    # ADR-050 (#1581): seed from THIS lens's prior-run finding (keyed on
    # lens-<id>.json) so a re-run's review references what the same lens flagged
    # before instead of starting blind. Advisory — re-judge against the CURRENT
    # diff; sanitized like the evidence. Gated on ZBUILD_RESTORED_ARTIFACTS_DIR so
    # it fires ONLY on a genuine cross-run restore (never this run's own lens output).
    local _prior_lens=""
    if [[ -n "${ZBUILD_RESTORED_ARTIFACTS_DIR:-}" ]]; then
        _prior_lens="$(_read_prior_output "lens-${lens}.json" 2>/dev/null || true)"
    fi
    if [[ -n "${_prior_lens//[[:space:]]/}" ]]; then
        _prior_lens="$(printf '%s' "$_prior_lens" | _zbuild_sanitize_for_llm)"
        prompt+=$'\n\n## PRIOR REVIEW (this lens on a previous attempt — reference; RE-JUDGE against the current diff)\n'
        prompt+="$_prior_lens"$'\n'
    fi

    # ─── ONE route_to_model call (ADR-017 per-stage tier; ADR-003 by tier) ──
    # ADR-018 Pattern 1: JSON envelope mode so reasoning turns don't leak as a
    # prose preamble that breaks the strict-JSON parse. Save/restore the env so
    # an outer caller's intent is preserved.
    local tier; tier="$(resolve_tier review-lens "$_RL_DIR")" || return 1
    local raw_response="" router_rc=0
    # #1577: probe resolve_persona_charter to set the #1567 carrier so INPUT
    # banners show the resolved lens persona id. Second call alongside the one
    # inside _rl_lens_charter; overhead is acceptable — mirrors the plan/build
    # pattern. The probe happens before the save window so the carrier var
    # shares the same save/restore block as ZBUILD_ROUTER_ARTIFACT_ID.
    local _rl_persona_applied=0 _rl_persona_probe
    if _rl_persona_probe="$(resolve_persona_charter "$lens" 2>/dev/null)" \
       && [[ -n "${_rl_persona_probe//[[:space:]]/}" ]]; then
        _rl_persona_applied=1
    fi
    local _prev_json_env="${ZBUILD_ROUTER_JSON_OUTPUT-__UNSET__}"
    local _prev_artifact_env="${ZBUILD_ROUTER_ARTIFACT_ID-__UNSET__}"
    local _prev_persona_env="${ZBUILD_STAGE_IO_PERSONA-__UNSET__}"
    export ZBUILD_ROUTER_JSON_OUTPUT=1
    export ZBUILD_ROUTER_ARTIFACT_ID="review-lens"
    if [[ "$_rl_persona_applied" -eq 1 ]]; then
        export ZBUILD_STAGE_IO_PERSONA="$lens"
    else
        export ZBUILD_STAGE_IO_PERSONA="$lens:fallback"
    fi
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
    if [[ "$_prev_persona_env" == "__UNSET__" ]]; then
        unset ZBUILD_STAGE_IO_PERSONA
    else
        export ZBUILD_STAGE_IO_PERSONA="$_prev_persona_env"
    fi

    # ─── Parse + normalize into {schema_version, name, score, findings[]} ───
    # A failed or unparseable lens degrades to empty (advisory — never fatal).
    if [[ $router_rc -ne 0 || -z "$raw_response" ]]; then
        emit_event "review_lens.failed" "lens=$lens" "router_rc=$router_rc"
        _review_lens_empty "$lens" "$out"
        emit_event "plugin.result" "plugin=review-lens" "lens=$lens" "score=0"
        return 0
    fi

    local json
    json="$(printf '%s' "$raw_response" | extract_first_json_object 2>/dev/null || true)"
    if [[ -z "$json" ]] || ! printf '%s' "$json" | jq empty >/dev/null 2>&1; then
        emit_event "review_lens.unparseable" "lens=$lens"
        _review_lens_empty "$lens" "$out"
        emit_event "plugin.result" "plugin=review-lens" "lens=$lens" "score=0"
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
        emit_event "plugin.result" "plugin=review-lens" "lens=$lens" "score=0"
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
    emit_event "plugin.result" "plugin=review-lens" \
        "lens=$lens" "score=$score" "findings_count=$findings_count" \
        "router_rc=$router_rc"
    return 0
}

# ─── review_lens_cleanup ───────────────────────────────────────────────────────
review_lens_cleanup() {
    emit_event "plugin.cleanup.complete" "plugin=review-lens"
    return 0
}
