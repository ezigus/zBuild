#!/usr/bin/env bash
# Shared helpers for GitHub-automation scripts. Used by deferred-tracker
# and manifest-sync. Scoped per #540 review: extract only genuinely shared
# logic (idempotency-log row check + append); single-caller helpers stay
# in their owning script.

[[ -n "${_ZBUILD_GHA_LOADED:-}" ]] && return 0
_ZBUILD_GHA_LOADED=1

_ZBUILD_GHA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
source "$_ZBUILD_GHA_DIR/helpers.sh"

# Returns 0 if PR number is present in a `| #N |`-style markdown log.
gha_is_already_scanned() {
    local pr_num="$1"
    local log_path="$2"
    [[ -f "$log_path" ]] || return 1
    grep -qE "^\| #${pr_num} \|" "$log_path"
}

# Appends a row to a markdown idempotency log if not already present.
# Bootstraps the file via the provided header callback when missing.
# Args:
#   $1 — log path
#   $2 — header callback name (function taking $log_path as arg, writes header)
#   $3 — column-3 value (date or status; positional)
#   $4… — entries in "pr_num|title" format
gha_append_scanned_log() {
    local log_path="$1"
    local header_fn="$2"
    local col3_value="$3"
    shift 3
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ ! -f "$log_path" ]]; then
        mkdir -p "$(dirname "$log_path")"
        "$header_fn" "$log_path" "$now"
    else
        zbuild_sed_inplace "s|^_Last updated:.*|_Last updated: ${now}_|" "$log_path"
    fi
    local entry pr_num title
    for entry in "$@"; do
        IFS='|' read -r pr_num title <<< "$entry"
        [[ -z "$pr_num" ]] && continue
        if grep -qE "^\| #${pr_num} \|" "$log_path"; then
            continue
        fi
        printf '| #%s | %s | %s |\n' "$pr_num" "$title" "$col3_value" >> "$log_path"
    done
}
