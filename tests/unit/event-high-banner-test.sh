#!/usr/bin/env bash
# Tests: core/output/event-banners.sh — operator-visible WARN banner for
# HIGH-severity cycle events (issue #526, amends ADR-021 §Fail-loud).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "event-banners — HIGH cycle banner emitter (#526)"
setup_test_env "event-high-banner"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/output/event-banners.sh"

# ─── T1: HIGH event emits a single-line WARN banner with ⚠ + type + k=v ──────
out="$(_emit_high_event_banner "cycle.feedback.missing" \
        "iter_next=2" "from_stage=test" "to_field=summary" "src=/tmp/x" 2>&1 >/dev/null)"
assert_contains "banner contains ⚠ glyph" "$out" "⚠"
assert_contains "banner contains event type verbatim" "$out" "cycle.feedback.missing"
assert_contains "banner contains k=v iter_next" "$out" "iter_next=2"
assert_contains "banner contains k=v from_stage" "$out" "from_stage=test"
assert_contains "banner contains src path" "$out" "src=/tmp/x"
# Count embedded newlines. `$(...)` strips the trailing newline, so a single
# line of banner output yields wc -l == 0. Anything > 0 means we got >1 line.
nlines="$(printf '%s' "$out" | wc -l | tr -d ' ')"
assert_eq "banner is single line (no embedded newlines)" "0" "$nlines"

# ─── T2: non-HIGH event types produce no banner ──────────────────────────────
out2="$(_emit_high_event_banner "cycle.plateau.skipped" "iter=2" 2>&1 >/dev/null)"
assert_eq "non-HIGH event → empty stderr (no banner)" "" "$out2"
out3="$(_emit_high_event_banner "cycle.iteration.complete" "iter=1" 2>&1 >/dev/null)"
assert_eq "informational event → empty stderr (no banner)" "" "$out3"

# ─── T3: NO_COLOR=1 strips ANSI escapes but keeps ⚠ glyph ────────────────────
out4="$(NO_COLOR=1 bash -c "
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$REPO_ROOT/core/output/event-banners.sh'
    _emit_high_event_banner 'cycle.config.invalid' 'reason=bad' 2>&1 >/dev/null
")"
assert_contains "NO_COLOR keeps ⚠ glyph" "$out4" "⚠"
assert_contains "NO_COLOR keeps event type" "$out4" "cycle.config.invalid"
if grep -qF $'\033[' <<< "$out4"; then
    assert_fail "NO_COLOR strips ANSI escapes" "found \\033[ in output"
else
    assert_pass "NO_COLOR strips ANSI escapes"
fi

# ─── T4: closed-stderr does NOT abort the helper ─────────────────────────────
set +e
( _emit_high_event_banner "cycle.history.lost" "iter=3" "reason=test" ) 2>&-
rc=$?
set -e
assert_eq "closed stderr → rc=0 (no abort)" "0" "$rc"

# ─── T5: all 5 HIGH event types are recognized ───────────────────────────────
for ev in cycle.feedback.missing cycle.config.invalid \
          cycle.iteration.verdict_missing cycle.history.lost cycle.metric.invalid; do
    bout="$(_emit_high_event_banner "$ev" "k=v" 2>&1 >/dev/null)"
    assert_contains "HIGH event $ev produces banner" "$bout" "$ev"
done

# ─── T6: cycle.feedback.absent is NOT a HIGH event — no banner (SPEC-4 guard) ──
out_absent="$(_emit_high_event_banner "cycle.feedback.absent" "src=/tmp/x" 2>&1 >/dev/null)"
assert_eq "[SPEC-4] cycle.feedback.absent is not HIGH → no banner emitted" "" "$out_absent"

# ─── T7: indent is two spaces (nests under cycle divider) ────────────────────
out6="$(_emit_high_event_banner "cycle.metric.invalid" "metric=foo" 2>&1 >/dev/null)"
# Strip ANSI to inspect the leading whitespace.
clean="$(printf '%s' "$out6" | sed $'s/\033\\[[0-9;]*m//g')"
if [[ "$clean" =~ ^"  "⚠ ]]; then
    assert_pass "banner is two-space indented"
else
    assert_fail "banner is two-space indented" "got: [$clean]"
fi

print_test_results
