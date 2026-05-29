#!/usr/bin/env bash
# Tests: render_plan_md — built-in plan renderer (#470)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/golden.sh
source "$REPO_ROOT/scripts/lib/golden.sh"

print_test_header "render_plan_md (#470)"
setup_test_env "render-plan"

# shellcheck source=../../scripts/lib/artifact-render.sh
source "$REPO_ROOT/scripts/lib/artifact-render.sh"

# ─── P1: full plan → golden match ────────────────────────────────────────────
input="$(cat "$REPO_ROOT/tests/fixtures/render/plan-full.json")"
out="$(render_plan_md "$input")"
set +e
assert_golden "render-plan.md" "$out"
gold_rc=$?
set -e
if [[ $gold_rc -eq 0 ]]; then
    assert_pass "P1 full plan matches render-plan.md.golden"
else
    assert_fail "P1 full plan matches render-plan.md.golden" "assert_golden returned $gold_rc"
fi

# ─── P2: empty input → placeholder ───────────────────────────────────────────
out="$(render_plan_md "")"
assert_eq "P2 empty plan placeholder" "_empty plan_" "$out"

# ─── P3: missing title → "(untitled)" placeholder ────────────────────────────
out="$(render_plan_md '{"goal":"x"}')"
assert_contains "P3 missing title shows (untitled)" "$out" "# Plan: (untitled)"
assert_contains "P3 missing title still shows goal" "$out" "**Goal:** x"

# ─── P4: invalid JSON → fenced raw passthrough ───────────────────────────────
out="$(render_plan_md '{"oops": invalid')"
assert_contains "P4 invalid JSON renders inside fence" "$out" '{"oops": invalid'
assert_contains_regex "P4 invalid JSON opens a fence" "$out" '^\`\`\`'

# ─── P5: markdown injection in title escaped ─────────────────────────────────
inj='{"title":"Evil `backtick` and # heading\nnewline","goal":"g"}'
out="$(render_plan_md "$inj")"
# Backticks in title must be escaped so user can't open a fence.
assert_contains "P5 title backticks escaped" "$out" '\`backtick\`'
# Newlines collapsed to spaces (single-line heading invariant).
if printf '%s' "$out" | head -1 | grep -qF "newline"; then
    assert_pass "P5 newline collapsed onto heading line"
else
    assert_fail "P5 newline collapsed onto heading line" "got: $(printf '%s' "$out" | head -1)"
fi

# ─── P6: steps with files render as backticked, comma-joined list ────────────
inp='{"title":"t","steps":[{"description":"do x","files":["a.sh","b/c.sh"],"estimated_lines":42}]}'
out="$(render_plan_md "$inp")"
assert_contains "P6 step number rendered" "$out" "1. do x"
assert_contains "P6 files line with backticks" "$out" '- Files: `a.sh`, `b/c.sh`'
assert_contains "P6 estimated lines rendered" "$out" "Estimated lines: 42"

# ─── P7: notes rendered under ## Notes ───────────────────────────────────────
inp='{"title":"t","notes":"keep it tidy"}'
out="$(render_plan_md "$inp")"
assert_contains "P7 notes section" "$out" "## Notes"
assert_contains "P7 notes content" "$out" "keep it tidy"

# ─── P8: only-known-fields render — no DoD or extra keys ────────────────────
# Plan schema currently has title/goal/steps/notes only. Verify we don't
# silently invent sections for unknown keys.
inp='{"title":"t","dod":"completion criteria here","foo":"bar"}'
out="$(render_plan_md "$inp")"
# No DoD section.
if printf '%s' "$out" | grep -qE '^## DoD'; then
    assert_fail "P8 no DoD section invented" "got DoD heading"
else
    assert_pass "P8 no DoD section invented"
fi

# ─── P9: drive the renderer without $() capture so xtrace coverage counts ────
# `out=$(render_plan_md ...)` runs the renderer inside a subshell, which under
# coverage instrumentation prefixes trace lines with extra Ts (the parser only
# counts top-level TRACE:). Calling the function in the current shell, redirected
# to a file, makes the same line executions show up as plain TRACE: entries and
# gives an accurate coverage signal for this file.
_p9_tmp="$TEST_TEMP_DIR/p9.out"
render_plan_md "$(cat "$REPO_ROOT/tests/fixtures/render/plan-full.json")" > "$_p9_tmp"
assert_contains "P9 in-shell render produces heading" "$(cat "$_p9_tmp")" "# Plan: Renderer registry"
# Also exercise the empty-input + bad-JSON + minimal-plan branches without $().
render_plan_md "" > "$_p9_tmp"
assert_contains "P9 empty plan placeholder" "$(cat "$_p9_tmp")" "_empty plan_"
render_plan_md '{not valid' > "$_p9_tmp"
assert_contains "P9 invalid JSON fence" "$(cat "$_p9_tmp")" '{not valid'
render_plan_md '{"goal":"x","notes":"n"}' > "$_p9_tmp"
assert_contains "P9 untitled placeholder" "$(cat "$_p9_tmp")" "# Plan: (untitled)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
