#!/usr/bin/env bash
# tests/unit/stage-summary-says-what-test.sh — a stage's summary line says what
# it produced or what failed, never only counts or how it works (ADR-064 §4,
# amended 2026-11-06, #2476).
#
# Why: a row on the issue is the stage's summary line, and on #1805 run
# 42127743259 they read "authored design.md — 17 file(s) in scope, 15
# acceptance SPEC(s)", "changed 1 test file(s); acceptance assertions for 12
# SPEC(s) from the design contract", "changed 2 file(s) over 1 pass(es), 1
# iteration(s)" and "verdict: fail". A reader learned how many, never what.
#
# Each case drives the stage's own summary writer:
# S1 [change] intake names the requirements it listed
# S2 [change] design names its SPECs, and each SPEC's line says what it covers
# S3 [change] test-author names the SPECs it wrote tests for, without its rules
# S4 [change] build names the files it changed; a try cut off says so
# S5 [change] test says how many passed, or which files failed
# S6 [change] a review lens names what it found, or that it found nothing
# S7 [change] the security lens names what it found, or that it found nothing
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a stage's summary line says what it produced or what failed (#2476)"
setup_test_env "stage-summary-says-what"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; A="$ZBUILD_STATE_DIR/artifacts"; mkdir -p "$A"
export ZBUILD_ARTIFACT_DIR="$A"

# _first <summary.md> — the line a row shows: the first that is not a heading.
_first() { awk 'NF && $0 !~ /^#/ { sub(/^- /, ""); print; exit }' "$1" 2>/dev/null; }

D="$A/design.md"
cat > "$D" <<'MD'
# Design
```acceptance
LOOP-1[code]: a fresh run starts at round 1 covers: RQST-1
KEEP-1[code]: a resumed run starts at the saved round covers: RQST-1 RQST-2
WIRING: none
TESTFILES:
LOOP-1: tests/loop-test.sh
KEEP-1: tests/keep-test.sh
```
MD

# ── S1 intake ────────────────────────────────────────────────────────────────
printf '%s\n' '{"schema_version":1,"source":"model","requirements":[{"id":"RQST-1","text":"a fresh run starts at round 1"},{"id":"RQST-2","text":"a resumed run keeps its round"}]}' > "$A/requirements.json"
( source "$REPO_ROOT/plugins/agent/intake/plugin.sh"
  _intake_pass_summary_write "$A/intake-summary.md" 42 "$A/requirements.json" "" ) >/dev/null 2>&1
assert_eq "[S1] intake names the requirements it listed" "2 requirement(s): RQST-1, RQST-2" "$(_first "$A/intake-summary.md")"
assert_contains "[S1] …each with its words" "$(cat "$A/intake-summary.md" 2>/dev/null)" "- RQST-2: a resumed run keeps its round"
( set -u; source "$REPO_ROOT/plugins/agent/intake/plugin.sh"
  _intake_pass_summary_write "$A/intake-goal-summary.md" 42 "" "" "Make the gate quieter" ) >/dev/null 2>&1
assert_eq "[S1] a goal run, with no list, says what it took in" \
    "took in the goal for issue #42: Make the gate quieter" "$(_first "$A/intake-goal-summary.md")"

# ── S2 design ────────────────────────────────────────────────────────────────
( source "$REPO_ROOT/plugins/agent/design/plugin.sh"
  _design_pass_summary_write "$A" "$D" ) >/dev/null 2>&1
assert_eq "[S2] design names its SPECs" "2 SPEC(s): LOOP-1, KEEP-1" "$(_first "$A/design-summary.md")"
assert_contains "[S2] …and what each covers" "$(cat "$A/design-summary.md" 2>/dev/null)" \
    "- KEEP-1 (covers RQST-1 RQST-2): a resumed run starts at the saved round"

# ── S3 test-author ───────────────────────────────────────────────────────────
R="$TEST_TEMP_DIR/repo"; mkdir -p "$R/tests"
printf 'assert_eq "[LOOP-1] fresh" 1 1\n' > "$R/tests/loop-test.sh"
printf 'assert_eq "[KEEP-1] resume" 2 2\n' > "$R/tests/keep-test.sh"
( export ZBUILD_REPO_ROOT="$R"; source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
  _ta_write_result "$A" pass "changed 2 test file(s); acceptance assertions for 2 SPEC(s) from the design contract" 2 ) >/dev/null 2>&1
