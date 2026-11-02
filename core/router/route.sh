#!/usr/bin/env bash
# core/router/route.sh — ADR-003 model router stub (issue #84)
# Maps tier ordinals (T0-T4) to concrete models via config/models.json.
# Phase 0.5: picks candidates[0]; UCB1 bandit deferred to #29.
# Sourced by callers — no set -euo pipefail at file scope (would mutate caller options).

[[ -n "${_ZBUILD_ROUTER_LOADED:-}" ]] && return 0
_ZBUILD_ROUTER_LOADED=1

_ROUTER_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)"
_ZBUILD_ROOT="$(cd "$_ROUTER_DIR/../.." && pwd)"
# Opens the read-only scope block for a stage that may not change the
# repository; also its idempotence guard (_route_redact_prompt).
_ZB_READ_ONLY_SCOPE_MARKER='## YOUR SCOPE (engine-provided)'

# ─── _route_has_done_sentinel <sentinel> <text> ─────────────────────────────
# rc 0 when some LINE of <text> is the sentinel once whitespace and punctuation
# are removed and case is ignored: `LOOP_COMPLETE.`, `**LOOP_COMPLETE**`,
# `Loop complete!` all count; a sentence that merely MENTIONS it does not.
# #1847 run 20260928102849-23575: design wrote "LOOP_COMPLETE." in 8 of 14
# answers, the exact-line match missed every one, and each miss bought another
# full model call (10 calls, ~41 min, for one design iteration).
_route_has_done_sentinel() {
    awk -v s="${1:-}" '
        BEGIN { s = toupper(s); gsub(/[^A-Z0-9]/, "", s); if (s == "") exit 1 }
        { l = toupper($0); gsub(/[^A-Z0-9]/, "", l); if (l == s) { found = 1; exit } }
        # END runs even after an `exit` above; `found` is unset (0) unless a
        # line matched, so an empty sentinel or no match both exit 1.
        END { exit(found ? 0 : 1) }' <<< "${2:-}"
}

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
# #1816 (ADR-017 §11): manifest_router_knob — the plugin's own declared budget.
# Sourced BY CONSTRUCTION rather than left to whether some other lib happened to
# pull manifest-validation.sh in first: _route_manifest_knob degrades to the
# compile-time constant when the reader is missing, so an unreachable reader
# would make every declaration silently inert instead of failing. Idempotent —
# the file's own load guard makes a repeat source a no-op.
if ! declare -F manifest_router_knob >/dev/null 2>&1; then
    _zbuild_route_require "$_ZBUILD_ROOT/core/plugin-registry/manifest-validation.sh"
    source "$_ZBUILD_ROOT/core/plugin-registry/manifest-validation.sh"
fi
# shellcheck source=../../scripts/lib/stage-limits.sh
_zbuild_route_require "$_ZBUILD_ROOT/scripts/lib/stage-limits.sh"
source "$_ZBUILD_ROOT/scripts/lib/stage-limits.sh"
# ADR-051 (#1305): resolve_persona + persona_text — resolve a stage persona from
# the four-step precedence chain (env > template-stage > template-global > generic)
# with two-root discovery (installed tree + per-repo overlay). Sourced here so
# every routing plugin gets resolve_persona/persona_text by construction.
_zbuild_route_require "$_ZBUILD_ROOT/scripts/lib/persona-resolve.sh"
source "$_ZBUILD_ROOT/scripts/lib/persona-resolve.sh"
# ADR-051 (amended 2026-10-12): every call a dispatched stage makes runs as its
# persona, delivered the way the provider takes it.
_zbuild_route_require "$_ZBUILD_ROOT/core/router/persona-delivery.sh"
# shellcheck source=persona-delivery.sh
source "$_ZBUILD_ROOT/core/router/persona-delivery.sh"
# ADR-067 §8: the engine/stage prompt contract — the router checks a stage
# prompt's order with stage_prompt_check before every model call.
_zbuild_route_require "$_ZBUILD_ROOT/scripts/lib/stage-prompt.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$_ZBUILD_ROOT/scripts/lib/stage-prompt.sh"
# #1752: the one shared timeout helper; both model-call paths bound through it.
_zbuild_route_require "$_ZBUILD_ROOT/scripts/lib/timeout-cmd.sh"
# shellcheck source=../../scripts/lib/timeout-cmd.sh
source "$_ZBUILD_ROOT/scripts/lib/timeout-cmd.sh"
# Shared setsid capability probe + process-group kill helper.
# Defines zbuild_pg_resolve and zbuild_pg_kill (extracted from the inline
# probe that used to live here, so the test plugin can share one impl).
_zbuild_route_require "$_ZBUILD_ROOT/scripts/lib/proc-group.sh"
source "$_ZBUILD_ROOT/scripts/lib/proc-group.sh"
# #1919 (C10): acceptEdits + settings file — replaces --dangerously-skip-permissions.
# Conditional (not _zbuild_route_require) so the stub-tree load test works without
# a permissions.sh fixture; spawn sites fail closed (command not found) if absent.
if [[ -f "$_ROUTER_DIR/permissions.sh" ]]; then
    source "$_ROUTER_DIR/permissions.sh"
fi

# #1706: map members run concurrently under one stage name; naming the record
# by the unit keeps one member's failure from overwriting another's.
_route_sync_diag_base() {
    printf '%s%s-sync-error' "${ZBUILD_UNIT:-${ZBUILD_CURRENT_STAGE:-router}}" "$(_route_try_suffix)"
}

# #2443: when the engine numbers the try, each try's record is its own file.
_route_try_suffix() {
    [[ -n "${ZBUILD_STAGE_TRY:-}" ]] && printf -- '-round%s-try%s' "${ZBUILD_CYCLE_ITER:-0}" "$ZBUILD_STAGE_TRY"
    return 0
}

# route_to_model <tier> <prompt> [--skip-precondition] [--model <id>]
# Exit codes: 0=success, 1=recoverable, 2=fatal
#
# C6 precondition: most-recent event for the current (run_id, stage) must be
# `redaction.applied` — scoped per-stage so concurrent parallel-group members
# each enforce their own redaction (ADR-039 §3). See ARCHITECTURE.md §3 /
# ADR-004. `--skip-precondition` requires operator override
# (ZBUILD_SCOPE_OVERRIDE=1 + token file). ADR-001.
route_to_model() {
    _ROUTE_LAST_BUDGET_EXHAUSTED=0   # #2187: set by the call path on a turn-budget hit
    declare -F _router_clear_budget_marker >/dev/null 2>&1 && _router_clear_budget_marker
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
    # The model is looked up first: the provider it names decides how the
    # stage's persona reaches the model, which redaction must know (ADR-051).
    _route_lookup_model "$tier" "$model_override"          || return $?
    _route_ensure_redaction "$tier" "$skip_precondition" "$prompt" || return $?
    prompt="$_ROUTE_REDACTED_PROMPT"

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
    _ev="$(mktemp "$(zbuild_engine_tmpdir)/zb-cli-events.XXXXXX")" || { error "route_to_model_cli: mktemp events failed"; return 2; }
    _man="$(mktemp "$(zbuild_engine_tmpdir)/zb-cli-scope.XXXXXX")" || { rm -f "$_ev"; error "route_to_model_cli: mktemp manifest failed"; return 2; }
    printf '+ core/\n+ scripts/\n+ plugins/\n+ tests/\n+ docs/\n+ config/\n' > "$_man"

    ZBUILD_RUN_ID="cli-$$" \
    ZBUILD_EVENTS_JSONL="$_ev" \
    ZBUILD_SCOPE_MANIFEST="$_man" \
        route_to_model "$tier" "$prompt" "$@" || _rc=$?

    rm -f "$_ev" "$_man"
    return "$_rc"
}

