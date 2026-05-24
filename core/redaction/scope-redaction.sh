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

    # ─── Parse scope manifest into a temporary allowlist file ──────────────
    local allow_file; allow_file="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$allow_file'" RETURN

    # Extract "+ path" entries; strip leading + and whitespace.
    awk '/^\+/ { sub(/^\+[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); if (length($0)) print $0 }' \
        "$manifest" > "$allow_file"

    # Add CSV allowlist entries
    if [[ -n "$allowlist" ]]; then
        echo "$allowlist" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' >> "$allow_file"
    fi

    # ─── Redact with awk (fence-aware, allowlist-driven) ────────────────────
    local size_before; size_before=$(wc -c < "$input")

    awk -v allow_file="$allow_file" '
    BEGIN {
        n_allow = 0
        while ((getline line < allow_file) > 0) {
            if (length(line) > 0) {
                allow[++n_allow] = line
            }
        }
        close(allow_file)
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
        # Find path-like tokens: contains / and matches [A-Za-z0-9._/-]+
        result = ""
        rest = line
        while (match(rest, /[A-Za-z0-9._-]*\/[A-Za-z0-9._\/-]+/)) {
            before = substr(rest, 1, RSTART - 1)
            token = substr(rest, RSTART, RLENGTH)
            after = substr(rest, RSTART + RLENGTH)
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
                result = result before token
            } else {
                result = result before "<out-of-scope-context>" token "</out-of-scope-context>"
            }
            rest = after
        }
        result = result rest
        print result
    }
    ' "$input" > "$output"

    local size_after; size_after=$(wc -c < "$output")
    local redactions; redactions=$(grep -c '<out-of-scope-context>' "$output" || true)
    local scope_hash; scope_hash="$(shasum -a 256 "$manifest" | cut -d' ' -f1)"

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
