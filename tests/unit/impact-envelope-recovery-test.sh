#!/usr/bin/env bash
# Unit tests: _impact_recover_envelope_json + _impact_envelope_schema_ok (#908)
#
# The shared parser extract_json_and_surrounding_prose (helpers.sh) is LAST-wins
# (#478/ADR-018) to defend brace-bearing PREAMBLE. Impact emits its envelope
# FIRST, so a brace-bearing POSTAMBLE makes LAST-wins select the wrong object
# and the schema gate fails -> empty impact iteration (#908). These tests pin
# the impact-local schema-aware recovery: enumerate every top-level balanced
# object and return the FIRST that passes the impact schema gate.
#
# U1: envelope-first + brace-bearing postamble -> returns the envelope
# U2: the postamble object is NOT what comes back
# U3: no schema_version-bearing valid object -> rc=1, empty (never fabricates)
# U4: sole envelope (happy-path parity) -> returned verbatim
# U5: two valid envelopes -> FIRST wins (opposite of shared LAST-wins)
# U6: weak first schema object (missing fields) then full envelope -> full wins
# U7: braces inside a JSON string value -> object not mis-split
# U8: stray ```json fence postamble (the dogfood shape) -> envelope recovered
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/llm-agent.sh
source "$REPO_ROOT/scripts/lib/llm-agent.sh"
# shellcheck source=../../scripts/lib/impact-prefilter.sh
source "$REPO_ROOT/scripts/lib/impact-prefilter.sh"

print_test_header "unit: impact schema-aware envelope recovery (#908)"
setup_test_env "impact-envelope-recovery"

# ─── U1/U2: envelope FIRST + brace-bearing postamble ────────────────────────
u1_raw='{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":"ok"}
Based on my analysis: {"note":"this is a stray postamble object"}'
u1_out="$(_impact_recover_envelope_json "$u1_raw" 2>/dev/null)"
if printf '%s' "$u1_out" | jq -e '.schema_version==1 and .verdict=="complete"' >/dev/null 2>&1; then
    assert_pass "U1: recovery returns the schema_version envelope, not the postamble object"
else
    assert_fail "U1: recovery returns the schema_version envelope" "$u1_out"
fi
case "$u1_out" in
    *"stray postamble object"*) assert_fail "U2: recovery wrongly returned the postamble object" "$u1_out" ;;
    *) assert_pass "U2: recovery did not return the postamble object" ;;
esac

# ─── U3: no valid schema object -> rc=1, empty (never fabricates) ────────────
u3_raw='Here is some prose. {"unrelated":true} and {"also":"no schema"}'
set +e
u3_out="$(_impact_recover_envelope_json "$u3_raw" 2>/dev/null)"; u3_rc=$?
set -e
assert_eq "U3: no schema object -> empty stdout" "" "$u3_out"
assert_eq "U3: no schema object -> rc=1" "1" "$u3_rc"

# ─── U4: sole envelope returned verbatim (happy-path parity) ────────────────
u4_raw='{"schema_version":1,"verdict":"incomplete","missing":[],"impact_feedback_md":"x"}'
u4_out="$(_impact_recover_envelope_json "$u4_raw" 2>/dev/null)"
assert_eq "U4: sole envelope returned verbatim" \
    '{"schema_version":1,"verdict":"incomplete","missing":[],"impact_feedback_md":"x"}' "$u4_out"

# ─── U5: two schema_version-bearing envelopes -> AMBIGUOUS -> no recovery ────
# Could be a preamble example + the real answer; recovering either risks
# shipping the wrong one. Fail closed (Codex review on PR #935).
u5_raw='{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":"FIRST"}
trailing {"schema_version":1,"verdict":"incomplete","missing":[],"impact_feedback_md":"SECOND"}'
set +e
u5_out="$(_impact_recover_envelope_json "$u5_raw" 2>/dev/null)"; u5_rc=$?
set -e
assert_eq "U5: two schema-bearing objects -> ambiguous -> empty (fail closed)" "" "$u5_out"
assert_eq "U5: two schema-bearing objects -> rc=1 (no recovery)" "1" "$u5_rc"

