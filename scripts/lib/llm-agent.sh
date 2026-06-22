#!/usr/bin/env bash
# scripts/lib/llm-agent.sh — Shared LLM-agent stage framework foundation (ADR-028)
#
# Pattern 1 (single-turn JSON envelope) helpers shared across plan, impact,
# review, test_assessment. Each plugin migrates incrementally — this PR ships
# the foundation; PRs 2-5 of ADR-028 migrate one plugin at a time.
#
# Helpers:
#   _llm_output_contract       — render canonical OUTPUT CONTRACT block
#   _llm_envelope_parse        — split LLM response into JSON + surrounding prose
#   _llm_envelope_validate     — two-pass: parse-class error vs structure-class
#   _llm_emit_violation        — contract.violation event with positional class
#   _llm_router_classify       — wrap _router_rc_classify (PR #788)
#   _llm_with_json_output      — Pattern 1 ZBUILD_ROUTER_JSON_OUTPUT save/restore
#
# v1 scope (per multi-agent design synthesis):
#   - Pattern 1 ONLY (build's loop-with-sentinel stays separate)
#   - No escape-repair in parser (deferred to v2; ADR-022 column-3208 case is
#     the regression target). v1 fails-soft with diagnostic-rich error.
#   - Per-stage OUTPUT CONTRACT goldens pin the rendered block.

if [[ "${_ZBUILD_LLM_AGENT_LOADED:-}" == "1" ]]; then
    return 0
fi
_ZBUILD_LLM_AGENT_LOADED=1

# Source the rc classifier from PR #788 (idempotent).
_LLM_AGENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./router-rc-classify.sh
source "$_LLM_AGENT_LIB_DIR/router-rc-classify.sh"
# shellcheck source=./helpers.sh
[[ -z "${_ZBUILD_HELPERS_LOADED:-}" ]] && source "$_LLM_AGENT_LIB_DIR/helpers.sh"

# ─── _llm_output_contract ───────────────────────────────────────────────────
# Renders the canonical OUTPUT CONTRACT prompt block to stdout. Per-stage
# variation is parameterized; the FORBIDDEN list, FINAL RULE, and
# "begins with `{`" rules are common to all stages.
#
# Args (long-form):
#   --stage <id>              — stage name (used in error events)
#   --verdicts <csv|none>     — verdict vocabulary; "none" omits the enum line
#                               entirely (use for plan which has no .verdict
#                               field; the schema MUST NOT assert .verdict)
#   --schema-json <inline>    — required JSON schema shape (multi-line)
#   --markdown-fields <csv>   — fields that may contain markdown; framework
#                               appends the ADR-022 escape requirement when set
#   [--extras <path>]         — per-stage extras file (FORBIDDEN extensions,
#                               CORRECT examples, etc.); appended verbatim
#                               between the schema block and the closing rule.
_llm_output_contract() {
    local stage="" verdicts="" schema_json="" markdown_fields="" extras_file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stage) stage="$2"; shift 2 ;;
            --verdicts) verdicts="$2"; shift 2 ;;
            --schema-json) schema_json="$2"; shift 2 ;;
            --markdown-fields) markdown_fields="$2"; shift 2 ;;
            --extras) extras_file="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    [[ -z "$stage" ]] && { printf '_llm_output_contract: --stage required\n' >&2; return 2; }
    [[ -z "$schema_json" ]] && { printf '_llm_output_contract: --schema-json required\n' >&2; return 2; }

    # Canonical opening — never varies across stages.
    cat <<'CONTRACT_HEAD'
OUTPUT CONTRACT (read first, obey absolutely):
- Respond with EXACTLY ONE JSON object. Nothing else.
- Your first output character MUST be `{`. Your last MUST be `}`.
- NO markdown code fences (no ```json, no ``` wrapping).
- NO prose before, after, or around the JSON envelope.
CONTRACT_HEAD

    # Verdict enum line — omitted when verdicts=none (plan).
    if [[ -n "$verdicts" && "$verdicts" != "none" ]]; then
        printf -- '- Your `.verdict` field MUST be one of: %s\n' "$verdicts"
    fi

    # Common FORBIDDEN list — preamble + postamble drift observed in dogfoods.
    cat <<'_FORBIDDEN_BLOCK'