# ── Shared state set by helpers ──────────────────────────────────────────────
_ROUTE_MODEL_ID="" _ROUTE_PROVIDER="" _ROUTE_FAMILY="" _ROUTE_MODEL_USED="" _ROUTE_CALL_COST=""
_ROUTE_CACHE_ELIGIBLE="false" _ROUTE_OVERRIDE_SOURCE="" _ROUTE_RESPONSE=""
_ROUTE_INPUT_TOKENS=0 _ROUTE_OUTPUT_TOKENS=0
_ROUTE_CACHE_READ=0 _ROUTE_CACHE_CREATION=0

# Wave 15-G (#687): claude is spawned in its own process group so the loop
# signal handler can TERM/KILL the entire tree (claude + any helpers it
# spawns) — not just the top-level PID. The narrow per-PID kill from Wave
# 8 (#612) leaves trap-ignoring or fork-spawning children alive, so SIGINT
# can take many seconds to unwind. With a PG kill we can guarantee a
# bounded grace window. The group comes from `set -m` at the spawn (#2056):
# bash job control makes a backgrounded job a process-group leader, which is
# POSIX and behaves the same on macOS and Linux. It replaced `setsid -w`, which
# does not exist on macOS — there the guarantee silently degraded to a per-PID
# kill and every descendant survived an abort.
# ADR-018 (#469): captured tool_uses[] envelope when JSON output mode is active.
# Empty when JSON mode off or envelope lacked the field. Consumers (review
# audit) read this AFTER route_to_model returns. Not exported to subshells —
# valid only within the parent shell that sourced route.sh.
_ROUTE_TOOL_USES_JSON="[]"


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

    # ADR-067 §8 (amended): a stage composes its whole prompt — its own three
    # parts and the engine's three blocks — with stage_prompt_compose. The
    # router adds nothing and edits nothing; for a model call a dispatched stage
    # makes, it only checks the contract order and refuses a prompt that breaks
    # it, rather than send a stage a prompt without its repository, its previous
    # work or its rules. A call outside any stage (no ZBUILD_PLUGIN_DIR) is not
    # a stage prompt and is not held to it.
    _ROUTE_PROMPT_REFUSED=0
    if [[ -n "${ZBUILD_PLUGIN_DIR:-}" ]]; then
        declare -F stage_prompt_check >/dev/null 2>&1 \
            || source "$_ZBUILD_ROOT/scripts/lib/stage-prompt.sh" 2>/dev/null || true
        if ! stage_prompt_check "$input"; then
            _ROUTE_PROMPT_REFUSED=1
            eb_emit_event "router.prompt.refused" "stage=${ZBUILD_CURRENT_STAGE:-}" \
                "reason=not_in_contract_order" 2>/dev/null || true
            printf 'router: refusing the %s prompt — it is not in the contract order (ADR-067 §8): compose it with stage_prompt_compose\n' \
                "${ZBUILD_CURRENT_STAGE:-stage}" >&2
            return 1
        fi
        # ADR-051: a provider that cannot take an agent gets the persona as the
        # prompt's first section — here, so it rides the redaction below.
        _route_persona_prepare
        _route_persona_into_prompt "$input"
        _route_persona_redact "$manifest" "$allowlist" "$cycle_id"
    fi

    # #2379 (ADR-043): every prompt is redacted — private paths are taken out —
    # whether or not the run has a scope manifest; the scope no longer decides
    # what a stage sees.
    declare -F apply_scope_redaction >/dev/null 2>&1 \
        || source "$_ZBUILD_ROOT/core/redaction/scope-redaction.sh" 2>/dev/null || true
    local _rc=0
    apply_scope_redaction "$input" "$output" "$manifest" "$allowlist" "$cycle_id" \
        >/dev/null 2>&1 || _rc=$?
    return "$_rc"
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
    if ! _tmp_in="$(mktemp "$(zbuild_engine_tmpdir)/zb-route-redact-in.XXXXXX" 2>/dev/null)"; then
        error "router redaction refused: mktemp failed"
        eb_emit_event "router.precondition.refused" "tier=$tier" "reason=mktemp_failed" 2>/dev/null || true
        return 2
    fi
    if ! _tmp_out="$(mktemp "$(zbuild_engine_tmpdir)/zb-route-redact-out.XXXXXX" 2>/dev/null)"; then
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
    rm -f "$_tmp_in" "$_tmp_out"
    # A stage prompt out of the contract order was refused and said so
    # (router.prompt.refused); the manifest is not the cause.
    [[ "${_ROUTE_PROMPT_REFUSED:-0}" == "1" ]] && return 2
    # Fail-closed: apply_scope_redaction refused (missing/empty manifest, no
    # override) or hit an I/O error. redaction.refused was already emitted there.
    error "router redaction refused (fail-closed) — scope manifest missing/empty for run_id=$run_id stage=${stage:-<none>}"
    return 2
}

# ─── _route_provider_load <provider> ─────────────────────────────────────────
# Sources core/router/providers/<provider>.sh (ADR-003 amendment). The name is
# validated so a models.json value cannot climb out of providers/.
_route_provider_load() {
    local p="${1:-}" f
    [[ "$p" =~ ^[a-z][a-z0-9_-]*$ ]] || return 1
    f="$_ZBUILD_ROOT/core/router/providers/$p.sh"
    [[ -f "$f" ]] || return 1
    # shellcheck source=providers/anthropic.sh
    source "$f"
    declare -F "provider_${p//-/_}_resolve" >/dev/null 2>&1
}

# ─── _route_lookup_model <tier> <model_override> ─────────────────────────────
# Resolves the model for a tier. A candidate names {provider, family}; the
# provider module turns the family into the model to request — for anthropic,
# the CLI alias that always means the newest model of that family. A pinned
# `id` wins. Cost never comes from here: it is the provider's to report per call.
# Sets _ROUTE_MODEL_ID, _ROUTE_PROVIDER, _ROUTE_FAMILY, _ROUTE_CACHE_ELIGIBLE,
# _ROUTE_OVERRIDE_SOURCE.
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
        _ROUTE_PROVIDER="anthropic" _ROUTE_FAMILY="" _ROUTE_CACHE_ELIGIBLE="false"
        _route_provider_load anthropic || true
    elif [[ -n "${ZBUILD_PLUGIN_MODEL:-}" ]]; then
        _ROUTE_MODEL_ID="$ZBUILD_PLUGIN_MODEL"
        _ROUTE_OVERRIDE_SOURCE="env"
        _ROUTE_PROVIDER="anthropic" _ROUTE_FAMILY="" _ROUTE_CACHE_ELIGIBLE="false"
        _route_provider_load anthropic || true
    else
        local _cand
        _cand="$(jq -c ".tiers.${tier}.candidates[0] // empty" "$models_file" 2>/dev/null)" \
            || { error "failed to read candidates for tier $tier"; return 2; }
        if [[ -z "$_cand" ]]; then
            error "no candidates for tier $tier"; return 1
        fi
        local _pin
        # \x1f, not a tab: `read` collapses runs of whitespace IFS characters,
        # so an empty field (no pinned id) would shift every field after it.
        IFS=$'\x1f' read -r _ROUTE_PROVIDER _ROUTE_FAMILY _pin _ROUTE_CACHE_ELIGIBLE < <(jq -r \
            '[(.provider // ""), (.family // ""), (.id // ""), ((.cache_eligible // false) | tostring)] | join("\u001f")' <<< "$_cand")
        _ROUTE_PROVIDER="${_ROUTE_PROVIDER:-anthropic}"
        if ! _route_provider_load "$_ROUTE_PROVIDER"; then
            error "tier $tier names provider '$_ROUTE_PROVIDER', which has no module (core/router/providers/$_ROUTE_PROVIDER.sh)"
            return 2
        fi
        if [[ -n "$_pin" ]]; then
            _ROUTE_MODEL_ID="$_pin"; _ROUTE_OVERRIDE_SOURCE="candidates[0].id"
        elif ! _ROUTE_MODEL_ID="$("provider_${_ROUTE_PROVIDER//-/_}_resolve" "$_ROUTE_FAMILY")" || [[ -z "$_ROUTE_MODEL_ID" ]]; then
            error "provider '$_ROUTE_PROVIDER' cannot resolve family '${_ROUTE_FAMILY:-<none>}' for tier $tier"
            return 2
        else
            _ROUTE_OVERRIDE_SOURCE="provider:${_ROUTE_PROVIDER}/${_ROUTE_FAMILY}"
        fi
    fi
    return 0
}

