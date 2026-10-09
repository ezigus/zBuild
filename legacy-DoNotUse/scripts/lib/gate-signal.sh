#!/usr/bin/env bash
# gate-signal.sh — Robust multi-layer LLM verdict detection
# Shared by sw-loop.sh and ai-provider.sh so detect_gate_signal is always available.
[[ -n "${_GATE_SIGNAL_LOADED:-}" ]] && return 0
_GATE_SIGNAL_LOADED=1

# detect_gate_signal — robust multi-layer LLM verdict detection.
# Handles fenced delimiters, legacy magic strings, and ambiguous/empty output.
#
# Usage: detect_gate_signal <log_file_or_dash> <gate_name> [legacy_pattern] [negative_pattern]
#   log_file_or_dash: path to log file, or "-" to read from stdin
#   gate_name: e.g., "AUDIT", "DOD", "LOOP", "HOLISTIC"
#   legacy_pattern: gate-specific Layer 3 regex (optional, defaults to GATE_PASS)
#   negative_pattern: gate-specific failure signals (optional, defaults to <<<GATE:FAIL>>>)
# Returns 0 (pass), 1 (fail/ambiguous)
detect_gate_signal() {
    local log_file="$1" gate="$2"
    local legacy="${3:-${gate}_PASS}"
    local negative="${4:-<<<${gate}:FAIL>>>}"
    local content

    if [[ "$log_file" == "-" ]]; then
        content="$(cat)"
    elif [[ -f "$log_file" ]]; then
        content="$(cat "$log_file")"
    else
        return 1
    fi

    # Layer 1: Negative-first — explicit failure signals override everything
    if echo "$content" | grep -iqE "$negative" 2>/dev/null; then
        return 1
    fi

    # Layer 2: Fenced delimiter (most reliable positive signal)
    if echo "$content" | grep -q "<<<${gate}:PASS>>>" 2>/dev/null; then
        return 0
    fi

    # Layer 3: Legacy compat (gate-specific, case-insensitive)
    if echo "$content" | grep -iqE "$legacy" 2>/dev/null; then
        return 0
    fi

    # Ambiguous — fail safely
    return 1
}
