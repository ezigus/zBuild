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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
