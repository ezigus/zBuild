#!/usr/bin/env bash
# core/output/stage-colors.sh — ADR-015 §v5 per-stage color registry (issue #492)
#
# A single source of truth that maps canonical pipeline stage IDs to ANSI color
# escapes drawn from scripts/lib/helpers.sh. Sourced by core/output/stage-io.sh
# (the banner emitter) and core/pipeline/runner.sh (the "▸ Running stage" line
# + stage-transition divider). NOT sourced by plugin-bootstrap — plugins emit
# colors via the helpers (info/success/warn/error) which already carry the
# correct palette; stages don't need direct access to the per-stage registry.
#
# Bash 5+ assoc-array (zBuild already enforces Bash 5 via scripts/lib/compat.sh).
# Source-once guard prevents re-declaration when this file is included from
# both stage-io.sh AND runner.sh in the same process.
#
# NO_COLOR / non-tty handling: scripts/lib/helpers.sh nulls all color globals
# when NO_COLOR is set or stdout is not a tty (see helpers.sh:19-31). Because
# this registry stores REFERENCES to those globals (not literal escape codes),
# NO_COLOR transparently strips colors here too — `_stage_color plan` returns
# the empty string under NO_COLOR, which renders identically to no-color mode.

[[ -n "${_ZBUILD_STAGE_COLORS_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_COLORS_LOADED=1

# Defensively source helpers.sh — it has its own load guard, so this is
# idempotent. Required so $CYAN/$BLUE/$YELLOW/etc are defined when this file
# is sourced standalone (a unit test sourcing only stage-colors.sh).
_ZBUILD_STAGE_COLORS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$_ZBUILD_STAGE_COLORS_DIR/../../scripts/lib/helpers.sh"

# Per-stage color map. Order chosen so adjacent pipeline stages contrast
# visually in the operator's terminal scrollback.
declare -gA _STAGE_COLORS=(
    [intake]="$BLUE"
    [plan]="$CYAN"
    [build]="$YELLOW"
    [test]="$PURPLE"
    [review]="$GREEN"
    [security-lens]="$RED"
)

# _stage_color <stage> — print the ANSI escape for a stage to stdout.
# Unknown stages fall back to $CYAN (matches the existing `info()` palette
# and keeps colored output non-jarring for any future stage that lands
# before its color is registered here). Always rc=0; never errors.
_stage_color() {
    local stage="${1:-}"
    if [[ -n "$stage" && -n "${_STAGE_COLORS[$stage]+x}" ]]; then
        printf '%s' "${_STAGE_COLORS[$stage]}"
    else
        printf '%s' "${CYAN:-}"
    fi
}
