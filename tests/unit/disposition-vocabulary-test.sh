#!/usr/bin/env bash
# Tests (#2187): the disposition vocabulary names the CAUSE; the engine maps each
# word to an ACTION; the retry budget comes from the template, not the word.
#
# ADR-054 §6 amended: a word exists when a reader needs to tell the cause apart,
# and many words may share one action. #1849 run 35949629759: every timeout was
# reported `interrupted`, `broken` covered both zBuild defects and a model's bad
# output, and `exhausted` mapped to `escalate`, which nothing implemented.
#
# SPEC-1 [change]: each word maps to its action —
#   complete→proceed; unusable|timed_out|out_of_turns|interrupted→retry;
#   throttled→retry_after_wait; rate_limited|unavailable→halt_unavailable;
#   misconfigured→halt_misconfigured; broken→halt_broken.
# SPEC-2 [change]: `exhausted` is accepted as a temporary alias and RETRIES
#   (it was `escalate`, which had no handler) until the stages migrate.
# SPEC-3 [change]: the retry budget is the template's per-stage `retry:`, else
#   the engine default 1 (#2439; was an env knob, then 3); capped at 5.
# SPEC-4: retired with the on-disk progress lookup (#2439) — the engine reads the
#   try it just made: stage-retry-test.sh R4/R10, attempt-progress-test.sh.
# SPEC-5 [change]: every dispatch consults the budget and the retry decision
#   (plugin_hook_call, #2439), and a halting word stops the cycle through the
#   existing member-terminal path — decided from the word, with no new exit code.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "disposition vocabulary: one word per cause, the template owns the retry budget (#2187)"
setup_test_env "disposition-vocabulary"
_test_cleanup_hook() { cleanup_test_env; }

# shellcheck source=../../core/pipeline/disposition.sh
source "$REPO_ROOT/core/pipeline/disposition.sh"

# ─── SPEC-1 ──────────────────────────────────────────────────────────────────
print_test_section "SPEC-1: each word maps to its action"
while read -r _w _want; do
    [[ -n "$_w" ]] || continue
    assert_eq "[SPEC-1] $_w → $_want" "$_want" "$(disposition_response "$_w" 2>/dev/null || echo UNKNOWN)"
done <<'TABLE'
complete proceed
unusable retry
timed_out retry
out_of_turns retry
interrupted retry
throttled retry_after_wait
rate_limited halt_unavailable
unavailable halt_unavailable
misconfigured halt_misconfigured
broken halt_broken
TABLE
if disposition_halts misconfigured 2>/dev/null; then
    assert_pass "[SPEC-1] misconfigured halts"
else
    assert_fail "[SPEC-1] misconfigured halts" "disposition_halts says it does not"
fi
assert_eq "[SPEC-1] an off-set word is still refused" "UNKNOWN" \
    "$(disposition_response wedged 2>/dev/null || echo UNKNOWN)"

# ─── SPEC-2 ──────────────────────────────────────────────────────────────────
print_test_section "SPEC-2: the temporary alias is gone; unfinished work is one predicate"
assert_eq "[SPEC-2] exhausted is no longer a word (every stage sends the cause)" "UNKNOWN" \
    "$(disposition_response exhausted 2>/dev/null || echo UNKNOWN)"
for _w in timed_out out_of_turns interrupted; do
    if disposition_unfinished "$_w" 2>/dev/null; then assert_pass "[SPEC-2] $_w is unfinished work"
    else assert_fail "[SPEC-2] $_w is unfinished work"; fi
done
for _w in complete unusable throttled broken; do
    if disposition_unfinished "$_w" 2>/dev/null; then assert_fail "[SPEC-2] $_w is not unfinished work"
    else assert_pass "[SPEC-2] $_w is not unfinished work"; fi
done
# ADR-063 §4 (review on PR #2262): `unavailable` ends the run instead of being
# retried, so a cycle never gets to converge on that call's verdict. It is
# therefore not an "unfinished" word — that list is for words the cycle retries.
if disposition_unfinished unavailable 2>/dev/null; then
    assert_fail "[ADR-063 §4] unavailable is not unfinished work (it is not retried)"
