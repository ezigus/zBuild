#!/usr/bin/env bash
# Tests: render_impact_md — built-in impact renderer (#768, ADR-060)
# Impact JSON shape (ADR-060): { schema_version, verdict, missing[] }
# The narrative is RENDERED from missing[]; the model no longer authors prose.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "render_impact_md (#768, ADR-060)"
setup_test_env "render-impact"

# shellcheck source=../../scripts/lib/artifact-render.sh
source "$REPO_ROOT/scripts/lib/artifact-render.sh"

# ─── I1: narrative is BUILT from missing[], not copied from a prose field ────
input='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"step-1","files_to_add":["a.sh","b.sh"],"reason":"golden diverges after the change"}]}'
out="$(render_impact_md "$input")"
assert_contains "I1 header shows verdict=incomplete" "$out" "Impact: verdict=incomplete"
assert_contains "I1 header shows missing=1" "$out" "missing=1"
assert_contains "I1 renders the step id"        "$out" "step-1"
assert_contains "I1 renders first file"         "$out" "a.sh"
assert_contains "I1 renders second file"        "$out" "b.sh"
assert_contains "I1 renders the reason"         "$out" "golden diverges after the change"

# ─── I2: verdict=complete with no missing → header only, no body ─────────────
input='{"schema_version":1,"verdict":"complete","missing":[]}'
out="$(render_impact_md "$input")"
assert_contains "I2 header shows verdict=complete" "$out" "Impact: verdict=complete"
assert_contains "I2 header shows missing=0" "$out" "missing=0"
case "$out" in
    *"step_id"*|*"Why:"*) assert_fail "I2 must not render a body when missing[] is empty" "got: $out" ;;
    *) assert_pass "I2 no spurious body when missing[] is empty" ;;
esac

# ─── I3: empty input → passthrough placeholder ───────────────────────────────
out="$(render_impact_md "")"
assert_eq "I3 empty input placeholder" "_empty impact_" "$out"

# ─── I4: invalid JSON → fenced raw passthrough ───────────────────────────────
out="$(render_impact_md '{"oops": invalid')"
assert_contains "I4 invalid JSON renders inside fence" "$out" '{"oops": invalid'

# ─── I5: three missing entries → count=3 and ALL three rendered ─────────────
input='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1","files_to_add":["f1"],"reason":"r1"},{"step_id":"s2","files_to_add":["f2"],"reason":"r2"},{"step_id":"s3","files_to_add":["f3"],"reason":"r3"}]}'
out="$(render_impact_md "$input")"
assert_contains "I5 missing count counted correctly" "$out" "missing=3"
assert_contains "I5 renders entry 1" "$out" "s1"
assert_contains "I5 renders entry 2" "$out" "s2"
assert_contains "I5 renders entry 3" "$out" "s3"

# ─── I6: prose-prefixed JSON (#510 contract violation forensics) ────────────
input='Based on my analysis, here is the verdict:

{"schema_version":1,"verdict":"complete","missing":[]}'
out="$(render_impact_md "$input")"
assert_contains "I6 prose-prefixed JSON still extracts verdict" "$out" "Impact: verdict=complete"
assert_contains "I6 llm comment marker present" "$out" "── llm comment ──"
assert_contains "I6 brief preamble line carries forensic signal" "$out" "Based on my analysis"
llm_comment_block="$(printf '%s' "$out" | awk '/── llm comment ──/{p=1;next} p')"
case "$llm_comment_block" in
    *'"schema_version":1,"verdict":"complete"'*)
        assert_fail "I6 llm-comment must NOT duplicate the rendered JSON envelope" ;;
    *)
        assert_pass "I6 llm-comment does not duplicate the rendered JSON envelope" ;;
esac

# ─── I6b (#777): inline-code backticks in reason survive rendering ──────────
input='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1","files_to_add":["bar.sh"],"reason":"Update `assert_eq foo` here"}]}'
out="$(render_impact_md "$input")"
assert_contains "I6b inline-code backticks preserved (not escaped)" "$out" 'assert_eq foo'
case "$out" in
    *'\`'*) assert_fail "I6b output must NOT contain backslash-escaped backticks" ;;
    *)      assert_pass "I6b output contains no backslash-escaped backticks" ;;
esac

# ─── I6c (#776 cont): genuine prose-only commentary still inlines ──────────
input='I noticed step-3 may reference an undeclared helper.

{"schema_version":1,"verdict":"incomplete","missing":[]}'
out="$(render_impact_md "$input")"
assert_contains "I6c genuine commentary inlines into llm-comment" \
    "$out" "I noticed step-3"

# ─── I7: renderer registered in registry ────────────────────────────────────
fn="${_ARTIFACT_RENDERERS[impact]:-}"
assert_eq "I7 impact renderer registered" "render_impact_md" "$fn"

# ─── I8: render_artifact dispatch with id=impact uses our renderer ──────────
out="$(render_artifact "impact" '{"schema_version":1,"verdict":"complete","missing":[]}')"
assert_contains "I8 render_artifact dispatches to impact renderer" "$out" "Impact: verdict=complete"

# ─── I9 (ADR-060): missing[].evidence is rendered when present ──────────────
input='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1","files_to_add":["g.golden"],"reason":"r","evidence":"exact-match assertion at line 126"}]}'
out="$(render_impact_md "$input")"
assert_contains "I9 evidence rendered" "$out" "exact-match assertion at line 126"

# ─── I10 (ADR-060): a legacy impact_feedback_md is IGNORED, never rendered ──
# Artifacts restored from a prior run's state branch may still carry the
# retired field. It is no longer part of the contract, so it must not appear.
input='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1","files_to_add":["a.sh"],"reason":"r"}],"impact_feedback_md":"## LEGACY BLOB SHOULD NOT RENDER"}'
out="$(render_impact_md "$input")"
case "$out" in
    *"LEGACY BLOB SHOULD NOT RENDER"*)
        assert_fail "I10 retired impact_feedback_md must NOT be rendered" "got: $out" ;;
    *)
        assert_pass "I10 retired impact_feedback_md is ignored" ;;
esac
assert_contains "I10 structured narrative still rendered" "$out" "s1"

# ─── I11 (ADR-060): a top-level reason is rendered when there are no gaps ───
# A router timeout writes verdict=incomplete, missing=[], reason=router_timeout.
# Before ADR-060 that explanation rode in a model-authored prose note. It is
# now a structured field, so the ENGINE must surface it or the terminal loses
# why the stage came back empty.
input='{"schema_version":1,"verdict":"incomplete","missing":[],"reason":"router_timeout","router_rc":"124"}'
out="$(render_impact_md "$input")"
assert_contains "I11 top-level reason rendered" "$out" "router_timeout"

# ─── I12: a per-entry reason must not be confused with the top-level one ───
input='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1","files_to_add":["a.sh"],"reason":"entry-level why"}]}'
out="$(render_impact_md "$input")"
assert_contains "I12 entry reason still rendered" "$out" "entry-level why"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
