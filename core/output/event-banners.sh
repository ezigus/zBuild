#!/usr/bin/env bash
# core/output/event-banners.sh — operator-visible WARN banners for HIGH-severity
# cycle events (issue #526, amends ADR-021 §Fail-loud).
#
# Why: ADR-021's HIGH-severity cycle events (feedback missing, config invalid,
# verdict missing, history lost, metric invalid) emit structured JSONL — durable
# and machine-readable — but a human watching the pipeline scroll has no nudge.
# This helper adds a single-line ⚠ banner to stderr, indented under the active
# cycle divider, that mirrors the event type and its k=v payload. JSONL is the
# source of truth; banner emit failure (closed fd, full pipe) MUST NOT abort
# the cycle.
#
# Single export:
#   _emit_high_event_banner <event_type> [k=v ...]
#     - Banner only fires for event types in _HIGH_EVENT_TYPES (hardcoded set).
#     - Non-HIGH event types are a silent no-op (caller still calls eb_emit_event
#       separately — banner does NOT steal emission).
#
# Sourced library: do not add `set -euo pipefail` here.

[[ -n "${_ZBUILD_EVENT_BANNERS_LOADED:-}" ]] && return 0
_ZBUILD_EVENT_BANNERS_LOADED=1

_ZBUILD_EVENT_BANNERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_EVENT_BANNERS_ROOT="$(cd "$_ZBUILD_EVENT_BANNERS_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$_ZBUILD_EVENT_BANNERS_ROOT/scripts/lib/helpers.sh"

# ─── HIGH event set (hardcoded; NOT a schema field) ──────────────────────────
# Expanding this list is a one-line non-breaking change. event-schema.json's
# flat `known_types[]` shape can't carry severity without breaking every
# consumer + the lint check, so severity lives here. Document additions in
# the ADR-021 amendment block.
readonly _HIGH_EVENT_TYPES=(
    cycle.feedback.missing
    cycle.config.invalid
    cycle.iteration.verdict_missing
    cycle.history.lost
    cycle.metric.invalid
)

# ─── _emit_high_event_banner <event_type> [k=v ...] ──────────────────────────
# Single-line WARN banner to stderr, two-space indented (nests under the cycle
# divider). Reuses helpers.sh ⚠ glyph + YELLOW/BOLD/RESET so NO_COLOR=1 strips
# ANSI automatically (helpers.sh:22).
_emit_high_event_banner() {
    local event_type="$1"; shift || true
    # Membership check — silent no-op for informational events.
    local is_high=0 t
    for t in "${_HIGH_EVENT_TYPES[@]}"; do
        [[ "$t" == "$event_type" ]] && is_high=1 && break
    done
    [[ $is_high -eq 0 ]] && return 0

    # Best-effort emit: a closed stderr or broken pipe MUST NOT abort the cycle.
    # JSONL is the durable record; this banner is an operator nudge. The printf
    # is wrapped with `|| true` so a failed write (e.g. stderr closed with 2>&-)
    # cannot propagate a non-zero rc back to the caller.
    #
    # Compose k=v payload space-separated, caller-order (matches eb_emit_event
    # convention). Two-space indent → visually nests beneath the cycle divider
    # from #524. printf preferred over echo -e so YELLOW/BOLD/RESET (already
    # resolved by helpers.sh, null under NO_COLOR per helpers.sh:22) render
    # cleanly on a single line.
    local payload="$*"
    if [[ -n "$payload" ]]; then
        printf '  %b⚠%b %s — %s\n' \
            "${YELLOW}${BOLD}" "${RESET}" "$event_type" "$payload" >&2 || true
    else
        printf '  %b⚠%b %s\n' \
            "${YELLOW}${BOLD}" "${RESET}" "$event_type" >&2 || true
    fi
    return 0
}
