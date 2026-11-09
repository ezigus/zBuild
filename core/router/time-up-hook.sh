#!/usr/bin/env bash
# core/router/time-up-hook.sh <deadline_epoch> <notes_file> — Claude Code's
# PreToolUse hook for one model call (ADR-063, amended 2026-11-08, #2503).
#
# Before the deadline it allows every tool. After it, it refuses every tool but
# writing or editing the stage's notes file, and tells the model why, so the
# call ends with its own last message — its answers written, its cost reported —
# instead of being killed at its time limit. The time limit still stops a call
# that does not end.
#
# MEASURED on CLI 2.1.319 (#2503): under --permission-mode bypassPermissions a
# PreToolUse `deny` is honoured, the reason reaches the model as the tool's
# result, and the call ends with a `result` message carrying its cost.
#
# Claude runs it with the call's tool input as JSON on stdin; it prints nothing
# to allow, or a deny decision.

deadline="${1:-0}" notes="${2:-}"
input=""; IFS= read -r -d '' input || true
printf -v now '%(%s)T' -1
[[ "$deadline" =~ ^[0-9]+$ ]] && (( now < deadline )) && exit 0

tool="$(jq -r '.tool_name // ""' <<< "$input" 2>/dev/null)"
path="$(jq -r '.tool_input.file_path // ""' <<< "$input" 2>/dev/null)"
if [[ -n "$notes" && "$path" == "$notes" && ( "$tool" == Write || "$tool" == Edit ) ]]; then
    exit 0
fi

why="Time is up: this call ends in under a minute. Stop the work you were doing."
[[ -n "$notes" ]] && why+=" You may still use Write or Edit on your notes file, $notes: write what you found there now, in one step."
why+=" Then give your final reply now, with your answer to every finding you were given. Every other tool is refused."
jq -cn --arg r "$why" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
exit 0
