#!/usr/bin/env bash
# core/router/route.sh — ADR-003 model router stub (issue #84)
# Maps tier ordinals (T0-T4) to concrete models via config/models.json.
# Phase 0.5: picks candidates[0]; UCB1 bandit deferred to #29.
# Sourced by callers — no set -euo pipefail at file scope (would mutate caller options).

[[ -n "${_ZBUILD_ROUTER_LOADED:-}" ]] && return 0
_ZBUILD_ROUTER_LOADED=1

_ROUTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="$(cd "$_ROUTER_DIR/../.." && pwd)"

# ─── base-include guard (#1624) ──────────────────────────────────────────────
# route.sh is the base include for EVERY routing plugin, so one bad library here
# takes down all dispatch at once. One helper rather than nine inline copies, so
# the policy cannot drift between call sites.
#
# `exit`, not `return`: no caller checks `source route.sh`'s status (verified —
# all 8+ call sites are a bare `source`), so returning would let a plugin run on
# with the router half-loaded, which is the silent failure this issue exists to
# remove.
#
# Syntax is checked with `bash -n` rather than `source X || …`: source returns
# the LAST command's status, so a well-formed library ending in a merely-falsy
# statement would be misreported as broken. `bash -n` parses without executing.
#
# bash's own parse error carries the line and token; it is captured and FORWARDED
# rather than discarded. Sending it to /dev/null would name the broken file while
# deleting the only text saying what is broken about it — strictly worse for the
# operator than the unguarded original, on an issue whose whole point is
# diagnosability (PR #1651 review; the pattern #1631 exists to lint for).
_zbuild_route_require() {
    local _p="$1" _err
    [[ -f "$_p" ]] \
        || { printf 'zbuild: fatal: missing include: %s\n' "$_p" >&2; exit 1; }
    _err="$(bash -n "$_p" 2>&1)" \
        || { printf 'zbuild: fatal: broken include: %s\n%s\n' "$_p" "$_err" >&2; exit 1; }
}

_zbuild_route_require "$_ZBUILD_ROOT/scripts/lib/helpers.sh"
source "$_ZBUILD_ROOT/scripts/lib/helpers.sh"
_zbuild_route_require "$_ZBUILD_ROOT/core/event-bus/event-bus.sh"
source "$_ZBUILD_ROOT/core/event-bus/event-bus.sh"
# ADR-015 v1 (#438): stage-io chokepoint — capture LLM prompt/response when
# the current stage declares io.destinations. Sourced library is idempotent.
_zbuild_route_require "$_ZBUILD_ROOT/core/output/stage-io.sh"
source "$_ZBUILD_ROOT/core/output/stage-io.sh"
# ADR-024 / #671 (Wave 13-B): fresh-user-shell helper for the claude spawn
# subshells below (the 4 spawn sites in _route_call_claude + the loop).
_zbuild_route_require "$_ZBUILD_ROOT/scripts/lib/env-scrub.sh"
source "$_ZBUILD_ROOT/scripts/lib/env-scrub.sh"
# ADR-043 (redaction by construction): the router owns the redaction step, so
# apply_scope_redaction must be available BY CONSTRUCTION in the model-call
# path (single-shot + loop). Idempotent source; plugins that also source it
# hit the load guard. See _route_redact_prompt / _route_ensure_redaction.
_zbuild_route_require "$_ZBUILD_ROOT/core/redaction/scope-redaction.sh"
source "$_ZBUILD_ROOT/core/redaction/scope-redaction.sh"
# #1237: rate-limit detection + honest reporting. The claude CLI reports a
# rate/session limit as rc=1 with a misleading subtype:"success" envelope
# (is_error:true + api_error_status ∈ {429,529}). _router_is_rate_limit /
# _router_rate_limit_message let the router surface an honest disposition
# instead of the opaque "claude CLI failed (rc=1)". Idempotent source.
_zbuild_route_require "$_ZBUILD_ROOT/scripts/lib/router-rc-classify.sh"
source "$_ZBUILD_ROOT/scripts/lib/router-rc-classify.sh"
# #1231 (ADR-003): resolve_tier — manifest config.tier_default is the single
# source of truth for a plugin's tier (operator override ZBUILD_<ID>_TIER wins).
# Sourced here so every routing plugin (all source route.sh) gets it by
# construction, replacing the per-plugin hardcoded `${ZBUILD_<ID>_TIER:-Tn}`.
_zbuild_route_require "$_ZBUILD_ROOT/scripts/lib/tier-resolve.sh"
source "$_ZBUILD_ROOT/scripts/lib/tier-resolve.sh"
# ADR-051 (#1305): resolve_persona + persona_text — resolve a stage persona from
# the four-step precedence chain (env > template-stage > template-global > generic)
# with two-root discovery (installed tree + per-repo overlay). Sourced here so
# every routing plugin gets resolve_persona/persona_text by construction.
_zbuild_route_require "$_ZBUILD_ROOT/scripts/lib/persona-resolve.sh"
source "$_ZBUILD_ROOT/scripts/lib/persona-resolve.sh"
# VIS-C (ADR-049): vision-document loader/validator — guard-idempotent source.
# Loaded here so _route_redact_prompt (shared funnel for single-shot + loop)
# can inject the advisory Intent preamble into every stage prompt.
_zbuild_route_require "$_ZBUILD_ROOT/scripts/lib/vision.sh"
source "$_ZBUILD_ROOT/scripts/lib/vision.sh"

