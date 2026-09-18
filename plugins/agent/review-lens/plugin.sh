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
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_RL_DIR="$_ZBUILD_PLUGIN_DIR"
_RL_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_RL_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_RL_ROOT/core/router/route.sh"
# ADR-028: shared LLM-agent framework (schema-gated reply parser, envelope parse).
# shellcheck source=../../../scripts/lib/llm-agent.sh
source "$_RL_ROOT/scripts/lib/llm-agent.sh"
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

# ─── _review_lens_envelope_schema_ok <json> ──────────────────────────────────
# Schema gate for _llm_envelope_parse: accepts an object with a .findings array.
# Mirrors _security_lens_envelope_schema_ok (ADR-028 §Migration, #2035).
_review_lens_envelope_schema_ok() {
    local _json="${1:-}"
    [[ -n "$_json" ]] || return 1
    printf '%s' "$_json" | jq -e '(type == "object") and (.findings | type == "array")' >/dev/null 2>&1
}

# ─── _review_lens_write_result <out> <verdict> <disposition> <reason> ────────
# Write a v2-compliant lens result file atomically. The output path is derived
# entirely from the $out parameter (no literal artifact filename strings inside).
# Called on every terminal exit path (degrade + success) so the file is always
# on disk — ADR-055 §3. Verdict appears here as a jq field, not a coercion token.
_review_lens_write_result() {
    local out="$1" verdict="$2" disposition="$3" reason="$4"
    local _base _name
    _base="$(basename "$out")"
    _name="${_base%.json}"; _name="${_name#lens-}"
    jq -nc \
        --arg n "$_name" \
        --arg v "$verdict" \
        --arg d "$disposition" \
        --arg r "$reason" \
        '{result_contract:2, schema_version:1, name:$n, score:0, findings:[], verdict:$v, disposition:$d, reason:$r}' \
        | atomic_write "$out" 2>/dev/null || true
}

# ─── _review_lens_interrupt_handler ──────────────────────────────────────────
# Trap handler for SIGTERM/SIGINT: write disposition:interrupted and propagate.
# Reads $_rl_out_ref (set by _review_lens_run_inner before trap registration)
# so it can be invoked directly in tests for SIGTERM simulation (SPEC-13).
_review_lens_interrupt_handler() {
    _review_lens_write_result "${_rl_out_ref:-}" "degraded" "interrupted" "signal_interrupt"
}

# ─── _review_lens_budget_guidance <max_turns> ────────────────────────────────
# TURN BUDGET block for the prompt (ADR-063 §1). Skipped when max_turns == 0.
_review_lens_budget_guidance() {
    local budget="${1:-}"
    [[ "$budget" =~ ^[0-9]+$ && "$budget" -gt 0 ]] || { printf ''; return 0; }
    cat <<EOF
TURN BUDGET (read this — you have a BOUNDED tool-call budget):
- You have about ${budget} tool-call turns to complete this lens review.
- A partial review with gaps named in prose BEATS exhausting the budget with no output.
- STOP if you are running low and emit your best-effort findings NOW.
EOF
}

# ─── _review_lens_wallclock_guidance <timeout_s> <elapsed_s> ─────────────────
# WALL CLOCK BUDGET block (ADR-063 §1). Skipped when timeout_s == 0.
_review_lens_wallclock_guidance() {
    local budget_s="${1:-}" elapsed_s="${2:-}"
    [[ "$budget_s" =~ ^[0-9]+$ && "$budget_s" -gt 0 ]] || { printf ''; return 0; }
    [[ "$elapsed_s" =~ ^[0-9]+$ ]] || elapsed_s=0
    [[ "$elapsed_s" -lt "$budget_s" ]] || { printf ''; return 0; }
    local _stop_at=$(( budget_s * 70 / 100 ))
    cat <<EOF
WALL CLOCK BUDGET (read this — the stage has a hard OS wall-clock timeout):
- This stage has a wall-clock budget of ${budget_s} seconds total; ~${elapsed_s}s have elapsed.
- Target emitting your best-effort findings before ~${_stop_at}s of wall-clock time.
EOF
}

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

# ─── _review_lens_empty <lens> <out> [<reason>] ─────────────────────────────
# Write the normalized empty result with v2 fields. Advisory degrade path — never fatal.
_review_lens_empty() {
    local _reason="${3:-degraded}"
    jq -nc --arg n "$1" --arg r "$_reason" \
        '{result_contract:2, schema_version:1, name:$n, score:0, findings:[], verdict:"degraded", disposition:"broken", reason:$r}' \
        | atomic_write "$2"
}