# The limits a stage's model calls run under (_route_manifest_knob,
# _route_resolve_knob, _route_resolve_timeout, _route_resolve_max_turns) live in
# scripts/lib/stage-limits.sh, sourced above, so the engine states to every
# stage the same numbers this router enforces (ADR-067 §8).

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
        "family=${_ROUTE_FAMILY:-}" \
        "cache_eligible=${_ROUTE_CACHE_ELIGIBLE}" \
        "timeout_s=${secs}"
}

# ─── _route_check_budget <tier> ──────────────────────────────────────────────
# Returns 1 (recoverable) if ZBUILD_BUDGET_USD is set and exceeded.
_route_check_budget() {
    local tier="$1"
    local _budget_usd="${ZBUILD_BUDGET_USD:-}"
    [[ -z "$_budget_usd" ]] && return 0
    # A call in this run whose cost the provider could not report means the
    # ledger cannot prove the run is under the cap — refuse rather than guess.
    if [[ -n "${ZBUILD_STATE_DIR:-}" && -f "$ZBUILD_STATE_DIR/runtime/cost-unknown" ]]; then
        error "router: a call's cost could not be determined this run — refusing model call for tier=$tier under budget ${_budget_usd}"
        eb_emit_event "cost.budget_exceeded" "tier=$tier" \
            "model_id=$_ROUTE_MODEL_ID" "spent=unknown" "budget=${_budget_usd}" 2>/dev/null || true
        return 1
    fi

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

    # The prompt goes on stdin, never argv: one argv string over 128 KiB
    # (Linux MAX_ARG_STRLEN) cannot be exec'd at all — run 36238164552 lost
    # every review lens to "Argument list too long" on a 1,600-line diff.
    local -a _claude_args=(--print --model "$_ROUTE_MODEL_ID")
    if [[ "$max_turns" -gt 0 ]]; then
        _claude_args+=(--max-turns "$max_turns")
    else
        eb_emit_event "router.max_turns.flag_omitted" \
            "tier=$tier" "model_id=$_ROUTE_MODEL_ID" \
            "resolved=0" "source=$(_route_classify_max_turns_source)" 2>/dev/null || true
    fi
    _claude_args+=(--disallowed-tools "EnterPlanMode,ExitPlanMode")
    # #2448: a plugin whose calls need no tools gets none — built-in or MCP.
    _route_manifest_no_tools && _claude_args+=(--strict-mcp-config --tools "")
    # ADR-051: the stage's persona, as the provider takes it.
    _route_persona_prepare
    _claude_args+=("${_ROUTE_PERSONA_ARGS[@]+"${_ROUTE_PERSONA_ARGS[@]}"}")
    # Ensure scratch dir is set before permissions.sh runs; in test/golden
    # contexts ZBUILD_STAGE_SCRATCH may be unset and the fallback warning event
    # would appear in the golden sequence. Pick the engine tmpdir as the default
    # (same value permissions.sh would fall back to, without emitting the event).
    : "${ZBUILD_STAGE_SCRATCH:="$(zbuild_engine_tmpdir)"}"
    # #1919 (C10): abort spawn on settings build failure (SPEC-3).
    _zbuild_build_permissions_settings || return 2
    # mapfile, not $( ) word-splitting: --add-dir IS the grant now, and a scratch
    # path containing a space would split into two tokens, silently granting a
    # directory nobody named. A visible failure would be safer than that; a
    # correct tokenisation is safer still.
    local -a _perm_args=()
    mapfile -t _perm_args < <(_zbuild_permission_args)
    _claude_args+=("${_perm_args[@]}")
    # Always the JSON envelope: it is where the provider reports the call's cost
    # and the concrete model that answered (ADR-003 amendment). A caller that
    # did not ask for JSON still gets plain text — the router unwraps .result.
    # #2139: stream-json (needs --verbose under --print): a call killed at its
    # wall clock still returns the steps it made, not nothing.
    _claude_args+=(--output-format stream-json --verbose)

    # #2439 (ADR-054 §6a): one call. A timed-out or out-of-turns call is not
    # repeated here; the stage says how it ended and the engine decides.
    local stderr_file rc=0 response
    # TERM-only (`none`), as this bound has always been: a -k here would turn
    # a hang into rc=137, which reads as an out-of-memory kill, not a timeout.
    _acceptance_timeout_prefix "$secs" none
    local -a _tout_cmd=(${_ACCEPTANCE_TOUT[@]+"${_ACCEPTANCE_TOUT[@]}"})
    if ! stderr_file="$(mktemp "$(zbuild_engine_tmpdir)/zb-router-stderr.XXXXXX" 2>/dev/null)"; then
        error "router: mktemp failed"
        eb_emit_event "router.error" "tier=$tier" "model_id=$_ROUTE_MODEL_ID" "reason=mktemp_failed"
        return 2
    fi
    local _prompt_in
    if ! _prompt_in="$(mktemp "$(zbuild_engine_tmpdir)/zb-router-prompt.XXXXXX" 2>/dev/null)" \
        || ! printf '%s' "$prompt" > "$_prompt_in"; then
        rm -f "$stderr_file" "${_prompt_in:-}"
        error "router: could not stage the prompt"
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
    declare -F stage_cutoff_clear >/dev/null 2>&1 && stage_cutoff_clear
    if [[ ${#_tout_cmd[@]} -gt 0 ]]; then
        response="$(
            _zbuild_make_fresh_shell
            "${_tout_cmd[@]}" claude "${_claude_args[@]}" <"$_prompt_in" 2>"$stderr_file"
        )" || rc=$?
    else
        response="$(
            _zbuild_make_fresh_shell
            claude "${_claude_args[@]}" <"$_prompt_in" 2>"$stderr_file"
        )" || rc=$?
    fi
    # #2139: keep the step stream for the diagnostic; everything below reads
    # the envelope, exactly as it did when the CLI printed only that.
    local _sync_stream="$response"
    response="$(_route_stream_envelope_text <<< "$_sync_stream")"

    if [[ $rc -ne 0 ]]; then
        # Wave 19-K (#748) + #762: mirror Wave 19-I Fix B for the SYNC path.
        # Persist diagnostic artifacts BEFORE the terse error log so the
        # human-readable message can cite the diagnostic path and include
        # parsed fields (#762: surface error_max_turns subtype to terminal).
        local _sync_diag_dir="${ZBUILD_ARTIFACT_DIR:-${ZBUILD_STATE_DIR:-${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}}/artifacts}/stage-io"
        mkdir -p "$_sync_diag_dir" 2>/dev/null || true
        local _sync_diag_base; _sync_diag_base="$(_route_sync_diag_base)"
        local _sync_json_path="$_sync_diag_dir/${_sync_diag_base}.raw-claude-output.json"
        local _sync_stderr_path="$_sync_diag_dir/${_sync_diag_base}.raw-claude-stderr.txt"
        # #2139: a killed call has no envelope — keep its step stream instead.
        if [[ -z "$response" && -n "$_sync_stream" ]]; then
            printf '%s' "$_sync_stream" > "$_sync_json_path" 2>/dev/null || _sync_json_path=""
        else
            printf '%s' "$response" > "$_sync_json_path" 2>/dev/null || _sync_json_path=""
        fi
        [[ $rc -eq 124 && -n "$_sync_json_path" ]] && declare -F stage_cutoff_write >/dev/null 2>&1 \
            && stage_cutoff_write "$_sync_json_path"
        if [[ -f "$stderr_file" ]]; then
            cp "$stderr_file" "$_sync_stderr_path" 2>/dev/null || _sync_stderr_path=""
        else
            : > "$_sync_stderr_path" 2>/dev/null || _sync_stderr_path=""
        fi
        # Parse JSON envelope fields once; #762 adds subtype/output_tokens/cost.
        local _sync_is_error="" _sync_err_text="" _sync_num_turns="" _sync_subtype="" _sync_out_tokens="" _sync_cost="" _sync_api_status=""
        local _sync_last_tool=""
        if [[ -z "$response" && -n "$_sync_stream" && -n "$_sync_json_path" ]]; then
            # #2139 (review on #2253): killed before its result — the stream is
            # the record, so read the turns and the last tool from it.
            local _sync_prog; _sync_prog="$(_route_stream_progress "$_sync_json_path")"
            _sync_num_turns="${_sync_prog%% *}"; _sync_last_tool="${_sync_prog#* }"
            [[ "$_sync_num_turns" == "0" ]] && _sync_num_turns=""
        elif [[ -n "$_sync_json_path" && -f "$_sync_json_path" ]]; then
            _sync_is_error="$(jq -r '.is_error // empty' "$_sync_json_path" 2>/dev/null || true)"
            if _sync_err_text="$(jq -r '.error // empty' "$_sync_json_path" 2>/dev/null)"; then
                _sync_err_text="${_sync_err_text:0:200}"
            else
                _sync_err_text="<unreadable>"
            fi
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
            # #1823: arm the durable marker so the engine can classify a dispatch
            # that dies after this as `throttled`. Both router paths write the
            # same channel — the engine must not have to know which path a stage
            # happened to take to learn that it was rate-limited.
            _router_arm_throttle_marker "$_sync_rl_msg"
        fi
        # #762: surface error_max_turns to the terminal with a human-readable
        # one-liner. Falls back to the legacy stderr-snip message otherwise.
        local snip; snip="$(head -c 200 "$stderr_file" 2>/dev/null || true)"
        if [[ "$_sync_rate_limited" == "1" ]]; then
            error "$_sync_rl_msg (model=$_ROUTE_MODEL_ID tier=$tier) — diagnostic: ${_sync_json_path:-absent}"
        elif [[ "$_sync_subtype" == "error_max_turns" ]]; then
            # #2187: the stage's classifier names this `out_of_turns`.
            _ROUTE_LAST_BUDGET_EXHAUSTED=1
            # #1847: the variable dies with the caller's `$( )`; the marker does not.
            _router_arm_budget_marker
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
            "last_tool=${_sync_last_tool:-absent}" \
            "subtype=${_sync_subtype:-absent}" \
            2>/dev/null || true
        rm -f "$stderr_file" "$_prompt_in"
        # A failed call can still have been billed; the provider says what it cost.
        _route_record_call "$response"
        _route_update_ledger
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
    rm -f "$stderr_file" "$_prompt_in"

    if [[ -z "$response" ]]; then
        error "claude CLI returned empty response model=$_ROUTE_MODEL_ID tier=$tier"
        eb_emit_event "router.error" "tier=$tier" "model_id=$_ROUTE_MODEL_ID" "reason=empty_response"
        return 1
    fi

    # JSON output mode: extract .result and token counts
    _ROUTE_INPUT_TOKENS=0 _ROUTE_OUTPUT_TOKENS=0
    _ROUTE_CACHE_READ=0 _ROUTE_CACHE_CREATION=0
    _ROUTE_TOOL_USES_JSON="[]"
    _route_record_call "$response"
    local _is_envelope=0
    jq -e 'type == "object" and has("result")' <<< "$response" >/dev/null 2>&1 && _is_envelope=1
    if [[ "$_is_envelope" == "1" || "${ZBUILD_ROUTER_JSON_OUTPUT:-0}" == "1" ]]; then
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
}

# ─── _route_emit_outcome <tier> <timeout_s> ──────────────────────────────────
_route_emit_outcome() {
    local tier="$1" secs="${2:-}"
    eb_emit_event "model.outcome" \
        "tier=$tier" \
        "model_id=$_ROUTE_MODEL_ID" \
        "provider=${_ROUTE_PROVIDER:-}" \
        "model_used=${_ROUTE_MODEL_USED:-}" \
        "cost_usd=${_ROUTE_CALL_COST:-unknown}" \
        "cache_eligible=${_ROUTE_CACHE_ELIGIBLE}" \
        "input_tokens=$_ROUTE_INPUT_TOKENS" \
        "output_tokens=$_ROUTE_OUTPUT_TOKENS" \
        "cache_read_input_tokens=$_ROUTE_CACHE_READ" \
        "cache_creation_input_tokens=$_ROUTE_CACHE_CREATION" \
        "timeout_s=${secs}"
}

# ─── _route_loop_report_call <tier> <timeout_s> <envelope> ───────────────────
# #1730: every loop call the provider billed gets a ledger row AND a
# model.outcome, so the two always count the same — success, failure, or a
# timeout after LOOP_COMPLETE alike.
_route_loop_report_call() {
    local tier="$1" secs="$2" envelope="${3:-}" usage
    _route_record_call "$envelope"
    _route_update_ledger
    usage="$(jq -r '.usage // {} | "\(.input_tokens // 0) \(.output_tokens // 0) \(.cache_read_input_tokens // 0) \(.cache_creation_input_tokens // 0)"' <<< "$envelope" 2>/dev/null || true)"
    [[ -n "$usage" ]] || usage="0 0 0 0"
    read -r _ROUTE_INPUT_TOKENS _ROUTE_OUTPUT_TOKENS _ROUTE_CACHE_READ _ROUTE_CACHE_CREATION <<< "$usage"
    _route_emit_outcome "$tier" "$secs"
}

# ─── _route_record_call <raw_response> ───────────────────────────────────────
# Asks the call's provider what it cost and which model answered (ADR-003
# amendment). Sets _ROUTE_CALL_COST (empty = the provider could not say) and
# _ROUTE_MODEL_USED.
_route_record_call() {
    local raw="${1:-}" p="${_ROUTE_PROVIDER:-anthropic}"
    p="${p//-/_}"
    _ROUTE_CALL_COST="" _ROUTE_MODEL_USED=""
    declare -F "provider_${p}_call_cost" >/dev/null 2>&1 \
        && _ROUTE_CALL_COST="$("provider_${p}_call_cost" "$raw")"
    declare -F "provider_${p}_model_used" >/dev/null 2>&1 \
        && _ROUTE_MODEL_USED="$("provider_${p}_model_used" "$raw")"
    return 0
}

# ─── _route_update_ledger ─────────────────────────────────────────────────────
# Appends the call's provider-reported cost to the cost ledger. The ledger path
# resolves via ZBUILD_COST_LEDGER (default ~/.zbuild/cost-ledger.jsonl) so a
# nested run can be fenced to its own ledger (#1214). A cost the provider could
# not report is never written as 0: it is evented and marked on the run, and
# _route_check_budget refuses further calls under a cap. Non-fatal on failure.
_route_update_ledger() {
    if [[ -z "${_ROUTE_CALL_COST:-}" ]]; then
        eb_emit_event "router.cost.unknown" "provider=${_ROUTE_PROVIDER:-}" \
            "model_id=$_ROUTE_MODEL_ID" "stage=${ZBUILD_CURRENT_STAGE:-unknown}" 2>/dev/null || true
        if [[ -n "${ZBUILD_STATE_DIR:-}" ]]; then
            mkdir -p "$ZBUILD_STATE_DIR/runtime" 2>/dev/null \
                && : > "$ZBUILD_STATE_DIR/runtime/cost-unknown" 2>/dev/null || true
        fi
        return 0
    fi
    local _call_cost_usd
    _call_cost_usd="$(awk -v c="$_ROUTE_CALL_COST" 'BEGIN{printf "%.6f", c+0}' 2>/dev/null || echo 0)"
    [[ "$_call_cost_usd" == "0.000000" ]] && return 0

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
# One agentic model call in $cwd: the model edits the working tree itself, and
# says `LOOP_COMPLETE` in its .result when the work is done. The LLM never
# emits a diff string; the caller reads `git diff HEAD` after the call returns.
# #2439 (ADR-054 §6a): ONE call per try. A call that does not finish ends the
# try with its reason; the engine runs the stage again (stage_retry_next).
#
# Usage:
#   route_to_model_loop <tier> <prompt_file> <cwd> \
#       [--max-turns-per-call N] [--done-sentinel TOKEN] \
#       [--inter-turn-hook FN] [--model ID] [--scope-allowlist CSV] \
#       [--defer-final-banner-close]
#
# Globals set:
#   _ROUTE_LOOP_ITERATIONS         — 1 once the call is made
#   _ROUTE_LOOP_TERMINATED_REASON  — done_sentinel | no_done_sentinel |
#                                    router_timeout | router_rate_limited |
#                                    signal | a _router_rc_classify reason
#   _ROUTE_LOOP_INPUT_TOKENS       — .usage.input_tokens
#   _ROUTE_LOOP_OUTPUT_TOKENS      — .usage.output_tokens
#   _ROUTE_LOOP_LAST_RESPONSE      — (#608) the call's result_text; the
#                                    FALLBACK for the build commit parser.
#   _ROUTE_LOOP_ITER_SUMMARIES     — (#1329) the call's COMMIT_SUMMARY value,
#                                    parsed + sanitized AT THE SOURCE. Storing
#                                    only the parsed one-line summary (not raw
#                                    result_text) prevents adversarial control
#                                    bytes in the LLM output from being read as
#                                    record boundaries (#1329 review).
#
# Returns: 0 on DONE-sentinel or a timeout (non-fatal, #1208), 1 when the call
# did not finish otherwise, 2 on a setup error, 130 on a signal.
_ROUTE_LOOP_ITERATIONS=0
_ROUTE_LOOP_TERMINATED_REASON=""
# #2111: the operator line the rate limit produced ("resets 3pm (UTC)"), for
# the stage to carry in its result — the engine ends the run on it.
_ROUTE_LOOP_RATE_LIMIT_MESSAGE=""
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
# caller passed --defer-final-banner-close AND the call reached the
# DONE-sentinel exit path (other exit reasons — no_done_sentinel, a failed
# call, signal — keep the legacy immediate
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
    # #2029: record whether the abort could target a process GROUP or had to fall
    # back to the single PID. The two paths reach different processes — a group
    # kill sweeps the child's descendants, a PID kill does not — so which one ran
    # is the first thing anyone investigating a surviving child needs to know, and
    # nothing recorded it. Operationally useful in its own right: an abort that
    # could not isolate a group is weaker than the contract assumes.
    eb_emit_event "loop.terminated.signal" \
        "signal=$sig" \
        "pg_kill=$([[ -n "$_pgid" ]] && printf 'group' || printf 'pid_only')" \
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

# ─── #2139: the model call's step stream ──────────────────────────────────────
# The loop asks the CLI for `stream-json`: one JSON line per step, written as it
# happens. A call killed at its wall clock used to leave nothing — the `json`
# format prints its one envelope only at the end — so a timeout could not say
# what the model had been doing (#1844 run 36969128968: 12 empty captures).

# _route_stream_envelope_text — stdin: what the CLI printed; stdout: the call's
# final envelope. One jq pass reads JSON lines and pretty-printed JSON alike:
# the last `"type":"result"` object when the output is a step stream; the whole
# output when it is no stream (a plain envelope or text, as stubs and older CLIs
# print); nothing when the stream ended before a result (a killed call).
_route_stream_envelope_text() {
    local raw; raw="$(cat)"
    [[ -n "$raw" ]] || return 0
    local env
    if env="$(jq -sc 'if ([.[] | objects | select(has("type"))] | length) == 0 then "__PLAIN__"
                      else ([.[] | objects | select(.type == "result")] | last // "__NONE__") end' \
                <<< "$raw" 2>/dev/null)"; then
        case "$env" in
            '"__PLAIN__"') printf '%s' "$raw" ;;
            '"__NONE__"')  ;;
            *)             printf '%s\n' "$env" ;;
        esac
    else
        printf '%s' "$raw"   # not JSON at all: hand it on unchanged
    fi
}

