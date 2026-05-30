#!/usr/bin/env bash
# Integration test (#492): the gh_comment body assembled by stage-io must
# contain ZERO ANSI escape bytes even when colors are forced on. This is the
# color-asymmetry contract documented in ADR-015 §v5 — `_stage_io_to_stdout`
# (the gh_comment body assembler, fd 1) MUST remain plain text by
# construction; only `_stage_io_stdout_begin`/`_stage_io_stdout_end` (fd 2/3)
# apply colors. Regression: a future change that adds color to
# `_stage_io_to_stdout` would silently leak ANSI bytes into the GitHub API
# call. Mocks `gh issue comment` to capture --body and asserts zero ESC bytes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Force colors ON globally so the test fails if ANY color path leaks into the
# gh_comment body. The contract is: even when colors are forced, gh body has
# zero escapes.
export FORCE_COLOR=1
export ZBUILD_STAGE_IO_FORCE_COLOR=1

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "stage-io gh_comment body has zero ANSI escapes (#492)"
setup_test_env "stage-io-gh-ansi-strip"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="gh-ansi-strip"
export ZBUILD_ISSUE="42"
export ZBUILD_OUTPUT_GH_COMMENT=1
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

# Mock gh: capture the --body argument to a file so we can grep it.
GH_BODY_CAPTURE="$TEST_TEMP_DIR/gh-body.txt"
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
# Mock gh: capture --body to a side-channel file.
prev=""
for arg in "\$@"; do
    if [[ "\$prev" == "--body" ]]; then
        printf '%s' "\$arg" > "$GH_BODY_CAPTURE"
        break
    fi
    prev="\$arg"
done
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

# shellcheck source=../../core/output/stage-io.sh
source "$REPO_ROOT/core/output/stage-io.sh"

# Force the stage-io destination to include gh_comment.
template_stage_io_dests()      { printf 'file\nstdout\ngh_comment\n'; }
template_stage_io_tail_lines() { printf ''; }
template_stage_io_redact()     { printf 'false'; }

# Drive a full begin+end pair so the gh_comment destination fires.
fd3="$TEST_TEMP_DIR/banner.fd3"
: > "$fd3"
exec 3>"$fd3"
ZBUILD_STAGE_IO_FD=3 \
    stage_io_begin --stage plan --kind llm --input "PROMPT BODY" >/dev/null
ZBUILD_STAGE_IO_FD=3 \
    stage_io_end --stage plan --kind llm --seq "$_STAGE_IO_LAST_SEQ" \
        --output "RESPONSE BODY" --duration-ms 100 >/dev/null
exec 3>&-

# ── Assertions ───────────────────────────────────────────────────────────────
if [[ -s "$GH_BODY_CAPTURE" ]]; then
    assert_pass "gh issue comment was invoked"
else
    assert_fail "gh issue comment was invoked" "no body captured at $GH_BODY_CAPTURE"
    cleanup_test_env
    print_test_results
    exit 1
fi

# Count ESC (\x1b) bytes in the captured body — MUST be zero.
esc_count="$(LC_ALL=C tr -cd '\033' < "$GH_BODY_CAPTURE" | wc -c | tr -d ' ')"
assert_eq "gh body has zero ANSI escape bytes" "0" "$esc_count"

# Spot-check that the body carries the expected content (proves we actually
# read the comment body, not an empty buffer).
body="$(cat "$GH_BODY_CAPTURE")"
assert_contains "gh body contains prompt"   "$body" "PROMPT BODY"
assert_contains "gh body contains response" "$body" "RESPONSE BODY"

# Bonus: the fd-3 banner (operator-visible) should HAVE ANSI escapes because
# we forced colors on. That confirms color-asymmetry: banners colored,
# gh body plain.
banner="$(cat "$fd3")"
if printf '%s' "$banner" | grep -q $'\x1b\\['; then
    assert_pass "fd-3 banner DOES carry ANSI (color asymmetry confirmed)"
else
    assert_fail "fd-3 banner DOES carry ANSI" "no ESC in banner — colors may be globally disabled"
fi

cleanup_test_env
print_test_results
exit "$FAIL"
