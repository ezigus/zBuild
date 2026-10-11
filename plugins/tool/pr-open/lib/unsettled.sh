#!/usr/bin/env bash
# plugins/tool/pr-open/lib/unsettled.sh — #1799 (ADR-019 fall-through): did the
# run's work settle, and if not, what to say about it. A run that did not settle
# still opens its PR — that is the fall-through, handing an unconverged attempt
# to whoever reviews it — but as a draft, with the reason at the top.
# Sourced library: no set -euo pipefail.
#
# What "did not settle" reads, and why from these two places:
#   * every loop in the state file's `cycle_iterations` — keyed by the loop's own
#     id from whichever template ran, with `status`, `current_iter` and
#     `max_iterations` written by the engine (cycle-orchestrator.sh
#     _cycle_state_write_iter_atomic). A loop whose last status is not
#     `complete` did not pass: it ran out of rounds (max_iterations), stopped
#     with findings no stage could act on (unowned_finding), or ended some other
#     way before passing (in_progress is what a plateau or divergence leaves).
#     A loop nested in an outer one restarts its count each outer round, so its
#     numbers are its last run's.
#   * the final gate roll-up, gate_aggregator_result — a declared input — when
#     its verdict is not `pass`.
# The run's own `status` is not read: the engine marks a run failed only on the
# paths that stop it, and the pr stage never runs after those.

# It escapes every value with the jq definitions advisory-section.sh holds
# (_PR_OPEN_FINDING_JQ_DEFS). plugin.sh sources that first; sourced on its own
# this file loads it, rather than render without escaping (review #2343).
if [[ -z "${_PR_OPEN_FINDING_JQ_DEFS:-}" ]]; then
    # shellcheck source=advisory-section.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/advisory-section.sh"
fi

# The hidden line zBuild puts in a description when IT made the PR a draft, so
# a later settled run turns back to ready only a draft zBuild made — never one a
# person made.
_pr_open_forced_draft_marker() {
    printf '%s' '<!-- zbuild: draft because the run did not settle (#1799) -->'
}

# _pr_open_unsettled <state_file> <gate_aggregator_result path, may be empty>
# The gate roll-up writes its own reason as "gates failed: <the list>", which
# would only repeat the list; a reason is shown only when it says more.
# Prints nothing when the work settled. Otherwise line 1 is a one-line reason
# (for the result and the event) and the rest is the description's warning
# block. One jq for both files (ADR-065).
_pr_open_unsettled() {
    local state_file="$1" gate_path="${2:-}" gates='null' open='[]'
    [[ -f "$state_file" ]] || return 0
    # ADR-068 §10: a finding nobody acted on — a warning included — means the
    # work did not settle either.
    if ! declare -F open_findings_json >/dev/null 2>&1; then
        # shellcheck source=../../../../core/pipeline/open-findings.sh
        source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)/core/pipeline/open-findings.sh" 2>/dev/null || true
    fi
    declare -F open_findings_json >/dev/null 2>&1 && open="$(open_findings_json "$state_file")"
    if [[ -n "$gate_path" && -s "$gate_path" ]] && jq -e 'type == "object"' "$gate_path" >/dev/null 2>&1; then
        gates="$(cat "$gate_path")"
    fi
    jq -r --argjson g "$gates" --argjson of "${open:-[]}" "${_PR_OPEN_FINDING_JQ_DEFS}"'
        def why: if . == "max_iterations" then "it ran out of rounds"
                 elif . == "unowned_finding" then "it had findings no stage could act on"
                 else "it ended before it passed" end;
        def num: if type == "number" then tostring else "?" end;
        [ (.cycle_iterations // {}) | to_entries[]
          | select((.value.status // "") != "complete")
          | { id: (.key | esc), round: (.value.current_iter | num),
              limit: (.value.max_iterations | num), why: ((.value.status // "") | why) } ] as $loops
        | ( if $g != null and (($g.verdict // "pass") != "pass")
            then { gates: (($g.failed // []) | map(esc) | join(", ")),
                   reason: (($g.reason // "") | if startswith("gates failed:") then "" else esc end) }
            else null end ) as $gate
        | if ($loops | length) == 0 and $gate == null and ($of | length) == 0 then empty else
            ( [ ($loops[] | "\(.id) stopped after round \(.round) of \(.limit)"),
                (if $gate then "gates failed: \($gate.gates)" else empty end),
                (if ($of | length) > 0 then "\($of | length) open finding(s)" else empty end) ] | join("; ") ),
            "> ⚠️ **This change did not settle, so the PR is a draft.**",
            ( $loops[] | "> - `\(.id)` stopped after round \(.round) of \(.limit) without passing: \(.why)." ),
            ( if $gate then "> - The final gate check did not pass: \($gate.gates)"
                  + (if $gate.reason != "" then " (\($gate.reason))" else "" end) + "."
              else empty end ),
            ( $of[] | "> - Open finding — \(.ref | esc): \(.text | esc). No stage said it was done, and the check that raised it did not say it was satisfied." )
          end' "$state_file" 2>/dev/null || true
}

# _pr_open_sync_draft <pr_number> <want_draft: true|false>
# Bring an EXISTING PR's draft state in line with this run. `gh pr edit` cannot
# change it, so this uses `gh pr ready` (and `--undo` for draft). Turns a PR
# back to ready only when its current description carries zBuild's marker.
# Never fails the stage: the PR is open and updated either way; a failure is
# reported (stdout: a short note for the summary).
_pr_open_sync_draft() {
    local n="$1" want="$2" view is_draft had_marker=0
    view="$(gh pr view "$n" --json isDraft,body 2>/dev/null || true)"
    is_draft="$(jq -r '.isDraft // false' <<< "${view:-{\}}" 2>/dev/null || printf 'false')"
    grep -qF -- "$(_pr_open_forced_draft_marker)" <<< "$(jq -r '.body // ""' <<< "${view:-{\}}" 2>/dev/null)" && had_marker=1
    if [[ "$want" == "true" && "$is_draft" != "true" ]]; then
        gh pr ready "$n" --undo >/dev/null 2>&1 || printf 'could not turn PR %s into a draft' "$n"
    elif [[ "$want" != "true" && "$is_draft" == "true" && $had_marker -eq 1 ]]; then
        gh pr ready "$n" >/dev/null 2>&1 || printf 'could not mark PR %s ready' "$n"
    fi
    return 0
}
