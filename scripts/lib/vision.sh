#!/usr/bin/env bash
# scripts/lib/vision.sh — vision-document loader and validator (ADR-049).
#
# Source-only library (guard-loaded, no side-effects on source).
# Public API:
#   load_vision_doc [repo_root]          — resolves path, prints it, rc=0; rc=1 if absent
#   validate_vision_doc <path>           — validates structure + word cap; rc=0 if valid

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

# validate_vision_doc <path>
# Validates the vision document at <path>:
#   - Must contain a "## Intent" heading
#   - Must contain a "## Principles" heading
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

    # Check for required headings
    if ! grep -q '^## Intent' "$path" 2>/dev/null; then
        printf 'vision-doc: missing required section "## Intent" in %s\n' "$path" >&2
        errors=$((errors + 1))
    fi

    if ! grep -q '^## Principles' "$path" 2>/dev/null; then
        printf 'vision-doc: missing required section "## Principles" in %s\n' "$path" >&2
        errors=$((errors + 1))
    fi

    # Word-cap check: count words in body text only (skip YAML frontmatter block
    # and heading lines themselves; count prose + list content).
    local in_frontmatter=0
    local frontmatter_done=0
    local fence_count=0
    local word_count=0

    while IFS= read -r line; do
        # Track YAML frontmatter (--- ... ---)
        if [[ $frontmatter_done -eq 0 && $fence_count -eq 0 && "$line" == "---" ]]; then
            in_frontmatter=$((in_frontmatter + 1))
            if [[ $in_frontmatter -eq 2 ]]; then
                frontmatter_done=1
            fi
            continue
        fi
        [[ $in_frontmatter -eq 1 ]] && continue  # inside frontmatter

        # Skip blank lines and heading lines
        [[ -z "${line// /}" ]] && continue
        [[ "$line" =~ ^# ]] && continue

        # Count words in this line
        local lw
        lw=$(printf '%s\n' "$line" | wc -w | tr -d '[:space:]')
        word_count=$((word_count + lw))
    done < "$path"

    if [[ $word_count -gt 300 ]]; then
        printf 'vision-doc: body word count %d exceeds 300-word cap in %s\n' "$word_count" "$path" >&2
        errors=$((errors + 1))
    fi

    return $errors
}
