#!/usr/bin/env bash
# scripts/lib/run-open-items.sh — what is still open when a run ends, in plain
# words (#2330, ADR-068 §8).
#
# Every place a run reports how it ended — the report of items no stage could
# act on, the live status comment, the issue completion comment, the end-of-run
# banner — names each open item the same way: what is unresolved, and what would
# settle it. The reader may be a person, an agent or a later run, so the words
# say WHAT must be checked, never who must check it, and never the engine's own
# codes (events keep those).
#
# An item comes from one of two places:
#   - <state>/artifacts/open-items.json, written with the report of items no
#     stage could act on (core/pipeline/unowned.sh) — those items exactly;
#   - otherwise every check whose result did not pass: each of its numbered
#     findings, or its reason when it has none.
# A finding may say what would settle it itself, after "What would settle it:".
#
# Source-only; no `set -e` at top level. Needs jq.
[[ -n "${_ZBUILD_RUN_OPEN_ITEMS_LOADED:-}" ]] && return 0
_ZBUILD_RUN_OPEN_ITEMS_LOADED=1

_OPEN_ITEMS_SETTLE_RE='[[:space:]]*What would settle it:[[:space:]]*'
# The one rule for a check result that passed — every reader of results uses it.
# shellcheck disable=SC2034  # read by core/pipeline/unowned.sh
_OPEN_ITEMS_JQ_PASSED='def passed: (.verdict // "" | ascii_downcase)
    | IN("pass", "passed", "approve", "approved", "complete", "success", "skip", "skipped", "");'

