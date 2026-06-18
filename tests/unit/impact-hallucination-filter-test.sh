#!/usr/bin/env bash
# Unit tests: _impact_drop_nonexistent_missing (#911)
#
# H1: mixed input — keeps existing paths, drops non-existent ones
# H2: all-ghost input — empties missing[], flips verdict incomplete→complete,
#     emits impact.hallucination.filtered with verdict_flipped=true
# H3: prefilter-forced existing file is NOT dropped (floor intact)
# H4: verdict=error is never flipped regardless of missing[] contents
# C1: charter mandate text is present in plugin.sh (_impact_instructions)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "unit: impact hallucination post-filter (#911)"
setup_test_env "impact-hallucination-filter"

# Override emit_event to capture events to a temp file for assertions.
EVENTS_LOG="$TEST_TEMP_DIR/events.log"
emit_event() {
    printf '%s\n' "$*" >> "$EVENTS_LOG"
    return 0
}

# shellcheck source=../../scripts/lib/impact-prefilter.sh
source "$REPO_ROOT/scripts/lib/impact-prefilter.sh"

# ─── Fake repo root with some real files ────────────────────────────────────
FAKE_ROOT="$TEST_TEMP_DIR/fake-repo"
mkdir -p "$FAKE_ROOT/core" "$FAKE_ROOT/plugins/agent/impact"
printf 'real\n' > "$FAKE_ROOT/core/existing.sh"
printf 'real\n' > "$FAKE_ROOT/plugins/agent/impact/plugin.sh"

# ─── H1: mixed input keeps existing paths, drops non-existent ───────────────
impact_json='{"schema_version":1,"verdict":"incomplete","missing":[
  {"step_id":"s1","files_to_add":["core/existing.sh","ghost/does-not-exist.sh"],"reason":"r1"}
],"impact_feedback_md":""}'

_impact_drop_nonexistent_missing "$FAKE_ROOT"

real_kept="$(printf '%s' "$impact_json" | jq -r '.missing[].files_to_add[]' 2>/dev/null)"
assert_contains "[SPEC-1] H1: existing path kept (non-existent stripped, entry preserved)" "$real_kept" "core/existing.sh"
case "$real_kept" in
    *"ghost/does-not-exist.sh"*)
        assert_fail "H1: ghost path must be dropped" "$real_kept" ;;
    *)
        assert_pass "H1: ghost path dropped" ;;
esac

h1_verdict="$(printf '%s' "$impact_json" | jq -r '.verdict')"
assert_eq "H1: verdict stays incomplete (real gap remains)" "incomplete" "$h1_verdict"

# ─── H2: all-ghost input — empties missing[], flips to complete ─────────────
: > "$EVENTS_LOG"

impact_json='{"schema_version":1,"verdict":"incomplete","missing":[
  {"step_id":"s2","files_to_add":["ghost/a.sh","ghost/b.sh"],"reason":"r2"}
],"impact_feedback_md":"gaps found"}'

_impact_drop_nonexistent_missing "$FAKE_ROOT"

h2_verdict="$(printf '%s' "$impact_json" | jq -r '.verdict')"
assert_eq "[SPEC-2] H2: all-ghost → missing[] empties → verdict flips to complete" "complete" "$h2_verdict"

h2_missing_len="$(printf '%s' "$impact_json" | jq '.missing | length')"
assert_eq "H2: missing[] is empty" "0" "$h2_missing_len"

if grep -q "impact.hallucination.filtered" "$EVENTS_LOG"; then
    assert_pass "H2: impact.hallucination.filtered event emitted"
else
    assert_fail "H2: impact.hallucination.filtered event not found" "$(cat "$EVENTS_LOG")"
fi

if grep -q "verdict_flipped=true" "$EVENTS_LOG"; then
    assert_pass "H2: event carries verdict_flipped=true"
else
    assert_fail "H2: event missing verdict_flipped=true" "$(cat "$EVENTS_LOG")"
fi

if grep -q "dropped_count=2" "$EVENTS_LOG"; then
    assert_pass "[SPEC-3] H2: impact.hallucination.filtered carries dropped_count=2 (+ verdict_flipped)"
else
    assert_fail "H2: event missing dropped_count=2" "$(cat "$EVENTS_LOG")"
fi

# ─── H3: prefilter-forced existing file is NOT dropped ──────────────────────
: > "$EVENTS_LOG"

impact_json='{"schema_version":1,"verdict":"incomplete","missing":[
  {"step_id":"prefilter","files_to_add":["plugins/agent/impact/plugin.sh"],"reason":"floor"}
],"impact_feedback_md":""}'

_impact_drop_nonexistent_missing "$FAKE_ROOT"

h3_files="$(printf '%s' "$impact_json" | jq -r '.missing[].files_to_add[]' 2>/dev/null)"
assert_contains "[SPEC-4] H3: prefilter-forced existing entry never dropped (floor integrity)" "$h3_files" "plugins/agent/impact/plugin.sh"

h3_verdict="$(printf '%s' "$impact_json" | jq -r '.verdict')"
assert_eq "H3: verdict stays incomplete (floor gap remains)" "incomplete" "$h3_verdict"

if grep -q "impact.hallucination.filtered" "$EVENTS_LOG"; then
    assert_fail "H3: no hallucination event when all paths exist" "$(cat "$EVENTS_LOG")"
else
    assert_pass "H3: no hallucination event emitted (nothing to drop)"
fi

# ─── H4: verdict=error is never flipped ─────────────────────────────────────
impact_json='{"schema_version":1,"verdict":"error","reason":"timeout","missing":[
  {"step_id":"s4","files_to_add":["ghost/c.sh"],"reason":"r4"}
],"impact_feedback_md":""}'

_impact_drop_nonexistent_missing "$FAKE_ROOT"

h4_verdict="$(printf '%s' "$impact_json" | jq -r '.verdict')"
assert_eq "[SPEC-5] H4: verdict=error never flipped by hallucination filter" "error" "$h4_verdict"

# ─── H5 (Copilot review): a ghost path with embedded whitespace is dropped ───
# Ghost detection (bash, strips ALL whitespace) and removal (jq) must normalize
# alike — otherwise a path with a tab/\r is detected-as-ghost yet left in
# missing[]. Here the only path is a non-existent one carrying a trailing tab.
: > "$EVENTS_LOG"
impact_json='{"schema_version":1,"verdict":"incomplete","missing":[
  {"step_id":"s5","files_to_add":["ghost/tabbed.sh\t"],"reason":"r5"}
],"impact_feedback_md":""}'
_impact_drop_nonexistent_missing "$FAKE_ROOT"
h5_len="$(printf '%s' "$impact_json" | jq '.missing | length')"
assert_eq "[SPEC-1] H5: whitespace-laden ghost path dropped (missing[] empties)" "0" "$h5_len"
h5_verdict="$(printf '%s' "$impact_json" | jq -r '.verdict')"
assert_eq "H5: verdict flips to complete after whitespace-ghost drop" "complete" "$h5_verdict"

# ─── C1: charter mandate text present in plugin.sh ──────────────────────────
PLUGIN_SH="$REPO_ROOT/plugins/agent/impact/plugin.sh"
assert_contains "[SPEC-6] C1: charter has EXISTENCE VERIFICATION heading" \
    "$(cat "$PLUGIN_SH")" "EXISTENCE VERIFICATION"
assert_contains "C1: charter prohibits non-existent paths in files_to_add" \
    "$(cat "$PLUGIN_SH")" "NEVER list a path you cannot verify"
assert_contains "C1: charter requires Read or Grep verification before listing" \
    "$(cat "$PLUGIN_SH")" "confirm the file exists"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