# ─── review_lens_run ──────────────────────────────────────────────────────────
# Hook: review_lens_run(stage, state_file). Derives the lens id + artifact paths
# and delegates to the unit-testable inner function.
review_lens_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "review_lens_run: state_file argument required"
        stage_summary_write "${ZBUILD_ARTIFACT_DIR:+$ZBUILD_ARTIFACT_DIR/lens-${ZBUILD_REVIEW_LENS_ID}-summary.md}" "review-lens" "error" \
            "the engine dispatched this stage with no state file, so it could not run" \
            "No work was attempted. This is an engine contract violation, not a fault in the change."
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
    local _rl_start_s="$SECONDS"

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

    # ─── ADR-063 §1: inject budget guidance before the model call ──────────
    local _budget_max_turns; _budget_max_turns="$(_route_resolve_max_turns)"
    local _budget_timeout_s; _budget_timeout_s="$(_route_resolve_timeout)"
    local _budget_elapsed_s=$(( SECONDS - _rl_start_s ))
    local _budget_block; _budget_block="$(_review_lens_budget_guidance "$_budget_max_turns")"
    if [[ -n "$_budget_block" ]]; then
        prompt+=$'\n\n'"$_budget_block"
    fi
    local _wallclock_block; _wallclock_block="$(_review_lens_wallclock_guidance "$_budget_timeout_s" "$_budget_elapsed_s")"
    if [[ -n "$_wallclock_block" ]]; then
        prompt+=$'\n\n'"$_wallclock_block"
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
    # ADR-063 §3: register interrupt handler so disposition:interrupted is written
    # if the model call is cut short by SIGTERM or SIGINT (SPEC-13).
    _rl_out_ref="$out"
    trap '_review_lens_interrupt_handler' TERM INT
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

    # rc=130 (SIGINT propagated through subshell) — distinct from advisory rc=0
    # degrade paths; write interrupted disposition and propagate the signal code.
    if [[ "$router_rc" -eq 130 ]]; then
        trap - TERM INT
        _review_lens_write_result "$out" "degraded" "interrupted" "signal_interrupt"
        return 130
    fi
    trap - TERM INT

    # rc=10 (budget/turn exhaustion — ADR-063 §3): distinct from advisory rc=0
    # degrade paths. Write disposition:exhausted and propagate rc=10 so the engine
    # can apply the §3 escalation (disposition.sh:97 → route.sh:749 +50% retry).
    if [[ "$router_rc" -eq 10 ]]; then
        _review_lens_write_result "$out" "degraded" "exhausted" "budget_exhausted"
        return 10
    fi

    # ─── Parse + normalize into {result_contract, schema_version, name, score, findings[]} ───
    # A failed or unparseable lens degrades to empty (advisory — never fatal).
    if [[ $router_rc -ne 0 || -z "$raw_response" ]]; then
        emit_event "review_lens.failed" "lens=$lens" "router_rc=$router_rc"
        _review_lens_write_result "$out" "degraded" "broken" "router_error"
        stage_summary_write "$artifact_dir/lens-${lens}-summary.md" "review-lens-${lens}" "skip" \
            "the model call failed, so this lens reviewed nothing" \
            "Advisory lens: no findings were produced. Absence here is not evidence of a clean change."
        emit_event "plugin.result" "plugin=review-lens" "lens=$lens" "score=0"
        return 0
    fi

    # ADR-028 §Migration (#2035): schema-gated envelope parser replaces bare
    # extract_first_json_object so postamble sign-offs don't discard the real answer.
    # shellcheck disable=SC2034  # prose is a required output-param of _llm_envelope_parse;
    # review-lens emits no prose sidecar (only impact does).
    local json prose
    _llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok "$raw_response" json prose
    if [[ -z "$json" ]] || ! printf '%s' "$json" | jq empty >/dev/null 2>&1; then
        emit_event "review_lens.unparseable" "lens=$lens"
        _review_lens_write_result "$out" "degraded" "broken" "unparseable_reply"
        stage_summary_write "$artifact_dir/lens-${lens}-summary.md" "review-lens-${lens}" "skip" \
            "the model returned unparseable JSON, so this lens reviewed nothing" \
            "Advisory lens: no findings were produced. Absence here is not evidence of a clean change."
        emit_event "plugin.result" "plugin=review-lens" "lens=$lens" "score=0"
        return 0
    fi

    # Coerce to the normalized shape; tolerate string or object findings.
    # v2 result fields (result_contract, verdict, disposition, reason) are embedded
    # in the primary output so the engine can read them from the declared primary
    # output without a separate sidecar (design decision #1840 — no sidecar).
    local normalized
    normalized="$(printf '%s' "$json" | jq -c --arg n "$lens" '
        {
          result_contract: 2,
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
            } end ],
          verdict: "complete",
          disposition: "complete",
          reason: "lens review complete"
        }' 2>/dev/null || true)"
    if [[ -z "$normalized" ]]; then
        emit_event "review_lens.unparseable" "lens=$lens"
        _review_lens_write_result "$out" "degraded" "broken" "normalization_failed"
        stage_summary_write "$artifact_dir/lens-${lens}-summary.md" "review-lens-${lens}" "skip" \
            "the lens response could not be normalised, so this lens reviewed nothing" \
            "Advisory lens: no findings were produced. Absence here is not evidence of a clean change."
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
    stage_summary_write "$artifact_dir/lens-${lens}-summary.md" "review-lens-${lens}" "pass" \
        "reviewed the change through the ${lens} lens — $findings_count finding(s), score $score" \
        "$(printf -- '- artifact: lens-%s.json' "${lens}")"
    emit_event "plugin.result" "plugin=review-lens" \
        "lens=$lens" "score=$score" "findings_count=$findings_count" \
        "router_rc=$router_rc"
    return 0
}

# ─── review_lens_cleanup ───────────────────────────────────────────────────────