# open_items_json <state_dir> — [{ref, opener, text, answers}] (answers may be []).
open_items_json() {
    local sd="$1" f
    if [[ -s "$sd/artifacts/open-items.json" ]]; then
        jq -c 'if type == "array" then . else [] end' "$sd/artifacts/open-items.json" 2>/dev/null || printf '[]'
        return 0
    fi
    local -a files=()
    for f in "$sd"/artifacts/*-result.json; do [[ -s "$f" ]] && files+=("$f"); done
    [[ ${#files[@]} -gt 0 ]] || { printf '[]'; return 0; }
    # A result is a check's when it carries a verdict; it is open when that
    # verdict is not a pass. input_filename names the check: <check>-result.json.
    jq -n -c "$_OPEN_ITEMS_JQ_PASSED"'
        [ inputs as $r | (input_filename | split("/") | last | sub("-result\\.json$"; "")) as $c
          | $r | select(type == "object" and (.verdict | type) == "string")
          | select(passed | not)
          | if ((.data.findings // []) | length) > 0 then
                (.data.findings[] | {ref: "\($c) finding \(.n)", opener: $c, text: (.text // ""), answers: []})
            else
                {ref: $c, opener: $c, text: ("the " + $c + " check did not pass: "
                                              + ((.reason // "") | if . == "" then "it gave no reason" else . end)),
                 answers: []}
            end ]' "${files[@]}" 2>/dev/null || printf '[]'
}

# open_items_count <state_dir>
open_items_count() {
    jq 'length' <<< "$(open_items_json "$1")" 2>/dev/null || printf '0'
}

# open_items_render <items_json> [with_answers] — the numbered list every report
# shows. Each item: its name and what is unresolved, then what would settle it.
open_items_render() {
    local items="$1" answers="${2:-0}"
    jq -r --arg re "$_OPEN_ITEMS_SETTLE_RE" --arg ans "$answers" '
        to_entries[] | .key as $i | .value as $it
        | ($it.text // "" | [splits($re)]) as $p
        | ($p[0] | sub("[[:space:]]+$"; "")) as $what
        | (if ($p | length) > 1 and ($p[1:] | join(" ") | length) > 0 then ($p[1:] | join(" "))
           else "the " + $it.opener + " check no longer reports it when it runs again: a change that resolves it, or evidence that it is already resolved"
           end) as $settle
        | "\($i + 1). **\($it.ref)**" + (if $it.ref == $it.opener then "" else " (opened by \($it.opener))" end)
          + ": " + (if $what == "" then "no words were given for it" else $what end)
          + "\n   - What would settle it: " + $settle
          + (if $ans == "1" then
                ([ ($it.answers // [])[] | "\n   - \(.by): \(.answer) — \(.why)" ] | join(""))
             else "" end)' <<< "$items" 2>/dev/null || true
}

# open_items_markdown <state_dir> — the list, or nothing when no item is open.
open_items_markdown() {
    local items; items="$(open_items_json "$1")"
    [[ "$items" != "[]" && -n "$items" ]] || return 0
    open_items_render "$items"
}

# _open_items_n <count> <noun> — "1 open item", "2 open items".
_open_items_n() {
    if [[ "$1" == "1" ]]; then printf '1 %s' "$2"; else printf '%s %ss' "$1" "$2"; fi
}

# run_end_words <reason> <open_count> — why the run stopped, in words. <reason>
# is the engine's code (events keep it); the words never repeat it.
run_end_words() {
    local reason="${1:-}" n="${2:-0}" with=""
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    [[ "$n" -gt 0 ]] && with=" with $(_open_items_n "$n" "open item")"
    case "$reason" in
        unowned_finding)
            printf 'stopped%s that no stage could act on' "${with:- with open items}" ;;
        max_iterations|max_iterations_tests_failing)
            printf 'ran out of rounds%s' "$with" ;;
        design_timeout_exhausted)
            printf 'ran out of rounds: the design step did not finish in time%s' "$with" ;;
        blocking_member_failure|member_terminal_failure)
            printf 'stopped: a check that must pass failed%s' "$with" ;;
        blocked|no_committed_changes)
            printf 'stopped: the work could not go further%s' "$with" ;;
        blocked_on_scope)
            printf 'stopped: the change needs files it was not allowed to edit%s' "$with" ;;
        cycle_abort)
            printf 'stopped: a check asked for the run to stop%s' "$with" ;;
        sigterm)
            printf 'stopped: the run was told to stop (TERM signal)%s' "$with" ;;
        sigint)
            printf 'stopped: the run was interrupted (INT signal, Ctrl-C)%s' "$with" ;;
        aborted)
            printf 'stopped: the run was interrupted%s' "$with" ;;
        llm_rate_limited)
            printf 'stopped: the model'"'"'s usage limit was reached%s' "$with" ;;
        llm_unavailable)
            printf 'stopped: the model could not be reached%s' "$with" ;;
        scope_too_large)
            printf 'stopped: the issue is too large to plan in one run — split it%s' "$with" ;;
        converged|complete|success)
            printf 'finished%s' "$with" ;;
        *)
            printf 'stopped before finishing%s' "$with" ;;
    esac
}

# run_end_reason <state_dir> — the engine's code for why the run ended: the last
# pipeline.end event's reason, else the state file's. Empty when neither says.
run_end_reason() {
    local sd="$1" r=""
    [[ -s "$sd/events.jsonl" ]] && r="$(jq -r 'select(type == "object" and .type == "pipeline.end") | .data.reason // empty' \
        "$sd/events.jsonl" 2>/dev/null | tail -n 1)"
    [[ -z "$r" && -s "$sd/pipeline-state.json" ]] && r="$(jq -r '.reason // empty' "$sd/pipeline-state.json" 2>/dev/null)"
    printf '%s' "$r"
}

# run_completion_body <result> <abort_reason> <abort_detail> <run_url> <started>
#   <open_items_md> <end_words> — the comment posted on the issue when a run
# ends. <result> is the job's result (success | failure | cancelled | …).
run_completion_body() {
    local result="${1:-}" reason="${2:-}" detail="${3:-}" url="${4:-}" started="${5:-}" items="${6:-}" words="${7:-}"
    local body
    if [[ "$result" == "success" ]]; then
        body="**zbuild pipeline completed successfully.**"
    elif [[ "$reason" == "llm_rate_limited" ]]; then
        body="**zbuild pipeline $(run_end_words "$reason" 0)** (${detail:-the reset time was not reported}). State was persisted — re-add \`zbuild-run\` after the reset to resume."
    elif [[ -n "$reason" ]]; then
        local n=0
        [[ -n "$items" ]] && n="$(grep -c '^[0-9][0-9]*\. ' <<< "$items" || true)"
        body="**zbuild pipeline $(run_end_words "$reason" "$n").**"
    elif [[ "$result" == "cancelled" ]] && declare -F rsc_cancel_closing >/dev/null 2>&1; then
        body="$(rsc_cancel_closing "$started")"
    elif [[ -n "$words" ]]; then
        body="**zbuild pipeline ${words}.**"
    else
        body="**zbuild pipeline did not finish.** The run log shows where it stopped."
    fi
    if [[ "$result" != "success" && -n "$items" ]]; then
        body+=$'\n\n'"Still open:"$'\n\n'"$items"
    fi
    printf '%s' "$body"
    [[ -n "$url" ]] && printf '\n\nRun: %s' "$url"
    return 0
}

# open_items_outbound <state_dir> — the end words and the list, cleaned of
# anything the scope manifest hides, for text that leaves the machine (the
# completion comment). Prints nothing when no item is open; a redactor failure
# prints nothing too — never post unredacted.
open_items_outbound() {
    local sd="$1" md manifest root
    md="$(open_items_markdown "$sd")"
    [[ -n "$md" ]] || return 0
    manifest="$sd/scope-manifest.md"
    if [[ ! -s "$manifest" ]]; then printf '%s\n' "$md"; return 0; fi
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    if ! declare -F apply_scope_redaction >/dev/null 2>&1; then
        # shellcheck source=../../core/redaction/scope-redaction.sh
        source "$root/core/redaction/scope-redaction.sh" 2>/dev/null || return 0
    fi
    local tin tout
    tin="$(mktemp "${TMPDIR:-/tmp}/open-items-in.XXXXXX")" || return 0
    tout="$(mktemp "${TMPDIR:-/tmp}/open-items-out.XXXXXX")" || { rm -f "$tin"; return 0; }
    printf '%s\n' "$md" > "$tin"
    apply_scope_redaction "$tin" "$tout" "$manifest" "" "0" >/dev/null 2>&1 && cat "$tout"
    rm -f "$tin" "$tout"
    return 0
}