assert_eq "[S3] test-author names the SPECs it wrote tests for" \
    "tests for LOOP-1, KEEP-1" "$(_first "$A/test-author-summary.md")"
if grep -qF "never from the implementation" "$A/test-author-summary.md" 2>/dev/null; then
    assert_fail "[S3] …and does not repeat its rules" "$(cat "$A/test-author-summary.md")"
else
    assert_pass "[S3] …and does not repeat its rules"
fi

# ── S4 build ─────────────────────────────────────────────────────────────────
s4="$( source "$REPO_ROOT/plugins/agent/build/plugin.sh"
  _build_summary_head_v h pass done_sentinel 11 4 '["core/a.sh","plugins/b.sh"]'; printf '%s\n' "$h"
  _build_summary_head_v h pass done_sentinel 0 0 '[]'; printf '%s\n' "$h"
  _build_summary_head_v h incomplete router_timeout 3 0 '["core/a.sh"]'; printf '%s\n' "$h"
  _build_summary_head_v h pass done_sentinel 1 0 '["docs/a b.md","x,y.sh","q\"z.sh"]'; printf '%s\n' "$h" 2>/dev/null )"
assert_eq "[S4] build names the files it changed" "changed core/a.sh, plugins/b.sh (+11 / -4)" "$(sed -n 1p <<< "$s4")"
assert_eq "[S4] …or that it changed none" "changed no file" "$(sed -n 2p <<< "$s4")"
assert_eq "[S4] …and a try cut off says so" "ran out of time; changed core/a.sh (+3 / -0) so far" "$(sed -n 3p <<< "$s4")"
assert_eq "[S4] …each file named whole, whatever it holds (review on #2479)" \
    'changed docs/a b.md, x,y.sh, q"z.sh (+1 / -0)' "$(sed -n 4p <<< "$s4")"

# ── S5 test ──────────────────────────────────────────────────────────────────
( source "$REPO_ROOT/plugins/tool/test/plugin.sh"
  _test_emit_failures_summary "$A/t-pass.md" pass 0 0 "unit: 7/7 passed" 7
  _test_emit_failures_summary "$A/t-fail.md" fail 2 1 "✗ [D7] x" 5 \
      $'## Failing files\n\n- tests/a-test.sh — ✗ [D7] x\n- tests/b-test.sh — ✗ [R1] y' ) >/dev/null 2>&1
assert_eq "[S5] test says how many passed" "all 7 tests passed" "$(_first "$A/t-pass.md")"
assert_eq "[S5] …or which files failed" "failed: tests/a-test.sh, tests/b-test.sh" "$(_first "$A/t-fail.md")"

# ── S6 review lens ───────────────────────────────────────────────────────────
s6="$( source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
  _rl_summary_head_v h correctness '{"findings":[{"file":"core/x.sh","line":3,"severity":"high","message":"the loop never ends"},{"file":"core/y.sh","severity":"low","message":"a name"}]}'
  printf '%s\n' "$h"
  _rl_summary_head_v h correctness '{"findings":[]}'; printf '%s\n' "$h" 2>/dev/null )"
assert_eq "[S6] a lens names what it found" "found: high: the loop never ends (core/x.sh:3) (and 1 more)" "$(sed -n 1p <<< "$s6")"
assert_eq "[S6] …or that it found nothing" "reviewed the change through the correctness lens: found no problem" "$(sed -n 2p <<< "$s6")"

# ── S7 security lens ─────────────────────────────────────────────────────────
s7="$( source "$REPO_ROOT/plugins/agent/security-lens/plugin.sh"
  _sl_summary_head_v h '[{"file":"core/r.sh","severity":"high","message":"a path is not checked"}]'; printf '%s\n' "$h"
  _sl_summary_head_v h '[]'; printf '%s\n' "$h" 2>/dev/null )"
assert_eq "[S7] the security lens names what it found" "found: high: a path is not checked (core/r.sh)" "$(sed -n 1p <<< "$s7")"
assert_eq "[S7] …or that it found nothing" "reviewed the change for security: found no problem" "$(sed -n 2p <<< "$s7")"

print_test_results
exit $((FAIL > 0))
