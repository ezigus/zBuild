# ai-provider.sh — Provider router and normalized AI run contract
[[ -n "${_AI_PROVIDER_LOADED:-}" ]] && return 0
_AI_PROVIDER_LOADED=1

_AI_PROVIDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${_AI_PROVIDER_DIR}/config.sh" ]] && source "${_AI_PROVIDER_DIR}/config.sh"
[[ -f "${_AI_PROVIDER_DIR}/gate-signal.sh" ]] && source "${_AI_PROVIDER_DIR}/gate-signal.sh"
[[ -f "${_AI_PROVIDER_DIR}/ai-provider-claude.sh" ]] && source "${_AI_PROVIDER_DIR}/ai-provider-claude.sh"
[[ -f "${_AI_PROVIDER_DIR}/ai-provider-codex.sh" ]] && source "${_AI_PROVIDER_DIR}/ai-provider-codex.sh"

_ai_cfg_get() {
    local key="$1" fallback="${2:-}"
    if [[ "$(type -t _config_get 2>/dev/null)" == "function" ]]; then
        _config_get "$key" "$fallback"
    else
        echo "$fallback"
    fi
}

ai_provider_command() {
    local provider="$1"
    _ai_cfg_get "ai.providers.${provider}.command" "$provider"
}

ai_provider_allowed_csv() {
    _ai_cfg_get "ai.provider.allowed" "claude,codex,copilot"
}

ai_provider_is_allowed() {
    local provider="$1"
    local allowed
    allowed="$(ai_provider_allowed_csv)"
    echo ",${allowed}," | tr '[:upper:]' '[:lower:]' | grep -q ",${provider},"
}

ai_provider_resolve() {
    local override="${1:-}"
    local provider=""
    if [[ -n "$override" ]]; then
        provider="$override"
    elif [[ -n "${SHIPWRIGHT_AI_PROVIDER:-}" ]]; then
        provider="$SHIPWRIGHT_AI_PROVIDER"
    else
        provider="$(_ai_cfg_get "ai.provider.default" "claude")"
    fi
    provider="$(echo "$provider" | tr '[:upper:]' '[:lower:]')"
    if ! ai_provider_is_allowed "$provider"; then
        echo "invalid_provider:${provider}" >&2
        return 1
    fi
    echo "$provider"
}

ai_provider_model_for_tier() {
    local provider="$1" tier="${2:-sonnet}"
    local configured
    configured="$(_ai_cfg_get "ai.models.${provider}.${tier}" "")"
    if [[ -n "$configured" && "$configured" != "null" ]]; then
        echo "$configured"
        return 0
    fi
    case "$provider" in
        claude) ai_provider_claude_model_for_tier "$tier" ;;
        codex) ai_provider_codex_model_for_tier "$tier" ;;
        *) echo "$tier" ;;
    esac
}

ai_provider_check_ready() {
    local provider="$1"
    local cmd
    cmd="$(ai_provider_command "$provider")"
    case "$provider" in
        claude) ai_provider_claude_check_ready "$cmd" ;;
        codex) ai_provider_codex_check_ready "$cmd" ;;
        *) command -v "$cmd" >/dev/null 2>&1 ;;
    esac
}

ai_provider_list_json() {
    local default_provider
    default_provider="$(ai_provider_resolve "" 2>/dev/null || echo "claude")"
    jq -n \
      --arg default "$default_provider" \
      --arg allowed "$(ai_provider_allowed_csv)" \
      '{
        default_provider: $default,
        allowed: ($allowed | split(",") | map(select(length > 0)))
      }'
}

ai_provider_doctor_json() {
    local provider
    provider="$(ai_provider_resolve "${1:-}" 2>/dev/null || echo "${1:-claude}")"
    local cmd installed ready
    cmd="$(ai_provider_command "$provider")"
    if command -v "$cmd" >/dev/null 2>&1; then
        installed=true
    else
        installed=false
    fi
    if ai_provider_check_ready "$provider"; then
        ready=true
    else
        ready=false
    fi
    jq -n \
      --arg provider "$provider" \
      --arg cmd "$cmd" \
      --argjson installed "$installed" \
      --argjson ready "$ready" \
      '{provider:$provider, command:$cmd, installed:$installed, ready:$ready}'
}

_ai_run_provider_json() {
    local provider="$1" cmd="$2" prompt="$3" model="$4" max_turns="$5" out_file="$6" err_file="$7"
    case "$provider" in
        claude) ai_provider_claude_run_json "$cmd" "$prompt" "$model" "$max_turns" "$out_file" "$err_file" ;;
        codex) ai_provider_codex_run_json "$cmd" "$prompt" "$model" "$max_turns" "$out_file" "$err_file" ;;
        *) return 1 ;;
    esac
}

_ai_parse_provider_json_result() {
    local provider="$1" out_file="$2"
    case "$provider" in
        claude) ai_provider_claude_parse_json_result "$out_file" ;;
        codex) ai_provider_codex_parse_json_result "$out_file" ;;
        *) echo "" ;;
    esac
}

_ai_parse_provider_json_usage() {
    local provider="$1" out_file="$2"
    case "$provider" in
        claude) ai_provider_claude_parse_json_usage "$out_file" ;;
        codex) ai_provider_codex_parse_json_usage "$out_file" ;;
        *) echo '{"input_tokens":0,"output_tokens":0,"cost_usd":null,"usage_source":"none"}' ;;
    esac
}

ai_run_json() {
    local provider="$1" prompt="$2" tier="${3:-sonnet}" max_turns="${4:-1}" out_file="$5" err_file="$6"
    local cmd model
    cmd="$(ai_provider_command "$provider")"
    model="$(ai_provider_model_for_tier "$provider" "$tier")"

    if ! _ai_run_provider_json "$provider" "$cmd" "$prompt" "$model" "$max_turns" "$out_file" "$err_file"; then
        return 1
    fi

    local result_text usage_json completion
    result_text="$(_ai_parse_provider_json_result "$provider" "$out_file")"
    usage_json="$(_ai_parse_provider_json_usage "$provider" "$out_file")"
    if echo "$result_text" | detect_gate_signal "-" "LOOP" \
        'LOOP_COMPLETE' \
        '<<<LOOP:FAIL>>>'; then
        completion=true
    else
        completion=false
    fi

    jq -n \
      --arg provider "$provider" \
      --arg result_text "$result_text" \
      --arg raw_payload_ref "$out_file" \
      --argjson completion_signal_detected "$completion" \
      --argjson usage "$usage_json" \
      '{
        ai_provider: $provider,
        result_text: $result_text,
        completion_signal_detected: $completion_signal_detected,
        input_tokens: ($usage.input_tokens // 0),
        output_tokens: ($usage.output_tokens // 0),
        cost_usd: ($usage.cost_usd // null),
        usage_source: ($usage.usage_source // "none"),
        raw_payload_ref: $raw_payload_ref
      }'
}

ai_run_text() {
    local provider="$1" prompt="$2" tier="${3:-sonnet}" max_turns="${4:-1}" out_file="$5" err_file="$6"
    local cmd model
    cmd="$(ai_provider_command "$provider")"
    model="$(ai_provider_model_for_tier "$provider" "$tier")"
    case "$provider" in
        claude) ai_provider_claude_run_text "$cmd" "$prompt" "$model" "$max_turns" "$out_file" "$err_file" ;;
        codex) ai_provider_codex_run_text "$cmd" "$prompt" "$model" "$max_turns" "$out_file" "$err_file" ;;
        *) return 1 ;;
    esac
}
