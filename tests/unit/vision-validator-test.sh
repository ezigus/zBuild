#!/usr/bin/env bash
# tests/unit/vision-validator-test.sh — vision-document validator (ADR-049, issue #1359).
#
# Covers:
#   SPEC-1  valid doc with all required sections passes validate_vision_doc (rc=0)
#   SPEC-2  doc missing ## Intent fails (rc non-zero + diagnostic)
#   SPEC-3  doc missing ## Principles fails (rc non-zero + diagnostic)
#   SPEC-4  doc exceeding 300 words fails (rc non-zero + diagnostic)
#   SPEC-5  load_vision_doc walks the three-path search order
#   SPEC-6  load_vision_doc returns rc=1 when no vision doc is present
#   SPEC-7  validate_vision_doc accepts optional YAML frontmatter
#   SPEC-8  validate_vision_doc rejects a non-existent file path
#   SPEC-9  the real docs/VISION.md passes validate_vision_doc (live-repo guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/vision.sh
source "$REPO_ROOT/scripts/lib/vision.sh"

print_test_header "scripts/lib/vision.sh — vision-document validator (ADR-049, #1359)"
setup_test_env "vision-validator"

# ── Fixture helpers ───────────────────────────────────────────────────────────

make_valid_doc() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'EOF'
## Intent

This project gives teams a reliable way to ship software consistently. You
encode your process once as a template, then run every repository and every
change through that same template the same way each time.

## Principles

- Consistency through repetition — the same template, run the same way.
- Flexible by composition — behavior is plugin-delivered and template-composed.
- Safety is non-negotiable — all model-bound text passes through one chokepoint.
EOF
}

make_over_limit_doc() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    # Write a doc with required headings but far more than 300 words of body text.
    {
        printf '## Intent\n\n'
        # Generate 310 words of body text using a repetitive phrase
        python3 -c "print(' '.join(['word'] * 310))" 2>/dev/null \
            || printf '%0.s word word word word word word word word word word\n' {1..31}
        printf '\n\n## Principles\n\n- principle one.\n'
    } > "$path"
}

# ── SPEC-1: valid doc passes (rc=0) ─────────────────────────────────────────
VALID_DOC="$TEST_TEMP_DIR/valid/vision.md"
make_valid_doc "$VALID_DOC"
rc=0
out="$(validate_vision_doc "$VALID_DOC" 2>&1)" || rc=$?
assert_eq "[SPEC-1] valid doc with all required sections passes (rc=0)" "0" "$rc"

# ── SPEC-2: missing ## Intent fails ─────────────────────────────────────────
NO_INTENT="$TEST_TEMP_DIR/no-intent/vision.md"
mkdir -p "$(dirname "$NO_INTENT")"
cat > "$NO_INTENT" <<'EOF'
## Principles

- consistency through repetition — same template, same way, every time.
- flexible by composition — behavior is plugin-delivered and template-composed.
EOF
rc=0
out="$(validate_vision_doc "$NO_INTENT" 2>&1)" || rc=$?
assert_eq "[SPEC-2] doc missing ## Intent fails (rc non-zero)" "1" "$rc"
assert_contains "[SPEC-2] diagnostic names the missing section" "$out" "Intent"

# ── SPEC-3: missing ## Principles fails ─────────────────────────────────────
NO_PRINCIPLES="$TEST_TEMP_DIR/no-principles/vision.md"
mkdir -p "$(dirname "$NO_PRINCIPLES")"
cat > "$NO_PRINCIPLES" <<'EOF'
## Intent

This project gives teams a reliable way to ship software consistently. You
encode your process once and run every change through the same template.
EOF
rc=0
out="$(validate_vision_doc "$NO_PRINCIPLES" 2>&1)" || rc=$?
assert_eq "[SPEC-3] doc missing ## Principles fails (rc non-zero)" "1" "$rc"
assert_contains "[SPEC-3] diagnostic names the missing section" "$out" "Principles"

# ── SPEC-4: doc exceeding 300 words fails ───────────────────────────────────
OVER_LIMIT="$TEST_TEMP_DIR/over-limit/vision.md"
make_over_limit_doc "$OVER_LIMIT"
rc=0
out="$(validate_vision_doc "$OVER_LIMIT" 2>&1)" || rc=$?
assert_eq "[SPEC-4] doc exceeding 300 words fails (rc non-zero)" "1" "$rc"
assert_contains "[SPEC-4] diagnostic mentions word count or cap" "$out" "300"