FORBIDDEN — your response MUST NOT contain any of these strings ANYWHERE,
not before the JSON, not after it, not inside any field:
  - "Based on my analysis"
  - "Based on my comprehensive analysis"
  - "Here is"
  - "Here's"
  - "After reviewing"
  - "I've identified"
  - "Now I have"
  - "Let me"
  - "I have all the information"
_FORBIDDEN_BLOCK

    # Markdown-field escape requirement (ADR-022 v2).
    if [[ -n "$markdown_fields" ]]; then
        cat <<MD_ESCAPE

JSON-STRING ESCAPING (ADR-022 v2 — applies to: $markdown_fields):
- Every \` " \` inside a string field MUST be escaped as \` \\" \`.
- Newlines inside a string field MUST be \` \\n \`, not raw newlines.
- A markdown body containing a table cell like \` "3" \` MUST be encoded as
  \` \\"3\\" \` in the JSON. Unescaped quotes break the JSON parse.
MD_ESCAPE
    fi

    cat <<'FINAL_RULE'

FINAL RULE: after your closing brace `}`, output NOTHING — not even a
newline, not even one character. Your response ends at `}`. Postamble
content is the same violation as preamble.

Required JSON schema:

FINAL_RULE

    printf '%s\n' "$schema_json"

    # Per-stage extras (FORBIDDEN extensions, additional CORRECT examples).
    if [[ -n "$extras_file" && -f "$extras_file" ]]; then
        printf '\n'
        cat "$extras_file"
    fi

    cat <<'CONTRACT_TAIL'

REMINDER: your response begins with `{`. No prose, no fences. Ends at `}`.
CONTRACT_TAIL
}

# ─── _llm_envelope_parse ────────────────────────────────────────────────────
# Thin wrapper over extract_json_and_surrounding_prose (helpers.sh).
# Preserves __PROSE__/__JSON__ sentinel semantics for renderer interop
# (artifact-render.sh _artifact_split_prose_json). v1 does NO mutation or
# repair — fail-soft via empty JSON if parser bails.
#
# Args (positional):
#   $1 = raw_response_text
#   $2 = json_var_name   (nameref output)
#   $3 = prose_var_name  (nameref output)
_llm_envelope_parse() {
    local raw="${1:-}"
    local _json_var="${2:-}"
    local _prose_var="${3:-}"

    [[ -z "$_json_var" || -z "$_prose_var" ]] && {
        printf '_llm_envelope_parse: <json_var> and <prose_var> required\n' >&2
        return 2
    }

    local _split_out=""
    if [[ -n "$raw" ]]; then
        _split_out="$(printf '%s' "$raw" | extract_json_and_surrounding_prose 2>/dev/null || true)"
    fi

    # Re-split using sentinel-aware awk (matches _artifact_split_prose_json behavior).
    local _prose _json
    _prose="$(printf '%s' "$_split_out" | awk '
        BEGIN { mode = "" }
        /^__PROSE__$/ { mode = "prose"; next }
        /^__JSON__$/  { mode = "json";  next }
        { if (mode == "prose") { if (out=="") out=$0; else out=out "\n" $0 } }
        END { printf "%s", out }
    ')"
    _json="$(printf '%s' "$_split_out" | awk '
        BEGIN { mode = "" }
        /^__PROSE__$/ { mode = "prose"; next }
        /^__JSON__$/  { mode = "json";  next }
        { if (mode == "json")  { if (out=="") out=$0; else out=out "\n" $0 } }
        END { printf "%s", out }
    ')"

    printf -v "$_json_var" '%s' "$_json"
    printf -v "$_prose_var" '%s' "$_prose"
    return 0
}

# ─── _llm_envelope_validate ─────────────────────────────────────────────────
# Two-pass validation: parse-class error (with col+ctx) vs structure-class.
# Per ADR-020 amendment + ADR-022 v2: distinguishing the two failure modes
# tells the operator (and the LLM on next iter) the real root cause.
#
# Args:
#   $1 = json_text
#   $2 = schema_expr (jq -e expression)
#   $3 = error_var_name (nameref; receives empty on success, diagnostic on fail)
# Returns:
#   0 = valid
#   2 = parse-class failure (sets error_var to "parse: <col> <ctx40>")
#   3 = structure-class failure (sets error_var to "structure: <jq stderr>")
_llm_envelope_validate() {
    local json="${1:-}" schema_expr="${2:-}" _err_var="${3:-}"

    [[ -z "$_err_var" ]] && {
        printf '_llm_envelope_validate: <error_var> required\n' >&2
        return 2
    }

    # Pass 1: parseability via `jq empty`.
    local _parse_err
    _parse_err="$(printf '%s' "$json" | jq empty 2>&1)"
    local _parse_rc=$?
    if [[ $_parse_rc -ne 0 ]]; then
        # Extract column from jq error if available (e.g. "line 1, column 3208").
        local _col=""
        _col="$(printf '%s' "$_parse_err" | grep -oE 'column [0-9]+' | head -1 | awk '{print $2}')"
        [[ -z "$_col" ]] && _col="?"
        # Surface 40-char context window around the column.
        local _ctx=""
        if [[ "$_col" =~ ^[0-9]+$ && -n "$json" ]]; then
            local _start=$(( _col > 20 ? _col - 20 : 0 ))
            _ctx="$(printf '%s' "$json" | tail -c +$(( _start + 1 )) | head -c 40 | tr '\n' ' ')"
        fi
        printf -v "$_err_var" 'parse: column %s context [%s]' "$_col" "$_ctx"
        return 2
    fi

    # Pass 2: structure via jq -e on schema_expr.
    if [[ -n "$schema_expr" ]]; then
        local _struct_err
        _struct_err="$(printf '%s' "$json" | jq -e "$schema_expr" 2>&1 >/dev/null)"
        if [[ $? -ne 0 ]]; then
            printf -v "$_err_var" 'structure: %s' "$_struct_err"
            return 3
        fi
    fi

    printf -v "$_err_var" '%s' ""
    return 0
}

# ─── _llm_emit_violation ────────────────────────────────────────────────────
# Emit a contract.violation event with structured reason. Event class is
# PASSED POSITIONALLY (not via env) so callers cannot leak class across
# sequential invocations.
#
# Args:
#   $1 = stage_name (e.g. "impact")
#   $2 = event_class (e.g. "impact.contract.violation", or "plugin.contract.violated" default)
#   $3 = reason_code
#   $4 = prose_length (for forensic metric)
#   $5 = sidecar_path (where prose was persisted)
_llm_emit_violation() {
    local stage="${1:-unknown}" event_class="${2:-plugin.contract.violated}" reason="${3:-unknown}"
    local prose_len="${4:-0}" sidecar="${5:-}"

    emit_event "$event_class" \
        "plugin=$stage" \
        "reason=$reason" \
        "prose_length=$prose_len" \
        "sidecar=$sidecar" 2>/dev/null || true
}

# ─── _llm_router_classify ───────────────────────────────────────────────────
# Thin re-export of _router_rc_classify from PR #788 for naming consistency
# with the rest of the framework.
_llm_router_classify() {
    _router_rc_classify "$@"
}

# ─── _llm_with_json_output ──────────────────────────────────────────────────
# Pattern 1 wrapper: save current ZBUILD_ROUTER_JSON_OUTPUT, force =1 for
# the callback, restore on exit (even on rc!=0). Per ADR-018 §330-345 the
# JSON envelope mode is mandatory for Pattern 1; this helper ensures every
# caller respects the save/restore contract.
#
# Args:
#   "$@" = command + args to execute under JSON_OUTPUT=1
#
# Caller passes the route_to_model call as the args:
#   _llm_with_json_output route_to_model T1 "$prompt"
_llm_with_json_output() {
    local _prev_env="${ZBUILD_ROUTER_JSON_OUTPUT-__UNSET__}"
    export ZBUILD_ROUTER_JSON_OUTPUT=1
    local _rc=0
    "$@" || _rc=$?
    if [[ "$_prev_env" == "__UNSET__" ]]; then
        unset ZBUILD_ROUTER_JSON_OUTPUT
    else
        export ZBUILD_ROUTER_JSON_OUTPUT="$_prev_env"
    fi
    return $_rc
}

# ─── CLI failure fast-fail (#1024, ADR-028 amendment) ───────────────────────
# File-based counter so consecutive failures accumulate across Pattern 1 plugin
# subshell invocations within the same pipeline run. Counter file lives under
# ${ZBUILD_STATE_DIR}/.llm_cli_fail_count; absent = 0.
#
# Threshold: ZBUILD_LLM_FAIL_THRESHOLD (default 2, matching ADR-029 G2).
# rc=9 is the new pipeline-abort class for llm_unavailable.

_zbuild_cli_fail_counter_path() {
    local _dir="${ZBUILD_STATE_DIR:-}"
    if [[ -n "$_dir" ]]; then
        printf '%s/.llm_cli_fail_count' "$_dir"
    else
        # No state dir: use a per-PID path so parallel test runs don't collide.
        printf '%s/.zbuild_llm_cli_fail_%s' "${TMPDIR:-/tmp}" "$$"
    fi
}

_zbuild_record_cli_fail() {
    local _path; _path="$(_zbuild_cli_fail_counter_path)"
    local _prev=0
    if [[ -f "$_path" ]]; then
        local _raw; _raw="$(cat "$_path" 2>/dev/null || true)"
        [[ "$_raw" =~ ^[0-9]+$ ]] && _prev="$_raw"
    fi
    local _next=$(( _prev + 1 ))
    printf '%s' "$_next" > "$_path" 2>/dev/null || true
    emit_event "llm.cli_fail" \
        "count=$_next" \
        "run_id=${ZBUILD_RUN_ID:-}" 2>/dev/null || true
    return 0
}

_zbuild_reset_cli_fail() {
    local _path; _path="$(_zbuild_cli_fail_counter_path)"
    rm -f "$_path" 2>/dev/null || true
    return 0
}

# _llm_check_cli_fail_abort — returns 9 when the consecutive CLI failure count
# has reached ZBUILD_LLM_FAIL_THRESHOLD (default 2); returns 0 otherwise.
# When rc=9 is returned, emits pipeline.aborted reason=llm_unavailable and
# prints a clear terminal message to stderr. The runner handles the actual
# state-file writes and pipeline.end events when it observes rc=9.
_llm_check_cli_fail_abort() {
    local _threshold="${ZBUILD_LLM_FAIL_THRESHOLD:-2}"
    local _path; _path="$(_zbuild_cli_fail_counter_path)"
    local _count=0
    if [[ -f "$_path" ]]; then
        local _raw; _raw="$(cat "$_path" 2>/dev/null || true)"
        [[ "$_raw" =~ ^[0-9]+$ ]] && _count="$_raw"
    fi
    if [[ "$_count" -ge "$_threshold" ]]; then
        local _run_id="${ZBUILD_RUN_ID:-unknown}"
        emit_event "pipeline.llm_unavailable" \
            "reason=llm_unavailable" \
            "count=$_count" \
            "threshold=$_threshold" \
            "run_id=$_run_id" 2>/dev/null || true
        emit_event "pipeline.aborted" \
            "reason=llm_unavailable" \
            "count=$_count" \
            "run_id=$_run_id" 2>/dev/null || true
        printf '✗ Pipeline aborted: the model CLI failed %s consecutive times (run_id=%s). Check your claude CLI installation and API key.\n' \
            "$_count" "$_run_id" >&2
        return 9
    fi
    return 0
}
