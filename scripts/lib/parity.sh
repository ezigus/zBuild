#!/usr/bin/env bash
# scripts/lib/parity.sh — Normalization helpers for CI/CLI parity tests
# Source this library in parity test files to strip non-deterministic fields
# before comparing pipeline output across environments.
#
# Functions:
#   normalize_run_id <text>           — replace YYYYMMDDHHMMSS-PID with __RUN_ID__
#   normalize_timestamps <text>       — replace ISO-8601 datetimes with __TS__
#   normalize_paths <text> <base>     — replace $base prefix with __FIXTURE_DIR__
#   strip_ci_only_events              — stdin filter: remove CI-only event type lines
#   normalize_output_for_parity <text> <base> — composed pipeline of all above

[[ -n "${_ZBUILD_PARITY_LOADED:-}" ]] && return 0
_ZBUILD_PARITY_LOADED=1

# normalize_run_id <text>
# Replaces patterns matching YYYYMMDDHHMMSS-<digits> (run_id format) with __RUN_ID__.
normalize_run_id() {
    local text="$1"
    printf '%s' "$text" | sed -E 's/[0-9]{14}-[0-9]+/__RUN_ID__/g'
}

# normalize_timestamps <text>
# Replaces ISO-8601 datetime strings (YYYY-MM-DDTHH:MM:SSZ) with __TS__.
normalize_timestamps() {
    local text="$1"
    printf '%s' "$text" | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/__TS__/g'
}

# normalize_paths <text> <base>
# Replaces occurrences of <base> in <text> with __FIXTURE_DIR__.
normalize_paths() {
    local text="$1"
    local base="$2"
    # Escape any regex special characters in base path
    local escaped_base
    escaped_base="$(printf '%s' "$base" | sed 's/[[\.*^$()+?{|]/\\&/g')"
    printf '%s' "$text" | sed "s|${escaped_base}|__FIXTURE_DIR__|g"
}

# strip_ci_only_events
# Stdin filter: removes lines containing CI-only event types that only fire when
# GITHUB_STEP_SUMMARY or GitHub check-run output is active.
strip_ci_only_events() {
    grep -Ev '^(output\.gh-check-run|output\.step-summary)$' || true
}

# normalize_output_for_parity <text> <base>
# Composed pipeline: applies all normalizers in sequence.
normalize_output_for_parity() {
    local text="$1"
    local base="$2"
    local result
    result="$(normalize_run_id "$text")"
    result="$(normalize_timestamps "$result")"
    result="$(normalize_paths "$result" "$base")"
    printf '%s' "$result"
}