# _route_stream_envelope <stream_file> <envelope_out> — the same, file to file.
_route_stream_envelope() {
    _route_stream_envelope_text 2>/dev/null < "$1" > "$2" || : > "$2"
}

# _route_stream_progress <stream_file> — "<turns> <last_tool>" read from the
# stream: assistant messages so far, and the last tool the model called.
_route_stream_progress() {
    local stream="$1"
    [[ -s "$stream" ]] || { printf '0 '; return 0; }
    jq -rs '
        [ .[] | select(type == "object" and .type == "assistant") ] as $a
        | ([ $a[] | .message.content[]? | select(.type == "tool_use") | .name ] | last // "") as $t
        | "\($a | length) \($t)"
    ' "$stream" 2>/dev/null || printf '0 '
}

route_to_model_loop() {
    # Reset before ANY return: an early exit must not leave the previous loop's
    # reason (a stale done_sentinel reads as success to the caller) — #2225.
    _ROUTE_LOOP_TERMINATED_REASON=""
    if [[ $# -lt 3 ]]; then
        error "route_to_model_loop requires <tier> <prompt_file> <cwd>"
        return 2
    fi
    local tier="$1" prompt_file="$2" cwd="$3"; shift 3

    local max_turns_per_call=""
    local done_sentinel="LOOP_COMPLETE"
    local inter_turn_hook="_route_loop_default_hook"
    local model_override=""
    local scope_allowlist=""
    # #646: when set, route_to_model_loop returns WITHOUT closing the call's
    # stage-io banner ONLY on the DONE-sentinel exit path. Other exit
    # paths (no_done_sentinel, error rc≥2, SIGINT) keep the
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

    local secs; secs="$(_route_resolve_timeout)"

    _ROUTE_LOOP_ITERATIONS=0
    _ROUTE_LOOP_TERMINATED_REASON=""
    _ROUTE_LOOP_RATE_LIMIT_MESSAGE=""
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

    # A temp dir outside the caller's artifacts dir so the parity goldens that
    # snapshot artifact filenames are not polluted by the call's files.
    local _loop_tmp; _loop_tmp="$(mktemp -d "$(zbuild_engine_tmpdir)/zb-loop-iters.XXXXXX")"
    # #628: function-scoped RETURN trap self-cleans on every exit path
    # (SIGINT propagation, timeout, done_sentinel, no_done_sentinel). RETURN fires per-function-frame; does not
    # conflict with the runner's SCRIPT-level EXIT trap or the loop's
    # INT/TERM signal traps installed by _route_loop_install_traps.
    # Single-quoted body: $_loop_tmp is expanded NOW and frozen into the
    # trap action, so any future reassignment can't redirect rm.
    # shellcheck disable=SC2064
    trap "rm -rf '$_loop_tmp' 2>/dev/null || true" RETURN

    local static_prompt
    static_prompt="$(cat "$prompt_file")"
    # #2439 (ADR-054 §6a, ADR-018 amended 2026-10-31): ONE model call per try.
    # A call that does not finish ends the try with its reason, and the engine
    # runs the stage again when the outcome says so and the template's retry:
    # allows (stage_retry_next). Nothing here repeats the call.
    local iter=1
    # The spending cap is checked before the call.
    _route_check_budget "$tier" || {
        # #2225: named, so the stage can say why it stopped (misconfigured —
        # the operator's cap), instead of an empty reason.
        _ROUTE_LOOP_TERMINATED_REASON="router_budget_exceeded"
        _route_loop_clear_traps; return 1; }
    _ROUTE_LOOP_ITERATIONS=1

    # The call gets the stage's prompt as the stage composed it (ADR-067
    # §8). No header, diff or branch summary is added: the code is in the
    # worktree, and the stage's notes file and Previous work carry what
    # earlier tries did.
    local iter_prompt="$static_prompt"

    # Redaction by construction (ADR-043). Shared with single-shot
    # route_to_model via _route_redact_prompt: emits the canonical
    # redaction.applied (or fail-closed refused). The call stays fail-OPEN
    # on a redaction error (|| cp) — it does not gate on C6.
    local iter_prompt_file="${_loop_tmp}/iter-${iter}.txt"
    local iter_redacted_file="${_loop_tmp}/iter-${iter}.redacted.txt"
    printf '%s\n' "$iter_prompt" > "$iter_prompt_file"

    if ! _route_redact_prompt "$iter_prompt_file" "$iter_redacted_file" "$iter" "$scope_allowlist"; then
        # A stage prompt out of the contract order is never sent (ADR-067
        # §8). Misconfigured, not a model failure.
        if [[ "${_ROUTE_PROMPT_REFUSED:-0}" == "1" ]]; then
            _ROUTE_LOOP_TERMINATED_REASON="router_config_error"
            _route_loop_clear_traps; return 1
        fi
        cp "$iter_prompt_file" "$iter_redacted_file"
    fi

    local final_prompt; final_prompt="$(cat "$iter_redacted_file")"

    eb_emit_event "loop.iteration" \
        "tier=$tier" "iteration=$iter" \
        "model_id=$_ROUTE_MODEL_ID" "cwd=$cwd" 2>/dev/null || true
    _route_emit_model_route "$tier" "$secs"

    local banner_input="$final_prompt"

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
    # ZBUILD_STAGE_SCRATCH first (ADR-058 §2): the dispatch seam redirects
    # TMPDIR to it, but this loop also runs where that redirect is not in
    # scope, and `${TMPDIR:-/tmp}` then resolves to /tmp — outside every
    # ADR-058 area. Naming the area directly does not depend on inheritance.
    local _rt_tmp; _rt_tmp="$(zbuild_engine_tmpdir)"
    stderr_file="$(mktemp "${_rt_tmp}/zb-loop-stderr.XXXXXX")"
    json_file="$(mktemp "${_rt_tmp}/zb-loop-json.XXXXXX")"

    # The prompt goes on stdin, never argv (MAX_ARG_STRLEN — see route_to_model).
    # In $_loop_tmp, so the RETURN trap removes it on every exit path.
    local _prompt_in="${_loop_tmp}/iter-${iter}.prompt"
    local _stream_file="${_loop_tmp}/iter-${iter}.stream.jsonl"
    printf '%s' "$final_prompt" > "$_prompt_in"
    # #2443: the list of a cut-off call is only ever about the call just before.
    declare -F stage_cutoff_clear >/dev/null 2>&1 && stage_cutoff_clear
    local -a _claude_args=(--print --model "$_ROUTE_MODEL_ID")
    # ADR-018 Amendment N (#762): omit --max-turns when sentinel mt=0.
    if [[ "$mt" -gt 0 ]]; then
        _claude_args+=(--max-turns "$mt")
    else
        eb_emit_event "router.max_turns.flag_omitted" \
            "tier=$tier" "model_id=$_ROUTE_MODEL_ID" \
            "resolved=0" "source=$(_route_classify_max_turns_source)" 2>/dev/null || true
    fi
    _claude_args+=(--disallowed-tools "EnterPlanMode,ExitPlanMode")
    # ADR-051: the stage's persona, as the provider takes it.
    _route_persona_prepare
    _claude_args+=("${_ROUTE_PERSONA_ARGS[@]+"${_ROUTE_PERSONA_ARGS[@]}"}")
    : "${ZBUILD_STAGE_SCRATCH:="$_rt_tmp"}"
    # #1919 (C10): abort iteration on settings build failure (SPEC-3).
    _zbuild_build_permissions_settings || {
        _ROUTE_LOOP_TERMINATED_REASON="router_config_error"
        rm -f "$stderr_file" "$json_file"
        _route_loop_clear_traps; return 1; }
    # mapfile, not $( ) word-splitting — see the single-shot site above.
    local -a _perm_args=()
    mapfile -t _perm_args < <(_zbuild_permission_args)
    _claude_args+=("${_perm_args[@]}")
    # #2139: stream-json (needs --verbose under --print) — every step lands
    # on disk as it happens, so a killed call still leaves its record.
    _claude_args+=(--output-format stream-json --verbose)

    rc=0
    # TERM-only, as in _route_call_claude (#1752).
    _acceptance_timeout_prefix "$secs" none
    local -a _tout_cmd=(${_ACCEPTANCE_TOUT[@]+"${_ACCEPTANCE_TOUT[@]}"})

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
    # Wave 15-G (#687): the claude tree lives in its own process group, so
    # _route_loop_on_signal TERM/KILLs the whole group rather than the
    # top-level PID. That is what lets the loop pre-abort in <2.5s even when
    # claude, or any child it spawned, ignores or delays SIGTERM.
    #
    # #2056: `set -m` — bash job control — puts the backgrounded job in its
    # OWN PROCESS GROUP, so PGID == $!. `kill -- -$!` then reaches the whole
    # claude tree, and `exec` keeps $! pointing at the real process rather
    # than a wrapping subshell.
    #
    # This replaced `setsid -w`, which was wrong here in two ways.
    #
    # It does not exist on macOS. The prefix went empty, no group was made,
    # and the abort degraded to killing one PID while every descendant
    # survived — so Wave 15-G's "an abort leaves nothing running" held on
    # Linux only. Nothing reported that, because the test covering it is
    # `skip_unless_platform linux`.
    #
    # And `-w` defeated the `exec` above. setsid only execs in place when it
    # need not survive; with `-w` it MUST fork, because it waits for the
    # child and returns its exit status. So $! was the setsid wrapper, still
    # in the runner's group, while the new session belonged to a process one
    # fork below — precisely the failure the old comment here described and
    # believed `exec` had prevented.
    #
    # Job control is POSIX and behaves identically on macOS and Linux, needs
    # no external binary, and gives PGID == PID deterministically. It is
    # already used for exactly this in core/pipeline/runner.sh,
    # plugins/tool/test/plugin.sh and three integration tests.
    #
    # Opened and closed tightly: `set -m` also turns on job-control messages
    # on stderr, which is noise anywhere but the spawn itself.
    set -m
    if [[ ${#_tout_cmd[@]} -gt 0 ]]; then
        (
            cd "$cwd" || exit 99
            _zbuild_make_fresh_shell
            # stdin AFTER the fresh shell: it points stdin at /dev/null (#2108).
            exec "${_tout_cmd[@]}" claude "${_claude_args[@]}" <"$_prompt_in"
        ) >"$_stream_file" 2>"$stderr_file" &
    else
        (
            cd "$cwd" || exit 99
            _zbuild_make_fresh_shell
            exec claude "${_claude_args[@]}" <"$_prompt_in"
        ) >"$_stream_file" 2>"$stderr_file" &
    fi
    _ROUTE_LOOP_CHILD_PID=$!
    set +m
    # Wave 15-G (#687), extracted in #1748. Empty means the group is not
    # provably distinct from the runner's own, so the handler falls back to
    # the per-PID kill (Wave 8 #612) rather than `kill -- -PGID`-ing itself.
    _ROUTE_LOOP_CHILD_PGID="$(zbuild_pg_resolve "$_ROUTE_LOOP_CHILD_PID")"
    # #2024: register it, so the group survives this shell. The in-memory
    # variable above is enough for the signal handler, which runs while the
    # runner is alive — but a SIGKILLed runner leaves nothing behind, and a
    # model spawn is the longest-lived child a stage has. On disk it is
    # reachable by `zbuild cleanup --pgroups` afterwards (#2018).
    zbuild_pg_register "$_ROUTE_LOOP_CHILD_PGID" 2>/dev/null || true
    wait "$_ROUTE_LOOP_CHILD_PID" 2>/dev/null || rc=$?
    _ROUTE_LOOP_CHILD_PID=""
    _ROUTE_LOOP_CHILD_PGID=""
    # #2139: the envelope everything below reads is the stream's result line.
    _route_stream_envelope "$_stream_file" "$json_file"

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

    if [[ $rc -ne 0 ]]; then
        # Wave 19-I Fix A (#743): if rc=124 (gtimeout SIGTERM) AND the
        # captured .result already contains LOOP_COMPLETE on its own
        # line, claude finished the work but the wrapper killed it
        # during final CLI exit. Honor the sentinel and end the try with
        # done_sentinel rather than discarding the work-done signal. Dogfood 20260607181657-82646
        # iter 4 exhibited this: 900s wall time + LOOP_COMPLETE in
        # output + rc=124 → loop wasted iter 5 on already-complete code.
        if [[ $rc -eq 124 && -s "$json_file" ]]; then
            local _rc124_result
            _rc124_result="$(jq -r '.result // empty' "$json_file" 2>/dev/null || true)"
            if _route_has_done_sentinel "$done_sentinel" "$_rc124_result"; then
                _route_loop_report_call "$tier" "$secs" "$(<"$json_file")"
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
        local _diag_try; _diag_try="$(_route_try_suffix)"
        local _diag_base="${_iter_stage_id:-loop}${_diag_try:--iter${iter}}-error"
        local _diag_json_path=""
        local _diag_stderr_path=""
        if [[ -f "$json_file" ]]; then
            _diag_json_path="$_diag_dir/${_diag_base}.raw-claude-output.json"
            # #2139: no envelope (killed before its result) → keep the step
            # stream itself, which is the only record of what the call did.
            if [[ ! -s "$json_file" && -s "${_stream_file:-}" ]]; then
                cp "$_stream_file" "$_diag_json_path" 2>/dev/null || _diag_json_path=""
            else
                cp "$json_file" "$_diag_json_path" 2>/dev/null || _diag_json_path=""
            fi
        fi
        # #2443: a call cut off at its limit leaves its steps for the next try.
        [[ $rc -eq 124 && -n "$_diag_json_path" ]] && declare -F stage_cutoff_write >/dev/null 2>&1 \
            && stage_cutoff_write "$_diag_json_path"
        if [[ -f "$stderr_file" ]]; then
            _diag_stderr_path="$_diag_dir/${_diag_base}.raw-claude-stderr.txt"
            cp "$stderr_file" "$_diag_stderr_path" 2>/dev/null || _diag_stderr_path=""
        fi
        # Parse envelope fields once; #762 adds subtype/cost.
        local _diag_is_error="" _diag_err_text="" _diag_num_turns="" _diag_out_tokens="" _diag_subtype="" _diag_cost=""
        local _diag_last_tool=""
        if [[ ! -s "$json_file" && -s "${_stream_file:-}" ]]; then
            # Killed before its result: count the turns the stream recorded.
            local _diag_prog; _diag_prog="$(_route_stream_progress "$_stream_file")"
            _diag_num_turns="${_diag_prog%% *}"; _diag_last_tool="${_diag_prog#* }"
            [[ "$_diag_num_turns" == "0" ]] && _diag_num_turns=""
        elif [[ -n "$_diag_json_path" ]]; then
            _diag_is_error="$(jq -r '.is_error // empty' "$_diag_json_path" 2>/dev/null || true)"
            if _diag_err_text="$(jq -r '.error // empty' "$_diag_json_path" 2>/dev/null)"; then
                _diag_err_text="${_diag_err_text:0:200}"
            else
                _diag_err_text="<unreadable>"
            fi
            _diag_num_turns="$(jq -r '.num_turns // empty' "$_diag_json_path" 2>/dev/null || true)"
            _diag_out_tokens="$(jq -r '.usage.output_tokens // empty' "$_diag_json_path" 2>/dev/null || true)"
            _diag_subtype="$(jq -r '.subtype // empty' "$_diag_json_path" 2>/dev/null || true)"
            _diag_cost="$(jq -r '.total_cost_usd // empty' "$_diag_json_path" 2>/dev/null || true)"
        fi
        # #1823 (absorbs #1723): the rate-limit detector's SECOND caller.
        # `_route_call_claude` has detected a 429/529 envelope since #1237,
        # but this loop does not go through `_route_call_claude` — it spawns
        # claude directly — so the one path that could name the failure never
        # saw it. A rate limit surfaced here as `reason=claude_rc_nonzero` and
        # was then called again, against the same limit, until the call limit
        # ran out at zero output (#1723).
        #
        # Detect on the envelope COPY (`_diag_json_path`), because the
        # original `$json_file` is removed on every error path below.
        # Read the envelope ONCE. Two `$(cat ...)` substitutions would fork
        # twice per failing iteration for the same bytes (review finding).
        local _loop_rate_limited=0 _loop_rl_msg="" _loop_envelope=""
        if [[ -n "$_diag_json_path" ]]; then
            _loop_envelope="$(cat "$_diag_json_path" 2>/dev/null || true)"
        fi
        # A failed iteration can still have been billed; the provider says.
        _route_loop_report_call "$tier" "$secs" "$_loop_envelope"
        if [[ -n "$_loop_envelope" ]] && _router_is_rate_limit "$_loop_envelope"; then
            _loop_rate_limited=1
            _loop_rl_msg="$(_router_rate_limit_message "$_loop_envelope")"
        fi
        # #762: surface error_max_turns subtype with a human-readable line.
        # Falls back to the legacy stderr-snip warning otherwise.
        local snip; snip="$(head -c 200 "$stderr_file" 2>/dev/null || true)"
        if [[ "$_loop_rate_limited" == "1" ]]; then
            error "$_loop_rl_msg (model=$_ROUTE_MODEL_ID iter=$iter) — diagnostic: ${_diag_json_path:-absent}"
        elif [[ "$_diag_subtype" == "error_max_turns" ]]; then
            error "claude max_turns reached (turns=${_diag_num_turns:-?}, output_tokens=${_diag_out_tokens:-?}, cost=\$${_diag_cost:-?}) — diagnostic: ${_diag_json_path:-absent}"
        else
            warn "route_to_model_loop: claude rc=$rc iter=$iter${snip:+: $snip}"
        fi
        eb_emit_event "loop.iteration.error" \
            "iteration=$iter" "rc=$rc" \
            "model_id=$_ROUTE_MODEL_ID" \
            "reason=$([[ "$_loop_rate_limited" == "1" ]] && printf 'router_rate_limited' || printf 'claude_rc_nonzero')" 2>/dev/null || true
        if [[ "$_loop_rate_limited" == "1" ]]; then
            eb_emit_event "router.rate_limited" \
                "tier=$tier" "model_id=$_ROUTE_MODEL_ID" "rc=$rc" \
                "stage=${ZBUILD_CURRENT_STAGE:-unknown}" \
                "iteration=$iter" \
                "message=$_loop_rl_msg" 2>/dev/null || true
        fi
        # #2183: the diagnostic reaches the OTHER stages, not only the
        # event log. One seam covers every router-backed stage — build,
        # design, plan, test-author, the judges and the lenses.
        if declare -F stage_errors_append >/dev/null 2>&1; then
            stage_errors_append "${_iter_stage_id:-${ZBUILD_CURRENT_STAGE:-}}" \
                "model call iter=$iter rc=$rc${_diag_subtype:+ subtype=$_diag_subtype}${_diag_num_turns:+ turns=$_diag_num_turns}${_diag_err_text:+: $_diag_err_text}"
            stage_errors_append_file "${_iter_stage_id:-${ZBUILD_CURRENT_STAGE:-}}" \
                "${_diag_stderr_path:-}" "model call iter=$iter stderr"
        fi
        eb_emit_event "router.loop.iter.error.diagnostic" \
            "iteration=$iter" "rc=$rc" \
            "stage=${_iter_stage_id:-unknown}" \
            "raw_json_path=${_diag_json_path:-absent}" \
            "raw_stderr_path=${_diag_stderr_path:-absent}" \
            "is_error=${_diag_is_error:-absent}" \
            "error_text=${_diag_err_text:-absent}" \
            "num_turns=${_diag_num_turns:-absent}" \
            "last_tool=${_diag_last_tool:-absent}" \
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
        # #1823: a rate limit ENDS the loop rather than iterating into it.
        # Retrying against a limit that has not reset yet cannot change the
        # outcome — every further iteration spends budget to be refused
        # again. The marker is armed so the engine's fallback classification
        # can resolve this dispatch to `throttled` (wait, then retry) instead
        # of `broken` (halt), which is the difference between a run that
        # resumes when the limit resets and one that is dead.
        if [[ "$_loop_rate_limited" == "1" ]]; then
            _ROUTE_LOOP_TERMINATED_REASON="router_rate_limited"
            _ROUTE_LOOP_RATE_LIMIT_MESSAGE="$_loop_rl_msg"
            _router_arm_throttle_marker "$_loop_rl_msg"
            rm -f "$stderr_file" "$json_file"
            _route_loop_clear_traps
            return 1
        fi
        rm -f "$stderr_file" "$json_file"
        if [[ $rc -eq 124 ]]; then
            # Issue #1208 / ADR-013: a timeout is never fatal. It ends THIS
            # try (non-fatal return 0) as router_timeout → timed_out, and the
            # engine decides whether there is another try (#2439). The
            # committed partial work is preserved (#602). warn, not error.
            warn "route_to_model_loop: the model call timed out — the try ends timed_out"
            _ROUTE_LOOP_TERMINATED_REASON="router_timeout"
            eb_emit_event "loop.timeout_yield" \
                "iterations=$iter" "model_id=$_ROUTE_MODEL_ID" \
                "reason=router_timeout" 2>/dev/null || true
            _route_loop_clear_traps
            return 0
        fi
        # Any other failure is named as a single-call stage names it.
        [[ "$_diag_subtype" == "error_max_turns" ]] && _ROUTE_LAST_BUDGET_EXHAUSTED=1
        local _fail_v="" _fail_reason=""
        _router_rc_classify "$rc" _fail_v _fail_reason 2>/dev/null || _fail_reason="router_rc_nonzero"
        _ROUTE_LOOP_TERMINATED_REASON="${_fail_reason:-router_rc_nonzero}"
        _route_loop_clear_traps
        return 1
    fi
    rm -f "$stderr_file"

    # Extract .result and token usage from claude JSON output.
    local result_text="" in_tok=0 out_tok=0
    result_text="$(jq -r '.result // empty' "$json_file" 2>/dev/null || true)"
    in_tok="$(jq -r '.usage.input_tokens // 0' "$json_file" 2>/dev/null || echo 0)"
    out_tok="$(jq -r '.usage.output_tokens // 0' "$json_file" 2>/dev/null || echo 0)"
    _ROUTE_LOOP_INPUT_TOKENS=$(( _ROUTE_LOOP_INPUT_TOKENS + in_tok ))
    _ROUTE_LOOP_OUTPUT_TOKENS=$(( _ROUTE_LOOP_OUTPUT_TOKENS + out_tok ))
    # ADR-003 amendment: the iteration's cost, as the provider reports it.
    _route_loop_report_call "$tier" "$secs" "$(<"$json_file")"
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
    if _route_has_done_sentinel "$done_sentinel" "$result_text"; then
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
    # The call ended without saying it is done: its output cannot be used
    # as a finished try (unusable). The engine decides whether to try again.
    _ROUTE_LOOP_TERMINATED_REASON="no_done_sentinel"
    eb_emit_event "loop.unfinished" \
        "iterations=$iter" "model_id=$_ROUTE_MODEL_ID" \
        "reason=no_done_sentinel" 2>/dev/null || true
    _route_loop_clear_traps
    return 1
}

# ─── _route_loop_close_final_banner — #646 deferred-close flush ──────────────
# Closes the banner pair that route_to_model_loop left open when called with
# --defer-final-banner-close AND the loop exited via the done_sentinel path.
# No-op when:
#   - the caller did not pass --defer-final-banner-close, OR
#   - the loop exited via a path that did not stash a deferred close
#     (no_done_sentinel, a failed call, signal — those paths keep legacy
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
