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

# ─── U5: two valid envelopes -> FIRST wins (vs shared LAST-wins) ────────────
u5_raw='{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":"FIRST"}
trailing {"schema_version":1,"verdict":"incomplete","missing":[],"impact_feedback_md":"SECOND"}'
u5_out="$(_impact_recover_envelope_json "$u5_raw" 2>/dev/null)"
assert_contains "U5: FIRST valid envelope wins (opposite of shared LAST-wins)" "$u5_out" "FIRST"
case "$u5_out" in
    *SECOND*) assert_fail "U5: returned SECOND, must be FIRST" "$u5_out" ;;
    *) assert_pass "U5: did not return the SECOND envelope" ;;
esac

# ─── U6: weak first schema object skipped, full envelope returned ───────────
# A {"schema_version":1} stub (missing verdict/missing/feedback) must NOT be
# returned; recovery re-validates each candidate against the full gate.
u6_raw='{"schema_version":1}
{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":"REAL"}'
u6_out="$(_impact_recover_envelope_json "$u6_raw" 2>/dev/null)"
assert_contains "U6: weak first schema stub skipped, full envelope returned" "$u6_out" "REAL"

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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
