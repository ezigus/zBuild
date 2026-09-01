#!/usr/bin/env bash
# scripts/lib/stage-summary.sh — every stage states what it did (#2000).
#
# ADR-055 §9 makes this mandatory for every stage-bound plugin, not just the
# gates #1988 covered. A stage that publishes nothing is indistinguishable from
# one that had nothing to say, and the pipeline cannot tell those apart — so the
# second silently absorbs the first. `acceptance-summary.txt` is the worked
# example: written by spec-acceptance, declared by nobody, unread for months.
#
# Shared rather than hand-rolled five times: the write is identical everywhere,
# and centralising it is what makes "every gate always speaks" enforceable
# rather than five separate chances to forget.
#
# Source-only; no `set -e` at top level (would mutate caller options).

[[ -n "${_ZBUILD_STAGE_SUMMARY_SH_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_SUMMARY_SH_LOADED=1

# ─── stage_summary_write <path> <stage> <verdict> <reason> [body] ────────────
# Writes the gate's summary on EVERY terminal verdict — pass, fail and skip.
#
# ADR-055 §9: a summary states what the stage DID, not what went wrong. A gate
# that passed still did work, and a later stage that cannot see its conclusion
# must either assume the work never happened or redo it. Writing
# unconditionally also collapses the ambiguity between "ran and found nothing"
# and "published nothing" — a missing summary now means something went wrong,
# full stop, which is why the output is `required: true`.
#
# The heading names the stage so a reader of the assembled prompt can tell whose
# statement it is once several are stacked.
stage_summary_write() {
    local path="${1:-}" stage="${2:-}" verdict="${3:-}" reason="${4:-}" body="${5:-}"
    [[ -n "$path" ]] || return 0
    mkdir -p "$(dirname "$path")" 2>/dev/null || true
    {
        printf '## %s — %s\n\n' "${stage:-stage}" "${verdict:-unknown}"
        if [[ -n "$reason" ]]; then
            printf -- '- %s\n' "$reason"
        else
            # Never silent: a verdict with nothing said still states that this
            # gate ran and reached it, which is the fact a later stage needs.
            printf -- '- no findings\n'
        fi
        [[ -n "$body" ]] && printf '\n%s\n' "$body"
    } > "$path" 2>/dev/null || true
}
