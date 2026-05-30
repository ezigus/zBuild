#!/usr/bin/env bash
# Tests: scripts/lib/helpers.sh::extract_first_json_object (issue #478)
#
# Helper is the durable safety net for ADR-018 Pattern 1 (#476). Envelope mode
# separates reasoning *turns* from the final turn, but the model can still
# preface its JSON with prose inside the final assistant message. The helper
# slices the LAST top-level balanced JSON object out of prose-prefixed text.
#
# Despite the name "first", the algorithm returns the LAST balanced object —
# models tend to emit reasoning examples first and the real answer last (e.g.
# "Here's an example {\"a\":1}. Real plan: {...}"). Name kept for #478 issue
# thread compatibility; behavior documented in the function's comment block.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/lib/helpers — extract_first_json_object (#478)"

# ─── E1: pure JSON object → passthrough ──────────────────────────────────────
out="$(printf '%s' '{"a":1}' | extract_first_json_object)"
assert_eq "E1: pure JSON object passes through" '{"a":1}' "$out"

# ─── E2: prose prefix + JSON (dogfood-shaped — REGRESSION LOCK) ─────────────
input='Now I have a complete picture.

{"schema_version":1,"steps":[]}'
out="$(printf '%s' "$input" | extract_first_json_object)"
assert_eq "E2: prose prefix + JSON returns JSON (REGRESSION LOCK)" \
    '{"schema_version":1,"steps":[]}' "$out"

# ─── E3: prose prefix + JSON + prose suffix → returns JSON ──────────────────
input='Here is the plan: {"a":1} -- end of response.'
out="$(printf '%s' "$input" | extract_first_json_object)"
assert_eq "E3: prose prefix + JSON + suffix returns JSON" '{"a":1}' "$out"

# ─── E4: markdown ```json fenced JSON → returns JSON ────────────────────────
input='```json
{"verdict":"approve"}
```'
out="$(printf '%s' "$input" | extract_first_json_object)"
assert_eq "E4: markdown json fence is stripped" '{"verdict":"approve"}' "$out"

# ─── E5: string-aware brace counting (REGRESSION LOCK) ──────────────────────
out="$(printf '%s' '{"x":"use { and }"}' | extract_first_json_object)"
assert_eq "E5: braces inside strings are ignored (REGRESSION LOCK)" \
    '{"x":"use { and }"}' "$out"

# ─── E6: escaped quotes / newlines inside strings ───────────────────────────
out="$(printf '%s' '{"x":"line1\nline2"}' | extract_first_json_object)"
assert_eq "E6: literal backslash-n inside string preserved" \
    '{"x":"line1\nline2"}' "$out"

# ─── E7: nested objects (REGRESSION LOCK) ───────────────────────────────────
out="$(printf '%s' '{"a":{"b":2}}' | extract_first_json_object)"
assert_eq "E7: nested object preserved (REGRESSION LOCK)" '{"a":{"b":2}}' "$out"

# ─── E8: two top-level objects → returns LAST (REGRESSION LOCK) ─────────────
out="$(printf '%s' '{"a":1}{"b":2}' | extract_first_json_object)"
assert_eq "E8: LAST balanced object wins (REGRESSION LOCK)" '{"b":2}' "$out"

# ─── E9: pure prose → passthrough verbatim (preserves #476 diagnostics) ─────
out="$(printf '%s' 'just some prose, no json here' | extract_first_json_object)"
assert_eq "E9: pure prose passes through verbatim (preserves #476)" \
    'just some prose, no json here' "$out"

# ─── E10: empty input → empty output ────────────────────────────────────────
out="$(printf '' | extract_first_json_object)"
assert_eq "E10: empty input -> empty output" '' "$out"

# ─── E11: unclosed JSON → passthrough verbatim ──────────────────────────────
out="$(printf '%s' 'prefix {"a":1' | extract_first_json_object)"
assert_eq "E11: unclosed brace -> passthrough" 'prefix {"a":1' "$out"

# ─── E12: only `}{` no opening sequence → passthrough ───────────────────────
out="$(printf '%s' '}{' | extract_first_json_object)"
assert_eq "E12: stray close-then-open -> passthrough" '}{' "$out"

# ─── E13: top-level array → passthrough (object-only contract) ──────────────
out="$(printf '%s' '[{"a":1}]' | extract_first_json_object)"
assert_eq "E13: top-level array passes through (object-only contract)" \
    '[{"a":1}]' "$out"

# ─── E14: 10 KB prose + JSON → still extracts, under 500ms (perf guard) ─────
prose="$(printf 'lorem ipsum dolor sit amet %.0s' {1..400})"
big_input="${prose} {\"ok\":true}"
t0_ns="$(date +%s%N 2>/dev/null || echo 0)"
out="$(printf '%s' "$big_input" | extract_first_json_object)"
t1_ns="$(date +%s%N 2>/dev/null || echo 0)"
assert_eq "E14: extracts JSON from 10KB prose" '{"ok":true}' "$out"
if [[ "$t0_ns" != "0" && "$t1_ns" != "0" ]]; then
    elapsed_ms=$(( (t1_ns - t0_ns) / 1000000 ))
    if [[ "$elapsed_ms" -lt 500 ]]; then
        assert_pass "E14: extraction under 500ms (perf guard, was ${elapsed_ms}ms)"
    else
        assert_fail "E14: extraction under 500ms (perf guard)" "took ${elapsed_ms}ms"
    fi
else
    assert_pass "E14: perf timing skipped (no nanosecond clock)"
fi

# ─── E15: UTF-8 BOM prefix → still extracts JSON ────────────────────────────
out="$(printf '\xef\xbb\xbf%s' '{"a":1}' | extract_first_json_object)"
assert_eq "E15: UTF-8 BOM prefix tolerated" '{"a":1}' "$out"

# ─── E16: multiple objects in prose → returns LAST (REGRESSION LOCK) ────────
out="$(printf '%s' 'prefix {"foo":"bar"} middle {"valid":true} suffix' | extract_first_json_object)"
assert_eq "E16: LAST of two prose-separated objects (REGRESSION LOCK)" \
    '{"valid":true}' "$out"

# ─── E17: inline example only — helper extracts; caller's jq -e rejects ─────
out="$(printf '%s' 'Just talking about {"foo":"bar"} as an example.' | extract_first_json_object)"
assert_eq "E17: helper extracts; layered defense delegates schema check upstream" \
    '{"foo":"bar"}' "$out"

# ─── E18: string-internal close brace edge ─────────────────────────────────
# Critical: a `}` inside a JSON string MUST NOT close the outer object.
out="$(printf '%s' '{"description": "use }} in regex"}' | extract_first_json_object)"
assert_eq "E18: close brace inside string preserved (NOT truncated)" \
    '{"description": "use }} in regex"}' "$out"

cleanup_test_env
print_test_results