# ── SPEC-4 regression: a mid-body '---' horizontal rule (no frontmatter) must
#    NOT be mistaken for a frontmatter fence and suppress body word counting.
#    (The prior fence-counter treated any '---' as frontmatter and dropped every
#    following line — a >300-word doc could pass by hiding words after a rule.)
HRULE_DOC="$TEST_TEMP_DIR/hrule/vision.md"
mkdir -p "$(dirname "$HRULE_DOC")"
{
    printf '## Intent\n\nShort intro.\n\n---\n\n## Principles\n\n'
    python3 -c "print(' '.join(['word'] * 310))" 2>/dev/null \
        || printf 'word word word word word word word word word word\n%.0s' {1..31}
} > "$HRULE_DOC"
rc=0
out="$(validate_vision_doc "$HRULE_DOC" 2>&1)" || rc=$?
assert_eq "[SPEC-4] mid-body '---' rule does not suppress word count (rc=1)" "1" "$rc"

# ── SPEC-5: load_vision_doc walks three-path search order ───────────────────
# Test 5a: .zbuild/vision.md wins when present (highest precedence)
SEARCH_REPO="$TEST_TEMP_DIR/search-repo"
mkdir -p "$SEARCH_REPO/.zbuild" "$SEARCH_REPO/docs"
printf '## Intent\nhigh-precedence\n## Principles\n- p1\n' > "$SEARCH_REPO/.zbuild/vision.md"
printf '## Intent\nlow-precedence\n## Principles\n- p1\n'  > "$SEARCH_REPO/docs/VISION.md"
rc=0
resolved="$(load_vision_doc "$SEARCH_REPO" 2>&1)" || rc=$?
assert_eq "[SPEC-5] load_vision_doc rc=0 when .zbuild/vision.md present" "0" "$rc"
assert_contains "[SPEC-5] .zbuild/vision.md wins over docs/VISION.md" "$resolved" ".zbuild/vision.md"

# Test 5b: falls through to docs/VISION.md when .zbuild/vision.md absent
SEARCH_REPO2="$TEST_TEMP_DIR/search-repo2"
mkdir -p "$SEARCH_REPO2/docs"
printf '## Intent\ndocs-vision\n## Principles\n- p1\n' > "$SEARCH_REPO2/docs/VISION.md"
rc=0
resolved2="$(load_vision_doc "$SEARCH_REPO2" 2>&1)" || rc=$?
assert_eq "[SPEC-5] falls through to docs/VISION.md (rc=0)" "0" "$rc"
assert_contains "[SPEC-5] docs/VISION.md resolved when .zbuild absent" "$resolved2" "docs/VISION.md"

# Test 5c: falls through to VISION.md at root when both above are absent
SEARCH_REPO3="$TEST_TEMP_DIR/search-repo3"
mkdir -p "$SEARCH_REPO3"
printf '## Intent\nroot-vision\n## Principles\n- p1\n' > "$SEARCH_REPO3/VISION.md"
rc=0
resolved3="$(load_vision_doc "$SEARCH_REPO3" 2>&1)" || rc=$?
assert_eq "[SPEC-5] falls through to VISION.md at root (rc=0)" "0" "$rc"
assert_contains "[SPEC-5] VISION.md at root resolved when others absent" "$resolved3" "VISION.md"

# ── SPEC-6: load_vision_doc returns rc=1 when no vision doc present ──────────
EMPTY_REPO="$TEST_TEMP_DIR/empty-repo"
mkdir -p "$EMPTY_REPO"
rc=0
load_vision_doc "$EMPTY_REPO" >/dev/null 2>&1 || rc=$?
assert_eq "[SPEC-6] load_vision_doc rc=1 when no vision doc present" "1" "$rc"

# ── SPEC-7: validate_vision_doc accepts optional YAML frontmatter ─────────────
FRONTMATTER_DOC="$TEST_TEMP_DIR/frontmatter/vision.md"
mkdir -p "$(dirname "$FRONTMATTER_DOC")"
cat > "$FRONTMATTER_DOC" <<'EOF'
---
version: '1.0'
updated: '2026-07-12'
---

## Intent

This project gives teams a reliable way to ship software consistently using
templates that encode the delivery process once and run it the same way each time.

## Principles

- Consistency through repetition — same template, same way, every time.
- Safety is non-negotiable — all model-bound text passes through one chokepoint.
EOF
rc=0
out="$(validate_vision_doc "$FRONTMATTER_DOC" 2>&1)" || rc=$?
assert_eq "[SPEC-7] doc with YAML frontmatter passes validation (rc=0)" "0" "$rc"

# ── SPEC-8: validate_vision_doc rejects non-existent file path ───────────────
rc=0
out="$(validate_vision_doc "$TEST_TEMP_DIR/nonexistent/vision.md" 2>&1)" || rc=$?
assert_eq "[SPEC-8] validate_vision_doc rc non-zero for missing file" "1" "$rc"
assert_contains "[SPEC-8] diagnostic names the bad path" "$out" "not found"

# ── SPEC-9: real docs/VISION.md passes validate_vision_doc (live-repo guard) ──
rc=0
out="$(validate_vision_doc "$REPO_ROOT/docs/VISION.md" 2>&1)" || rc=$?
assert_eq "[SPEC-9] real docs/VISION.md passes validate_vision_doc (rc=0)" "0" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
