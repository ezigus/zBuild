#!/usr/bin/env bash
# Tests: render_review_md — built-in review renderer (#470)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/golden.sh
source "$REPO_ROOT/scripts/lib/golden.sh"

print_test_header "render_review_md (#470)"
setup_test_env "render-review"

# shellcheck source=../../scripts/lib/artifact-render.sh
source "$REPO_ROOT/scripts/lib/artifact-render.sh"

# ─── V1: full review → golden ────────────────────────────────────────────────
input="$(cat "$REPO_ROOT/tests/fixtures/render/review-block.json")"
out="$(render_review_md "$input")"
set +e
assert_golden "render-review.md" "$out"
gold_rc=$?
set -e
if [[ $gold_rc -eq 0 ]]; then
    assert_pass "V1 full review matches render-review.md.golden"
else
    assert_fail "V1 full review matches render-review.md.golden" "rc=$gold_rc"
fi

# ─── V2: empty input → placeholder ───────────────────────────────────────────
out="$(render_review_md "")"
assert_eq "V2 empty review placeholder" "_empty review_" "$out"

# ─── V3: invalid JSON → fenced raw passthrough ───────────────────────────────
out="$(render_review_md '{not valid')"
assert_contains "V3 invalid JSON body preserved" "$out" "{not valid"

# ─── V4: minimal verdict-only ────────────────────────────────────────────────
out="$(render_review_md '{"verdict":"approve"}')"
assert_contains "V4 minimal heading" "$out" "# Review"
assert_contains "V4 minimal verdict" "$out" "**Verdict:** approve"
# No Issues / Summary sections.
if grep -qE '^## Issues' <<< "$out"; then
    assert_fail "V4 no Issues section when missing" "issues heading present"
else
    assert_pass "V4 no Issues section when missing"
fi
if grep -qE '^## Summary' <<< "$out"; then
    assert_fail "V4 no Summary section when missing" "summary heading present"
else
    assert_pass "V4 no Summary section when missing"
fi

# ─── V5: issues list rendered as bullets, backticks escaped ─────────────────
out="$(render_review_md '{"verdict":"block","issues":["foo `bar`","baz"]}')"
assert_contains "V5 issues heading" "$out" "## Issues"
assert_contains "V5 first issue with escaped backtick" "$out" '- foo \`bar\`'
assert_contains "V5 second issue" "$out" "- baz"

# ─── V6: empty issues array → no Issues section ─────────────────────────────
out="$(render_review_md '{"verdict":"approve","issues":[]}')"
if grep -qE '^## Issues' <<< "$out"; then
    assert_fail "V6 empty issues → no section" "issues heading present"
else
    assert_pass "V6 empty issues → no section"
fi

# ─── V7: drive the renderer without $() capture for accurate coverage ──────
_v7_tmp="$TEST_TEMP_DIR/v7.out"
render_review_md "$input" > "$_v7_tmp"
assert_contains "V7 in-shell review render" "$(cat "$_v7_tmp")" "# Review"
render_review_md "" > "$_v7_tmp"
assert_contains "V7 empty placeholder" "$(cat "$_v7_tmp")" "_empty review_"
render_review_md '{"verdict":"approve","confidence":0.5}' > "$_v7_tmp"
assert_contains "V7 minimal verdict" "$(cat "$_v7_tmp")" "**Verdict:** approve"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
