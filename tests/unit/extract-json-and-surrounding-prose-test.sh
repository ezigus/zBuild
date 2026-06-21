#!/usr/bin/env bash
# Tests: scripts/lib/helpers.sh::extract_json_and_surrounding_prose (#510)
#
# Sibling of extract_first_json_object that also returns the prose around the
# LAST balanced top-level JSON object. Output is two sentinel-delimited slices:
#
#   __PROSE__
#   <prose bytes>
#   __JSON__
#   <json bytes>
#
# Renderers consume this to split a plan/review banner into rendered artifact
# + ── llm comment ── block when the model emits prose alongside JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/lib/helpers — extract_json_and_surrounding_prose (#510)"

# Parser helper: extract <slice> from sentinel-delimited output.
# <slice> is "prose" or "json".
_split_slice() {
    local payload="$1" which="$2"
    printf '%s' "$payload" | awk -v want="$which" '
        BEGIN { mode = "" }
        /^__PROSE__$/ { mode = "prose"; next }
        /^__JSON__$/  { mode = "json";  next }
        {
            if (mode == want) {
                if (out == "") out = $0
                else out = out "\n" $0
            }
        }
        END { printf "%s", out }
    '
}

run() {
    local input="$1"
    printf '%s' "$input" | extract_json_and_surrounding_prose
}

# ─── X1: pure JSON → prose empty, json=input ─────────────────────────────────
out="$(run '{"a":1}')"
assert_eq "X1 prose empty for pure JSON"   "" "$(_split_slice "$out" prose)"
assert_eq "X1 json matches for pure JSON" '{"a":1}' "$(_split_slice "$out" json)"

# ─── X2: pure prose → prose=input, json empty ───────────────────────────────
out="$(run 'just some words')"
assert_eq "X2 prose preserved" "just some words" "$(_split_slice "$out" prose)"
assert_eq "X2 json empty"       "" "$(_split_slice "$out" json)"

# ─── X3: prose prefix + JSON → prose=prefix, json=object ────────────────────
input='Here is the plan.

{"schema_version":1}'
out="$(run "$input")"
assert_eq "X3 prose is prefix" "Here is the plan." "$(_split_slice "$out" prose)"
assert_eq "X3 json is object"  '{"schema_version":1}' "$(_split_slice "$out" json)"

# ─── X4: JSON + prose suffix → prose=suffix ─────────────────────────────────
input='{"a":1}

Let me know if you want changes.'
out="$(run "$input")"
assert_eq "X4 prose is suffix" "Let me know if you want changes." "$(_split_slice "$out" prose)"
assert_eq "X4 json is object"  '{"a":1}' "$(_split_slice "$out" json)"

# ─── X5: prose + JSON + prose → prose=concat with blank-line separator ──────
input='Here is the plan.

{"a":1}

Let me know.'
out="$(run "$input")"
expected_prose=$'Here is the plan.\n\nLet me know.'
assert_eq "X5 prose concat with blank line" "$expected_prose" "$(_split_slice "$out" prose)"
assert_eq "X5 json is object"  '{"a":1}' "$(_split_slice "$out" json)"

# ─── X6: multi-JSON (inline example) → LAST wins; earlier object in prose ──
input='For example {"foo":"bar"}. The real plan: {"valid":true}'
out="$(run "$input")"
assert_eq "X6 LAST balanced object wins" '{"valid":true}' "$(_split_slice "$out" json)"
# The earlier inline-example object survives inside prose.
if grep -qF '{"foo":"bar"}' <<< "$(_split_slice "$out" prose)"; then
    assert_pass "X6 earlier inline-example object survives in prose"
else
    assert_fail "X6 earlier inline-example object survives in prose" \
        "got prose: $(_split_slice "$out" prose)"
fi

# ─── X7: markdown ```json fence stripped BEFORE slicing ─────────────────────
input='```json
{"verdict":"approve"}
```'
out="$(run "$input")"
assert_eq "X7 fenced JSON extracted"  '{"verdict":"approve"}' "$(_split_slice "$out" json)"
assert_eq "X7 prose empty after fence strip" "" "$(_split_slice "$out" prose)"

# ─── X8: empty input → both empty ───────────────────────────────────────────
out="$(run '')"
assert_eq "X8 empty input → prose empty" "" "$(_split_slice "$out" prose)"
assert_eq "X8 empty input → json empty"  "" "$(_split_slice "$out" json)"

# ─── X9: unclosed JSON → entire buffer is prose (no balanced object) ───────
input='prefix {"a":1 unclosed'
out="$(run "$input")"
assert_eq "X9 unclosed JSON → prose=verbatim" 'prefix {"a":1 unclosed' "$(_split_slice "$out" prose)"
assert_eq "X9 unclosed JSON → json empty"     "" "$(_split_slice "$out" json)"

# ─── X10: braces inside strings ignored (parity with sibling helper) ───────
input='note {"x":"use { and }"} fin'
out="$(run "$input")"
assert_eq "X10 string-internal braces respected" '{"x":"use { and }"}' "$(_split_slice "$out" json)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
