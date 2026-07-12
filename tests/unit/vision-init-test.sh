#!/usr/bin/env bash
# tests/unit/vision-init-test.sh — vision-init.sh authoring helpers (ADR-049 Phase 1.1, #1360).
#
# Covers:
#   SPEC-1  vision_init_blank produces a file containing '## Intent'
#   SPEC-2  vision_init_blank output contains '## Principles'
#   SPEC-3  vision_init_blank output passes validate_vision_doc (rc=0)
#   SPEC-4  vision_condense with mocked LLM produces file with body word count ≤ 300
#   SPEC-5  vision_condense output passes validate_vision_doc (rc=0)
#   SPEC-6  vision_init_draft with mocked LLM produces a file that passes validate_vision_doc
#   SPEC-7  vision_init_blank creates parent directories if needed
#   SPEC-8  vision_condense fails (rc non-zero) when input file does not exist
#   SPEC-9  vision_condense rejects LLM output that fails validation (bad output)
#   SPEC-10 vision_init_blank is usable without route_to_model available
#   SPEC-11 vision_init_draft calls the claude stub (LLM call happens)
#   SPEC-12 vision_condense calls the claude stub (LLM call happens)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/vision.sh
source "$REPO_ROOT/scripts/lib/vision.sh"

print_test_header "scripts/lib/vision-init.sh — vision authoring helpers (ADR-049 #1360)"
setup_test_env "vision-init"

# ── Stub claude binary ────────────────────────────────────────────────────────
# The stub follows the argv-recording pattern from router-claude-flags-test.sh:
# it writes full argv to last_args_nl for grepping, and outputs a conforming
# vision document on stdout (what route_to_model will use as the LLM response).

CONFORMING_VISION="$(cat <<'CONFORMING'
## Intent

This project gives teams a reliable way to ship software consistently.
Templates encode the delivery process once; every run reproduces it exactly.

## Principles

- Consistency through repetition — same template, same way every time.
- Flexible by composition — behavior is plugin-delivered and template-composed.
- Safety is non-negotiable — all model-bound text passes through one chokepoint.
CONFORMING
)"

STUB_BIN="$TEST_TEMP_DIR/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/claude" <<STUB
#!/usr/bin/env bash
# argv-recording stub
printf '%s\n' "\$@" > "$TEST_TEMP_DIR/last_args_nl"
printf '%s\n' "$CONFORMING_VISION"
exit 0
STUB
chmod +x "$STUB_BIN/claude"
export PATH="$STUB_BIN:$PATH"

# Set up scope-override so route_to_model's --skip-precondition is accepted
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf 'bootstrap' > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# Point event bus at temp dir so route_to_model side-effects stay isolated
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"
mkdir -p "$TEST_TEMP_DIR/events"

# shellcheck source=../../scripts/lib/vision-init.sh
source "$REPO_ROOT/scripts/lib/vision-init.sh"

# ── SPEC-10: vision_init_blank is usable without route_to_model ──────────────
# (vision_init_blank sources only vision.sh, not the router stack)
BLANK_OUT="$TEST_TEMP_DIR/blank-test/vision.md"
vision_init_blank "$BLANK_OUT"
assert_file_exists "[SPEC-10] vision_init_blank: output file created without LLM" "$BLANK_OUT"

# ── SPEC-1: blank output contains ## Intent ───────────────────────────────────
blank_content="$(<"$BLANK_OUT")"
assert_contains "[SPEC-1] vision_init_blank: output contains '## Intent'" \
    "$blank_content" "## Intent"

# ── SPEC-2: blank output contains ## Principles ───────────────────────────────
assert_contains "[SPEC-2] vision_init_blank: output contains '## Principles'" \
    "$blank_content" "## Principles"

# ── SPEC-3: blank output passes validate_vision_doc ───────────────────────────
rc=0
validate_vision_doc "$BLANK_OUT" >/dev/null 2>&1 || rc=$?
assert_eq "[SPEC-3] vision_init_blank: output passes validate_vision_doc (rc=0)" "0" "$rc"

# ── SPEC-7: vision_init_blank creates parent dirs if needed ───────────────────
NESTED_OUT="$TEST_TEMP_DIR/deeply/nested/path/vision.md"
vision_init_blank "$NESTED_OUT"
assert_file_exists "[SPEC-7] vision_init_blank: creates parent directories" "$NESTED_OUT"

# ── SPEC-6: vision_init_draft produces a file that passes validate_vision_doc ──
DRAFT_REPO="$TEST_TEMP_DIR/draft-fixture-repo"
mkdir -p "$DRAFT_REPO/docs/adr"
printf '# README\nA minimal fixture repo for vision-init tests.\n' > "$DRAFT_REPO/README.md"
printf 'module example.com/fixture\n\ngo 1.21\n' > "$DRAFT_REPO/go.mod"
printf '# ADR-001 Plugin contract\n' > "$DRAFT_REPO/docs/adr/ADR-001.md"

DRAFT_OUT="$TEST_TEMP_DIR/draft-out/vision.md"
vision_init_draft "$DRAFT_REPO" "$DRAFT_OUT"
assert_file_exists "[SPEC-6] vision_init_draft: output file created" "$DRAFT_OUT"
rc=0
validate_vision_doc "$DRAFT_OUT" >/dev/null 2>&1 || rc=$?
assert_eq "[SPEC-6] vision_init_draft: output passes validate_vision_doc (rc=0)" "0" "$rc"

