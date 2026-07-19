#!/usr/bin/env bash
# scripts/lib/vision.sh — vision-document loader and validator (ADR-049).
#
# Source-only library (guard-loaded, no side-effects on source).
# Public API:
#   load_vision_doc [repo_root]          — resolves path, prints it, rc=0; rc=1 if absent
#   validate_vision_doc <path>           — validates structure + word cap; rc=0 if valid
#   vision_gate_mode                     — admission-gate mode: env > config > enforce

[[ -n "${_VISION_LOADED:-}" ]] && return 0
_VISION_LOADED=1

# Search order (ADR-049): .zbuild/vision.md → docs/VISION.md → VISION.md
_VISION_SEARCH_PATHS=(".zbuild/vision.md" "docs/VISION.md" "VISION.md")

# load_vision_doc [repo_root]
# Walks the three-path search order from repo_root (default: current directory).
# Prints the resolved absolute path on stdout and returns 0.
# Returns 1 (prints nothing) when no vision document is found.
load_vision_doc() {
    local root="${1:-$(pwd)}"
    local candidate
    for rel in "${_VISION_SEARCH_PATHS[@]}"; do
        candidate="$root/$rel"
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# vision_gate_mode — resolve the admission-gate mode with clear precedence:
#   1. ZBUILD_VISION_GATE env var (if set)  — per-invocation override
#   2. .zbuild/config.yaml  vision.gate     — persistent per-repo setting
#   3. built-in default: enforce            — fail-closed
# `off` (env or config) means "do not require a vision document — just run".
# An unrecognized value resolves to enforce (fail-closed on misconfiguration).
vision_gate_mode() {
    local mode="${ZBUILD_VISION_GATE:-}"
    if [[ -z "$mode" ]] && declare -F zbuild_config_get >/dev/null 2>&1; then
        mode="$(zbuild_config_get vision gate 2>/dev/null || true)"
    fi
    case "${mode:-enforce}" in
        off|warn|enforce) printf '%s\n' "${mode:-enforce}" ;;
        *) printf 'enforce\n' ;;
    esac
}

# validate_vision_doc <path>
# Validates the vision document at <path>:
#   - Body text (non-heading, non-frontmatter lines) must not exceed 300 words
# Prints human-readable diagnostics on stderr for each violation.
# Returns 0 if the document is valid, non-zero if any check fails.
validate_vision_doc() {
    local path="${1:-}"
    if [[ -z "$path" || ! -f "$path" ]]; then
        printf 'validate_vision_doc: file not found: %s\n' "$path" >&2
        return 1
    fi

    local errors=0

    # Word-cap check: count words in body text only. YAML frontmatter is a
    # single optional block delimited by '---' fences, recognized ONLY when the
    # very first line of the file is '---' — a bare '---' anywhere else is a
    # horizontal rule, not frontmatter, and must not suppress body counting.
    local in_frontmatter=0
    local line_num=0
    local word_count=0

    while IFS= read -r line; do
        line_num=$((line_num + 1))

        # Open frontmatter only on a first-line fence; the next fence closes it.
        if [[ $line_num -eq 1 && "$line" == "---" ]]; then
            in_frontmatter=1
            continue
        fi
        if [[ $in_frontmatter -eq 1 ]]; then
            [[ "$line" == "---" ]] && in_frontmatter=0
            continue
        fi

        # Skip blank lines and heading lines
        [[ -z "${line// /}" ]] && continue
        [[ "$line" =~ ^# ]] && continue

        # Count words without a subshell (avoids a per-line fork and any printf
        # format-specifier misinterpretation of file content).
        local -a words
        read -ra words <<< "$line"
        word_count=$((word_count + ${#words[@]}))
    done < "$path"

    # An opening fence with no matching close is malformed frontmatter, not a
    # horizontal rule — every remaining line was silently swallowed by the
    # in_frontmatter branch above (word_count undercounts to 0), which would
    # otherwise let a truncated document pass validation with no diagnostic.
    if [[ $in_frontmatter -eq 1 ]]; then
        printf 'vision-doc: unterminated YAML frontmatter fence (opening --- has no matching close) in %s\n' \
            "$path" >&2
        errors=$((errors + 1))
    fi

    if [[ $word_count -gt 300 ]]; then
        local _overage=$(( word_count - 300 ))
        printf 'vision-doc: body word count %d exceeds 300-word cap by %d words in %s\n' \
            "$word_count" "$_overage" "$path" >&2
        printf 'Run: zbuild vision init --condense to reduce it\n' >&2
        errors=$((errors + 1))
    fi

    # Stable contract (ADR-049): any violation returns rc=1 (stderr already
    # enumerated each one). A raw count could exceed the 0-255 return range and
    # would break callers that test for rc=1 specifically.
    [[ $errors -gt 0 ]] && return 1
    return 0
}