else
    assert_pass "[ADR-063 §4] unavailable is not unfinished work (it is not retried)"
fi
assert_eq "[ADR-063 §4] unavailable ends the run (halt_unavailable), so no cycle converges on it" \
    "halt_unavailable" "$(disposition_response unavailable 2>/dev/null || echo UNKNOWN)"

# ─── SPEC-3 ──────────────────────────────────────────────────────────────────
print_test_section "SPEC-3: the template owns the retry budget"
# shellcheck source=../../scripts/lib/stage-retry.sh
source "$REPO_ROOT/scripts/lib/stage-retry.sh"
TPL="$TEST_TEMP_DIR/tpl.yaml"
cat > "$TPL" <<'YAML'
id: t
stages:
  - build
build:
  gate: auto
  retry: 2
design:
  gate: auto
huge:
  retry: 99
none:
  retry: 0
word:
  retry: lots
YAML
export _TPL_SOURCE_FILE="$TPL"
_budget() { local b; stage_retry_budget_v b "$1"; printf '%s' "$b"; }
assert_eq "[SPEC-3] the template's retry: wins" "2" "$(ZBUILD_DISPOSITION_REDISPATCH=4 _budget build)"
assert_eq "[SPEC-3] no template value → the engine default 1 (the env knob is gone)" "1" \
    "$(ZBUILD_DISPOSITION_REDISPATCH=4 _budget design)"
assert_eq "[SPEC-3] above the cap clamps to 5" "5" "$(_budget huge)"
assert_eq "[SPEC-3] an explicit 0 opts out" "0" "$(_budget none)"
assert_eq "[SPEC-3] a non-number falls back to the default" "1" "$(_budget word)"

# ─── SPEC-5 ──────────────────────────────────────────────────────────────────
print_test_section "SPEC-5: every dispatch is wired to the budget, the retry decision and the halt"
LIFECYCLE="$REPO_ROOT/core/plugin-registry/lifecycle.sh"
for _fn in stage_retry_budget_v stage_retry_next; do
    _hits="$(grep -nE "^[^#]*\b${_fn} " "$LIFECYCLE" 2>/dev/null || true)"
    if [[ -n "$_hits" ]]; then
        assert_pass "[SPEC-5] plugin_hook_call calls $_fn"
    else
        assert_fail "[SPEC-5] plugin_hook_call calls $_fn" "no call site in lifecycle.sh"
    fi
done
# No new exit code: the halt is decided from the WORD, in the cycle, and ends
# through the existing member-terminal path.
ORCH="$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
if grep -qE '^[^#]*disposition_halts "' "$ORCH"; then
    assert_pass "[SPEC-5] the cycle stops on a halting word"
else
    assert_fail "[SPEC-5] the cycle stops on a halting word" "no disposition_halts call in cycle-orchestrator.sh"
fi
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$ORCH" 2>/dev/null
set +e
_r="$(_CYCLE_DISPATCH_DISPOSITION=misconfigured _CYCLE_DISPATCH_REASON="no model tier resolved" _cycle_member_halt_reason)"
assert_eq "[SPEC-5] misconfigured halts, naming the word and the reason" "misconfigured: no model tier resolved" "$_r"
_r="$(_CYCLE_DISPATCH_DISPOSITION=broken _CYCLE_DISPATCH_REASON="result_write_failed" _cycle_member_halt_reason)"
assert_eq "[SPEC-5] broken halts too, naming the word and the reason" "broken: result_write_failed" "$_r"
for _w in complete timed_out unusable; do
    if ( _CYCLE_DISPATCH_DISPOSITION="$_w" _cycle_member_halt_reason >/dev/null 2>&1 ); then
        assert_fail "[SPEC-5] $_w does not halt" "it halted"
    else
        assert_pass "[SPEC-5] $_w does not halt"
    fi
done


print_test_results
exit $((FAIL > 0))