# ── SPEC-11: vision_init_draft called the claude stub ────────────────────────
if [[ -f "$TEST_TEMP_DIR/last_args_nl" ]]; then
    assert_pass "[SPEC-11] vision_init_draft: claude stub was invoked (last_args_nl exists)"
else
    assert_fail "[SPEC-11] vision_init_draft: claude stub was NOT invoked" \
        "last_args_nl not written"
fi

# ── SPEC-4 / SPEC-5: vision_condense produces valid output ≤ 300 words ────────
# Build an over-length source doc to condense
OVER_SRC="$TEST_TEMP_DIR/over-src/vision.md"
mkdir -p "$(dirname "$OVER_SRC")"
{
    printf '## Intent\n\n'
    python3 -c "print(' '.join(['word'] * 310))" 2>/dev/null \
        || printf 'word word word word word word word word word word\n%.0s' {1..31}
    printf '\n\n## Principles\n\n- principle one.\n'
} > "$OVER_SRC"

# Reset last_args_nl so we can detect if condense calls the stub
rm -f "$TEST_TEMP_DIR/last_args_nl"

CONDENSE_OUT="$TEST_TEMP_DIR/condensed/vision.md"
rc=0
vision_condense "$OVER_SRC" "$CONDENSE_OUT" || rc=$?
assert_eq "[SPEC-4] vision_condense: exits rc=0 on success" "0" "$rc"
assert_file_exists "[SPEC-4] vision_condense: output file created" "$CONDENSE_OUT"

# Count body words in the condensed output (same logic as validate_vision_doc)
_condense_word_count=0
_in_fm=0; _lnum=0
while IFS= read -r _line; do
    _lnum=$((_lnum + 1))
    if [[ $_lnum -eq 1 && "$_line" == "---" ]]; then _in_fm=1; continue; fi
    if [[ $_in_fm -eq 1 ]]; then [[ "$_line" == "---" ]] && _in_fm=0; continue; fi
    [[ -z "${_line// /}" ]] && continue
    [[ "$_line" =~ ^# ]] && continue
    read -ra _ws <<< "$_line"
    _condense_word_count=$((_condense_word_count + ${#_ws[@]}))
done < "$CONDENSE_OUT"

if [[ $_condense_word_count -le 300 ]]; then
    assert_pass "[SPEC-4] vision_condense: body word count ≤ 300 (got $_condense_word_count)"
else
    assert_fail "[SPEC-4] vision_condense: body word count exceeds 300" \
        "count=$_condense_word_count"
fi

rc=0
validate_vision_doc "$CONDENSE_OUT" >/dev/null 2>&1 || rc=$?
assert_eq "[SPEC-5] vision_condense: output passes validate_vision_doc (rc=0)" "0" "$rc"

# ── SPEC-12: vision_condense called the claude stub ──────────────────────────
if [[ -f "$TEST_TEMP_DIR/last_args_nl" ]]; then
    assert_pass "[SPEC-12] vision_condense: claude stub was invoked"
else
    assert_fail "[SPEC-12] vision_condense: claude stub was NOT invoked" \
        "last_args_nl not written"
fi

# ── SPEC-8: vision_condense fails when input file does not exist ──────────────
rc=0
vision_condense "$TEST_TEMP_DIR/nonexistent/vision.md" "$TEST_TEMP_DIR/should-not-exist.md" 2>/dev/null || rc=$?
if [[ $rc -ne 0 ]]; then
    assert_pass "[SPEC-8] vision_condense: rc non-zero when input missing (got rc=$rc)"
else
    assert_fail "[SPEC-8] vision_condense: expected rc non-zero for missing input" "got rc=0"
fi

# ── SPEC-9: vision_condense rejects invalid LLM output ────────────────────────
# Install a stub that returns output missing ## Intent (fails validation).
BAD_STUB_BIN="$TEST_TEMP_DIR/bad-stub-bin"
mkdir -p "$BAD_STUB_BIN"
cat > "$BAD_STUB_BIN/claude" <<'BADSTUB'
#!/usr/bin/env bash
# Returns a document missing ## Intent — should fail validate_vision_doc
printf '## Principles\n\n- only a principles section.\n'
exit 0
BADSTUB
chmod +x "$BAD_STUB_BIN/claude"

# Temporarily prepend bad stub to PATH
OLD_PATH="$PATH"
export PATH="$BAD_STUB_BIN:$PATH"

BAD_SRC="$TEST_TEMP_DIR/bad-condense-src/vision.md"
mkdir -p "$(dirname "$BAD_SRC")"
{
    printf '## Intent\n\n'
    python3 -c "print(' '.join(['word'] * 310))" 2>/dev/null \
        || printf 'word word word word word word word word word word\n%.0s' {1..31}
    printf '\n\n## Principles\n\n- principle one.\n'
} > "$BAD_SRC"

rc=0
vision_condense "$BAD_SRC" "$TEST_TEMP_DIR/bad-condense-out/vision.md" 2>/dev/null || rc=$?
if [[ $rc -ne 0 ]]; then
    assert_pass "[SPEC-9] vision_condense: rejects LLM output failing validation (rc=$rc)"
else
    assert_fail "[SPEC-9] vision_condense: expected rc non-zero for invalid LLM output" "got rc=0"
fi

# Restore PATH
export PATH="$OLD_PATH"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
