#!/usr/bin/env bash
# core/router/providers/anthropic.sh — the Anthropic provider module (ADR-003
# amendment). Sourced library: no set -euo pipefail.
#
# Every provider module implements the same three functions, named
# provider_<name>_<fn>; the router calls them and never knows a provider's
# model names or prices:
#
#   provider_<name>_resolve <family>          → the model to request for a family
#   provider_<name>_call_cost <response>      → the call's cost in USD, or nothing
#                                               when the provider cannot say
#   provider_<name>_model_used <response>     → the concrete model that answered
#   provider_<name>_persona_args <name> <description> <perspective>
#                                             → the call's arguments that run it
#                                               as a persona; absent or rc 1 when
#                                               the provider cannot, and the router
#                                               then puts the persona in the prompt
#   provider_<name>_tool_args <word>...       → the call's arguments that give it
#                                               exactly the tools zbuild's words
#                                               name (ADR-017 §12), MCP servers
#                                               off; rc 1, saying why on stderr,
#                                               for a word it cannot supply
#
# <response> is the raw output of the call.

[[ -n "${_ZBUILD_PROVIDER_ANTHROPIC_LOADED:-}" ]] && return 0
_ZBUILD_PROVIDER_ANTHROPIC_LOADED=1

# The claude CLI resolves a family alias (haiku, sonnet, opus) to the newest
# model of that family, so requesting the alias IS "always the latest".
provider_anthropic_resolve() {
    case "${1:-}" in
        haiku|sonnet|opus) printf '%s' "$1" ;;
        *) return 1 ;;
    esac
}

# The CLI's JSON envelope carries the exact cost Anthropic computed for the
# call — cache reads and writes included. No envelope, no cost: print nothing.
provider_anthropic_call_cost() {
    local c
    c="$(jq -r 'if type == "object" then (.total_cost_usd // empty) else empty end' <<< "${1:-}" 2>/dev/null || true)"
    [[ "$c" =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]] && printf '%s' "$c"
    return 0
}

# modelUsage is keyed by the concrete model id; the one that produced the most
# output answered the call (a call can touch a second model internally).
provider_anthropic_model_used() {
    jq -r 'if type == "object" then ((.modelUsage // {}) | to_entries
            | max_by(.value.outputTokens // 0) | .key // empty) else empty end' \
        <<< "${1:-}" 2>/dev/null || true
}

# provider_anthropic_persona_args <name> <description> <perspective> — how this
# provider runs a call as a persona (ADR-051, amended 2026-10-12): the claude
# CLI takes an agent definition and the agent to run as. One argument per line.
# rc 1 (and nothing printed) when the name is not one the CLI accepts.
provider_anthropic_persona_args() {
    local name="${1:-}" desc="${2:-}" prompt="${3:-}" json
    [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ && -n "$prompt" ]] || return 1
    json="$(jq -cn --arg n "$name" --arg d "${desc:-$name}" --arg p "$prompt" \
        '{($n): {description: $d, prompt: $p}}' 2>/dev/null)" || return 1
    [[ -n "$json" ]] || return 1
    printf '%s\n' --agents "$json" --agent "$name"
}

# provider_anthropic_tool_args <word>... — zbuild's tool words as the claude
# CLI's flags (#2507, ADR-017 §12, ADR-003), one argument per line. --tools
# lists the built-in tools the call has (none at all when given no word);
# --strict-mcp-config loads no MCP server from the machine or the repository.
# read-git without run-commands is the shell, allowed only git's reading
# commands; the call's hook refuses any other (core/router/tool-hook.sh).
provider_anthropic_tool_args() {
    local w tools="" git=0 run=0
    for w in "$@"; do
        case "$w" in
            read-files)   tools+=",Read,Grep,Glob" ;;
            edit-files)   tools+=",Edit,Write" ;;
            run-commands) run=1 ;;
            read-git)     git=1 ;;
            web-search)   tools+=",WebSearch,WebFetch" ;;
            subagents)    tools+=",Task" ;;
            todo-list)    tools+=",TodoWrite" ;;
            mcp)  printf 'the anthropic provider cannot give a call mcp: no manifest names the MCP servers a call may use yet\n' >&2; return 1 ;;
            *)    printf "the anthropic provider has no tools for the word '%s'\n" "$w" >&2; return 1 ;;
        esac
    done
    # Bash where Edit,Write would put it, so the order reads as the words do.
    if (( run || git )); then
        if [[ "$tools" == *",Write"* ]]; then tools="${tools/,Write/,Write,Bash}"
        elif [[ "$tools" == *",Glob"* ]]; then tools="${tools/,Glob/,Glob,Bash}"
        else tools=",Bash$tools"; fi
    fi
    printf '%s\n' --tools "${tools#,}"
    (( git && !run )) && printf '%s\n' --allowedTools 'Bash(git diff *),Bash(git log *),Bash(git show *),Bash(git status *)'
    printf '%s\n' --strict-mcp-config
}
