# ai-provider-codex.sh — Codex adapter for provider router
[[ -n "${_AI_PROVIDER_CODEX_LOADED:-}" ]] && return 0
_AI_PROVIDER_CODEX_LOADED=1

ai_provider_codex_model_for_tier() {
    local tier="${1:-sonnet}"
    case "$tier" in
        haiku) echo "gpt-5.1-codex-mini" ;;
        sonnet) echo "gpt-5.1-codex" ;;
        opus) echo "gpt-5" ;;
        *) echo "gpt-5.1-codex" ;;
    esac
}

ai_provider_codex_check_ready() {
    local cmd="${1:-codex}"
    command -v "$cmd" >/dev/null 2>&1
}

ai_provider_codex_run_json() {
    local cmd="$1" prompt="$2" model="${3:-}" _max_turns="${4:-1}" out_file="$5" err_file="$6"
    local args=(exec --skip-git-repo-check --json)
    [[ -n "$model" ]] && args+=(--model "$model")
    args+=("$prompt")
    "$cmd" "${args[@]}" >"$out_file" 2>"$err_file"
}

ai_provider_codex_run_text() {
    local cmd="$1" prompt="$2" model="${3:-}" _max_turns="${4:-1}" out_file="$5" err_file="$6"
    local args=(exec --skip-git-repo-check)
    [[ -n "$model" ]] && args+=(--model "$model")
    args+=("$prompt")
    "$cmd" "${args[@]}" >"$out_file" 2>"$err_file"
}

ai_provider_codex_parse_json_result() {
    local out_file="$1"
    jq -s -r 'map(select(.type=="item.completed" and .item.type=="agent_message") | .item.text) | last // ""' "$out_file" 2>/dev/null || echo ""
}

ai_provider_codex_parse_json_usage() {
    local out_file="$1"
    jq -s -c '
      (map(select(.type=="turn.completed") | .usage) | last // {}) as $u |
      {
        input_tokens: ($u.input_tokens // 0),
        output_tokens: ($u.output_tokens // 0),
        cost_usd: null,
        usage_source: (if (($u.input_tokens // 0) > 0) or (($u.output_tokens // 0) > 0) then "exact" else "none" end)
      }
    ' "$out_file" 2>/dev/null || echo '{"input_tokens":0,"output_tokens":0,"cost_usd":null,"usage_source":"none"}'
}

ai_provider_codex_parse_text_usage() {
    echo '{"input_tokens":0,"output_tokens":0,"cost_usd":null,"usage_source":"none"}'
}
