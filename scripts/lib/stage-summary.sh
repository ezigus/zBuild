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

# ─── stage_errors_append <stage> <text...> ──────────────────────────────────
# Append to THIS stage's declared error channel (#2183). One place, so a stage
# adds a line without knowing where the file lives or how it is published: the
# engine reads the manifest's `errors: true` output and carries a bounded tail
# into the summaries the other stages read when this stage fails.
#
# Path convention: ${artifact_dir}/<stage>-errors.log. Appends, so a stage with
# several failing subprocesses keeps all of them. Cleared by the engine at the
# start of each dispatch (the previous attempt's copy is already archived).
# Fail-open: a diagnostic write never changes a stage's fate.
stage_errors_append() {
    local stage="${1:-${ZBUILD_CURRENT_STAGE:-}}"; shift || true
    [[ -n "$stage" ]] || return 0
    local art="${ZBUILD_ARTIFACT_DIR:-${ZBUILD_STATE_DIR:+$ZBUILD_STATE_DIR/artifacts}}"
    [[ -n "$art" ]] || return 0
    mkdir -p "$art" 2>/dev/null || true
    local safe="${stage//[^A-Za-z0-9_-]/_}"
    printf '%s\n' "$*" >> "$art/${safe}-errors.log" 2>/dev/null || true
    return 0
}

# ─── stage_errors_append_file <stage> <file> [label] ────────────────────────
# The same, for a file a subprocess wrote (its stderr, a tool's log).
stage_errors_append_file() {
    local stage="${1:-${ZBUILD_CURRENT_STAGE:-}}" file="${2:-}" label="${3:-}"
    [[ -n "$file" && -s "$file" ]] || return 0
    [[ -n "$label" ]] && stage_errors_append "$stage" "--- $label ---"
    stage_errors_append "$stage" "$(cat "$file" 2>/dev/null || true)"
    return 0
}
