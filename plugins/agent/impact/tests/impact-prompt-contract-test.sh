#!/usr/bin/env bash
# Tests: impact plugin output-contract enforcement (#767)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "impact prompt contract + parser + forensics (#767)"
setup_test_env "impact-prompt-contract"

PROMPT_FILE="$REPO_ROOT/plugins/agent/impact/plugin.sh"

# T1: prompt strengthening
assert_contains "T1: prompt has explicit OUTPUT CONTRACT block" \
    "$(cat "$PROMPT_FILE")" "OUTPUT CONTRACT"
assert_contains "T1: prompt requires first character {" \
    "$(cat "$PROMPT_FILE")" "first output character MUST be"
assert_contains "T1: prompt has CORRECT example" \
    "$(cat "$PROMPT_FILE")" "CORRECT example"
assert_contains "T1: prompt has INCORRECT example" \
    "$(cat "$PROMPT_FILE")" "INCORRECT example"
assert_contains "T1: prompt repeats reminder before PLAN" \
    "$(cat "$PROMPT_FILE")" "response begins with"

# T2: parser switched
assert_contains "T2: parser switched to extract_json_and_surrounding_prose" \
    "$(cat "$PROMPT_FILE")" "extract_json_and_surrounding_prose"

# T3: contract violation event registered
SCHEMA_FILE="$REPO_ROOT/config/event-schema.json"
assert_contains "T3: impact.contract.violation in event-schema.json" \
    "$(cat "$SCHEMA_FILE")" "impact.contract.violation"

# T4: fenced+prose input parses cleanly
fenced_input='Based on my analysis:

```json
{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":""}
```

That is my final answer.'
out="$(printf '%s' "$fenced_input" | extract_json_and_surrounding_prose 2>/dev/null)"
json_part="$(awk '/^__JSON__$/{j=1;next} j' <<<"$out")"
prose_part="$(awk '/^__PROSE__$/{p=1;next} /^__JSON__$/{p=0;next} p' <<<"$out")"
assert_contains "T4: JSON extracted from fenced + prose input" \
    "$json_part" '"verdict":"complete"'
assert_contains "T4: prose captured for forensics" \
    "$prose_part" "Based on my analysis"
case "$json_part" in
    *'```'*) assert_fail "T4: extracted JSON must be fence-free" "$json_part" ;;
    *) assert_pass "T4: extracted JSON is fence-free" ;;
esac

# T5: clean JSON
clean_input='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1"}],"impact_feedback_md":"x"}'
out="$(printf '%s' "$clean_input" | extract_json_and_surrounding_prose 2>/dev/null)"
json_part="$(awk '/^__JSON__$/{j=1;next} j' <<<"$out")"
prose_part="$(awk '/^__PROSE__$/{p=1;next} /^__JSON__$/{p=0;next} p' <<<"$out")"
assert_contains "T5: clean JSON extracted as-is" "$json_part" '"verdict":"incomplete"'
assert_eq "T5: empty prose when no preamble" "" "$(printf '%s' "$prose_part" | tr -d '[:space:]')"

# ─── #774 prompt hardening: explicit FORBIDDEN list + escape valve ──────────
# Dogfood #754 (run_id 20260610065040-35172) showed 3/3 impact iters fired
# impact.contract.violation with decreasing prose lengths (258→117→113).
# The contract block was directionally correct but the model kept emitting
# the same handful of preamble phrases. Pin them by literal match so the
# prompt explicitly refuses them.

# T6: FORBIDDEN list names each observed prose preamble verbatim.
PROMPT_BODY="$(cat "$PROMPT_FILE")"
for phrase in 'Based on my analysis' "Here is" "Here's" 'After reviewing' "I've identified"; do
    assert_contains "T6: FORBIDDEN list names '$phrase' verbatim" \
        "$PROMPT_BODY" "$phrase"
done

# T7: explicit FORBIDDEN heading present (locks the section so it can't drift
# back to interleaved soft language).
assert_contains "T7: prompt has explicit FORBIDDEN heading" \
    "$PROMPT_BODY" "FORBIDDEN"

# T8: prominent escape valve directing observations into the JSON field
# instead of around the envelope. Phrased so the model can't miss it.
assert_contains "T8: prompt directs observations into impact_feedback_md field" \
    "$PROMPT_BODY" "impact_feedback_md"
assert_contains "T8: prompt explicitly forbids prose AROUND the envelope" \
    "$PROMPT_BODY" "before or after"

# T9: defensive parser kept in place — #771 recovery still load-bearing at
# any prompt-quality level. Regression guard against accidentally removing
# the safety net when the preventive path is hardened.
assert_contains "T9: extract_json_and_surrounding_prose still in plugin (#771 safety net)" \
    "$PROMPT_BODY" "extract_json_and_surrounding_prose"

# ─── #783 postamble FORBIDDEN — model emits banned phrases AFTER `}` ────────
# Wave 2 dogfood (run_id 20260610184141-48161) impact iter 2 emitted clean
# JSON but appended "Based on my comprehensive analysis..." and "I've
# identified..." AFTER the closing brace. PR #779's FORBIDDEN list catches
# preamble; this issue extends it to postamble + adds FINAL RULE sentinel.

PROMPT_BODY_783="$(cat "$PROMPT_FILE")"

# T10: FINAL RULE sentence — last instruction the model reads before PLAN:.
assert_contains "T10: prompt has FINAL RULE sentinel" \
    "$PROMPT_BODY_783" "FINAL RULE"
assert_contains "T10: FINAL RULE says 'ends at' or 'output NOTHING'" \
    "$PROMPT_BODY_783" "output NOTHING"

# T11: extended FORBIDDEN list names the iter-2 observed variants.
for variant in 'Based on my comprehensive analysis' 'Now I have' 'Let me' 'I have all the information'; do
    assert_contains "T11: FORBIDDEN names '$variant' verbatim" \
        "$PROMPT_BODY_783" "$variant"
done

# T12: explicit PREFIX/POSTFIX or "before AND after" emphasis — the model
# must read the rule as bidirectional, not "don't START with".
case "$PROMPT_BODY_783" in
    *"AFTER"*|*"postamble"*|*"after the JSON"*)
        assert_pass "T12: prompt explicitly names POSTAMBLE / 'after the JSON'" ;;
    *)
        assert_fail "T12: prompt must explicitly name AFTER/postamble" ;;
esac

# T13: parser still in place — defensive recovery from #771/#774 is the
# safety net at any prompt-quality level (regression guard).
assert_contains "T13: extract_json_and_surrounding_prose still present (#771 safety net)" \
    "$PROMPT_BODY_783" "extract_json_and_surrounding_prose"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
