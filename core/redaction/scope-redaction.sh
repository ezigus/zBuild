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
# Behavior (ADR-004, ADR-043; #2379):
#   1. Every private path (scripts/lib/private-paths.sh) in the text, code
#      fences included, is replaced with <private>. Nothing else is changed:
#      every stage sees every other file.
#   2. Emit redaction.applied with the count.
#   3. Idempotent.
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_REDACTION_LOADED:-}" ]] && return 0
_ZBUILD_REDACTION_LOADED=1

_ZBUILD_REDACTION_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)"
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

    # #2379 (ADR-043): every stage sees every file except private ones. The
    # scope no longer decides what a stage is shown — wrapping paths outside it
    # only labelled them, and wrapped the files the engine tells a stage to
    # write. What is taken out is a private path (scripts/lib/private-paths.sh:
    # the engine's list plus the template's and the repository's), everywhere
    # in the text, code fences included. <scope_manifest> and <allowlist> are
    # accepted and unused.
    : "$manifest" "$allowlist"
    if ! declare -F private_paths_list >/dev/null 2>&1; then
        # shellcheck source=../../scripts/lib/private-paths.sh
        source "$_ZBUILD_ROOT/scripts/lib/private-paths.sh" || return 2
    fi
    local repo="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}" patterns
    patterns="$(private_paths_list "$repo")"

    local size_before; size_before=$(wc -c < "$input")
    ZBUILD_REDACTION_PRIVATE="$patterns" ZBUILD_REDACTION_REPO="$repo" awk '
    function glob_re(g,    r, i, c) {
        r = ""
        for (i = 1; i <= length(g); i++) {
            c = substr(g, i, 1)
            if (c == "*") r = r "[^/]*"
            else if (c == "?") r = r "[^/]"
            else if (c ~ /[.+^$(){}|\[\]\\]/) r = r "\\" c
            else r = r c
        }
        return r
    }
    BEGIN {
        repo = ENVIRON["ZBUILD_REDACTION_REPO"]
        n = split(ENVIRON["ZBUILD_REDACTION_PRIVATE"], pats, "\n")
        for (i = 1; i <= n; i++) {
            p = pats[i]
            if (p == "") continue
            if (p ~ /\/$/)     { kind[++k] = "dir";  re[k] = "^" glob_re(p) }
            else if (p ~ /\//) { kind[++k] = "path"; re[k] = "^" glob_re(p) "$" }
            else               { kind[++k] = "name"; re[k] = "^" glob_re(p) "$" }
        }
    }
    function is_private(tok,    rel, base, j) {
        rel = tok
        if (repo != "" && index(rel, repo "/") == 1) rel = substr(rel, length(repo) + 2)
        sub(/^\.\//, "", rel)
        base = rel; sub(/.*\//, "", base)
        for (j = 1; j <= k; j++) {
            if (kind[j] == "name" && base ~ re[j]) return 1
            if (kind[j] != "name" && rel ~ re[j]) return 1
        }
        return 0
    }
    {
        line = $0; out = ""
        while (match(line, /[A-Za-z0-9._\/~-]+/)) {
            tok = substr(line, RSTART, RLENGTH)
            out = out substr(line, 1, RSTART - 1)
            if (is_private(tok)) { out = out "<private>"; redacted++ }
            else out = out tok
            line = substr(line, RSTART + RLENGTH)
        }
        print out line
    }
    ' "$input" > "$output" || return 2

    local size_after; size_after=$(wc -c < "$output")
    local redactions; redactions=$(grep -o '<private>' "$output" | grep -c . || true)

    emit_event "redaction.applied" \
        "input=$input" \
        "output=$output" \
        "size_before=$size_before" \
        "size_after=$size_after" \
        "redactions=$redactions" \
        "cycle=$cycle_id"

    return 0
}
