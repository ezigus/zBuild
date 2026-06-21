#!/usr/bin/env bash
# Tests: render_plan_md + render_review_md prose+JSON splitting (#510)
#
# When the LLM emits prose alongside JSON in the same assistant turn
# (envelope mode separates turns but not in-turn prose), the renderer must
# split: rendered artifact FIRST (eye-target priority), then a
# `── llm comment ──` block carrying the prose.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "render_plan_md / render_review_md — prose+JSON split (#510)"
setup_test_env "render-plan-with-comment"

# shellcheck source=../../scripts/lib/artifact-render.sh
source "$REPO_ROOT/scripts/lib/artifact-render.sh"

PLAN='{"schema_version":1,"title":"T","steps":[{"description":"d","files":["a"]}]}'

# ─── C1: pure JSON → plan only, no comment marker (regression lock) ─────────
out="$(render_plan_md "$PLAN")"
assert_contains "C1 plan heading present"     "$out" "# Plan: T"
if grep -qF "── llm comment ──" <<< "$out"; then
    assert_fail "C1 no comment marker on pure-JSON input" "got: $out"
else
    assert_pass "C1 no comment marker on pure-JSON input"
fi

# ─── C2: pure prose → comment-only output, heading placeholder ──────────────
out="$(render_plan_md "Just talking, no JSON here.")"
assert_contains "C2 prose-only emits placeholder heading" "$out" "# Plan: (no JSON returned)"
assert_contains "C2 prose-only emits comment marker"      "$out" "── llm comment ──"
assert_contains "C2 prose body preserved"                 "$out" "Just talking, no JSON here."

# ─── C3: prose prefix + JSON → plan FIRST, then comment ─────────────────────
input="Here is the plan.

$PLAN"
out="$(render_plan_md "$input")"
assert_contains "C3 plan heading present"  "$out" "# Plan: T"
assert_contains "C3 comment marker present" "$out" "── llm comment ──"
assert_contains "C3 prose body preserved"   "$out" "Here is the plan."
# Ordering: plan heading must come BEFORE the comment marker.
plan_pos="$(printf '%s\n' "$out" | grep -n "# Plan: T" | head -1 | cut -d: -f1)"
comm_pos="$(printf '%s\n' "$out" | grep -n "── llm comment ──" | head -1 | cut -d: -f1)"
if [[ -n "$plan_pos" && -n "$comm_pos" && "$plan_pos" -lt "$comm_pos" ]]; then
    assert_pass "C3 plan renders BEFORE comment block"
else
    assert_fail "C3 plan renders BEFORE comment block" \
        "plan_pos=$plan_pos comm_pos=$comm_pos"
fi

# ─── C4: JSON + prose suffix → plan + comment ───────────────────────────────
input="$PLAN

Let me know if you want changes."
out="$(render_plan_md "$input")"
assert_contains "C4 plan heading present"  "$out" "# Plan: T"
assert_contains "C4 comment marker present" "$out" "── llm comment ──"
assert_contains "C4 suffix prose preserved" "$out" "Let me know if you want changes."

# ─── C5: prose+JSON+prose → comment concatenates both segments ─────────────
input="Before.

$PLAN

After."
out="$(render_plan_md "$input")"
assert_contains "C5 prefix prose preserved" "$out" "Before."
assert_contains "C5 suffix prose preserved" "$out" "After."

# ─── C6: multi-JSON inline example → LAST renders, earlier in comment ──────
input='For example {"foo":"bar"}. The real plan: {"schema_version":1,"title":"Real","steps":[]}'
out="$(render_plan_md "$input")"
assert_contains "C6 LAST object renders as plan" "$out" "# Plan: Real"
assert_contains "C6 inline-example object in comment" "$out" '{"foo":"bar"}'

# ─── C7: malformed JSON → comment-only, rc=0 ────────────────────────────────
set +e
out="$(render_plan_md '{not valid json}')"
rc=$?
set -e
assert_eq "C7 malformed JSON rc=0" "0" "$rc"
# Malformed JSON: the regex slicer still finds a balanced "{...}" — so it
# routes to the json slot and the renderer falls back to fenced passthrough.
# Either way the body MUST surface in the output; assert that.
assert_contains "C7 malformed body surfaces in output" "$out" "not valid json"

# ─── C8: empty input → empty output, rc=0 ───────────────────────────────────
set +e
out="$(render_plan_md "")"
rc=$?
set -e
assert_eq "C8 empty input rc=0" "0" "$rc"
assert_eq "C8 empty input → placeholder" "_empty plan_" "$out"

# ─── C9: markdown ```json fences stripped, NOT duplicated into comment ─────
input='```json
'"$PLAN"'
```'
out="$(render_plan_md "$input")"
assert_contains "C9 fenced JSON renders as plan" "$out" "# Plan: T"
if grep -qF "── llm comment ──" <<< "$out"; then
    assert_fail "C9 fences alone do NOT produce comment block" "got: $out"
else
    assert_pass "C9 fences alone do NOT produce comment block"
fi

# ─── C10 (#777): backticks in prose body preserved (NOT escaped) ────────────
# Prior behavior escaped all backticks to `\\\`` which broke LLM-authored
# markdown bodies with inline-code spans (dogfood: `assert_eq foo` rendered
# as literal `\\`assert_eq foo\\\``). New contract: block content preserves
# backticks verbatim; stage-io banner safety comes from outer fence
# isolation, not per-block escaping. Inline fields (titles, verdicts) still
# escape via _artifact_md_escape_inline — see P5 in artifact-render-plan-test.
input='Here is `inline-code` prose.

'"$PLAN"
out="$(render_plan_md "$input")"
assert_contains "C10 inline-code backticks preserved verbatim" "$out" '`inline-code`'
case "$out" in
    *'\`'*)
        assert_fail "C10 output must NOT contain backslash-escaped backticks" ;;
    *)
        assert_pass "C10 output contains no backslash-escaped backticks" ;;
esac

# ─── C11: review renderer gets the same split treatment ────────────────────
REVIEW='{"verdict":"approve","confidence":0.9,"issues":[],"summary":"ok"}'
input="Reviewer note: looks fine.

$REVIEW"
out="$(render_review_md "$input")"
assert_contains "C11 review heading present"   "$out" "# Review"
assert_contains "C11 review verdict present"   "$out" "**Verdict:** approve"
assert_contains "C11 review comment marker"    "$out" "── llm comment ──"
assert_contains "C11 review prose preserved"   "$out" "Reviewer note: looks fine."

# ─── C12: review pure JSON → no comment marker (regression lock) ───────────
out="$(render_review_md "$REVIEW")"
assert_contains "C12 review heading present" "$out" "# Review"
if grep -qF "── llm comment ──" <<< "$out"; then
    assert_fail "C12 no comment marker on pure-JSON review" "got: $out"
else
    assert_pass "C12 no comment marker on pure-JSON review"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
