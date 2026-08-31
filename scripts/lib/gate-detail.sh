#!/usr/bin/env bash
# scripts/lib/gate-detail.sh — a gate publishes what only it knows (#1988).
#
# Five gates declared only a result JSON, so the gate-aggregator was the sole
# path for their failure detail to reach a prompt — it read seven scattered
# result files and rendered them as prose. #1976 made another path: a gate marks
# one output `summary: true` and the engine delivers it.
#
# Shared rather than hand-rolled five times: the write is identical everywhere,
# and centralising it is what makes "every gate always speaks" enforceable
# rather than five separate chances to forget.
#
# Source-only; no `set -e` at top level (would mutate caller options).

[[ -n "${_ZBUILD_GATE_DETAIL_SH_LOADED:-}" ]] && return 0
_ZBUILD_GATE_DETAIL_SH_LOADED=1

# ─── gate_detail_write <path> <gate> <verdict> <reason> [body] ───────────────
# Writes the gate's summary on EVERY terminal verdict — pass, fail and skip.
#
# ADR-055 §9: a summary states what the stage DID, not what went wrong. A gate
# that passed still did work, and a later stage that cannot see its conclusion
# must either assume the work never happened or redo it. Writing
# unconditionally also collapses the ambiguity between "ran and found nothing"
# and "published nothing" — a missing summary now means something went wrong,
# full stop, which is why the output is `required: true`.
#
# The heading names the gate so a reader of the assembled prompt can tell whose
# statement it is once several are stacked.
gate_detail_write() {
    local path="${1:-}" gate="${2:-}" verdict="${3:-}" reason="${4:-}" body="${5:-}"
    [[ -n "$path" ]] || return 0
    mkdir -p "$(dirname "$path")" 2>/dev/null || true
    {
        printf '## %s — %s\n\n' "${gate:-gate}" "${verdict:-unknown}"
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