# route_to_model <tier> <prompt> [--skip-precondition] [--model <id>]
# Exit codes: 0=success, 1=recoverable, 2=fatal
#
# C6 precondition: most-recent event for the current (run_id, stage) must be
# `redaction.applied` — scoped per-stage so concurrent parallel-group members
# each enforce their own redaction (ADR-039 §3). See ARCHITECTURE.md §3 /
# ADR-004. `--skip-precondition` requires operator override
# (ZBUILD_SCOPE_OVERRIDE=1 + token file). ADR-001.
route_to_model() {
    if [[ $# -lt 2 ]]; then
        error "route_to_model requires <tier> <prompt>"
        return 2
    fi
    local tier="$1" prompt="$2"
    local skip_precondition=false model_override="" _prev_arg=""
    for arg in "${@:3}"; do
        [[ "$arg" == "--skip-precondition" ]] && skip_precondition=true
        [[ "${_prev_arg}" == "--model" ]] && model_override="$arg"
        _prev_arg="$arg"
    done

    if [[ ! "$tier" =~ ^T[0-4]$ ]]; then
        error "invalid tier '$tier' — must be T0-T4"; return 2
    fi
    if [[ "$tier" == "T0" ]]; then
        error "T0 (WASM) not implemented in Phase 0.5"; return 2
    fi

    # ADR-043 (redaction by construction): ensure the prompt is redacted BEFORE
    # the model call. If a plugin already redacted (its redaction.applied is the
    # most-recent event for this run/stage) we proceed unchanged; otherwise the
    # router redacts now and hands _route_call_claude the redacted text. On a
    # fail-closed refusal (missing/empty manifest, no override) this returns 2.
    _route_ensure_redaction "$tier" "$skip_precondition" "$prompt" || return $?
    prompt="$_ROUTE_REDACTED_PROMPT"
    _route_lookup_model "$tier" "$model_override"          || return $?

    # ADR-017 (#455): precedence-aware timeout resolution.
    # per-stage template router.timeout_s > ZBUILD_ROUTER_TIMEOUT env > 300s default.
    local secs; secs="$(_route_resolve_timeout)"
    if [[ ! "$secs" =~ ^[0-9]+$ ]] || [[ "$secs" -eq 0 ]]; then
        error "ZBUILD_ROUTER_TIMEOUT must be a positive integer (>=1), got: $secs"; return 2
    fi

    _route_emit_model_route "$tier" "$secs"
    _route_check_budget "$tier" || return $?

    # #481: split LLM-kind stage I/O so input banner emits BEFORE the LLM call
    # and output banner emits AFTER. The two halves are paired by reserved seq.
    # Capture failure must not fail the router — best-effort throughout.
    local _stage_io_seq=""
    local -a _capture_meta_extra=()
    if [[ -n "${ZBUILD_CURRENT_STAGE:-}" ]]; then
        if [[ -n "${ZBUILD_ROUTER_ARTIFACT_ID:-}" ]]; then
            _capture_meta_extra+=( --metadata "artifact=$ZBUILD_ROUTER_ARTIFACT_ID" )
        fi
        # Direct call (not $()) so begin's assoc-array state survives in
        # the caller's shell — $() in a subshell would lose the pending map.
        stage_io_begin \
            --stage "$ZBUILD_CURRENT_STAGE" \
            --kind llm \
            --input "$prompt" \
            --metadata "tier=$tier" \
            "${_capture_meta_extra[@]}" >/dev/null 2>&1 || true
        _stage_io_seq="$_STAGE_IO_LAST_SEQ"
    fi

    _ROUTE_RESPONSE=""
    local _call_rc=0
    _route_call_claude "$tier" "$prompt" "$secs" || _call_rc=$?
    if [[ "$_call_rc" -ne 0 ]]; then
        # On error, close the begin so it doesn't orphan into the EXIT trap.
        if [[ -n "$_stage_io_seq" ]]; then
            stage_io_end \
                --stage "$ZBUILD_CURRENT_STAGE" \
                --kind llm \
                --seq "$_stage_io_seq" \
                --output "${_ROUTE_RESPONSE:-}" \
                --metadata "model_id=$_ROUTE_MODEL_ID" \
                --metadata "error=true" \
                >/dev/null 2>&1 || true
        fi
        return "$_call_rc"
    fi

    _route_emit_outcome "$tier" "$secs"
    _route_update_ledger

    if [[ -n "$_stage_io_seq" ]]; then
        stage_io_end \
            --stage "$ZBUILD_CURRENT_STAGE" \
            --kind llm \
            --seq "$_stage_io_seq" \
            --output "$_ROUTE_RESPONSE" \
            --metadata "model_id=$_ROUTE_MODEL_ID" \
            --metadata "input_tokens=${_ROUTE_INPUT_TOKENS:-0}" \
            --metadata "output_tokens=${_ROUTE_OUTPUT_TOKENS:-0}" \
            --metadata "cache_read=${_ROUTE_CACHE_READ:-0}" \
            --metadata "cache_creation=${_ROUTE_CACHE_CREATION:-0}" \
            >/dev/null || true
    fi

    printf '%s\n' "$_ROUTE_RESPONSE"
    return 0
}

# route_to_model_cli <tier> <prompt> [extra route_to_model args...]
# Invoke the router from a STANDALONE CLI command (outside a pipeline run) with
# redaction-BY-CONSTRUCTION — never --skip-precondition, never a scope-override
# token. When already inside a run, pass through unchanged. Otherwise provision an
# EPHEMERAL run context (temp events log + a concrete-dirs scope manifest) so
# route_to_model's normal _route_ensure_redaction/_route_redact_prompt path does
# REAL redaction instead of the no-manifest passthrough, then tear it down.
route_to_model_cli() {
    if [[ $# -lt 2 ]]; then
        error "route_to_model_cli requires <tier> <prompt>"
        return 2
    fi
    local tier="$1" prompt="$2"
    shift 2

    # Already in a run → the runner has set the manifest/events; do not disturb.
    if [[ -n "${ZBUILD_RUN_ID:-}" && -n "${ZBUILD_EVENTS_JSONL:-}" ]]; then
        route_to_model "$tier" "$prompt" "$@"
        return $?
    fi

    # Standalone: build an ephemeral context. The concrete top-level dirs (NOT the
    # universal-allow `+ ./`) make apply_scope_redaction wrap out-of-scope paths
    # (e.g. /etc/passwd, absolute $HOME paths) while in-repo paths pass through.
    local _ev _man _rc=0
    _ev="$(mktemp "${TMPDIR:-/tmp}/zb-cli-events.XXXXXX")" || { error "route_to_model_cli: mktemp events failed"; return 2; }
    _man="$(mktemp "${TMPDIR:-/tmp}/zb-cli-scope.XXXXXX")" || { rm -f "$_ev"; error "route_to_model_cli: mktemp manifest failed"; return 2; }
    printf '+ core/\n+ scripts/\n+ plugins/\n+ tests/\n+ docs/\n+ config/\n' > "$_man"

    ZBUILD_RUN_ID="cli-$$" \
    ZBUILD_EVENTS_JSONL="$_ev" \
    ZBUILD_SCOPE_MANIFEST="$_man" \
        route_to_model "$tier" "$prompt" "$@" || _rc=$?

    rm -f "$_ev" "$_man"
    return "$_rc"
}

# ── Shared state set by helpers ──────────────────────────────────────────────
_ROUTE_MODEL_ID="" _ROUTE_PROVIDER="" _ROUTE_COST_IN="" _ROUTE_COST_OUT=""
_ROUTE_CACHE_ELIGIBLE="false" _ROUTE_OVERRIDE_SOURCE="" _ROUTE_RESPONSE=""
_ROUTE_INPUT_TOKENS=0 _ROUTE_OUTPUT_TOKENS=0
_ROUTE_CACHE_READ=0 _ROUTE_CACHE_CREATION=0

# Wave 15-G (#687): claude is spawned in its own process group so the loop
# signal handler can TERM/KILL the entire tree (claude + any helpers it
# spawns) — not just the top-level PID. The narrow per-PID kill from Wave
# 8 (#612) leaves trap-ignoring or fork-spawning children alive, so SIGINT
# can take many seconds to unwind. With a PG kill we can guarantee a
# bounded grace window. `_ROUTE_PG_PREFIX` is an array — empty when setsid
# is unavailable (e.g. plain macOS without util-linux), in which case the
# loop spawn falls back to the per-PID kill from Wave 8 (the signal handler
# also adds a 1s-delayed SIGKILL backstop in that mode, so a wedged child
# is still bounded — the PG-kill upgrade is what guarantees the <2.5s
# budget). The `-w` flag waits for the child and forwards its exit code,
# so callers see the same rc as before.
if command -v setsid >/dev/null 2>&1 && setsid -w true >/dev/null 2>&1; then
    _ROUTE_PG_PREFIX=(setsid -w)
else
    _ROUTE_PG_PREFIX=()
fi
# ADR-018 (#469): captured tool_uses[] envelope when JSON output mode is active.
# Empty when JSON mode off or envelope lacked the field. Consumers (review
# audit) read this AFTER route_to_model returns. Not exported to subshells —
# valid only within the parent shell that sourced route.sh.
_ROUTE_TOOL_USES_JSON="[]"

# ─── _route_vision_preamble ──────────────────────────────────────────────────
# VIS-C (ADR-049): resolve the advisory Intent preamble ONCE per repo root and
# cache it in _ROUTE_VISION_PREAMBLE (empty = no/invalid vision doc). Memoized
# because _route_redact_prompt runs on every stage prompt (single-shot + each
# loop iteration) and must not fork git/load/validate/awk per call. Keyed on the
# resolved root so distinct repos (and per-scenario tests) recompute correctly.
_ROUTE_VISION_PREAMBLE=""
_ROUTE_VISION_CACHE_ROOT=$'\x00'   # sentinel: "not yet resolved for any root"
_route_vision_preamble() {
    declare -F load_vision_doc >/dev/null 2>&1 || { _ROUTE_VISION_PREAMBLE=""; return 0; }
    local _root="${ZBUILD_REPO_ROOT:-}"
    if [[ -z "$_root" ]]; then
        _root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
        [[ -z "$_root" ]] && _root="$(pwd)"
    fi
    # Cache hit: same root already resolved → keep the memoized preamble.
    [[ "$_root" == "$_ROUTE_VISION_CACHE_ROOT" ]] && return 0
    _ROUTE_VISION_CACHE_ROOT="$_root"
    _ROUTE_VISION_PREAMBLE=""
    local _path=""
    _path="$(load_vision_doc "$_root" 2>/dev/null)" || return 0
    { [[ -n "$_path" ]] && validate_vision_doc "$_path" >/dev/null 2>&1; } || return 0
    # Read via stdin redirect so a path beginning with '-' can't be read as an
    # awk option; strip YAML frontmatter (---…--- opening block) and emit the
    # entire remaining body. Blank lines are stripped so the preamble is a
    # single contiguous block (no internal \n\n), keeping the trailing \n\n
    # as the sole separator between the preamble and the actual prompt.
    local _body
    _body="$(awk 'NR==1&&/^---/{fm=1;next} fm&&/^---/{fm=0;next} fm{next} NF{print}' \
        < "$_path" 2>/dev/null || true)"
    [[ -n "$_body" ]] || return 0
    # Size cap (defense-in-depth): validate_vision_doc enforces the ~300-word
    # vision cap, but hard-cap the injected bytes so an oversized doc
    # can't silently bloat every LLM call.
    local _cap="${ZBUILD_VISION_PREAMBLE_MAX_BYTES:-4096}"
    if (( ${#_body} > _cap )); then _body="${_body:0:_cap}"; fi
    printf -v _ROUTE_VISION_PREAMBLE '# Intent (advisory)\n%s\n\n' "$_body"
}

# ─── _route_redact_prompt <input_file> <output_file> [cycle_id] [allowlist] ──
# Shared redaction step for BOTH single-shot route_to_model and route_to_model_loop
# (ADR-043). When ZBUILD_SCOPE_MANIFEST names a readable manifest, delegate to
# apply_scope_redaction (which emits the canonical redaction.applied on success,
# or redaction.refused fail-closed on a missing/empty manifest). When no manifest
# is configured (unit-test / bootstrap mode) fall back to a passthrough copy plus
# a redaction.applied stub, so the by-construction invariant still holds. The
# allowlist defaults to ZBUILD_SCOPE_ALLOWLIST (runner-exported from plan.files[])
# and is ADDITIVE to the manifest's own `+ path` allowlist.
# Returns apply_scope_redaction's rc (0 ok / 1 fail-closed refusal / 2 io) in the
# manifest path, or 0 in the passthrough-stub path.
_route_redact_prompt() {
    local input="$1" output="$2" cycle_id="${3:-0}"
    local allowlist="${4:-${ZBUILD_SCOPE_ALLOWLIST:-}}"
    local manifest="${ZBUILD_SCOPE_MANIFEST:-}"

    # VIS-C (ADR-049): prepend the advisory Intent preamble when a valid vision
    # doc is present. Resolved+cached once per repo root (_route_vision_preamble).
    # Fail-open: absent/invalid doc leaves the prompt unchanged. Idempotent: skip
    # if the input already carries the marker (guards re-entrancy / retries). The
    # preamble is injected HERE, before apply_scope_redaction, so it passes
    # through the redaction chokepoint by construction (ADR-004).
    _route_vision_preamble
    if [[ -n "${_ROUTE_VISION_PREAMBLE:-}" ]] \
        && [[ "$(head -n1 "$input" 2>/dev/null)" != '# Intent (advisory)' ]]; then
        local _pre_tmp
        _pre_tmp="$(mktemp "${TMPDIR:-/tmp}/zb-vis-pre.XXXXXX" 2>/dev/null)" || true
        if [[ -n "$_pre_tmp" ]]; then
            { printf '%s' "$_ROUTE_VISION_PREAMBLE"; cat "$input"; } > "$_pre_tmp" \
                && mv "$_pre_tmp" "$input" 2>/dev/null || rm -f "$_pre_tmp" 2>/dev/null || true
        fi
    fi

    if [[ -n "$manifest" ]] && declare -F apply_scope_redaction >/dev/null 2>&1; then
        # A configured manifest is authoritative: apply_scope_redaction handles a
        # missing/empty file itself by emitting redaction.refused (rc1, fail-closed)
        # — we do NOT downgrade that to a passthrough here.
        local _rc=0
        apply_scope_redaction "$input" "$output" "$manifest" "$allowlist" "$cycle_id" \
            >/dev/null 2>&1 || _rc=$?
        return "$_rc"
    fi

    # No manifest configured (var unset) → unit-test/bootstrap passthrough. Emit a
    # redaction.applied stub so the by-construction invariant (redaction.applied
    # immediately precedes model.route) holds even without a manifest.
    cp "$input" "$output" 2>/dev/null || true
    eb_emit_event "redaction.applied" \
        "input=$input" "output=$output" \
        "size_before=0" "size_after=0" "redactions=0" \
        "scope_hash=router-passthrough" "cycle=$cycle_id" 2>/dev/null || true
    return 0
}

# ─── _route_ensure_redaction <tier> <skip:bool> <prompt> ─────────────────────
# ADR-043 (redaction by construction). Supersedes the former C6 precondition
# (_route_check_precondition): instead of REFUSING when the prompt was not
# already redacted, the router REDACTS it now. Backward-compatible with the ~8
# plugins that still self-redact — when the most-recent event for this
# (run_id, stage) is already redaction.applied we proceed unchanged (no double
# redaction / double emit). Sets _ROUTE_REDACTED_PROMPT to the text the router
# should send. Returns 0 to proceed, 2 to refuse (fail-closed).
#
# Fail-closed is preserved: a configured-but-missing/empty manifest makes
# apply_scope_redaction emit redaction.refused (rc1) and we refuse the call —
# exactly as C6 did. Degenerate environments (no run_id / no events log) also
# stay fail-closed, since we cannot scope or emit reliably there.
#
# ADR-039 §3: the "already redacted" check is scoped per-stage so concurrent
# parallel-group members each dedup on THEIR OWN redaction.applied rather than a
# sibling's interleaved event. The static lint (scripts/lib/lint-stage-io.sh) +
# the fact that route_to_model[_loop] is the ONLY model path remain the real
# anti-bypass guarantee (ADR-004 §Enforcement).
_ROUTE_REDACTED_PROMPT=""
_route_ensure_redaction() {
    local tier="$1" skip_precondition="$2" prompt="$3"
    _ROUTE_REDACTED_PROMPT="$prompt"

    # Operator override (--skip-precondition): audited bypass, no redaction.
    if $skip_precondition; then
        local override_token="${HOME}/.zbuild/scope-override-token"
        local override_ok=false
        if [[ "${ZBUILD_SCOPE_OVERRIDE:-0}" == "1" && -f "$override_token" ]]; then
            local token_run_id; token_run_id="$(cat "$override_token" 2>/dev/null || echo "")"
            local rid="${ZBUILD_RUN_ID:-bootstrap}"
            [[ "$token_run_id" == "$rid" ]] && override_ok=true
        fi
        if ! $override_ok; then
            error "router redaction refused: --skip-precondition requires ZBUILD_SCOPE_OVERRIDE=1 + ~/.zbuild/scope-override-token containing run_id (or 'bootstrap' if RUN_ID unset)"
            eb_emit_event "router.precondition.refused" \
                "tier=$tier" "reason=skip_without_override" \
                "run_id_state=${ZBUILD_RUN_ID:+set}${ZBUILD_RUN_ID:-unset}" 2>/dev/null || true
            return 2
        fi
        eb_emit_event "router.precondition.skipped" \
            "tier=$tier" "reason=skip_precondition_flag" \
            "run_id_state=${ZBUILD_RUN_ID:+set}${ZBUILD_RUN_ID:-unset}" 2>/dev/null || true
        return 0
    fi

    local run_id="${ZBUILD_RUN_ID:-}" events_log="${ZBUILD_EVENTS_JSONL:-}"
    local stage="${ZBUILD_CURRENT_STAGE:-}"

    # Degenerate environments: cannot scope/emit reliably → fail-closed
    # (unchanged from C6). In production the runner always sets both.
    if [[ -z "$run_id" ]]; then
        error "router redaction refused: ZBUILD_RUN_ID is unset; cannot scope/emit redaction"
        eb_emit_event "router.precondition.refused" "tier=$tier" "reason=no_run_id" 2>/dev/null || true
        return 2
    fi
    if [[ -z "$events_log" || ! -f "$events_log" ]]; then
        error "router redaction refused: ZBUILD_EVENTS_JSONL='${events_log}' missing; cannot emit redaction for run_id=$run_id"
        eb_emit_event "router.precondition.refused" "tier=$tier" "reason=no_events_log" 2>/dev/null || true
        return 2
    fi

    # Already redacted by the caller? (per-stage dedup — see ADR-039 §3 note above.)
    local last_event_type
    if [[ -n "$stage" ]]; then
        last_event_type="$(jq -r --arg rid "$run_id" --arg st "$stage" \
            'select(.run_id == $rid and (.stage // "") == $st) | .type' "$events_log" 2>/dev/null | tail -1 || true)"
    else
        last_event_type="$(jq -r --arg rid "$run_id" \
            'select(.run_id == $rid) | .type' "$events_log" 2>/dev/null | tail -1 || true)"
    fi
    if [[ "$last_event_type" == "redaction.applied" ]]; then
        # Caller already redacted — proceed with the caller's (redacted) prompt.
        return 0
    fi

    # ── Router redacts by construction now. ──
    local _tmp_in _tmp_out _rc=0
    if ! _tmp_in="$(mktemp "${TMPDIR:-/tmp}/zb-route-redact-in.XXXXXX" 2>/dev/null)"; then
        error "router redaction refused: mktemp failed"
        eb_emit_event "router.precondition.refused" "tier=$tier" "reason=mktemp_failed" 2>/dev/null || true
        return 2
    fi
    if ! _tmp_out="$(mktemp "${TMPDIR:-/tmp}/zb-route-redact-out.XXXXXX" 2>/dev/null)"; then
        rm -f "$_tmp_in"
        error "router redaction refused: mktemp failed"
        eb_emit_event "router.precondition.refused" "tier=$tier" "reason=mktemp_failed" 2>/dev/null || true
        return 2
    fi
    printf '%s' "$prompt" > "$_tmp_in"
    _route_redact_prompt "$_tmp_in" "$_tmp_out" 0 "${ZBUILD_SCOPE_ALLOWLIST:-}" || _rc=$?
    if [[ "$_rc" -eq 0 ]]; then
        _ROUTE_REDACTED_PROMPT="$(cat "$_tmp_out" 2>/dev/null || printf '%s' "$prompt")"
        rm -f "$_tmp_in" "$_tmp_out"
        return 0
    fi
    # Fail-closed: apply_scope_redaction refused (missing/empty manifest, no
    # override) or hit an I/O error. redaction.refused was already emitted there.
    rm -f "$_tmp_in" "$_tmp_out"
    error "router redaction refused (fail-closed) — scope manifest missing/empty for run_id=$run_id stage=${stage:-<none>}"
    return 2
}

# ─── _route_lookup_model <tier> <model_override> ─────────────────────────────
# Resolves model_id and cost metadata from models.json.
# Sets _ROUTE_MODEL_ID, _ROUTE_PROVIDER, _ROUTE_COST_IN, _ROUTE_COST_OUT,
# _ROUTE_CACHE_ELIGIBLE, _ROUTE_OVERRIDE_SOURCE.
_route_lookup_model() {
    local tier="$1" model_override="$2"

    local models_file="${ZBUILD_MODELS_FILE:-$_ZBUILD_ROOT/config/models.json}"
    if [[ ! -f "$models_file" ]]; then
        error "models.json not found: $models_file"; return 2
    fi

    local class
    class="$(jq -r ".tiers.${tier}.class // empty" "$models_file" 2>/dev/null)" \
        || { error "failed to parse models.json for tier $tier"; return 2; }
    if [[ -z "$class" ]]; then
        error "tier $tier not found in models.json"; return 2
    fi

    if [[ -n "$model_override" ]]; then
        _ROUTE_MODEL_ID="$model_override"
        _ROUTE_OVERRIDE_SOURCE="flag"
        _ROUTE_PROVIDER="" _ROUTE_COST_IN="" _ROUTE_COST_OUT="" _ROUTE_CACHE_ELIGIBLE="false"
    elif [[ -n "${ZBUILD_PLUGIN_MODEL:-}" ]]; then
        _ROUTE_MODEL_ID="$ZBUILD_PLUGIN_MODEL"
        _ROUTE_OVERRIDE_SOURCE="env"
        _ROUTE_PROVIDER="" _ROUTE_COST_IN="" _ROUTE_COST_OUT="" _ROUTE_CACHE_ELIGIBLE="false"
    else
        _ROUTE_MODEL_ID="$(jq -r ".tiers.${tier}.candidates[0].id // empty" "$models_file" 2>/dev/null)" \
            || { error "failed to read candidates for tier $tier"; return 2; }
        if [[ -z "$_ROUTE_MODEL_ID" ]]; then
            error "no candidates for tier $tier"; return 1
        fi
        _ROUTE_OVERRIDE_SOURCE="candidates[0]"
        _ROUTE_PROVIDER="$(jq -r ".tiers.${tier}.candidates[0].provider // empty" "$models_file" 2>/dev/null)" || _ROUTE_PROVIDER=""
        _ROUTE_COST_IN="$(jq -r ".tiers.${tier}.candidates[0].cost_per_input_mtok // empty" "$models_file" 2>/dev/null)" || _ROUTE_COST_IN=""
        _ROUTE_COST_OUT="$(jq -r ".tiers.${tier}.candidates[0].cost_per_output_mtok // empty" "$models_file" 2>/dev/null)" || _ROUTE_COST_OUT=""
        _ROUTE_CACHE_ELIGIBLE="$(jq -r ".tiers.${tier}.candidates[0].cache_eligible // false" "$models_file" 2>/dev/null)" || _ROUTE_CACHE_ELIGIBLE="false"
    fi
    return 0
}

# ─── _route_resolve_knob — ADR-017 (#455) precedence chokepoint ──────────────
# Generic helper: future knobs (tier_default, budget_usd, model_override) reuse
# this. Accessor returns per-stage value or empty; env_var supplies session-wide
# fallback; default is the compile-time floor.
_route_resolve_knob() {
    local accessor_fn="$1" env_var="$2" default_val="$3"
    local override_event="${4:-router.timeout.override_ignored}"
    local v=""
    if [[ -n "${ZBUILD_CURRENT_STAGE:-}" ]] && declare -F "$accessor_fn" >/dev/null 2>&1; then
        v="$($accessor_fn "$ZBUILD_CURRENT_STAGE" 2>/dev/null || true)"
    fi
    if [[ -n "$v" ]]; then
        # If env var ALSO set and differs, emit override-ignored event for audit.
        local env_val="${!env_var:-}"
        if [[ -n "$env_val" && "$env_val" != "$v" ]]; then
            eb_emit_event "$override_event" \
                "stage=${ZBUILD_CURRENT_STAGE:-}" \
                "env_var=$env_var" \
                "env_value=$env_val" \
                "applied=$v" 2>/dev/null || true
        fi
        printf '%s\n' "$v"; return 0
    fi
    printf '%s\n' "${!env_var:-$default_val}"
}

# Concrete: per-stage router.timeout_s > $ZBUILD_ROUTER_TIMEOUT > 300s default.
_route_resolve_timeout() {
    _route_resolve_knob template_stage_router_timeout ZBUILD_ROUTER_TIMEOUT 300
}

# ADR-018 (#466): per-stage router.max_turns > $ZBUILD_ROUTER_MAX_TURNS > 25 default.
# ADR-029 G3 (#812): when the cycle orchestrator detects a router timeout for
# this stage, it sets ZBUILD_ROUTER_MAX_TURNS_OVERRIDE so the next dispatch
# of the same stage uses an escalated budget (+50%, capped at 2× base). The
# override wins over the per-stage template AND the env knob because that's
# the entire point — escalation must beat the static config that already
# proved too small.
_route_resolve_max_turns() {
    if [[ "${ZBUILD_ROUTER_MAX_TURNS_OVERRIDE:-}" =~ ^[0-9]+$ ]]; then
        printf '%s' "$ZBUILD_ROUTER_MAX_TURNS_OVERRIDE"
        return 0
    fi
    _route_resolve_knob template_stage_router_max_turns ZBUILD_ROUTER_MAX_TURNS 25 \
        router.max_turns.override_ignored
}

# ADR-018 Amendment N (#762): when max_turns resolves to the 0 sentinel,
# classify which source set it (template > env > default) for telemetry.
# Emits `template`, `env`, or `default`. The `default` branch is currently
# unreachable (compile-time default is 25, not 0) but kept for forward
# compatibility if the default ever changes.
# Copilot review #764: compare numerically so "00", "000" etc. (accepted
# by the ^[0-9]+$ validator) classify correctly.
_route_classify_max_turns_source() {
    local _tpl_val=""
    if [[ -n "${ZBUILD_CURRENT_STAGE:-}" ]] \
        && command -v template_stage_router_max_turns >/dev/null 2>&1; then
        _tpl_val="$(template_stage_router_max_turns "$ZBUILD_CURRENT_STAGE" 2>/dev/null || true)"
    fi
    if [[ "$_tpl_val" =~ ^[0-9]+$ ]] && [[ "$_tpl_val" -eq 0 ]]; then
        printf '%s' "template"
    elif [[ "${ZBUILD_ROUTER_MAX_TURNS:-}" =~ ^[0-9]+$ ]] && [[ "${ZBUILD_ROUTER_MAX_TURNS}" -eq 0 ]]; then
        printf '%s' "env"
    else
        printf '%s' "default"
    fi
}

# ADR-018 (#467): per-stage router.max_iterations > $ZBUILD_ROUTER_MAX_ITERATIONS > 10 default.
_route_resolve_max_iterations() {
    _route_resolve_knob template_stage_router_max_iterations ZBUILD_ROUTER_MAX_ITERATIONS 10 \
        router.max_iterations.override_ignored
}

# ADR-029 (#1230): per-stage router.retries > $ZBUILD_ROUTER_RETRIES > 0 default.
# The count of retry-on-timeout (rc=124) attempts BEFORE the verbatim-124
# fallback. Default 0 (opt-in). Honored by BOTH leaf paths — single-shot
# (_route_call_claude) and agentic-loop (route_to_model_loop) — so every leaf
# node respects the knob wherever it sits. Out-of-range values (validator
# already bounds template 0..10; env is unbounded) clamp to 0 fail-safe.
_route_resolve_retries() {
    local v; v="$(_route_resolve_knob template_stage_router_retries ZBUILD_ROUTER_RETRIES 0 \
        router.retries.override_ignored)"
    if [[ "$v" =~ ^[0-9]+$ ]] && [[ "$v" -ge 0 ]] && [[ "$v" -le 10 ]]; then
        printf '%s' "$v"
    else
        printf '0'
    fi
}

# ADR-029 (#1230): escalate a base timeout for retry attempt k (1-based).
# secs = min(base * 1.5^k, 2*base) — ties the +50%/cap-2× rule ADR-029 already
# uses for max_turns escalation. Guarantees strictly-increasing budgets that
# plateau at 2× so a retried timeout gets more headroom without unbounded waits.
_route_escalate_timeout() {
    local base="$1" k="$2"
    awk -v b="$base" -v k="$k" 'BEGIN{
        v = b * (1.5 ^ k); cap = 2 * b;
        if (v > cap) v = cap;
        if (v < 1) v = 1;
        printf "%d", int(v + 0.5);
    }'
}

# ─── _route_emit_model_route <tier> <timeout_s> ──────────────────────────────
_route_emit_model_route() {
    local tier="$1" secs="${2:-}"
    eb_emit_event "model.route" \
        "tier=$tier" \
        "model_id=$_ROUTE_MODEL_ID" \
        "provider=${_ROUTE_PROVIDER:-}" \
        "recommended=$_ROUTE_MODEL_ID" \
        "applied=$_ROUTE_MODEL_ID" \
        "selector=${_ROUTE_OVERRIDE_SOURCE}" \
        "override_source=${_ROUTE_OVERRIDE_SOURCE}" \
        "cost_per_input_mtok=${_ROUTE_COST_IN:-}" \
        "cost_per_output_mtok=${_ROUTE_COST_OUT:-}" \
        "cache_eligible=${_ROUTE_CACHE_ELIGIBLE}" \
        "timeout_s=${secs}"
}

# ─── _route_check_budget <tier> ──────────────────────────────────────────────
# Returns 1 (recoverable) if ZBUILD_BUDGET_USD is set and exceeded.
_route_check_budget() {
    local tier="$1"
    local _budget_usd="${ZBUILD_BUDGET_USD:-}"
    [[ -z "$_budget_usd" ]] && return 0

    local _ledger_file="${ZBUILD_COST_LEDGER:-${HOME}/.zbuild/cost-ledger.jsonl}"
    local _total_cost=0
    [[ -f "$_ledger_file" ]] && \
        _total_cost="$(awk '{s+=$1} END{printf "%.6f", s+0}' "$_ledger_file" 2>/dev/null || echo 0)"

    local _over_budget
    _over_budget="$(awk -v tot="$_total_cost" -v bud="$_budget_usd" \
        'BEGIN{print (tot+0 >= bud+0) ? "1" : "0"}')"
    if [[ "$_over_budget" == "1" ]]; then
        error "router: token budget exceeded (spent=${_total_cost} budget=${_budget_usd}) — refusing model call for tier=$tier"
        eb_emit_event "cost.budget_exceeded" "tier=$tier" \
            "model_id=$_ROUTE_MODEL_ID" "spent=${_total_cost}" "budget=${_budget_usd}" 2>/dev/null || true
        return 1
    fi
    return 0
}

# ─── _route_call_claude <tier> <prompt> <timeout_secs> ───────────────────────
# Executes the claude CLI. Sets _ROUTE_RESPONSE (avoids subshell variable leak).
# Returns 1 on recoverable error, 2 on fatal error.
_route_call_claude() {
    local tier="$1" prompt="$2" secs="$3"

    if ! command -v claude >/dev/null 2>&1; then
        error "claude binary not found in PATH — cannot route tier=$tier"
        eb_emit_event "router.error" "tier=$tier" "model_id=$_ROUTE_MODEL_ID" "reason=claude_binary_missing"
        return 1
    fi

    # ADR-018 (#466): adopt shipwright's flag set so Pattern 1 (one-shot with tools)
    # works. Tools are available to claude --print unless disallowed; we forbid
    # only EnterPlanMode/ExitPlanMode and skip the permission prompt (headless).
    local max_turns; max_turns="$(_route_resolve_max_turns)"
    # ADR-018 Amendment N (#762): max_turns=0 is a sentinel meaning "omit
    # the --max-turns flag from claude argv; defer to claude CLI default".
    # Negatives, non-numeric, and >200 remain invalid.
    if [[ ! "$max_turns" =~ ^[0-9]+$ ]] || [[ "$max_turns" -gt 200 ]]; then
        error "router: max_turns must be integer in 0..200, got: $max_turns"
        eb_emit_event "router.error" "tier=$tier" "model_id=$_ROUTE_MODEL_ID" \
            "reason=invalid_max_turns" "max_turns=$max_turns"
        return 2
    fi

    local -a _claude_args=(-p "$prompt" --print --model "$_ROUTE_MODEL_ID")
    if [[ "$max_turns" -gt 0 ]]; then
        _claude_args+=(--max-turns "$max_turns")
    else
        eb_emit_event "router.max_turns.flag_omitted" \
            "tier=$tier" "model_id=$_ROUTE_MODEL_ID" \
            "resolved=0" "source=$(_route_classify_max_turns_source)" 2>/dev/null || true
    fi
    _claude_args+=(--disallowed-tools "EnterPlanMode,ExitPlanMode")
    _claude_args+=(--dangerously-skip-permissions)
    [[ "${ZBUILD_ROUTER_JSON_OUTPUT:-0}" == "1" ]] && _claude_args+=(--output-format json)

    # ADR-029 (#1230): retry-on-timeout. On rc=124 (gtimeout SIGTERM) and while
    # attempts remain, re-spawn with an escalated LOCAL timeout before falling
    # through to the verbatim-124 path (impact's #937 verdict=incomplete fallback
    # is unchanged). Default 0 → single attempt (legacy behavior). The retry loop
    # is the lowest shared layer for the SINGLE-SHOT leaf path; the agentic loop
    # (route_to_model_loop) implements its own intra-iteration retry.
    local _retries; _retries="$(_route_resolve_retries)"
    local _attempt=0 _local_secs="$secs"
    local stderr_file rc response
    while :; do
    rc=0
    local -a _tout_cmd=()
    if   command -v gtimeout >/dev/null 2>&1; then _tout_cmd=("gtimeout" "$_local_secs")
    elif command -v timeout  >/dev/null 2>&1; then _tout_cmd=("timeout"  "$_local_secs")
    fi
    if ! stderr_file="$(mktemp "${TMPDIR:-/tmp}/zb-router-stderr.XXXXXX" 2>/dev/null)"; then
        error "router: mktemp failed"
        eb_emit_event "router.error" "tier=$tier" "model_id=$_ROUTE_MODEL_ID" "reason=mktemp_failed"
        return 2
    fi

    # ADR-024 / #671 (Wave 13-B): claude spawn is a fresh-user-shell class
    # subprocess — it MUST NOT see ZBUILD_* pipeline state. _zbuild_make_fresh_shell
    # scrubs the entire ZBUILD_* namespace and closes fd 3 (the ADR-015
    # stage-io channel). Supersedes Wave 11C (#647)'s narrow
    # `unset ZBUILD_STAGE_IO_FD; exec 3>&-` pair — the wider scrub also
    # covers ZBUILD_RUN_ID + ZBUILD_EVENTS_JSONL leaks that Wave 13 dogfood
    # discovered would otherwise trigger the C6 precondition refusal when
    # the spawned process recurses into route_to_model. The C6 precondition
    # itself runs in the PARENT scope, not the spawn subshell. The 4 agent
    # plugins that route via route_to_model (plan, test_assessment, review,
    # security-lens) all inherit this protection; the build plugin gets the
    # same protection from route_to_model_loop below.
    # Wave 15-G (#687): the SYNC (non-loop) form deliberately does NOT use
    # setsid. The sync path has no _route_loop_on_signal handler to forward
    # an operator abort to the spawned claude's session — moving claude
    # into its own session/PGID via setsid would mean a terminal Ctrl-C
    # delivered by the kernel to the foreground process group would NOT
    # reach claude, leaving it (and any children) running until gtimeout
    # eventually fires. The loop sites get setsid because the loop's
    # trap manually re-delivers the signal to the captured PGID.
    # (Copilot review #696 caught this; see PR description.)
    if [[ ${#_tout_cmd[@]} -gt 0 ]]; then
        response="$(
            _zbuild_make_fresh_shell
            "${_tout_cmd[@]}" claude "${_claude_args[@]}" 2>"$stderr_file"
        )" || rc=$?
    else
        response="$(
            _zbuild_make_fresh_shell
            claude "${_claude_args[@]}" 2>"$stderr_file"
        )" || rc=$?
    fi

    # ADR-029 (#1230): retry a bare router timeout (rc=124) with an escalated
    # local budget BEFORE the verbatim-124 fallback + diagnostic path. Only
    # rc=124 retries; every other rc falls through unchanged.
    if [[ $rc -eq 124 && $_attempt -lt $_retries ]]; then
        _attempt=$(( _attempt + 1 ))
        local _next_secs; _next_secs="$(_route_escalate_timeout "$secs" "$_attempt")"
        # #1241: a bare event made a multi-minute retry look like a silent hang.
        # Surface it on the operator terminal (warn → fd 2) so the retry is
        # visible mid-run. Output-only; the retry control-flow is unchanged.
        warn "router: ${ZBUILD_CURRENT_STAGE:-stage} timed out (rc=124) — retry ${_attempt}/${_retries}, escalating timeout ${_local_secs}s → ${_next_secs}s"
        eb_emit_event "router.timeout.retry" \
            "tier=$tier" "model_id=$_ROUTE_MODEL_ID" \
            "stage=${ZBUILD_CURRENT_STAGE:-unknown}" \
            "path=single_shot" \
            "attempt=$_attempt" "retries=$_retries" \
            "from_secs=$_local_secs" "to_secs=$_next_secs" 2>/dev/null || true
        _local_secs="$_next_secs"
        rm -f "$stderr_file"
        continue
    fi

    if [[ $rc -ne 0 ]]; then
        # Wave 19-K (#748) + #762: mirror Wave 19-I Fix B for the SYNC path.
        # Persist diagnostic artifacts BEFORE the terse error log so the
        # human-readable message can cite the diagnostic path and include
        # parsed fields (#762: surface error_max_turns subtype to terminal).
        local _sync_diag_dir="${ZBUILD_ARTIFACT_DIR:-${ZBUILD_STATE_DIR:-${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}}/artifacts}/stage-io"
        mkdir -p "$_sync_diag_dir" 2>/dev/null || true
        local _sync_diag_base="${ZBUILD_CURRENT_STAGE:-router}-sync-error"
        local _sync_json_path="$_sync_diag_dir/${_sync_diag_base}.raw-claude-output.json"
        local _sync_stderr_path="$_sync_diag_dir/${_sync_diag_base}.raw-claude-stderr.txt"
        printf '%s' "$response" > "$_sync_json_path" 2>/dev/null || _sync_json_path=""
        if [[ -f "$stderr_file" ]]; then
            cp "$stderr_file" "$_sync_stderr_path" 2>/dev/null || _sync_stderr_path=""
        else
            : > "$_sync_stderr_path" 2>/dev/null || _sync_stderr_path=""
        fi
        # Parse JSON envelope fields once; #762 adds subtype/output_tokens/cost.
        local _sync_is_error="" _sync_err_text="" _sync_num_turns="" _sync_subtype="" _sync_out_tokens="" _sync_cost="" _sync_api_status=""
        if [[ -n "$_sync_json_path" && -f "$_sync_json_path" ]]; then
            _sync_is_error="$(jq -r '.is_error // empty' "$_sync_json_path" 2>/dev/null || true)"
            _sync_err_text="$(jq -r '.error // empty' "$_sync_json_path" 2>/dev/null | head -c 200 || true)"
            _sync_num_turns="$(jq -r '.num_turns // empty' "$_sync_json_path" 2>/dev/null || true)"
            _sync_subtype="$(jq -r '.subtype // empty' "$_sync_json_path" 2>/dev/null || true)"
            _sync_out_tokens="$(jq -r '.usage.output_tokens // empty' "$_sync_json_path" 2>/dev/null || true)"
            _sync_cost="$(jq -r '.total_cost_usd // empty' "$_sync_json_path" 2>/dev/null || true)"
            _sync_api_status="$(jq -r '.api_error_status // empty' "$_sync_json_path" 2>/dev/null || true)"
        fi
        # #1237: a rate/session limit is reported as rc=1 with a misleading
        # subtype:"success" envelope (is_error:true + api_error_status ∈
        # {429,529}). Detect it BEFORE the generic "claude CLI failed" line so
        # the operator sees an honest "rate-limited — resets X" message and the
        # event stream carries a distinct reason. Still returns rc=1 (below), so
        # advisory stages that treat rc=1 as recoverable stay non-blocking, and
        # it is NOT auto-retried (the retry loop above is rc=124-only).
        local _sync_rate_limited=0 _sync_rl_msg=""
        if _router_is_rate_limit "$response"; then
            _sync_rate_limited=1
            _sync_rl_msg="$(_router_rate_limit_message "$response")"
        fi
        # #762: surface error_max_turns to the terminal with a human-readable
        # one-liner. Falls back to the legacy stderr-snip message otherwise.
        local snip; snip="$(head -c 200 "$stderr_file" 2>/dev/null || true)"
        if [[ "$_sync_rate_limited" == "1" ]]; then
            error "$_sync_rl_msg (model=$_ROUTE_MODEL_ID tier=$tier) — diagnostic: ${_sync_json_path:-absent}"
        elif [[ "$_sync_subtype" == "error_max_turns" ]]; then
            error "claude max_turns reached (turns=${_sync_num_turns:-?}, output_tokens=${_sync_out_tokens:-?}, cost=\$${_sync_cost:-?}) — diagnostic: ${_sync_json_path:-absent}"
        else
            error "claude CLI failed (rc=$rc) model=$_ROUTE_MODEL_ID tier=$tier${snip:+: $snip}"
        fi
        if [[ "$_sync_rate_limited" == "1" ]]; then
            eb_emit_event "router.rate_limited" \
                "tier=$tier" "model_id=$_ROUTE_MODEL_ID" "rc=$rc" \
                "stage=${ZBUILD_CURRENT_STAGE:-unknown}" \
                "api_error_status=${_sync_api_status:-absent}" \
                "message=$_sync_rl_msg" 2>/dev/null || true
        fi
        eb_emit_event "router.error" "tier=$tier" "model_id=$_ROUTE_MODEL_ID" "rc=$rc" \
            "reason=$([[ "$_sync_rate_limited" == "1" ]] && printf 'router_rate_limited' || printf 'claude_cli_failed')"
        eb_emit_event "router.error.diagnostic" \
            "tier=$tier" "model_id=$_ROUTE_MODEL_ID" "rc=$rc" \
            "stage=${ZBUILD_CURRENT_STAGE:-unknown}" \
            "raw_json_path=${_sync_json_path:-absent}" \
            "raw_stderr_path=${_sync_stderr_path:-absent}" \
            "is_error=${_sync_is_error:-absent}" \
            "error_text=${_sync_err_text:-absent}" \
            "num_turns=${_sync_num_turns:-absent}" \
            "subtype=${_sync_subtype:-absent}" \
            2>/dev/null || true
        rm -f "$stderr_file"
        # ADR-021 v3 R2: rc=124 (gtimeout SIGTERM) and rc=137 (SIGKILL/OOM)
        # are infra failures and MUST reach the agent plugin verbatim — they
        # carry max_turns/timeout semantics that `_router_rc_classify` maps
        # to verdict=error. Other claude-emitted error rcs collapse to rc=1
        # (caller's classify path still maps generic >0 to verdict=fail).
        case "$rc" in
            124|137) return "$rc" ;;
            *)       return 1 ;;
        esac
    fi
    rm -f "$stderr_file"

    if [[ -z "$response" ]]; then
        error "claude CLI returned empty response model=$_ROUTE_MODEL_ID tier=$tier"
        eb_emit_event "router.error" "tier=$tier" "model_id=$_ROUTE_MODEL_ID" "reason=empty_response"
        return 1
    fi

    # JSON output mode: extract .result and token counts
    _ROUTE_INPUT_TOKENS=0 _ROUTE_OUTPUT_TOKENS=0
    _ROUTE_CACHE_READ=0 _ROUTE_CACHE_CREATION=0
    _ROUTE_TOOL_USES_JSON="[]"
    if [[ "${ZBUILD_ROUTER_JSON_OUTPUT:-0}" == "1" ]]; then
        local text_response
        text_response="$(printf '%s' "$response" | jq -r '.result // empty' 2>/dev/null || true)"
        if [[ -z "$text_response" ]]; then
            error "router: JSON output mode active but .result missing — response: ${response:0:120}"
            eb_emit_event "router.error" "tier=$tier" "model_id=$_ROUTE_MODEL_ID" "reason=json_result_missing"
            return 1
        fi
        _ROUTE_INPUT_TOKENS="$(printf '%s' "$response" | jq -r '.usage.input_tokens // 0' 2>/dev/null || echo 0)"
        _ROUTE_OUTPUT_TOKENS="$(printf '%s' "$response" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo 0)"
        _ROUTE_CACHE_READ="$(printf '%s' "$response" | jq -r '.usage.cache_read_input_tokens // 0' 2>/dev/null || echo 0)"
        _ROUTE_CACHE_CREATION="$(printf '%s' "$response" | jq -r '.usage.cache_creation_input_tokens // 0' 2>/dev/null || echo 0)"
        # ADR-018 (#469): expose tool_uses[] for opt-in audit consumers.
        # Fail-soft — bad/missing field becomes empty array; never blocks.
        local _tu
        _tu="$(printf '%s' "$response" | jq -c '.tool_uses // []' 2>/dev/null || echo '[]')"
        if printf '%s' "$_tu" | jq -e 'type == "array"' >/dev/null 2>&1; then
            _ROUTE_TOOL_USES_JSON="$_tu"
        else
            _ROUTE_TOOL_USES_JSON="[]"
        fi
        # Side-channel: route_to_model is typically called via $() which
        # discards subshell state. Callers that need _ROUTE_TOOL_USES_JSON
        # across that boundary set ZBUILD_ROUTER_TOOL_USES_FILE to a path
        # the parent shell can read after the call returns.
        if [[ -n "${ZBUILD_ROUTER_TOOL_USES_FILE:-}" ]]; then
            printf '%s\n' "$_ROUTE_TOOL_USES_JSON" \
                > "$ZBUILD_ROUTER_TOOL_USES_FILE" 2>/dev/null || true
        fi
        response="$text_response"
    fi

    _ROUTE_RESPONSE="$response"
    return 0
    # ADR-029 (#1230): closes the retry-on-timeout `while`. Every path above
    # either returns or `continue`s, so this is reached only structurally.
    done
}

# ─── _route_emit_outcome <tier> <timeout_s> ──────────────────────────────────
_route_emit_outcome() {
    local tier="$1" secs="${2:-}"
    eb_emit_event "model.outcome" \
        "tier=$tier" \
        "model_id=$_ROUTE_MODEL_ID" \
        "cache_eligible=${_ROUTE_CACHE_ELIGIBLE}" \
        "input_tokens=$_ROUTE_INPUT_TOKENS" \
        "output_tokens=$_ROUTE_OUTPUT_TOKENS" \
        "cache_read_input_tokens=$_ROUTE_CACHE_READ" \
        "cache_creation_input_tokens=$_ROUTE_CACHE_CREATION" \
        "timeout_s=${secs}"
}

# ─── _route_update_ledger ─────────────────────────────────────────────────────
# Appends call cost to the cost ledger. The ledger path resolves via
# ZBUILD_COST_LEDGER (default ~/.zbuild/cost-ledger.jsonl) so a nested run can be
# fenced to its own ledger (#1214). Non-fatal on failure.
_route_update_ledger() {
    [[ -z "${_ROUTE_COST_IN:-}" || -z "${_ROUTE_COST_OUT:-}" ]] && return 0

    local _call_cost_usd
    _call_cost_usd="$(awk \
        -v i="$_ROUTE_INPUT_TOKENS" -v o="$_ROUTE_OUTPUT_TOKENS" \
        -v ri="$_ROUTE_COST_IN" -v ro="$_ROUTE_COST_OUT" \
        'BEGIN{printf "%.6f", (i*ri + o*ro)/1000000}' 2>/dev/null || echo 0)"

    [[ "$_call_cost_usd" == "0" || "$_call_cost_usd" == "0.000000" ]] && return 0

    local _ledger_file="${ZBUILD_COST_LEDGER:-${HOME}/.zbuild/cost-ledger.jsonl}"
    local _ledger_dir; _ledger_dir="$(dirname "$_ledger_file")"
    mkdir -p "$_ledger_dir" 2>/dev/null || true
    if zbuild_has_flock; then
        (
            flock -w 5 9 || exit 1
            printf '%s\n' "$_call_cost_usd" >> "$_ledger_file"
        ) 9>"${_ledger_file}.lock" 2>/dev/null || true
    else
        printf '%s\n' "$_call_cost_usd" >> "$_ledger_file" 2>/dev/null || true
    fi
}

# ─── route_to_model_loop — ADR-018 Pattern 2 (Issue #467) ────────────────────
# Multi-turn agent loop. Each iteration invokes claude in $cwd; the pipeline
# captures `git diff HEAD` between turns and appends to the next prompt.
# Terminates on `LOOP_COMPLETE` sentinel from .result, or max-iterations cap.
# The LLM never emits a diff string; the caller reads `git diff HEAD` after
# the loop returns.
#
# Usage:
#   route_to_model_loop <tier> <prompt_file> <cwd> <max_iterations> \
#       [--max-turns-per-call N] [--done-sentinel TOKEN] \
#       [--inter-turn-hook FN] [--model ID] [--scope-allowlist CSV]
#
# Globals set:
#   _ROUTE_LOOP_ITERATIONS         — count of iterations actually run
#   _ROUTE_LOOP_TERMINATED_REASON  — done_sentinel | max_iterations | signal |
#                                    hook_failed | error
#   _ROUTE_LOOP_INPUT_TOKENS       — cumulative .usage.input_tokens
#   _ROUTE_LOOP_OUTPUT_TOKENS      — cumulative .usage.output_tokens
#   _ROUTE_LOOP_LAST_RESPONSE      — (#608) result_text of the FINAL iteration.
#                                    Since #1329 this is the LEGACY / single-iteration
#                                    FALLBACK for the build commit parser; the PRIMARY
#                                    path is _ROUTE_LOOP_ITER_SUMMARIES (below). Empty
#                                    when no iteration ran.
#   _ROUTE_LOOP_ITER_SUMMARIES     — (#1329) newline-separated accumulation of the
#                                    per-iteration COMMIT_SUMMARY value, parsed +
#                                    sanitized AT THE SOURCE (one line per iteration
#                                    that emitted a marker). Consumed by the build
#                                    plugin for cumulative commit-message composition.
#                                    Storing only the parsed one-line summaries (not
#                                    raw result_text) keeps this bounded and prevents
#                                    adversarial control bytes in the LLM output from
#                                    being read as record boundaries (#1329 review).
#
# Returns: 0 on DONE-sentinel, 1 on max-iter no-DONE, 2 on fatal.
_ROUTE_LOOP_ITERATIONS=0
_ROUTE_LOOP_TERMINATED_REASON=""
_ROUTE_LOOP_INPUT_TOKENS=0
_ROUTE_LOOP_OUTPUT_TOKENS=0
_ROUTE_LOOP_LAST_RESPONSE=""
_ROUTE_LOOP_ITER_SUMMARIES=""
_ROUTE_LOOP_CHILD_PID=""
# Wave 15-G (#687): PGID of the in-flight claude spawn (when known).
# Set alongside _ROUTE_LOOP_CHILD_PID at the spawn site, cleared after wait.
# Signal handler kills the whole group; falls back to the PID when empty.
_ROUTE_LOOP_CHILD_PGID=""
# #646: deferred-final-banner-close handshake. Only populated when the
# caller passed --defer-final-banner-close AND the loop reached the
# DONE-sentinel exit path on a successful iteration (other exit reasons —
# no_progress, max_iterations, error, signal — keep the legacy immediate
# stage_io_end behavior and leave these globals empty). Caller MUST invoke
# _route_loop_close_final_banner after emitting any post-loop operator
# output that needs to land inside the iter banner pair; it is a safe
# no-op when nothing was deferred.
_ROUTE_LOOP_FINAL_STAGE_ID=""
_ROUTE_LOOP_FINAL_KIND=""
_ROUTE_LOOP_FINAL_SEQ=""
_ROUTE_LOOP_FINAL_OUTPUT=""
_ROUTE_LOOP_FINAL_EXIT_CODE=""
_ROUTE_LOOP_FINAL_ITER=""
_ROUTE_LOOP_FINAL_TOKENS_IN=""
_ROUTE_LOOP_FINAL_TOKENS_OUT=""
_ROUTE_LOOP_FINAL_PENDING="false"

# Default no-op inter-turn hook — overridden via --inter-turn-hook FN
_route_loop_default_hook() { :; }

# Signal trap installer — kills child claude, emits terminated.signal event.
_route_loop_install_traps() {
    trap '_route_loop_on_signal SIGINT' INT
    trap '_route_loop_on_signal SIGTERM' TERM
}
_route_loop_clear_traps() {
    trap - INT TERM
}
_route_loop_on_signal() {
    local sig="$1"
    # Wave 15-G (#687): TERM the whole process group, then SIGKILL after a 1s
    # grace. The grace covers claude's normal cleanup; the KILL covers
    # trap-ignoring or wedged children. Falls back to the per-PID kill from
    # Wave 8 (#612) when the PGID is unknown (setsid unavailable AND the spawn
    # subshell did not capture a distinct PGID). Negative arg targets the
    # process group: `kill -- -PGID`.
    #
    # #905: the abort is SYNCHRONOUS — this handler does not return until the
    # child tree has actually been signalled-to-death. The previous design
    # detached the SIGKILL as `{ sleep 1 && kill -KILL; } &` and returned
    # immediately; route_to_model_loop (and its caller/driver) could then
    # unwind and exit while a TERM-ignoring claude was still alive, the backstop
    # KILL landing up to a second later — or never, if that orphaned backstop
    # was lost to the caller's own teardown. The result was orphaned claude
    # processes surviving an abort (the route-fast-abort-test leak, flaky under
    # load). Here the SIGKILL escalation runs in a *local* watchdog that we
    # reap, and we sweep the whole group before returning, so by the time the
    # loop returns 130 no process from this spawn is still running. Graceful
    # children still abort fast — they exit on TERM and `wait` returns before
    # the watchdog fires; only trap-ignoring children pay the full 1s grace.
    local _pid="${_ROUTE_LOOP_CHILD_PID:-}"
    local _pgid="${_ROUTE_LOOP_CHILD_PGID:-}"
    if [[ -n "$_pid" || -n "$_pgid" ]]; then
        local _wd=""
        if [[ -n "$_pgid" ]]; then
            kill -TERM -- "-$_pgid" 2>/dev/null || true
            { sleep 1 && kill -KILL -- "-$_pgid" 2>/dev/null || true; } &
            _wd=$!
        else
            kill -TERM "$_pid" 2>/dev/null || true
            { sleep 1 && kill -KILL "$_pid" 2>/dev/null || true; } &
            _wd=$!
        fi
        # Wait for the group leader: graceful children exit on TERM (fast);
        # trap-ignoring children are SIGKILLed by the watchdog at the grace.
        # Either way `wait` returns only once the leader has been reaped.
        [[ -n "$_pid" ]] && { wait "$_pid" 2>/dev/null || true; }
        # The leader exiting does NOT imply the group drained — claude may have
        # spawned children, or a `gtimeout`/`setsid` wrapper may outlive or
        # predecease it. Sweep the WHOLE group with a final synchronous SIGKILL
        # so no member survives (and so a leader that exited gracefully before
        # the watchdog fired doesn't leave siblings behind — the watchdog is
        # torn down next, so this sweep is the only guaranteed group kill in
        # that case). Then stand down + reap the watchdog so we never leave a
        # detached `sleep`/kill orphan behind.
        [[ -n "$_pgid" ]] && { kill -KILL -- "-$_pgid" 2>/dev/null || true; }
        [[ -n "$_pid" ]] && { kill -KILL "$_pid" 2>/dev/null || true; }
        if [[ -n "$_wd" ]]; then
            kill -KILL "$_wd" 2>/dev/null || true
            wait "$_wd" 2>/dev/null || true
        fi
    fi
    _ROUTE_LOOP_TERMINATED_REASON="signal"
    eb_emit_event "loop.terminated.signal" \
        "signal=$sig" \
        "iterations=${_ROUTE_LOOP_ITERATIONS}" 2>/dev/null || true
    return 130
}

# #1329: extract + sanitize the LAST COMMIT_SUMMARY marker from ONE iteration's
# result text. Returns a single control-char-free line (≤72 chars), or empty when
# the iteration emitted no marker. Parsing at the source (not accumulating raw
# result_text) is what makes _ROUTE_LOOP_ITER_SUMMARIES bounded and injection-safe.
_route_parse_commit_summary_line() {
    local text="${1:-}" out
    [[ -z "$text" ]] && { printf ''; return 0; }
    out="$(printf '%s\n' "$text" \
        | tail -n 50 \
        | grep -E '^COMMIT_SUMMARY:[[:space:]]*(.+)$' \
        | tail -n 1 \
        | sed -E 's/^COMMIT_SUMMARY:[[:space:]]*//' \
        | LC_ALL=C tr -d '\000-\037\177' \
        | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | cut -c1-72 || true)"
    printf '%s' "$out"
    return 0
}

route_to_model_loop() {
    if [[ $# -lt 4 ]]; then
        error "route_to_model_loop requires <tier> <prompt_file> <cwd> <max_iterations>"
        return 2
    fi
    local tier="$1" prompt_file="$2" cwd="$3" max_iterations="$4"; shift 4

    local max_turns_per_call=""
    local done_sentinel="LOOP_COMPLETE"
    local inter_turn_hook="_route_loop_default_hook"
    local model_override=""
    local scope_allowlist=""
    # #646: when set, route_to_model_loop returns WITHOUT closing the final
    # iter's stage-io banner ONLY on the DONE-sentinel exit path. Other exit
    # paths (no_progress, max_iterations, error rc≥2, SIGINT) keep the
    # legacy immediate stage_io_end behavior — the build-plugin discrepancy
    # warn this flag exists to wrap only fires on done_sentinel, so the
    # narrow scope is sufficient. Caller is responsible for emitting any
    # post-loop operator output INSIDE the banner pair and then calling
    # _route_loop_close_final_banner to flush the close-banner; that helper
    # is a safe no-op when the loop did not stash a deferred close.
    local defer_final_banner_close="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-turns-per-call) max_turns_per_call="$2"; shift 2 ;;
            --done-sentinel)      done_sentinel="$2";       shift 2 ;;
            --inter-turn-hook)    inter_turn_hook="$2";     shift 2 ;;
            --model)              model_override="$2";      shift 2 ;;
            --scope-allowlist)    scope_allowlist="$2";     shift 2 ;;
            --defer-final-banner-close) defer_final_banner_close="true"; shift ;;
            *) error "route_to_model_loop: unknown flag '$1'"; return 2 ;;
        esac
    done

    if [[ ! "$tier" =~ ^T[0-4]$ ]]; then
        error "route_to_model_loop: invalid tier '$tier'"
        return 2
    fi
    if [[ -z "$prompt_file" || ! -f "$prompt_file" ]]; then
        error "route_to_model_loop: prompt_file '$prompt_file' missing"
        return 2
    fi
    if [[ -z "$cwd" || ! -d "$cwd" ]]; then
        error "route_to_model_loop: cwd '$cwd' missing or not a directory"
        return 2
    fi
    if ! [[ "$max_iterations" =~ ^[0-9]+$ ]] || [[ "$max_iterations" -lt 1 ]]; then
        error "route_to_model_loop: max_iterations must be positive integer, got: $max_iterations"
        return 2
    fi

    _route_lookup_model "$tier" "$model_override" || return $?

    if ! command -v claude >/dev/null 2>&1; then
        error "route_to_model_loop: claude binary not found in PATH"
        eb_emit_event "router.error" "tier=$tier" "model_id=$_ROUTE_MODEL_ID" \
            "reason=claude_binary_missing" 2>/dev/null || true
        return 2
    fi

    local mt; mt="$(_route_resolve_max_turns)"
    # ADR-018 Amendment N (#762): max_turns=0 is a sentinel (omit flag).
    if ! [[ "$mt" =~ ^[0-9]+$ ]] || [[ "$mt" -gt 200 ]]; then
        error "route_to_model_loop: max_turns must be integer in 0..200, got: $mt"
        return 2
    fi
    # Copilot review #764: per-call override must still be validated.
    # The sentinel (0) is allowed only via the resolver chain
    # (template > env > default); explicit --max-turns-per-call always
    # enforces 1..200 per ADR-018 Amendment N "Loop mode" clause.
    if [[ -n "$max_turns_per_call" ]]; then
        if ! [[ "$max_turns_per_call" =~ ^[0-9]+$ ]] \
            || [[ "$max_turns_per_call" -lt 1 ]] \
            || [[ "$max_turns_per_call" -gt 200 ]]; then
            error "route_to_model_loop: --max-turns-per-call must be integer in 1..200, got: $max_turns_per_call"
            return 2
        fi
        mt="$max_turns_per_call"
    fi

    # ADR-029 (#1230): $secs is the base timeout; the per-iteration `_tout_cmd`
    # is (re)built inside the spawn loop from the escalated `_iter_local_secs`.
    local secs; secs="$(_route_resolve_timeout)"

    _ROUTE_LOOP_ITERATIONS=0
    _ROUTE_LOOP_TERMINATED_REASON=""
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    _ROUTE_LOOP_LAST_RESPONSE=""
    _ROUTE_LOOP_ITER_SUMMARIES=""
    # #646: clear deferred-final-banner-close handshake state from any prior call.
    _ROUTE_LOOP_FINAL_STAGE_ID=""
    _ROUTE_LOOP_FINAL_KIND=""
    _ROUTE_LOOP_FINAL_SEQ=""
    _ROUTE_LOOP_FINAL_OUTPUT=""
    _ROUTE_LOOP_FINAL_EXIT_CODE=""
    _ROUTE_LOOP_FINAL_ITER=""
    _ROUTE_LOOP_FINAL_TOKENS_IN=""
    _ROUTE_LOOP_FINAL_TOKENS_OUT=""
    _ROUTE_LOOP_FINAL_PENDING="false"

    _route_loop_install_traps

    # Per-iteration temp dir outside the caller's artifacts dir so the parity
    # goldens that snapshot artifact filenames are not polluted by iter files.
    local _loop_tmp; _loop_tmp="$(mktemp -d "${TMPDIR:-/tmp}/zb-loop-iters.XXXXXX")"
    # #628: function-scoped RETURN trap self-cleans on every exit path
    # (SIGINT propagation, 3-consecutive-timeout fatal, capture_diff error,
    # done_sentinel, no_progress, max_iterations). Previously two of those
    # paths skipped cleanup. RETURN fires per-function-frame; does not
    # conflict with the runner's SCRIPT-level EXIT trap or the loop's
    # INT/TERM signal traps installed by _route_loop_install_traps.
    # Single-quoted body: $_loop_tmp is expanded NOW and frozen into the
    # trap action, so any future reassignment can't redirect rm.
    # shellcheck disable=SC2064
    trap "rm -rf '$_loop_tmp' 2>/dev/null || true" RETURN

    local static_prompt prev_diff="" timeout_recur=0 prev_iter_timed_out=false
    static_prompt="$(cat "$prompt_file")"
    # #505: snapshot of prev_diff at start of THIS iteration, used to detect
    # an unchanged diff between iterations for the operator banner pointer.
    local _prev_diff_for_banner=""

    local diff_cap="${ZBUILD_LOOP_DIFF_CAP_CHARS:-20000}"
    # Wave 8 #613: track consecutive empty-diff iters as a no-progress safety net.
    local empty_iter_count=0
    local iter
    for (( iter=1; iter <= max_iterations; iter++ )); do
        _ROUTE_LOOP_ITERATIONS=$iter

        local iter_prompt _timeout_warn=""
        if [[ "$prev_iter_timed_out" == "true" ]] && (( iter >= 2 )); then
            _timeout_warn="
> **WARNING — prior iteration timed out (rc=124):** The model's previous response
> was cut off. LOOP_COMPLETE was NOT received. Re-verify the implementation
> before emitting LOOP_COMPLETE.
"
        fi
        if [[ -z "$prev_diff" ]]; then
            iter_prompt="$static_prompt

## Iteration ${iter}/${max_iterations}${_timeout_warn}
(No prior changes — this is the first iteration.)"
        else
            iter_prompt="$static_prompt

## Iteration ${iter}/${max_iterations}${_timeout_warn}
## Cumulative diff so far (\`git diff HEAD\`):
${prev_diff}"
        fi

        # Wave 8 #614: branch-cumulative context.
        # Show the LLM what's already committed on this branch since intake
        # started. Critical for "already done" recognition: without this, the
        # LLM sees an empty iter delta on iter 1 and doesn't know the branch
        # has commits from prior pipeline runs / human work.
        local _intake_ref _commits _stat _short_head
        _intake_ref=""
        if [[ -n "${ZBUILD_STATE_DIR:-}" && -f "$ZBUILD_STATE_DIR/intake-baseline-ref.txt" ]]; then
            _intake_ref="$(cat "$ZBUILD_STATE_DIR/intake-baseline-ref.txt" 2>/dev/null || true)"
        fi
        if [[ -n "$_intake_ref" ]]; then
            _commits="$(git -C "$cwd" log "${_intake_ref}..HEAD" --oneline 2>/dev/null | head -10 || true)"
            _stat="$(git -C "$cwd" diff "${_intake_ref}..HEAD" --stat 2>/dev/null || true)"
            _short_head="$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null || echo unknown)"
            iter_prompt="${iter_prompt}

## BRANCH STATE since intake (HEAD: ${_short_head})
Commits:
${_commits:-  (none)}

Diff vs intake baseline:
${_stat:-  (no changes)}"
        fi

        # Per-iteration redaction by construction (ADR-043). Shared with
        # single-shot route_to_model via _route_redact_prompt: emits the
        # canonical redaction.applied (or fail-closed refused). The loop stays
        # fail-OPEN on a redaction error (|| cp) — it does not gate on C6 and a
        # per-iteration refusal must not silently drop the turn.
        local iter_prompt_file="${_loop_tmp}/iter-${iter}.txt"
        local iter_redacted_file="${_loop_tmp}/iter-${iter}.redacted.txt"
        printf '%s\n' "$iter_prompt" > "$iter_prompt_file"

        _route_redact_prompt "$iter_prompt_file" "$iter_redacted_file" "$iter" "$scope_allowlist" \
            || cp "$iter_prompt_file" "$iter_redacted_file"

        local final_prompt; final_prompt="$(cat "$iter_redacted_file")"

        eb_emit_event "loop.iteration" \
            "tier=$tier" "iteration=$iter" "max_iterations=$max_iterations" \
            "model_id=$_ROUTE_MODEL_ID" "cwd=$cwd" 2>/dev/null || true

        # #505: build operator-facing banner_input that DEDUPES the static
        # prompt + REPLACES the cumulative diff section with a pointer once
        # we are past iter 1. The LLM still gets the full final_prompt; only
        # the scrollback banner is trimmed. See ADR-018 §Pattern 2.5.
        #
        # Dedupe minimum (chars): below this, the full prompt is fine.
        local _banner_dedupe_min="${ZBUILD_LOOP_BANNER_DEDUPE_MIN_CHARS:-500}"
        local banner_input="$final_prompt"
        if (( iter >= 2 )) && (( ${#static_prompt} >= _banner_dedupe_min )); then
            # sha = first 8 hex chars of sha256(static_prompt) — detects
            # mid-loop static-prompt mutation across iterations.
            local _sha8="" _static_lines
            _static_lines="$(printf '%s' "$static_prompt" | wc -l | tr -d ' ')"
            if command -v shasum >/dev/null 2>&1; then
                _sha8="$(printf '%s' "$static_prompt" | shasum -a 256 | cut -c1-8)"
            elif command -v sha256sum >/dev/null 2>&1; then
                _sha8="$(printf '%s' "$static_prompt" | sha256sum | cut -c1-8)"
            else
                _sha8="nohash"
            fi

            # Classify the diff pointer: cap-exceeded (stat-only marker from
            # _route_loop_capture_diff), unchanged across iters, or normal.
            local _diff_pointer
            if [[ "$prev_diff" == "(diff exceeded cap of "* ]]; then
                _diff_pointer="[diff: stat-only, see ── changed-files ──]"
            elif [[ -n "${_prev_diff_for_banner:-}" && "$_prev_diff_for_banner" == "$prev_diff" ]]; then
                _diff_pointer="[diff: unchanged from iter $((iter - 1))]"
            else
                local _diff_lines _diff_chars
                _diff_lines="$(printf '%s' "$prev_diff" | wc -l | tr -d ' ')"
                _diff_chars="${#prev_diff}"
                _diff_pointer="[diff: see ── changed-files ── summary below (${_diff_lines} lines, ${_diff_chars}c)]"
            fi

            banner_input="[static prompt: same as iter 1, ${_static_lines} lines, sha=${_sha8}]

## Iteration ${iter}/${max_iterations}

${_diff_pointer}"
        fi
        # Track prev_diff snapshot for next-iter "unchanged" detection.
        _prev_diff_for_banner="$prev_diff"

        # #482: per-iteration stage_io banner (Pattern 2). Mirrors #481's
        # split begin/end emit around the LLM call so build's loop is
        # observable like plan/review. Fails soft — capture never blocks
        # the loop. Uses ZBUILD_CURRENT_STAGE (preferred) or ZBUILD_PLUGIN.
        local _iter_stage_io_seq=""
        local _iter_stage_id="${ZBUILD_CURRENT_STAGE:-${ZBUILD_PLUGIN:-}}"
        if [[ -n "$_iter_stage_id" ]]; then
            # #505: --persist-input writes final_prompt (full payload) into
            # the artifact .input field, while --input drives only the
            # (possibly deduped) scrollback banner. Default behavior — for
            # callers that don't pass --persist-input — is unchanged.
            stage_io_begin \
                --stage "$_iter_stage_id" \
                --kind llm \
                --input "$banner_input" \
                --persist-input "$iter_redacted_file" \
                --metadata "tier=$tier" \
                --metadata "iter=$iter" \
                --metadata "model_id=$_ROUTE_MODEL_ID" \
                >/dev/null 2>&1 || true
            _iter_stage_io_seq="${_STAGE_IO_LAST_SEQ:-}"
        fi

        local stderr_file rc=0 json_file
        stderr_file="$(mktemp "${TMPDIR:-/tmp}/zb-loop-stderr.XXXXXX")"
        json_file="$(mktemp "${TMPDIR:-/tmp}/zb-loop-json.XXXXXX")"

        local -a _claude_args=(-p "$final_prompt" --print --model "$_ROUTE_MODEL_ID")
        # ADR-018 Amendment N (#762): omit --max-turns when sentinel mt=0.
        if [[ "$mt" -gt 0 ]]; then
            _claude_args+=(--max-turns "$mt")
        elif [[ "$iter" -eq 1 ]]; then
            # Emit sentinel-resolution telemetry once per loop run (iter 1).
            eb_emit_event "router.max_turns.flag_omitted" \
                "tier=$tier" "model_id=$_ROUTE_MODEL_ID" \
                "resolved=0" "source=$(_route_classify_max_turns_source)" 2>/dev/null || true
        fi
        _claude_args+=(--disallowed-tools "EnterPlanMode,ExitPlanMode")
        _claude_args+=(--dangerously-skip-permissions)
        _claude_args+=(--output-format json)

        # ADR-029 (#1230): intra-iteration retry-on-timeout. router.retries is the
        # count of per-iteration CALL retries with an escalated LOCAL timeout,
        # layered BEFORE the cross-iteration timeout_recur breaker (#1208). An
        # iteration bumps timeout_recur only AFTER exhausting the N inner retries
        # (router.retries = intra-iteration call retries; timeout_recur =
        # cross-iteration breaker — no double-count). #1208 "timeouts never fatal"
        # is preserved: once inner retries are spent, control falls through to the
        # unchanged rc=124 path (sentinel-honor + timeout_recur + non-fatal yield).
        local _iter_retries; _iter_retries="$(_route_resolve_retries)"
        local _iter_attempt=0 _iter_local_secs="$secs"
        while :; do
        rc=0
        local -a _tout_cmd=()
        if   command -v gtimeout >/dev/null 2>&1; then _tout_cmd=("gtimeout" "$_iter_local_secs")
        elif command -v timeout  >/dev/null 2>&1; then _tout_cmd=("timeout"  "$_iter_local_secs")
        fi

        # Run claude in $cwd as background child so signal trap can kill it.
        # ADR-024 / #671 (Wave 13-B): claude spawn is a fresh-user-shell class
        # subprocess. _zbuild_make_fresh_shell scrubs ZBUILD_* + closes fd 3.
        # Supersedes Wave 11C (#647)'s narrow per-var unset; the build
        # plugin (the loop's primary caller) inherits this protection.
        # Copilot P1 on #673: guard cd BEFORE the helper, because the
        # helper disables errexit (fresh-user-shell posture). A failed
        # cd here would otherwise silently spawn claude from the
        # runner's cwd instead of $cwd.
        #
        # Wave 15-G (#687): wrap the spawn in `setsid -w` (when available) so
        # the claude tree lives in its own process group. _route_loop_on_signal
        # then TERM/KILLs the whole group rather than the top-level PID, which
        # is what lets the loop pre-abort in <2.5s even when claude (or any
        # child it spawned) ignores or delays SIGTERM. When setsid is not
        # installed (plain macOS without util-linux), _ROUTE_PG_PREFIX is
        # empty and the signal handler falls back to the per-PID kill from
        # Wave 8 (#612) — same behavior as before this wave.
        #
        # `exec` so the subshell PROCESS is replaced by setsid (when
        # available) or by gtimeout/claude (when not). This makes $! point
        # at the actual session leader — `kill -- -$!` then targets the
        # whole claude tree in setsid mode. Without exec, $! would point at
        # the bash subshell that wraps setsid; the new session/PGID would
        # belong to the setsid child (one fork below), and bash's PGID
        # would still be the parent runner's — so `kill -- -$!` would TERM
        # the runner, not claude.
        if [[ ${#_tout_cmd[@]} -gt 0 ]]; then
            (
                cd "$cwd" || exit 99
                _zbuild_make_fresh_shell
                exec "${_ROUTE_PG_PREFIX[@]}" "${_tout_cmd[@]}" claude "${_claude_args[@]}"
            ) >"$json_file" 2>"$stderr_file" &
        else
            (
                cd "$cwd" || exit 99
                _zbuild_make_fresh_shell
                exec "${_ROUTE_PG_PREFIX[@]}" claude "${_claude_args[@]}"
            ) >"$json_file" 2>"$stderr_file" &
        fi
        _ROUTE_LOOP_CHILD_PID=$!
        # Wave 15-G (#687): with setsid -w, the child IS the session/process
        # group leader → PGID == PID, and `kill -- -PGID` is safe (targets
        # only the claude tree, never the parent runner).
        # Without setsid the spawn subshell inherits the parent's PGID, so
        # using `kill -- -PGID` would also kill the runner. Only set the
        # PGID when we can prove it differs from the runner's own PGID;
        # otherwise leave it empty and the handler falls back to the per-
        # PID kill (same behavior as Wave 8 #612, plus the 1s KILL backstop).
        if [[ ${#_ROUTE_PG_PREFIX[@]} -gt 0 ]]; then
            _ROUTE_LOOP_CHILD_PGID="$_ROUTE_LOOP_CHILD_PID"
        else
            _ROUTE_LOOP_CHILD_PGID=""
            local _child_pgid _self_pgid
            _child_pgid="$(ps -o pgid= -p "$_ROUTE_LOOP_CHILD_PID" 2>/dev/null | tr -d ' ' || true)"
            _self_pgid="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ' || true)"
            if [[ -n "$_child_pgid" && -n "$_self_pgid" && "$_child_pgid" != "$_self_pgid" ]]; then
                _ROUTE_LOOP_CHILD_PGID="$_child_pgid"
            fi
        fi
        wait "$_ROUTE_LOOP_CHILD_PID" 2>/dev/null || rc=$?
        _ROUTE_LOOP_CHILD_PID=""
        _ROUTE_LOOP_CHILD_PGID=""

        # #612: rc=130 means the child claude was interrupted by SIGINT (either
        # delivered to the foreground process group by the operator's Ctrl-C, or
        # by _route_loop_on_signal's `kill`). It is NOT a transient error —
        # falling through to the generic `continue` below absorbs the signal and
        # spawns another claude on the next iteration, making the pipeline
        # impossible to interrupt. Short-circuit here: emit a terminal signal
        # event, set the reason, clear traps, return 130 so callers (build
        # plugin, runner) can propagate the abort.
        #
        # Wave 15-G (#687): also short-circuit on rc=143 (SIGTERM) and any
        # rc when _route_loop_on_signal already marked the reason as "signal".
        # The PG-kill path can produce 143 (TERM landed cleanly) or 137 (KILL
        # backstop fired) instead of 130 — all three are signal-class exits
        # and must NOT be swallowed by the loop's generic-error continue.
        if [[ $rc -eq 130 || $rc -eq 143 || $rc -eq 137 \
              || "${_ROUTE_LOOP_TERMINATED_REASON:-}" == "signal" ]]; then
            warn "route_to_model_loop: claude interrupted (rc=$rc) iter=$iter — propagating signal"
            _ROUTE_LOOP_TERMINATED_REASON="signal"
            eb_emit_event "loop.terminated.signal" \
                "iterations=$iter" "child_rc=$rc" \
                "model_id=$_ROUTE_MODEL_ID" 2>/dev/null || true
            # Close the per-iteration stage_io banner on the signal path so
            # we don't orphan it into the EXIT trap.
            if [[ -n "$_iter_stage_io_seq" ]]; then
                stage_io_end \
                    --stage "$_iter_stage_id" \
                    --kind llm \
                    --seq "$_iter_stage_io_seq" \
                    --output "" \
                    --exit-code 130 \
                    --metadata "iter=$iter" \
                    --metadata "signal=true" \
                    >/dev/null 2>&1 || true
            fi
            rm -f "$stderr_file" "$json_file"
            _route_loop_clear_traps
            # #628: $_loop_tmp cleanup handled by RETURN trap above.
            return 130
        fi

        # ADR-029 (#1230): intra-iteration retry on a bare timeout (rc=124) while
        # attempts remain. Honor LOOP_COMPLETE-on-timeout first — if the work is
        # already done we do NOT retry (let the sentinel path below terminate the
        # loop cleanly). Otherwise emit router.timeout.retry, escalate the LOCAL
        # timeout, and re-spawn within THIS iteration (timeout_recur unchanged).
        if [[ $rc -eq 124 && $_iter_attempt -lt $_iter_retries ]]; then
            local _rr_done="false"
            if [[ -s "$json_file" ]]; then
                local _rr_res; _rr_res="$(jq -r '.result // empty' "$json_file" 2>/dev/null || true)"
                if printf '%s\n' "$_rr_res" | \
                   grep -qE "^[[:space:]]*${done_sentinel}[[:space:]]*\$" 2>/dev/null; then
                    _rr_done="true"
                fi
            fi
            if [[ "$_rr_done" != "true" ]]; then
                _iter_attempt=$(( _iter_attempt + 1 ))
                local _rr_next; _rr_next="$(_route_escalate_timeout "$secs" "$_iter_attempt")"
                # #1241: surface the loop-path retry on the operator terminal too
                # (mirror the single-shot branch) so it is not a silent hang.
                warn "router: ${_iter_stage_id:-stage} timed out (rc=124) — iter=$iter retry ${_iter_attempt}/${_iter_retries}, escalating timeout ${_iter_local_secs}s → ${_rr_next}s"
                eb_emit_event "router.timeout.retry" \
                    "tier=$tier" "model_id=$_ROUTE_MODEL_ID" \
                    "stage=${_iter_stage_id:-unknown}" "path=loop" \
                    "iteration=$iter" "attempt=$_iter_attempt" "retries=$_iter_retries" \
                    "from_secs=$_iter_local_secs" "to_secs=$_rr_next" 2>/dev/null || true
                _iter_local_secs="$_rr_next"
                continue
            fi
        fi
        break
        done

        if [[ $rc -ne 0 ]]; then
            # Wave 19-I Fix A (#743): if rc=124 (gtimeout SIGTERM) AND the
            # captured .result already contains LOOP_COMPLETE on its own
            # line, claude finished the work but the wrapper killed it
            # during final CLI exit. Honor the sentinel and terminate the
            # loop with done_sentinel reason rather than discarding the
            # work-done signal and retrying. Dogfood 20260607181657-82646
            # iter 4 exhibited this: 900s wall time + LOOP_COMPLETE in
            # output + rc=124 → loop wasted iter 5 on already-complete code.
            if [[ $rc -eq 124 && -s "$json_file" ]]; then
                local _rc124_result
                _rc124_result="$(jq -r '.result // empty' "$json_file" 2>/dev/null || true)"
                if printf '%s\n' "$_rc124_result" | \
                   grep -qE "^[[:space:]]*${done_sentinel}[[:space:]]*\$" 2>/dev/null; then
                    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
                    _ROUTE_LOOP_ITERATIONS=$iter
                    eb_emit_event "router.loop.iter.timeout_with_sentinel" \
                        "iteration=$iter" "rc=$rc" \
                        "stage=${_iter_stage_id:-unknown}" \
                        "model_id=$_ROUTE_MODEL_ID" \
                        "reason=gtimeout_after_loop_complete" \
                        2>/dev/null || true
                    if [[ -n "$_iter_stage_io_seq" ]]; then
                        stage_io_end \
                            --stage "$_iter_stage_id" \
                            --kind llm \
                            --seq "$_iter_stage_io_seq" \
                            --output "$_rc124_result" \
                            --exit-code 0 \
                            --metadata "iter=$iter" \
                            --metadata "terminated=gtimeout_after_sentinel" \
                            >/dev/null 2>&1 || true
                    fi
                    eb_emit_event "loop.complete" \
                        "iterations=$iter" \
                        "model_id=$_ROUTE_MODEL_ID" \
                        "reason=done_sentinel" 2>/dev/null || true
                    rm -f "$stderr_file" "$json_file"
                    _route_loop_clear_traps
                    return 0
                fi
            fi
            # Wave 19-I Fix B (#743) + #762: preserve diagnostic artifacts
            # BEFORE the warn/error log so the human-readable message can
            # cite the path and parsed fields (including subtype for #762).
            local _diag_dir="${ZBUILD_ARTIFACT_DIR:-${ZBUILD_STATE_DIR:-${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}}/artifacts}/stage-io"
            mkdir -p "$_diag_dir" 2>/dev/null || true
            local _diag_base="${_iter_stage_id:-loop}-iter${iter}-error"
            local _diag_json_path=""
            local _diag_stderr_path=""
            if [[ -f "$json_file" ]]; then
                _diag_json_path="$_diag_dir/${_diag_base}.raw-claude-output.json"
                cp "$json_file" "$_diag_json_path" 2>/dev/null || _diag_json_path=""
            fi
            if [[ -f "$stderr_file" ]]; then
                _diag_stderr_path="$_diag_dir/${_diag_base}.raw-claude-stderr.txt"
                cp "$stderr_file" "$_diag_stderr_path" 2>/dev/null || _diag_stderr_path=""
            fi
            # Parse envelope fields once; #762 adds subtype/cost.
            local _diag_is_error="" _diag_err_text="" _diag_num_turns="" _diag_out_tokens="" _diag_subtype="" _diag_cost=""
            if [[ -n "$_diag_json_path" ]]; then
                _diag_is_error="$(jq -r '.is_error // empty' "$_diag_json_path" 2>/dev/null || true)"
                _diag_err_text="$(jq -r '.error // empty' "$_diag_json_path" 2>/dev/null | head -c 200 || true)"
                _diag_num_turns="$(jq -r '.num_turns // empty' "$_diag_json_path" 2>/dev/null || true)"
                _diag_out_tokens="$(jq -r '.usage.output_tokens // empty' "$_diag_json_path" 2>/dev/null || true)"
                _diag_subtype="$(jq -r '.subtype // empty' "$_diag_json_path" 2>/dev/null || true)"
                _diag_cost="$(jq -r '.total_cost_usd // empty' "$_diag_json_path" 2>/dev/null || true)"
            fi
            # #762: surface error_max_turns subtype with a human-readable line.
            # Falls back to the legacy stderr-snip warning otherwise.
            local snip; snip="$(head -c 200 "$stderr_file" 2>/dev/null || true)"
            if [[ "$_diag_subtype" == "error_max_turns" ]]; then
                error "claude max_turns reached (turns=${_diag_num_turns:-?}, output_tokens=${_diag_out_tokens:-?}, cost=\$${_diag_cost:-?}) — diagnostic: ${_diag_json_path:-absent}"
            else
                warn "route_to_model_loop: claude rc=$rc iter=$iter${snip:+: $snip}"
            fi
            eb_emit_event "loop.iteration.error" \
                "iteration=$iter" "rc=$rc" \
                "model_id=$_ROUTE_MODEL_ID" \
                "reason=claude_rc_nonzero" 2>/dev/null || true
            eb_emit_event "router.loop.iter.error.diagnostic" \
                "iteration=$iter" "rc=$rc" \
                "stage=${_iter_stage_id:-unknown}" \
                "raw_json_path=${_diag_json_path:-absent}" \
                "raw_stderr_path=${_diag_stderr_path:-absent}" \
                "is_error=${_diag_is_error:-absent}" \
                "error_text=${_diag_err_text:-absent}" \
                "num_turns=${_diag_num_turns:-absent}" \
                "output_tokens=${_diag_out_tokens:-absent}" \
                "subtype=${_diag_subtype:-absent}" \
                2>/dev/null || true
            # #482: close the per-iteration banner on the error path so we
            # don't orphan it into the EXIT trap. Output is whatever (if
            # anything) ended up in json_file before the failure.
            if [[ -n "$_iter_stage_io_seq" ]]; then
                local _err_result=""
                _err_result="$(jq -r '.result // empty' "$json_file" 2>/dev/null || true)"
                stage_io_end \
                    --stage "$_iter_stage_id" \
                    --kind llm \
                    --seq "$_iter_stage_io_seq" \
                    --output "$_err_result" \
                    --exit-code "$rc" \
                    --metadata "iter=$iter" \
                    --metadata "error=true" \
                    >/dev/null 2>&1 || true
            fi
            if [[ $rc -eq 124 ]]; then
                prev_iter_timed_out=true
                timeout_recur=$(( timeout_recur + 1 ))
                if [[ $timeout_recur -ge 3 ]]; then
                    # Issue #1208 / ADR-013 (router-loop): a per-turn timeout is
                    # NEVER fatal. Repeated timeouts end THIS build attempt and
                    # YIELD control back to the cycle (non-fatal return 0), which
                    # always runs the test stage to verify the actual state and
                    # iterates. The caller (build plugin) reads
                    # _ROUTE_LOOP_TERMINATED_REASON=router_timeout to mark the
                    # attempt did-not-finish (mid-flight, not a clean resting
                    # point) so the iteration cannot ratify convergence — but the
                    # committed partial work is preserved (#602). warn, not error.
                    warn "route_to_model_loop: 3 consecutive timeouts — yielding to cycle (non-fatal)"
                    _ROUTE_LOOP_TERMINATED_REASON="router_timeout"
                    eb_emit_event "loop.timeout_yield" \
                        "iterations=$iter" "model_id=$_ROUTE_MODEL_ID" \
                        "consecutive=$timeout_recur" \
                        "reason=router_timeout" 2>/dev/null || true
                    rm -f "$stderr_file" "$json_file"
                    _route_loop_clear_traps
                    return 0
                fi
            fi
            rm -f "$stderr_file" "$json_file"
            # Capture diff after error iteration too so progress isn't lost.
            _route_loop_capture_diff "$cwd" "$diff_cap" prev_diff || {
                _ROUTE_LOOP_TERMINATED_REASON="error"
                _route_loop_clear_traps
                return 2
            }
            continue
        fi
        timeout_recur=0
        prev_iter_timed_out=false
        rm -f "$stderr_file"

        # Extract .result and token usage from claude JSON output.
        local result_text="" in_tok=0 out_tok=0
        result_text="$(jq -r '.result // empty' "$json_file" 2>/dev/null || true)"
        in_tok="$(jq -r '.usage.input_tokens // 0' "$json_file" 2>/dev/null || echo 0)"
        out_tok="$(jq -r '.usage.output_tokens // 0' "$json_file" 2>/dev/null || echo 0)"
        _ROUTE_LOOP_INPUT_TOKENS=$(( _ROUTE_LOOP_INPUT_TOKENS + in_tok ))
        _ROUTE_LOOP_OUTPUT_TOKENS=$(( _ROUTE_LOOP_OUTPUT_TOKENS + out_tok ))
        # #608: expose the most recent iteration's LLM text so the build plugin
        # can parse the COMMIT_SUMMARY marker after the loop returns.
        _ROUTE_LOOP_LAST_RESPONSE="$result_text"
        # #1329: parse THIS iteration's COMMIT_SUMMARY at the source and keep only
        # the sanitized one-line value (newline-separated). Storing the parsed
        # summary — not the raw result_text — keeps the accumulator bounded and
        # means no adversarial control byte in the LLM output can be read as a
        # record boundary (summaries-only; the build plugin composes the message).
        local _iter_summary
        _iter_summary="$(_route_parse_commit_summary_line "$result_text")"
        if [[ -n "$_iter_summary" ]]; then
            if [[ -z "$_ROUTE_LOOP_ITER_SUMMARIES" ]]; then
                _ROUTE_LOOP_ITER_SUMMARIES="$_iter_summary"
            else
                _ROUTE_LOOP_ITER_SUMMARIES="${_ROUTE_LOOP_ITER_SUMMARIES}"$'\n'"${_iter_summary}"
            fi
        fi

        # Inter-turn hook (best-effort; failure does not abort the loop).
        # #646: moved AHEAD of the per-iter stage_io_end so any operator
        # output the hook emits (e.g., build's post-loop discrepancy warn,
        # when wired via --defer-final-banner-close) lands inside the open
        # banner pair rather than in the inter-stage gap.
        if declare -F "$inter_turn_hook" >/dev/null 2>&1; then
            "$inter_turn_hook" "$iter" "$cwd" "$json_file" "$result_text" || \
                warn "route_to_model_loop: hook '$inter_turn_hook' rc=$? iter=$iter"
        fi

        # #646: DONE-sentinel detection moved AHEAD of stage_io_end so that
        # callers using --defer-final-banner-close can decide whether to
        # leave the banner open for post-loop output. Line-anchored grep
        # against the result text; matches whitespace + sentinel + whitespace.
        local _iter_done_sentinel="false"
        if printf '%s\n' "$result_text" | \
           grep -qE "^[[:space:]]*${done_sentinel}[[:space:]]*\$" 2>/dev/null; then
            _iter_done_sentinel="true"
        fi

        # #646: If this iter triggers a success-exit AND the caller asked us
        # to defer the final banner close, stash the close-banner parameters
        # in module-level state and skip stage_io_end. The caller MUST flush
        # via _route_loop_close_final_banner before returning to the runner.
        # Non-sentinel iters AND callers that did NOT opt in to defer keep
        # the legacy behavior — close immediately on success.
        local _iter_banner_closed="false"
        if [[ "$_iter_done_sentinel" == "true" && "$defer_final_banner_close" == "true" && -n "$_iter_stage_io_seq" ]]; then
            _ROUTE_LOOP_FINAL_STAGE_ID="$_iter_stage_id"
            _ROUTE_LOOP_FINAL_KIND="llm"
            _ROUTE_LOOP_FINAL_SEQ="$_iter_stage_io_seq"
            _ROUTE_LOOP_FINAL_OUTPUT="$result_text"
            _ROUTE_LOOP_FINAL_EXIT_CODE="0"
            _ROUTE_LOOP_FINAL_ITER="$iter"
            _ROUTE_LOOP_FINAL_TOKENS_IN="$in_tok"
            _ROUTE_LOOP_FINAL_TOKENS_OUT="$out_tok"
            _ROUTE_LOOP_FINAL_PENDING="true"
            _iter_banner_closed="true"  # deferred — caller will close
        fi

        # #482: close the per-iteration banner on the success path. Output
        # is the LLM's result text (matches Pattern 1's banner shape).
        # #646: skipped when deferred above.
        if [[ "$_iter_banner_closed" != "true" && -n "$_iter_stage_io_seq" ]]; then
            stage_io_end \
                --stage "$_iter_stage_id" \
                --kind llm \
                --seq "$_iter_stage_io_seq" \
                --output "$result_text" \
                --exit-code 0 \
                --metadata "iter=$iter" \
                --metadata "tokens_in=$in_tok" \
                --metadata "tokens_out=$out_tok" \
                >/dev/null 2>&1 || true
        fi

        if [[ "$_iter_done_sentinel" == "true" ]]; then
            _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
            eb_emit_event "loop.complete" \
                "iterations=$iter" "model_id=$_ROUTE_MODEL_ID" \
                "input_tokens=$_ROUTE_LOOP_INPUT_TOKENS" \
                "output_tokens=$_ROUTE_LOOP_OUTPUT_TOKENS" \
                "reason=done_sentinel" 2>/dev/null || true
            rm -f "$json_file"
            _route_loop_clear_traps
            # #628: $_loop_tmp cleanup handled by RETURN trap above.
            return 0
        fi
        rm -f "$json_file"

        # Capture diff for next iteration's prompt.
        _route_loop_capture_diff "$cwd" "$diff_cap" prev_diff || {
            _ROUTE_LOOP_TERMINATED_REASON="error"
            _route_loop_clear_traps
            # #628: $_loop_tmp cleanup handled by RETURN trap above.
            return 2
        }

        # Wave 8 #613: auto-terminate after N consecutive truly-empty diff iters.
        # Safety net for when the LLM forgets to emit LOOP_COMPLETE (e.g., it
        # observes the work is already done but responds without the sentinel).
        # Codex P1 on #615: DO NOT count capped-diff sentinel as empty —
        # the LLM may legitimately be producing large patches each iter
        # that exceed ZBUILD_LOOP_DIFF_CAP_CHARS. Only truly empty diff
        # (zero changes) counts toward the no-progress streak.
        if [[ -z "$prev_diff" ]]; then
            empty_iter_count=$(( empty_iter_count + 1 ))
        else
            empty_iter_count=0
        fi
        if [[ $empty_iter_count -ge 2 ]]; then
            _ROUTE_LOOP_TERMINATED_REASON="no_progress"
            eb_emit_event "loop.no_progress" \
                "iterations=$iter" \
                "empty_iter_streak=$empty_iter_count" 2>/dev/null || true
            _route_loop_clear_traps
            # #628: $_loop_tmp cleanup handled by RETURN trap above.
            return 0
        fi
    done

    _ROUTE_LOOP_TERMINATED_REASON="max_iterations"
    eb_emit_event "loop.max_iterations" \
        "iterations=$max_iterations" "model_id=$_ROUTE_MODEL_ID" \
        "input_tokens=$_ROUTE_LOOP_INPUT_TOKENS" \
        "output_tokens=$_ROUTE_LOOP_OUTPUT_TOKENS" 2>/dev/null || true
    _route_loop_clear_traps
    # #628: $_loop_tmp cleanup handled by RETURN trap above.
    return 1
}

# ─── _route_loop_close_final_banner — #646 deferred-close flush ──────────────
# Closes the banner pair that route_to_model_loop left open when called with
# --defer-final-banner-close AND the loop exited via the done_sentinel path.
# No-op when:
#   - the caller did not pass --defer-final-banner-close, OR
#   - the loop exited via a path that did not stash a deferred close
#     (no_progress, max_iterations, error, signal — those paths keep legacy
#     banner-close semantics for now), OR
#   - the deferred-close state was already flushed.
# Safe to call unconditionally from the build plugin after every loop return.
_route_loop_close_final_banner() {
    if [[ "$_ROUTE_LOOP_FINAL_PENDING" != "true" ]]; then
        return 0
    fi
    if [[ -z "$_ROUTE_LOOP_FINAL_SEQ" || -z "$_ROUTE_LOOP_FINAL_STAGE_ID" ]]; then
        _ROUTE_LOOP_FINAL_PENDING="false"
        return 0
    fi
    stage_io_end \
        --stage "$_ROUTE_LOOP_FINAL_STAGE_ID" \
        --kind  "$_ROUTE_LOOP_FINAL_KIND" \
        --seq   "$_ROUTE_LOOP_FINAL_SEQ" \
        --output "$_ROUTE_LOOP_FINAL_OUTPUT" \
        --exit-code "$_ROUTE_LOOP_FINAL_EXIT_CODE" \
        --metadata "iter=$_ROUTE_LOOP_FINAL_ITER" \
        --metadata "tokens_in=$_ROUTE_LOOP_FINAL_TOKENS_IN" \
        --metadata "tokens_out=$_ROUTE_LOOP_FINAL_TOKENS_OUT" \
        >/dev/null 2>&1 || true
    # Clear the handshake state so the full LLM result text (potentially
    # several KB) isn't held in module-level globals for the remainder of
    # the runner process, and so later inspection of these vars can't
    # accidentally read stale data from a previous loop's deferred close.
    _ROUTE_LOOP_FINAL_STAGE_ID=""
    _ROUTE_LOOP_FINAL_KIND=""
    _ROUTE_LOOP_FINAL_SEQ=""
    _ROUTE_LOOP_FINAL_OUTPUT=""
    _ROUTE_LOOP_FINAL_EXIT_CODE=""
    _ROUTE_LOOP_FINAL_ITER=""
    _ROUTE_LOOP_FINAL_TOKENS_IN=""
    _ROUTE_LOOP_FINAL_TOKENS_OUT=""
    _ROUTE_LOOP_FINAL_PENDING="false"
    return 0
}

# _route_loop_capture_diff <cwd> <cap_chars> <prev_diff_var_name>
# Captures `git -C <cwd> diff HEAD` into the named variable.
#
# #530: bash `$()` strips trailing newlines, leaving the captured diff 1 byte
# short of the raw `git diff HEAD` output → downstream `git apply --check`
# fails with "corrupt patch at line N". Fix: stream `git diff HEAD` to a
# tempfile (no command-substitution trimming), then read it back via the
# `printf x; %x` trick to round-trip the trailing newline through a bash
# variable losslessly.
#
# On overflow: replaces with `git diff --stat` + truncation notice.
# On git failure: emits loop.git_diff_failed and returns 1.
_route_loop_capture_diff() {
    local cwd="$1" cap="$2" var_name="$3"
    # intent-to-add so new untracked files appear in `git diff HEAD`
    git -C "$cwd" add -N . 2>/dev/null || true

    # Stream directly to disk; do not let `$()` touch the byte stream.
    local _diff_tmp; _diff_tmp="$(mktemp "${TMPDIR:-/tmp}/zb-loop-diff.XXXXXX")"
    local diff_rc=0
    git -C "$cwd" diff HEAD > "$_diff_tmp" 2>/dev/null || diff_rc=$?
    if [[ $diff_rc -ne 0 ]]; then
        rm -f "$_diff_tmp"
        # Best-effort: clear `-N` intent-to-add entries so a later iteration's
        # diff isn't polluted by an aborted capture.
        git -C "$cwd" reset -q 2>/dev/null || true
        eb_emit_event "loop.git_diff_failed" \
            "cwd=$cwd" "rc=$diff_rc" 2>/dev/null || true
        return 1
    fi

    # Lossless readback: `cat file; printf x` then strip the final 'x'.
    local diff_out
    diff_out="$(cat "$_diff_tmp"; printf x)"
    diff_out="${diff_out%x}"
    rm -f "$_diff_tmp"

    if [[ ${#diff_out} -gt $cap ]]; then
        local stat_out
        stat_out="$(git -C "$cwd" diff --stat HEAD 2>/dev/null || echo "(diff too large)")"
        diff_out="(diff exceeded cap of ${cap} chars; showing stats only)
${stat_out}"
        eb_emit_event "loop.diff_capture_warning" \
            "cwd=$cwd" "reason=cap_exceeded" "cap=$cap" 2>/dev/null || true
    fi
    printf -v "$var_name" '%s' "$diff_out"
    return 0
}
