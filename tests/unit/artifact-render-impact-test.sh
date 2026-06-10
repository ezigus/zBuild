#!/usr/bin/env bash
# Tests: render_impact_md — built-in impact renderer (#768)
# Impact JSON shape:
#   { schema_version, verdict (complete|incomplete), missing[], impact_feedback_md }
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "render_impact_md (#768)"
setup_test_env "render-impact"

# shellcheck source=../../scripts/lib/artifact-render.sh
source "$REPO_ROOT/scripts/lib/artifact-render.sh"

# ─── I1: verdict=incomplete with feedback markdown → renders header + body ──
input='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"step-1","files_to_add":["a.sh","b.sh"],"reason":"r"}],"impact_feedback_md":"## Missing\n- a.sh\n- b.sh"}'
out="$(render_impact_md "$input")"
assert_contains "I1 header shows verdict=incomplete" "$out" "Impact: verdict=incomplete"
assert_contains "I1 header shows missing=1" "$out" "missing=1"
assert_contains "I1 body contains markdown header" "$out" "## Missing"
assert_contains "I1 body contains bullet a.sh" "$out" "- a.sh"

# ─── I2: verdict=complete with no missing → header only, no body ─────────────
input='{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":""}'
out="$(render_impact_md "$input")"
assert_contains "I2 header shows verdict=complete" "$out" "Impact: verdict=complete"
assert_contains "I2 header shows missing=0" "$out" "missing=0"
# No "## " heading in the body when feedback is empty
case "$out" in
    *$'\n\n## '*) assert_fail "I2 must not render empty body" "got: $out" ;;
    *) assert_pass "I2 no spurious body when impact_feedback_md is empty" ;;
esac

# ─── I3: empty input → passthrough placeholder ───────────────────────────────
out="$(render_impact_md "")"
assert_eq "I3 empty input placeholder" "_empty impact_" "$out"

# ─── I4: invalid JSON → fenced raw passthrough ───────────────────────────────
out="$(render_impact_md '{"oops": invalid')"
assert_contains "I4 invalid JSON renders inside fence" "$out" '{"oops": invalid'

# ─── I5: missing array with 3 entries → count=3 ──────────────────────────────
input='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1"},{"step_id":"s2"},{"step_id":"s3"}],"impact_feedback_md":"x"}'
out="$(render_impact_md "$input")"
assert_contains "I5 missing count counted correctly" "$out" "missing=3"

# ─── I6: prose-prefixed JSON (#510 contract violation forensics) ────────────
# #776: forensic marker stays so operator knows the violation fired, but the
# llm-comment block must NOT duplicate the rendered JSON envelope inline.
input='Based on my analysis, here is the verdict:

{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":""}'
out="$(render_impact_md "$input")"
assert_contains "I6 prose-prefixed JSON still extracts verdict" "$out" "Impact: verdict=complete"
assert_contains "I6 llm comment marker present" "$out" "── llm comment ──"
assert_contains "I6 brief preamble line carries forensic signal" "$out" "Based on my analysis"
# Critically: the duplicated JSON envelope must NOT appear in the llm-comment
# block (the clean render already showed it above; inlining it again is the
# noise #776 fixes).
llm_comment_block="$(printf '%s' "$out" | awk '/── llm comment ──/{p=1;next} p')"
case "$llm_comment_block" in
    *'"schema_version":1,"verdict":"complete"'*)
        assert_fail "I6 llm-comment must NOT duplicate the rendered JSON envelope" ;;
    *)
        assert_pass "I6 llm-comment does not duplicate the rendered JSON envelope" ;;
esac

# ─── I6b (#777): impact_feedback_md inline-code backticks survive rendering ─
# Dogfood showed `_artifact_md_escape_block` escaped backticks in
# LLM-authored markdown, so inline-code spans rendered as literal \` instead
# of monospace. Drop the backtick escape — banner fence isolation handles
# stage-io safety.
input='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1"}],"impact_feedback_md":"Update `assert_eq foo` here — see `bar.sh`."}'
out="$(render_impact_md "$input")"
assert_contains "I6b inline-code backticks preserved (not escaped)" "$out" '`assert_eq'
assert_contains "I6b second inline-code span preserved" "$out" '`bar.sh`'
case "$out" in
    *'\`'*)
        assert_fail "I6b output must NOT contain backslash-escaped backticks" ;;
    *)
        assert_pass "I6b output contains no backslash-escaped backticks" ;;
esac

# ─── I6c (#776 cont): genuine prose-only commentary still inlines ──────────
# When prose is real commentary without a duplicate envelope, keep it inline
# so context isn't lost. The "drop envelope duplicate" rule applies only
# when the prose itself contains a JSON object literal.
input='I noticed step-3 may reference an undeclared helper.

{"schema_version":1,"verdict":"incomplete","missing":[],"impact_feedback_md":""}'
out="$(render_impact_md "$input")"
assert_contains "I6c genuine commentary inlines into llm-comment" \
    "$out" "I noticed step-3"

# ─── I7: renderer registered in registry ────────────────────────────────────
# This passes once the registration is added (greens with the implementation)
fn="${_ARTIFACT_RENDERERS[impact]:-}"
assert_eq "I7 impact renderer registered" "render_impact_md" "$fn"

# ─── I8: render_artifact dispatch with id=impact uses our renderer ──────────
out="$(render_artifact "impact" '{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":""}')"
assert_contains "I8 render_artifact dispatches to impact renderer" "$out" "Impact: verdict=complete"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
