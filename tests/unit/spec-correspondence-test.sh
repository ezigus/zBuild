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

# ─── [#2108] a model that drains stdin does not eat the SPEC roster ──────────
# `claude -p` reads a non-TTY stdin into its prompt (verified). The plugin
# calls route_to_model from inside `while read sid … < <(acceptance_list_spec_ids)`,
# so without `</dev/null` at the call the FIRST call swallows SPEC-2..N: one
# judgment, N-1 ids in the model's prompt, and a verdict written over 1 SPEC.
_SC3="$TEST_TEMP_DIR/run3"; _A3="$_SC3/artifacts"; _R3="$_SC3/repo"
mkdir -p "$_A3" "$_R3/tests"
export ZBUILD_REPO_ROOT="$_R3" ZBUILD_ARTIFACT_DIR="$_A3"
for n in 1 2 3; do
    printf 'assert_pass "[SPEC-%s] thing %s holds"\n' "$n" "$n" >> "$_R3/tests/acc-test.sh"
done
cat > "$_A3/design.md" <<'EOF'
# Design
```acceptance
SPEC-1[change]: thing 1 holds
SPEC-2[change]: thing 2 holds
SPEC-3[change]: thing 3 holds
TESTFILES:
SPEC-1: tests/acc-test.sh
SPEC-2: tests/acc-test.sh
SPEC-3: tests/acc-test.sh
WIRING: scripts/thing.sh
```
EOF
printf '{}' > "$_SC3/pipeline-state.json"
_SC_CALLS="$TEST_TEMP_DIR/calls3"; : > "$_SC_CALLS"
route_to_model() { cat >/dev/null; printf 'x\n' >> "$_SC_CALLS"; printf '%s' "$_SC_REPLY"; return 0; }
set +e; spec_correspondence_run "spec-correspondence" "$_SC3/pipeline-state.json" >/dev/null 2>&1; set -e
# #2143: one batched call first; a reply without SPEC-n prefixes judges
# nothing, so the per-SPEC fallback runs for each — 1 + 3 calls, every one
# with </dev/null (the #2108 property this section pins).
assert_eq "[#2108] a stdin-draining model still leaves every SPEC judged (1 batch + 3 fallback calls)" \
    "4" "$(wc -l < "$_SC_CALLS" | tr -d ' ')"
assert_contains "[#2108] the stage judged all 3 SPECs" \
    "$(cat "$_A3/spec-correspondence-summary.md" 2>/dev/null || true)" "judged 3 SPEC(s)"

# ─── #2129: no SPEC ids → uncheckable, never "corresponds" ───────────────────
# n=0 fell through the worst-wins ladder to `corresponds` — a gate that judged
# nothing reporting that everything corresponds.
_SC4="$TEST_TEMP_DIR/run4"; _A4="$_SC4/artifacts"; _R4="$_SC4/repo"
mkdir -p "$_A4" "$_R4/tests"
export ZBUILD_REPO_ROOT="$_R4" ZBUILD_ARTIFACT_DIR="$_A4"
cat > "$_A4/design.md" <<'EOF'
# Design
```acceptance
TESTFILES:
tests/acc-test.sh
```
EOF
printf 'diff --git a/x b/x\n+y\n' > "$_A4/diff.patch"
printf '{"verdict":"pass","files_changed_count":1}' > "$_A4/build-summary.json"
printf '{}' > "$_SC4/pipeline-state.json"
set +e; spec_correspondence_run "spec-correspondence" "$_SC4/pipeline-state.json" >/dev/null 2>&1; set -e
assert_eq "[#2129] zero SPEC ids → verdict=uncheckable" "uncheckable" \
    "$(jq -r '.verdict // ""' "$_A4/spec-correspondence-result.json" 2>/dev/null || true)"
assert_contains "[#2129] the reason says nothing was judged" \
    "$(jq -r '.reason // ""' "$_A4/spec-correspondence-result.json" 2>/dev/null || true)" "no SPEC ids"

# ─── #2143: one batched call, then a stage clock ─────────────────────────────
# Run 35412141973: 19 SPECs = 19 serial model calls, each with its own 600 s
# budget; 13 took ~35 s, 6 took 4–10 min, one was killed — 53 minutes on the
# critical path of one iteration, for an advisory stage.
print_test_section "#2143: batched judging + stage clock"
export ZBUILD_REPO_ROOT="$_R3" ZBUILD_ARTIFACT_DIR="$_A3"
: > "$_SC_CALLS"; _SC_PROMPT_B="$TEST_TEMP_DIR/prompt-batch.txt"; : > "$_SC_PROMPT_B"
_SC_BATCH_REPLY='SPEC-1: VERDICT: corresponds | REASON: exactly the property
SPEC-2: VERDICT: partial | REASON: one case of several
SPEC-3: VERDICT: corresponds | REASON: exactly the property'
route_to_model() { cat >/dev/null; printf 'x\n' >> "$_SC_CALLS"; printf '%s' "$2" >> "$_SC_PROMPT_B"; printf '%s' "$_SC_BATCH_REPLY"; return 0; }
set +e; spec_correspondence_run "spec-correspondence" "$_SC3/pipeline-state.json" >/dev/null 2>&1; set -e
assert_eq "[#2143] all 3 SPECs are judged in ONE model call" "1" "$(wc -l < "$_SC_CALLS" | tr -d ' ')"
for _id in SPEC-1 SPEC-2 SPEC-3; do
    assert_contains "[#2143] the batch prompt carries every SPEC id ($_id as a section heading)" "$(cat "$_SC_PROMPT_B")" "### $_id"
done
assert_contains "[#2143] the prompt asks for the heading's identifier on each answer line" "$(cat "$_SC_PROMPT_B")" "identifier from its \`###\` heading"
assert_contains "[#2143] …and every requirement text" "$(cat "$_SC_PROMPT_B")" "thing 2 holds"
assert_contains "[#2143] the tally reflects the batched verdicts" \
    "$(cat "$_A3/spec-correspondence-summary.md" 2>/dev/null || true)" "2 correspond, 1 partial"
# Stage clock: a slow model (2 s/call) and a junk batch reply → the per-SPEC
# fallback would take 6 s more; a 3 s stage clock stops it with the rest unjudged.
: > "$_SC_CALLS"
route_to_model() { cat >/dev/null; printf 'x\n' >> "$_SC_CALLS"; sleep 2; printf 'no verdict here'; return 0; }
# #2191-class flake: this asserted wall-clock time (<= 6 s), which a loaded CI
# runner breaks. What the clock must DO is asserted below instead: the fallback
# stops early (few calls) and the rest is left unjudged, not invented.
set +e; ZBUILD_SPEC_CORRESPONDENCE_STAGE_TIMEOUT_S=3 spec_correspondence_run "spec-correspondence" "$_SC3/pipeline-state.json" >/dev/null 2>&1; set -e
assert_contains "[#2143] SPECs the clock cut off are unjudged, not invented" \
    "$(cat "$_A3/spec-correspondence-summary.md" 2>/dev/null || true)" "unjudged"
if [[ "$(wc -l < "$_SC_CALLS" | tr -d ' ')" -le 2 ]]; then assert_pass "[#2143] at most the batch + one fallback call before the clock"; else assert_fail "[#2143] too many calls under the clock" "$(wc -l < "$_SC_CALLS")"; fi

print_test_results
exit $((FAIL > 0))
