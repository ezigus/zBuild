#!/usr/bin/env bash
# scripts/lib/lint-bare-timeout.sh — fail on bare `timeout` invocations (#1752)
# Scans core/, scripts/, plugins/ for .sh files that call `timeout` as a command
# (not as an argument to `command -v`). Every timeout bound must go through
# _acceptance_timeout_prefix (scripts/lib/timeout-cmd.sh, ADR-036 amendment).
#
# Per-line opt-out: append  # lint-bare-timeout:allow: <reason>  to the line.
# Self-exemptions:
#   scripts/lib/test-helpers.sh — the `timeout` there is a stub that just execs
#     the remaining args; it is a fake binary, not a timeout invocation.
#   scripts/lib/lint-bare-timeout.sh (this file) — self-reference.
set -euo pipefail

LINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LINT_DIR/../.." && pwd)"

SCAN_ROOT="${1:-$REPO_ROOT}"

_failures=0

# _check_file uses awk with basic quote-state tracking so that `timeout` inside
# a double-quoted string (e.g. warn "escalating timeout ${s}s") is not flagged.
# Single-quoted strings are also tracked. Escaped quotes (\") are skipped.
# The match requires `timeout` at a command-position (start of line or after a
# command separator) and NOT inside a quoted context.
_check_file() {
    local file="$1"
    # Self-exempt: this lint script and the test-helpers stub.
    case "$file" in
        */scripts/lib/lint-bare-timeout.sh) return 0 ;;
        # lint-bare-timeout:allow: test-helpers timeout is a recording stub (fake binary), not an invocation
        */scripts/lib/test-helpers.sh) return 0 ;;
    esac

    local hits
    hits="$(awk '
    function is_cmd_sep(c) {
        return (c == " " || c == "\t" || c == ";" || c == "|" || \
                c == "&" || c == "(" || c == "`")
    }
    {
        line = $0
        # Skip pure comment lines
        if (line ~ /^[[:space:]]*#/) next
        # Skip command -v timeout (binary probe)
        if (line ~ /command[[:space:]]+-v[[:space:]]+timeout/) next
        # Skip lines with allow opt-out
        if (index(line, "lint-bare-timeout:allow") > 0) next

        # Simple quote-state scan
        in_dq = 0; in_sq = 0
        n = length(line)
        for (i = 1; i <= n; i++) {
            c = substr(line, i, 1)
            # Handle escape inside double-quote
            if (in_dq && c == "\\") { i++; continue }
            # Toggle double-quote
            if (!in_sq && c == "\"") { in_dq = !in_dq; continue }
            # Toggle single-quote (no escapes inside single-quotes in shell)
            if (!in_dq && c == "'\''" ) { in_sq = !in_sq; continue }

            # Only look for timeout outside quotes
            if (in_dq || in_sq) continue

            # `timeout` is 7 characters; check match at position i
            if (substr(line, i, 7) != "timeout") continue

            # Require word-boundary after: space or end-of-string
            after = (i + 7 <= n) ? substr(line, i + 7, 1) : " "
            if (after !~ /[[:space:]]/) continue

            # Require command-position before: start of line or sep char
            before = (i > 1) ? substr(line, i - 1, 1) : " "
            if (i == 1 || is_cmd_sep(before)) {
                print FILENAME ":" NR ": bare timeout invocation (use _acceptance_timeout_prefix): " line
            }
        }
    }' "$file" 2>/dev/null || true)"

    if [[ -n "$hits" ]]; then
        printf '%s\n' "$hits" >&2
        local count
        count="$(printf '%s\n' "$hits" | wc -l)"
        _failures=$(( _failures + count ))
    fi
}

if [[ -n "${1:-}" ]]; then
    # Explicit target: scan the given directory recursively
    while IFS= read -r -d '' sh_file; do
        _check_file "$sh_file"
    done < <(find "$SCAN_ROOT" -name '*.sh' -not -path '*/legacy/*' -print0 2>/dev/null)
else
    # Default: scan the canonical source dirs
    while IFS= read -r -d '' sh_file; do
        _check_file "$sh_file"
    done < <(find "$SCAN_ROOT/core" "$SCAN_ROOT/scripts" "$SCAN_ROOT/plugins" \
        -name '*.sh' -not -path '*/legacy/*' -print0 2>/dev/null)
fi

if [[ "$_failures" -gt 0 ]]; then
    printf 'lint-bare-timeout: %d bare timeout invocation(s) found\n' "$_failures" >&2
    exit 1
fi
exit 0
