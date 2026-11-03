#!/usr/bin/env bash
# scripts/lib/lint-stage-io.sh — ADR-015 §v4 (#491) static guard.
#
# Refuses any same-line `route_to_model` / `route_to_model_loop` /
# `run_captured_command` callsite that discards stderr via 2>/dev/null.
# Reason: those callers wrap the action in $() and the chokepoint writes the
# input banner to fd 2 (ZBUILD_STAGE_IO_FD default); 2>/dev/null swallows it
# and breaks the input-before-action ordering contract.
#
# The regex is narrow on purpose: it only matches when `route_to_model[_loop]`
# OR `run_captured_command` and `2>/dev/null` appear on the same line. This
# avoids the ~100 false positives from unrelated 2>/dev/null uses elsewhere in
# the codebase (gh/git probes, optional helpers, etc.) — those are not
# action-capture call sites and don't affect banner emission.
#
# Exit codes:
#   0 — clean
#   1 — at least one offending line found (printed to stderr with file:line)
#
# Usage:
#   bash scripts/lib/lint-stage-io.sh            # lint the whole repo
#   bash scripts/lib/lint-stage-io.sh <path>...  # lint specific paths

set -euo pipefail

_LINT_STAGE_IO_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)"
_LINT_STAGE_IO_REPO="$(cd "$_LINT_STAGE_IO_DIR/../.." && pwd)"

# Search scope defaults to production code (plugin.sh + core/router/route.sh).
# Test files are excluded: they legitimately invoke `route_to_model 2>/dev/null`
# while exercising error returns (the chokepoint's banner is irrelevant in unit
# tests). Callers may pass explicit paths to widen the scope (e.g. mutation tests).
_targets=()
if [[ $# -gt 0 ]]; then
    _targets=("$@")
else
    # Action-capture surface: plugin entry points and the router itself.
    _targets=(
        "$_LINT_STAGE_IO_REPO/core/router/route.sh"
    )
    # Collect every plugins/**/plugin.sh (the entry-point file convention).
    while IFS= read -r -d '' _f; do
        _targets+=("$_f")
    done < <(find "$_LINT_STAGE_IO_REPO/plugins" -name 'plugin.sh' -not -path '*/tests/*' -print0 2>/dev/null)
fi

# Pattern documented in ADR-015 §v4: same-line route_to_model[_loop] OR
# run_captured_command followed by 2>/dev/null with optional whitespace.
# #2460: whole commands — a call whose arguments carry on to the next line is
# joined onto its first line (shell-join.sh), so `2>/dev/null` there is seen.
# shellcheck source=./shell-join.sh
source "$_LINT_STAGE_IO_DIR/shell-join.sh"
_ere='(route_to_model(_loop)?|run_captured_command)([^A-Za-z0-9_].*)?2>[[:space:]]*/dev/null'
_offenders=""
for _f in "${_targets[@]}"; do
    [[ -f "$_f" ]] || continue
    while IFS= read -r _hit; do
        [[ -n "$_hit" ]] && _offenders+="$_f:$_hit"$'\n'
    done < <(zb_shell_join "$_f" | grep -nE "$_ere" || true)
done
_offenders="${_offenders%$'\n'}"
if [[ -n "$_offenders" ]]; then
    printf 'lint-stage-io: ADR-015 §v4 violation — 2>/dev/null on same line as route_to_model[_loop] or run_captured_command:\n' >&2
    printf '%s\n' "$_offenders" >&2
    printf '\nFix: remove `2>/dev/null` from the offending call. The stage-io input banner writes to fd 2 (default ZBUILD_STAGE_IO_FD); suppressing stderr drops the banner and violates the input-before-action ordering contract. See ADR-015 §v4.\n' >&2
    exit 1
fi

exit 0
