#!/usr/bin/env bash
# tests/unit/spec-correspondence-test.sh — does the assertion test what the SPEC
# SAYS? (#2034)
#
# #2022 made the code and the assertion two independent readings, so a
# disagreement between them fails a test. This is the link above that, and the
# one execution cannot reach: a passing test proves the implementation satisfies
# the ASSERTION, never that the assertion satisfies the SENTENCE.
#
# Measured before it was built. Over a corpus of merged pairs plus planted
# inversions, a three-word vocabulary caught 3/3 inversions but called 6/15
# merged pairs `mismatch` — because it had nowhere to put "tests the right
# property, but narrower than promised". Adding `partial` took false mismatches
# to 0/15 with no true positive lost. The vocabulary was the defect.
#
#   SPEC-1 [change]: the prompt carries the SPEC requirement TEXT and the
#                    assertion source
#   SPEC-2 [guard] : and carries NO implementation — no diff, no build summary.
#                    Placement makes this true (build has not run yet); the
#                    assertion pins it so a later edit cannot quietly undo it
#   SPEC-3 [change]: `partial` is in the declared vocabulary — without it the
#                    judge must call narrow-but-correct coverage a mismatch
#   SPEC-4 [guard] : advisory — never in an exit_when, so it cannot gate
#                    (ADR-040 §5: only a mechanical stage may block)
#   SPEC-5 [guard] : v2 contract — result_contract:2, rc binary, and a stage
#                    that merely FINDS a problem is disposition:complete
#   SPEC-7 [change]: a reply with no parseable verdict is COUNTED, not silently
#                    dropped — the counters ACCOUNT FOR every SPEC judged, so
#                    `judged N` and the four (now five) numbers agree
#   SPEC-8 [change]: and zero successful judgments over a non-zero SPEC set is
#                    NOT a pass. `worst` began at the passing word and was only
#                    ever escalated by a non-zero counter, so eight junk replies
#                    incremented nothing and the stage wrote a complete pass
#                    (#2062; run 33944161764 shipped exactly that artifact)
#   SPEC-6 [change]: the QA persona's perspective REACHES the prompt, and the
#                    template BINDS it. #1627 recorded that personas are
#                    consumed only by review lenses and that no template carries
#                    a persona: key — so a persona manifest that nothing
#                    resolves is decoration, the "green-but-inert" shape #1628
#                    names. Asserted so it cannot silently go inert again
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "spec-correspondence: the assertion vs the sentence (#2034)"
setup_test_env "spec-correspondence"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
# shellcheck source=../../scripts/lib/persona-resolve.sh
source "$REPO_ROOT/scripts/lib/persona-resolve.sh" 2>/dev/null || true
# shellcheck source=../../core/plugin-registry/persona.sh
source "$REPO_ROOT/core/plugin-registry/persona.sh" 2>/dev/null || true
export ZBUILD_SPEC_CORRESPONDENCE_PERSONA="quality-assurance"

_SC_PROMPT="$TEST_TEMP_DIR/prompt.txt"
_SC_REPLY='VERDICT: corresponds
REASON: the assertion checks exactly the property the requirement names'
# shellcheck source=../../plugins/agent/spec-correspondence/plugin.sh
source "$REPO_ROOT/plugins/agent/spec-correspondence/plugin.sh"

# Stubbed AFTER the plugin loads, not before: as of #2062 the plugin sources
# core/router/route.sh itself, which would overwrite a stub defined ahead of it
# and send this unit test at a real model. Same ordering every build/design unit
# test uses (e.g. tests/unit/build-acceptance-charter-test.sh:33-37).
route_to_model() { printf '%s' "$2" >> "$_SC_PROMPT"; printf '%s' "$_SC_REPLY"; return 0; }
resolve_tier() { printf 'T2'; }

