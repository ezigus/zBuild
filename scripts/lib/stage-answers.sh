#!/usr/bin/env bash
# scripts/lib/stage-answers.sh — every stage answers every finding it receives
# (#2271, ADR-068).
#
# The engine no longer decides who owns a finding. Each stage sees every
# finding ("<stage> finding <n> (opened by <stage>)", input-resolve.sh) and
# answers each one with a standard word:
#   done — <what it changed>         nothing to do — <why>     (any stage)
#   satisfied — <why>                (only the stage that opened the finding)
# The router appends the request to the prompt (answers_prompt_block) and reads
# the answers back from the reply (answers_record). The engine only counts them.
#
# Source-only; no `set -e` at top level.
[[ -n "${_ZBUILD_STAGE_ANSWERS_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_ANSWERS_LOADED=1

_ZB_ANSWERS_MARKER="=== ANSWER EVERY FINDING ==="
# A finding line as input-resolve.sh renders it.
_ZB_FINDING_LINE_RE='^- ([A-Za-z0-9_.-]+) finding ([0-9]+) \(opened by ([A-Za-z0-9_.-]+)\): '

# _answers_own_findings — the findings this stage opened last time, as finding
# lines; empty when it opened none or has no result yet. Read from its own
# primary result before it overwrites it.
_answers_own_findings() {
    local stage="${ZBUILD_CURRENT_STAGE:-}" dir="${ZBUILD_PLUGIN_DIR:-}" sd="${ZBUILD_STATE_DIR:-}"
    [[ -n "$stage" && -n "$dir" && -n "$sd" && -f "$dir/manifest.yaml" ]] || return 0
    if ! declare -F _verdict_resolve_path >/dev/null 2>&1; then
        # shellcheck source=../../core/pipeline/verdict.sh
        source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/pipeline/verdict.sh" 2>/dev/null || return 0
    fi
    local raw res
    raw="$(_verdict_primary_output_path "$dir/manifest.yaml" 2>/dev/null || true)"
    [[ -n "$raw" ]] || return 0
    res="$(_verdict_resolve_path "$raw" "$sd" 2>/dev/null || true)"
    [[ -s "$res" ]] || return 0
    jq -r --arg s "$stage" '(.data.findings // [])[]?
        | select(type == "object" and (.n|type) == "number")
        | "- \($s) finding \(.n) (opened by \($s)): \(.text|tostring|gsub("[\r\n]+"; " "))"' "$res" 2>/dev/null || true
}

# answers_prompt_block <prompt_file> — the request to answer each finding, or
# nothing when the prompt carries no findings and the stage opened none.
answers_prompt_block() {
    local prompt="${1:-}" refs="" own
    [[ -f "$prompt" ]] && refs="$(grep -E "$_ZB_FINDING_LINE_RE" "$prompt" 2>/dev/null \
        | sed -E 's/^- ([A-Za-z0-9_.-]+ finding [0-9]+) .*/\1/' || true)"
    own="$(_answers_own_findings)"
    [[ -n "$refs" || -n "$own" ]] || return 0
    printf '%s\n' "$_ZB_ANSWERS_MARKER"
    if [[ -n "$refs" ]]; then
        cat <<'EOF'
Answer every finding listed above, one line each, in this form:
  ANSWER <stage> finding <n>: done — <what you changed for it>
  ANSWER <stage> finding <n>: nothing to do — <why there is nothing for you to change>
Judge each finding against your own job. Work on one finding can take more than one stage:
if another stage already did something for it, that does not mean you have nothing to do.
Say `done` only when you changed something for it, and say what you changed.
Fill in one line for each:
EOF
        local _r
        while IFS= read -r _r; do [[ -n "$_r" ]] && printf 'ANSWER %s: \n' "$_r"; done <<< "$refs"
    fi
    if [[ -n "$own" ]]; then
        cat <<'EOF'

These are the findings you opened last time. Make your own judgment of the
work first, then answer each of these, one line each:
  ANSWER <stage> finding <n>: satisfied — <why the problem is gone>
Leave a finding unanswered if the problem is still there.
EOF
        printf '%s\n' "$own"
    fi
}

# answers_parse <reply_text> — the answers in a reply, as JSON keyed by the
# finding reference: {"<stage> finding <n>": {answer, why, by}}. Lines that are
# not well-formed answers are ignored. `satisfied` counts only from the stage
# that opened the finding.
answers_parse() {
    local by="${ZBUILD_UNIT:-${ZBUILD_CURRENT_STAGE:-}}" me="${ZBUILD_CURRENT_STAGE:-}"
    jq -R -s -c --arg by "$by" --arg me "$me" '
        [ split("\n")[]
          | capture("^\\s*ANSWER (?<opener>[A-Za-z0-9_.-]+) finding (?<n>[0-9]+):\\s*(?<answer>done|nothing to do|satisfied)\\s*(—|--|-)\\s*(?<why>.+?)\\s*$")?
          | select(.answer != "satisfied" or .opener == $me)
          | {key: "\(.opener) finding \(.n)", value: {answer, why, by: $by}} ]
        | from_entries' <<< "${1:-}" 2>/dev/null || printf '{}'
}

# answers_record <reply_text> — keep this run's answers where the engine counts
# them: <state_dir>/finding-answers/<unit>.json. Written only when the reply
# answered something.
answers_record() {
    local sd="${ZBUILD_STATE_DIR:-}" unit="${ZBUILD_UNIT:-${ZBUILD_CURRENT_STAGE:-}}" j
    [[ -n "$sd" && -n "$unit" ]] || return 0
    j="$(answers_parse "${1:-}")"
    [[ -n "$j" && "$j" != "{}" ]] || return 0
    unit="${unit//[^A-Za-z0-9._-]/_}"
    mkdir -p "$sd/finding-answers" 2>/dev/null || return 0
    printf '%s\n' "$j" > "$sd/finding-answers/.$unit.json.tmp" 2>/dev/null \
        && mv -f "$sd/finding-answers/.$unit.json.tmp" "$sd/finding-answers/$unit.json" 2>/dev/null || true
}
