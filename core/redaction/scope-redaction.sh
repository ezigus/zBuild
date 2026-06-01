#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild scope-redaction chokepoint (ADR-004)                              ║
# ║  Every LLM-bound text in zBuild passes through apply_scope_redaction.     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# This is the SINGLE entry point for emitting text to an LLM. Plugins
# REQUIRE 'core: [redaction]' in their manifest; the registry refuses
# kind: agent plugins without it.
#
# Behavior (per ADR-004):
#   1. Refuse to emit if scope manifest is unset, empty, or unreadable.
#   2. Strip absolute and repo-relative paths outside the allowlist + scope.
#      Replace with <out-of-scope-context> markers.
#   3. Preserve code-fence boundaries verbatim.
#   4. Emit redaction.applied event with stats.
#   5. Idempotent.
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_REDACTION_LOADED:-}" ]] && return 0
_ZBUILD_REDACTION_LOADED=1

_ZBUILD_REDACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="$(cd "$_ZBUILD_REDACTION_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$_ZBUILD_ROOT/scripts/lib/helpers.sh"

# ─── apply_scope_redaction ──────────────────────────────────────────────────
# Usage:
#   apply_scope_redaction <input_file> <output_file> <scope_manifest_path> [allowlist_csv] [cycle_id]
#
# Returns: 0 on success, 1 on fail-closed refusal, 2 on I/O error.
apply_scope_redaction() {
    local input="${1:-}"
    local output="${2:-}"
    local manifest="${3:-}"
    local allowlist="${4:-}"
    local cycle_id="${5:-0}"

    if [[ -z "$input" || -z "$output" ]]; then
        error "apply_scope_redaction: requires <input> <output> <manifest> [allowlist] [cycle_id]"
        return 2
    fi
    if [[ ! -f "$input" ]]; then
        error "apply_scope_redaction: input not found: $input"
        return 2
    fi

    # ─── Fail-closed: refuse to emit without scope manifest ─────────────────
    if [[ -z "$manifest" || ! -f "$manifest" || ! -s "$manifest" ]]; then
        # Check operator override (audit-trail required)
        local override_token="${HOME}/.zbuild/scope-override-token"
        if [[ "${ZBUILD_SCOPE_OVERRIDE:-0}" == "1" && -f "$override_token" && -n "${ZBUILD_RUN_ID:-}" ]]; then
            local token_run_id; token_run_id="$(cat "$override_token" 2>/dev/null || echo "")"
            if [[ "$token_run_id" == "$ZBUILD_RUN_ID" ]]; then
                warn "apply_scope_redaction: operator override active for run_id=$ZBUILD_RUN_ID"
                emit_event "redaction.refused.overridden" "run_id=$ZBUILD_RUN_ID" "input=$input"
                cp "$input" "$output"
                return 0
            fi
        fi
        error "apply_scope_redaction: refusing — scope manifest missing/empty: ${manifest:-<unset>}"
        emit_event "redaction.refused" "reason=missing_scope_manifest" "input=$input" "cycle=$cycle_id"
        return 1
    fi

    # ─── Build allowlist as in-memory string (no tempfile; #296 Δ-3) ───────
    # Previously: wrote to mktemp + trap RETURN + awk read via getline < file.
    # Race window: if a concurrent process deleted the tempfile between write
    # and read, awk would silently see an empty allowlist (fail-safe but
    # silent over-redaction). Inlining via environment variable eliminates
    # the tempfile and the race entirely.
    local allow_lines
    allow_lines="$(awk '/^\+/ { sub(/^\+[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); if (length($0)) print $0 }' "$manifest")"
    if [[ -n "$allowlist" ]]; then
        # printf instead of echo: echo mishandles "-n"/"-e"/backslashes on
        # some platforms (Copilot caught this on PR #297).
        local csv_lines; csv_lines="$(printf '%s\n' "$allowlist" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [[ -n "$allow_lines" ]]; then
            allow_lines="${allow_lines}"$'\n'"${csv_lines}"
        else
            allow_lines="$csv_lines"
        fi
    fi

    # ─── Redact with awk (fence-aware, allowlist-driven) ────────────────────
    local size_before; size_before=$(wc -c < "$input")
    local counter_skipped_log="$output.counter-skipped"
    : > "$counter_skipped_log"

    ZBUILD_REDACTION_ALLOW="$allow_lines" \
    ZBUILD_REDACTION_COUNTER_LOG="$counter_skipped_log" \
    awk '
    BEGIN {
        n_allow = 0
        allow_data = ENVIRON["ZBUILD_REDACTION_ALLOW"]
        counter_log = ENVIRON["ZBUILD_REDACTION_COUNTER_LOG"]
        n = split(allow_data, lines, "\n")
        for (i = 1; i <= n; i++) {
            if (length(lines[i]) > 0) {
                allow[++n_allow] = lines[i]
            }
        }
        in_fence = 0
    }
    /^```/ {
        in_fence = 1 - in_fence
        print
        next
    }
    in_fence == 1 {
        print
        next
    }
    {
        line = $0
        # Idempotence (#606 Bug A2): skip tokenization inside existing
        # <out-of-scope-context>...</out-of-scope-context> spans. The path
        # regex matches "/out-of-scope-context" inside the closing tag,
        # which would cascade-nest markers on a second pass. Segment the
        # line by markers and only tokenize outside-marker segments.
        result = ""
        rest = line
        open_tag  = "<out-of-scope-context>"
        close_tag = "</out-of-scope-context>"
        depth = 0
        while (length(rest) > 0) {
            if (depth == 0) {
                # Find next opening marker (if any) and tokenize text before it.
                opos = index(rest, open_tag)
                if (opos == 0) {
                    # No more markers on this line; tokenize whole remainder.
                    result = result tokenize_paths(rest)
                    rest = ""
                } else {
                    pre = substr(rest, 1, opos - 1)
                    result = result tokenize_paths(pre) open_tag
                    rest = substr(rest, opos + length(open_tag))
                    depth = 1
                }
            } else {
                # Inside a marker: copy verbatim until matching close.
                cpos = index(rest, close_tag)
                if (cpos == 0) {
                    # Unterminated marker; copy verbatim, exit loop.
                    result = result rest
                    rest = ""
                } else {
                    result = result substr(rest, 1, cpos - 1) close_tag
                    rest = substr(rest, cpos + length(close_tag))
                    depth = 0
                }
            }
        }
        print result
    }
    # ── helper: tokenize path-like substrings in plain (non-marker) text ──
    function tokenize_paths(text,    out, rest, before, token, after, in_scope, stripped, i, a) {
        out = ""
        rest = text
        while (match(rest, /[A-Za-z0-9._-]*\/[A-Za-z0-9._\/-]+/)) {
            before = substr(rest, 1, RSTART - 1)
            token  = substr(rest, RSTART, RLENGTH)
            after  = substr(rest, RSTART + RLENGTH)
            # Alpha-guard (#504): legitimate paths always contain at least one
            # ASCII letter. Pure-digit tokens like "2/10" (iteration counters)
            # or "2026/05/29" (date prefixes) are not paths — skip wrapping
            # and log so we can emit a redaction.counter_skipped event.
            if (token !~ /[A-Za-z]/) {
                out = out before token
                print token >> counter_log
                rest = after
                continue
            }
            # Check if token starts with any allowed prefix (with optional leading ./)
            in_scope = 0
            stripped = token
            sub(/^\.\//, "", stripped)
            for (i = 1; i <= n_allow; i++) {
                a = allow[i]
                # Match if stripped starts with allowed prefix, OR if token == allowed exactly
                if (index(stripped, a) == 1 || index(token, a) == 1) {
                    in_scope = 1
                    break
                }
            }
            if (in_scope) {
                out = out before token
            } else {
                out = out before "<out-of-scope-context>" token "</out-of-scope-context>"
            }
            rest = after
        }
        return out rest
    }
    ' "$input" > "$output"

    local size_after; size_after=$(wc -c < "$output")
    local redactions; redactions=$(grep -c '<out-of-scope-context>' "$output" || true)
    local scope_hash; scope_hash="$(shasum -a 256 "$manifest" | cut -d' ' -f1)"

    # Emit a debug-grade event when the alpha-guard skipped one or more
    # candidate tokens (#504). Single event per call regardless of count, to
    # keep volume low; sample tokens included for triage.
    if [[ -s "$counter_skipped_log" ]]; then
        local counter_count counter_sample
        counter_count=$(wc -l < "$counter_skipped_log" | tr -d ' ')
        counter_sample="$(head -3 "$counter_skipped_log" | tr '\n' ',' | sed 's/,$//')"
        emit_event "redaction.counter_skipped" \
            "input=$input" \
            "count=$counter_count" \
            "sample=$counter_sample" \
            "cycle=$cycle_id"
    fi
    rm -f "$counter_skipped_log"

    emit_event "redaction.applied" \
        "input=$input" \
        "output=$output" \
        "size_before=$size_before" \
        "size_after=$size_after" \
        "redactions=$redactions" \
        "scope_hash=$scope_hash" \
        "cycle=$cycle_id"

    return 0
}