_S="$TEST_TEMP_DIR/run"; _A="$_S/artifacts"; _R="$_S/repo"
mkdir -p "$_A" "$_R/tests"
export ZBUILD_REPO_ROOT="$_R" ZBUILD_ARTIFACT_DIR="$_A"
cat > "$_R/tests/acc-test.sh" <<'FIX'
if grep -q 'data' "$OUT"; then
    assert_pass "[SPEC-1] fields are nested under data"
else
    assert_fail "[SPEC-1] fields are not nested"
fi
FIX
cat > "$_A/design.md" <<'EOF'
# Design
```acceptance
SPEC-1[change]: plugin-specific fields live under data:{} not at the top level
TESTFILES:
SPEC-1: tests/acc-test.sh
WIRING: scripts/thing.sh
```
EOF
printf 'diff --git a/x b/x\n+top level exit_code\n' > "$_A/diff.patch"
printf '{"verdict":"pass","files_changed_count":9}' > "$_A/build-summary.json"
printf '{}' > "$_S/pipeline-state.json"
: > "$_SC_PROMPT"

set +e; spec_correspondence_run "spec-correspondence" "$_S/pipeline-state.json"; _rc=$?; set -e
_P="$(cat "$_SC_PROMPT" 2>/dev/null || true)"
_judged_event="$(jq -c 'select(.type == "spec_correspondence.judged")' "$ZBUILD_EVENTS_JSONL" | tail -n 1)"
assert_eq "[SPEC-7][change] judged event carries the total SPEC count" \
    "1" "$(jq -r '.data.specs // "MISSING"' <<< "$_judged_event")"
for _pair in corresponds:1 partial:0 mismatch:0 uncheckable:0 unjudged:0; do
    _counter="${_pair%%:*}"
    _expected="${_pair##*:}"
    assert_eq "[SPEC-7][change] judged event carries $_counter counter" \
        "$_expected" "$(jq -r --arg k "$_counter" '.data[$k] // "MISSING"' <<< "$_judged_event")"
done
assert_eq "[SPEC-7][change] judged event counters sum to specs" \
    "1" "$(jq -r '[.data.corresponds, .data.partial, .data.mismatch, .data.uncheckable, .data.unjudged] | map(tonumber) | add' <<< "$_judged_event")"
_res() { jq -r "$1" "$_A/spec-correspondence-result.json" 2>/dev/null || echo MISSING; }

assert_contains "[SPEC-1][change] the prompt carries the requirement TEXT" \
    "$_P" "fields live under data:{} not at the top level"
assert_contains "[SPEC-1][change] and the assertion source" \
    "$_P" "fields are nested under data"
assert_eq "[SPEC-2][guard] the prompt carries NO diff" \
    "0" "$(grep -c 'diff --git' <<< "$_P" || true)"
assert_eq "[SPEC-2][guard] nor the build summary" \
    "0" "$(grep -c 'files_changed_count' <<< "$_P" || true)"
assert_contains "[SPEC-3][change] partial is offered as a verdict" "$_P" "partial"
assert_eq "[SPEC-5][guard] result_contract is 2" "2" "$(_res '.result_contract')"
assert_eq "[SPEC-5][guard] rc is binary" "0" "$_rc"
assert_eq "[SPEC-5][guard] a stage that merely reports is disposition=complete" \
    "complete" "$(_res '.disposition')"

# ── SPEC-3: the declared vocabulary carries all four words ──────────────────
_MAN="$REPO_ROOT/plugins/agent/spec-correspondence/manifest.yaml"
for _w in corresponds partial mismatch uncheckable; do
    assert_contains "[SPEC-3][change] valid_verdicts declares '$_w'" \
        "$(sed -n '/valid_verdicts:/,/^[a-z]/p' "$_MAN")" "$_w"
done

# ── SPEC-4: advisory, and not on any convergence path ──────────────────────
assert_contains "[SPEC-4][guard] the manifest marks it advisory" \
    "$(cat "$_MAN")" "convergence: advisory"
