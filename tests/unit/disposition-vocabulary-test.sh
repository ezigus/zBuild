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
# SPEC-3 [change]: the retry budget is the template's per-stage `retry:`, over the
#   env knob, over the engine default 3; capped at 5.
# SPEC-4 [change]: an attempt whose declared outputs all came back unchanged made
#   no progress, so it is not retried; a changed output, or no record, allows it.
# SPEC-5 [change]: the dispatch loop consults the budget and the progress check,
#   and a halting word stops the cycle through the existing member-terminal path —
#   decided from the word, with no new exit code.
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

# ─── SPEC-3 ──────────────────────────────────────────────────────────────────
print_test_section "SPEC-3: the template owns the retry budget"
# shellcheck source=../../core/pipeline/runner.sh
source "$REPO_ROOT/core/pipeline/runner.sh"
set +e   # runner.sh turns errexit on; every assertion must run
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
YAML
export _TPL_SOURCE_FILE="$TPL"
assert_eq "[SPEC-3] the template's retry: wins" "2" \
    "$(ZBUILD_DISPOSITION_REDISPATCH=4 _runner_retry_budget build 2>/dev/null)"
assert_eq "[SPEC-3] no template value → the env knob" "4" \
    "$(ZBUILD_DISPOSITION_REDISPATCH=4 _runner_retry_budget design 2>/dev/null)"
assert_eq "[SPEC-3] neither → the engine default 3" "3" \
    "$(unset ZBUILD_DISPOSITION_REDISPATCH; _runner_retry_budget design 2>/dev/null)"
assert_eq "[SPEC-3] above the cap clamps to 5" "5" \
    "$(ZBUILD_DISPOSITION_REDISPATCH=99 _runner_retry_budget design 2>/dev/null)"
assert_eq "[SPEC-3] an explicit 0 opts out" "0" \
    "$(ZBUILD_DISPOSITION_REDISPATCH=0 _runner_retry_budget design 2>/dev/null)"
assert_eq "[SPEC-3] a non-number falls back to the default" "3" \
    "$(ZBUILD_DISPOSITION_REDISPATCH=lots _runner_retry_budget design 2>/dev/null)"
assert_eq "[SPEC-3] a negative value is not a number here and falls back" "3" \
    "$(ZBUILD_DISPOSITION_REDISPATCH=-2 _runner_retry_budget design 2>/dev/null)"

# ─── SPEC-4 ──────────────────────────────────────────────────────────────────
print_test_section "SPEC-4: an attempt that changed nothing made no progress"
ART="$TEST_TEMP_DIR/art"
_attempt() {   # <n> <outputs-json>
    mkdir -p "$ART/attempts/build/iter-1-attempt-$1"
    printf '{"stage":"build","cycle_iter":1,"attempt":%s,"outputs":%s}\n' "$1" "$2" \
        > "$ART/attempts/build/iter-1-attempt-$1/attempt.json"
}
if _runner_attempt_made_progress "$ART" build 1 2>/dev/null; then
    assert_pass "[SPEC-4] no attempt record → progress is assumed (retry allowed)"
else
    assert_fail "[SPEC-4] no attempt record → progress is assumed"
fi
_attempt 1 '{"build-summary.json":"changed"}'
if _runner_attempt_made_progress "$ART" build 1 2>/dev/null; then
    assert_pass "[SPEC-4] a changed output is progress"
else
    assert_fail "[SPEC-4] a changed output is progress"
fi
_attempt 2 '{"build-summary.json":"unchanged","build-summary.md":"absent"}'
if _runner_attempt_made_progress "$ART" build 1 2>/dev/null; then
    assert_fail "[SPEC-4] the LATEST attempt changed nothing → no progress" "reported progress"
else
    assert_pass "[SPEC-4] the LATEST attempt changed nothing → no progress"
fi

# ─── SPEC-5 ──────────────────────────────────────────────────────────────────
print_test_section "SPEC-5: the dispatch loop is wired to the budget, the progress check and the halt"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
for _fn in _runner_retry_budget _runner_attempt_made_progress; do
    _hits="$(grep -nE "^[^#]*\b${_fn} \"" "$RUNNER" 2>/dev/null || true)"
    if [[ -n "$_hits" ]]; then
        assert_pass "[SPEC-5] the dispatch loop calls $_fn"
    else
        assert_fail "[SPEC-5] the dispatch loop calls $_fn" "no call site in runner.sh"
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