# ─── U6 (Codex P2): preamble EXAMPLE (valid) + malformed real answer, both
# bearing schema_version -> ambiguous -> NO recovery. Prevents shipping the
# example as the verdict when the real (LAST) object is malformed. This is the
# exact half-validated-plan risk the strict gate was avoiding.
u6_raw='Example: {"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":"EXAMPLE"}
Real answer: {"schema_version":1,"verdict":"incomplete","missing":[]}'
set +e
u6_out="$(_impact_recover_envelope_json "$u6_raw" 2>/dev/null)"; u6_rc=$?
set -e
case "$u6_out" in
    *EXAMPLE*) assert_fail "U6: must NOT recover the preamble example as the verdict" "$u6_out" ;;
    *) assert_pass "U6: did not ship the preamble example as the verdict" ;;
esac
assert_eq "U6: example + malformed-real (2 schema objects) -> rc=1 (fail closed)" "1" "$u6_rc"

# ─── U7: braces inside a JSON string value are not mis-split ─────────────────
u7_raw='{"schema_version":1,"verdict":"incomplete","missing":[],"impact_feedback_md":"see {a} and }{ here"}
postamble {"note":"x"}'
u7_out="$(_impact_recover_envelope_json "$u7_raw" 2>/dev/null)"
assert_eq "U7: object with string-embedded braces recovered whole, verdict read" \
    "incomplete" "$(printf '%s' "$u7_out" | jq -r '.verdict' 2>/dev/null)"

# ─── U8: stray ```json fence postamble (dogfood shape) -> envelope recovered ─
u8_raw='{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":"ok"}
Based on my comprehensive analysis, the changes look good.
```json
{"summary":"all good"}
```'
u8_out="$(_impact_recover_envelope_json "$u8_raw" 2>/dev/null)"
assert_eq "U8: stray-fence postamble -> envelope verdict recovered" \
    "complete" "$(printf '%s' "$u8_out" | jq -r '.verdict' 2>/dev/null)"

# ─── ADR-060 / #1833: the retired impact_feedback_md field ──────────────────
# The gate must accept an envelope that does NOT carry impact_feedback_md.
# The field was a model-authored markdown blob; ADR-060 removes it.
u9_env='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1","files_to_add":["a.sh"],"reason":"r"}]}'
if _impact_envelope_schema_ok "$u9_env"; then
    assert_pass "U9: gate accepts an envelope with no impact_feedback_md (ADR-060)"
else
    assert_fail "U9: gate accepts an envelope with no impact_feedback_md (ADR-060)" \
        "gate rejected: $u9_env"
fi

# A legacy envelope that still carries the field must ALSO pass (artifacts
# restored from a prior run's state branch predate the removal).
u9b_env='{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":"legacy"}'
if _impact_envelope_schema_ok "$u9b_env"; then
    assert_pass "U9b: gate still accepts a legacy envelope carrying the retired field"
else
    assert_fail "U9b: gate still accepts a legacy envelope carrying the retired field" \
        "gate rejected: $u9b_env"
fi

# ─── U10-U12 (#1833): a PARSE failure is distinguishable from a SCHEMA one ──
# Run 32886190954 died on `done\_sentinel` inside impact_feedback_md. `\_` is
# not a legal JSON escape, so jq could not parse the object at all -- yet the
# error said "requires schema_version=1, verdict in {...}", naming five checks
# and identifying none. The classifier separates the two causes.
u10_raw='{"schema_version":1,"verdict":"incomplete","missing":[],"impact_feedback_md":"the done\_sentinel branch"}'
assert_eq "U10: invalid JSON escape classifies as unparseable (#1833)" \
    "unparseable" "$(_llm_envelope_classify "$u10_raw")"

u11_raw='{"schema_version":1,"verdict":"banana","missing":[]}'
assert_eq "U11: parseable JSON with a bad verdict classifies as schema" \
    "schema" "$(_llm_envelope_classify "$u11_raw" _impact_envelope_schema_ok)"

u12_raw='{"schema_version":1,"verdict":"complete","missing":[]}'
assert_eq "U12: a conformant envelope classifies as ok" \
    "ok" "$(_llm_envelope_classify "$u12_raw" _impact_envelope_schema_ok)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
