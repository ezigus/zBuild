#!/usr/bin/env bash
# sw-ai.sh — AI provider management commands
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh"
[[ -f "$SCRIPT_DIR/lib/ai-provider.sh" ]] && source "$SCRIPT_DIR/lib/ai-provider.sh"

show_help() {
    echo "Usage: shipwright ai <list|doctor|test|set> [options]"
    echo ""
    echo "Commands:"
    echo "  list                     List default + allowed providers"
    echo "  doctor [--provider p]    Check provider binary/readiness"
    echo "  test [--provider p]      Run a minimal prompt through provider"
    echo "  set <provider>           Persist default provider to .claude/daemon-config.json"
}

parse_provider_flag() {
    local provider=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --provider) provider="${2:-}"; shift 2 ;;
            --provider=*) provider="${1#--provider=}"; shift ;;
            *) shift ;;
        esac
    done
    echo "$provider"
}

cmd_list() {
    ai_provider_list_json | jq -r '
      "default: " + .default_provider,
      "allowed: " + (.allowed | join(", "))
    '
}

cmd_doctor() {
    local provider="${1:-}"
    ai_provider_doctor_json "$provider" | jq
}

cmd_test() {
    local provider="${1:-}"
    provider="$(ai_provider_resolve "$provider")"
    local out_file err_file json
    out_file=$(mktemp "${TMPDIR:-/tmp}/sw-ai-test.XXXXXX")
    err_file=$(mktemp "${TMPDIR:-/tmp}/sw-ai-test-err.XXXXXX")
    json=$(ai_run_json "$provider" "Reply with exactly: OK" "haiku" "1" "$out_file" "$err_file" || true)
    rm -f "$out_file" "$err_file"
    echo "$json" | jq
}

cmd_set() {
    local provider="$1"
    provider="$(ai_provider_resolve "$provider")"
    local root cfg
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    cfg="${root}/.claude/daemon-config.json"
    mkdir -p "$(dirname "$cfg")"
    if [[ ! -f "$cfg" ]]; then
        echo '{}' > "$cfg"
        chmod 600 "$cfg"
    fi
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/sw-ai-set.XXXXXX")
    jq --arg provider "$provider" '.ai.provider.default = $provider' "$cfg" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$cfg"
    echo "Set ai.provider.default=${provider} in ${cfg}"
}

SUBCOMMAND="${1:-help}"
shift 2>/dev/null || true

case "$SUBCOMMAND" in
    list) cmd_list ;;
    doctor)
        cmd_doctor "$(parse_provider_flag "$@")"
        ;;
    test)
        cmd_test "$(parse_provider_flag "$@")"
        ;;
    set)
        [[ $# -lt 1 ]] && { echo "Usage: shipwright ai set <provider>" >&2; exit 1; }
        cmd_set "$1"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown ai command: $SUBCOMMAND" >&2
        show_help
        exit 1
        ;;
esac
