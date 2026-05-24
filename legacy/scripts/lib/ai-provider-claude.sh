# ai-provider-claude.sh — Claude adapter for provider router
[[ -n "${_AI_PROVIDER_CLAUDE_LOADED:-}" ]] && return 0
_AI_PROVIDER_CLAUDE_LOADED=1

ai_provider_claude_model_for_tier() {
    local tier="${1:-sonnet}"
    case "$tier" in
        haiku|sonnet|opus) echo "$tier" ;;
        *) echo "sonnet" ;;
    esac
}

ai_provider_claude_check_ready() {
    local cmd="${1:-claude}"
    command -v "$cmd" >/dev/null 2>&1
}

ai_provider_claude_run_json() {
    local cmd="$1" prompt="$2" model="${3:-}" max_turns="${4:-1}" out_file="$5" err_file="$6"
    local args=(--print --output-format json -p "$prompt" --max-turns "$max_turns")
    [[ -n "$model" ]] && args+=(--model "$model")
    "$cmd" "${args[@]}" >"$out_file" 2>"$err_file"
}

ai_provider_claude_run_text() {
    local cmd="$1" prompt="$2" model="${3:-}" max_turns="${4:-1}" out_file="$5" err_file="$6"
    local args=(--print --output-format text -p "$prompt" --max-turns "$max_turns")
    [[ -n "$model" ]] && args+=(--model "$model")
    "$cmd" "${args[@]}" >"$out_file" 2>"$err_file"
}

ai_provider_claude_parse_json_result() {
    local out_file="$1"
    jq -r 'if type=="object" then .result // "" else .[-1].result // "" end' "$out_file" 2>/dev/null || echo ""
}

ai_provider_claude_parse_json_usage() {
    local out_file="$1"
    jq -c '
      def usage_obj:
        if type=="object" then .usage // {}
        else .[-1].usage // {}
        end;
      def cost_value:
        if type=="object" then .total_cost_usd
        else .[-1].total_cost_usd
        end;
      (usage_obj) as $u |
      {
        input_tokens: ($u.input_tokens // 0),
        output_tokens: ($u.output_tokens // 0),
        cost_usd: (cost_value // null),
        usage_source: (if (($u.input_tokens // 0) > 0) or (($u.output_tokens // 0) > 0) then "exact" else "none" end)
      }
    ' "$out_file" 2>/dev/null || echo '{"input_tokens":0,"output_tokens":0,"cost_usd":null,"usage_source":"none"}'
}

ai_provider_claude_parse_text_usage() {
    echo '{"input_tokens":0,"output_tokens":0,"cost_usd":null,"usage_source":"none"}'
}