assert_eq "[SPEC-4][guard] no exit_when in any template names it" \
    "0" "$(grep -rl 'spec-correspondence' "$REPO_ROOT/config/templates/" 2>/dev/null \
           | xargs -I{} grep -A4 'exit_when:' {} 2>/dev/null \
           | grep -c 'spec-correspondence' || true)"

# ── SPEC-6: the persona is resolved and reaches the prompt ─────────────────
assert_contains "[SPEC-6][change] the QA persona's perspective reaches the prompt" \
    "$_P" "You assure traceability, you do not test"

# ── SPEC-6: and the TEMPLATE binds it, so it is not inert in a real run ────
assert_contains "[SPEC-6][change] simple.yaml binds the persona to the stage" \
    "$(sed -n '/^spec-correspondence:/,/^$/p' "$REPO_ROOT/config/templates/simple.yaml")" \
    "persona: quality-assurance"

# ── SPEC-7/8: a router that answers, but never intelligibly ────────────────
# Independent of the missing-router defect (#2062 A): these are junk replies
# from a live model, not an absent call. Three SPECs so "the counters sum to n"
# is a real arithmetic check rather than a 1-vs-0 coincidence.
route_to_model() { printf 'I am afraid I cannot help with that.'; return 0; }

_S2="$TEST_TEMP_DIR/run-unparseable"; _A2="$_S2/artifacts"; _R2="$_S2/repo"
mkdir -p "$_A2" "$_R2/tests"
export ZBUILD_REPO_ROOT="$_R2" ZBUILD_ARTIFACT_DIR="$_A2"
cat > "$_R2/tests/junk-test.sh" <<'FIX2'
assert_eq "[SPEC-1] the header names the run" "$(hdr)" "run"
assert_eq "[SPEC-2] the footer names the tally" "$(ftr)" "tally"
assert_eq "[SPEC-3] the body names the verdict" "$(body)" "verdict"
FIX2
cat > "$_A2/design.md" <<'EOF'
# Design
```acceptance
SPEC-1[change]: the rendered header names the run
SPEC-2[change]: the rendered footer names the tally
SPEC-3[change]: the rendered body names the verdict
TESTFILES:
SPEC-1: tests/junk-test.sh
SPEC-2: tests/junk-test.sh
SPEC-3: tests/junk-test.sh
WIRING: scripts/render.sh
```
EOF
printf '{}' > "$_S2/pipeline-state.json"

set +e; spec_correspondence_run "spec-correspondence" "$_S2/pipeline-state.json"; set -e
_res2() { jq -r "$1" "$_A2/spec-correspondence-result.json" 2>/dev/null || echo MISSING; }

# The stage's own claim about how many it judged, read back from its reason line.
_judged="$(_res2 '.reason' | sed -n 's/^judged \([0-9][0-9]*\) SPEC(s).*/\1/p')"
assert_eq "[SPEC-7][change] all three SPECs were judged" "3" "${_judged:-NONE}"
assert_eq "[SPEC-7][change] the counters account for every SPEC judged" \
    "$_judged" "$(_res2 '[.data | to_entries[] | .value] | add')"

# Asserted through the engine's own reader, not against a literal word: what
# must not happen is a GREEN indicator, and verdict_classify is what decides
# that. It also pins the word into the classify table, which #1708's lint
# (scripts/lib/lint-verdict-classify.sh) requires of every declared verdict.
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh" 2>/dev/null || true
_cls2="$(verdict_classify "$(_res2 '.verdict')" 2>/dev/null || echo NO-CLASSIFIER)"
assert_eq "[SPEC-8][change] zero successful judgments does not classify as a pass" \
    "not-pass" "$([[ "$_cls2" == "pass" ]] && printf 'pass' || printf 'not-pass')"
assert_eq "[SPEC-8][change] and the word it writes is one the engine classifies" \
    "classified" "$([[ "$_cls2" == "unknown" || "$_cls2" == "NO-CLASSIFIER" ]] \
        && printf '%s' "$_cls2" || printf 'classified')"

print_test_results
exit $((FAIL > 0))
