#!/usr/bin/env bash
# Tests: impact plugin output-contract enforcement (#767)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# #908: recovery helper under test (T19) lives in the impact prefilter lib.
source "$REPO_ROOT/scripts/lib/impact-prefilter.sh"

print_test_header "impact prompt contract + parser + forensics (#767)"
setup_test_env "impact-prompt-contract"

# ADR-028 PR 5/5: OUTPUT CONTRACT / FORBIDDEN / FINAL RULE moved into the
# shared llm-agent framework. The plugin sources it; the contract still
# lives in source, just split across two files now. Concatenate for the
# grep-based assertions below.
PROMPT_SOURCES="$(cat "$REPO_ROOT/plugins/agent/impact/plugin.sh" \
                      "$REPO_ROOT/scripts/lib/llm-agent.sh")"
PROMPT_FILE="$(mktemp -t impact-contract-prompt.XXXXXX)"
printf '%s' "$PROMPT_SOURCES" > "$PROMPT_FILE"
trap 'rm -f "$PROMPT_FILE"' EXIT

# T1: prompt strengthening (ADR-028 canonical OUTPUT CONTRACT block).
# Consolidation: CORRECT/INCORRECT examples and the duplicate REMINDER
# ("response begins with") were redundant with FORBIDDEN+FINAL RULE; the
# framework block states each rule exactly once. See PR #807 / ADR-028.
assert_contains "T1: prompt has explicit OUTPUT CONTRACT block" \
    "$(cat "$PROMPT_FILE")" "OUTPUT CONTRACT"
assert_contains "T1: prompt requires first character {" \
    "$(cat "$PROMPT_FILE")" "first output character MUST be"
assert_contains "T1: prompt declares EXACTLY ONE JSON object" \
    "$(cat "$PROMPT_FILE")" "EXACTLY ONE JSON object"
assert_contains "T1: prompt has FINAL RULE preventing postamble" \
    "$(cat "$PROMPT_FILE")" "FINAL RULE"

# T2: parser switched
assert_contains "T2: parser switched to extract_json_and_surrounding_prose" \
    "$(cat "$PROMPT_FILE")" "extract_json_and_surrounding_prose"

# T3: contract violation event registered
# #1717: impact.* belongs to the impact plugin, so the event is declared in its
# own manifest (provides.events) and composed into the engine's known set.
# shellcheck source=../../../../core/event-bus/known-types.sh
source "$REPO_ROOT/core/event-bus/known-types.sh"
assert_contains "T3: impact.contract.violation declared in the impact manifest" \
    "$(eb_manifest_events "$REPO_ROOT/plugins/agent/impact/manifest.yaml")" \
    "impact.contract.violation"
assert_contains "T3b: impact.contract.violation in the composed known set" \
    "$(eb_compose_known_types)" "impact.contract.violation"

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

# ─── #774 prompt hardening: explicit FORBIDDEN list + escape valve ──────────
# Dogfood #754 (run_id 20260610065040-35172) showed 3/3 impact iters fired
# impact.contract.violation with decreasing prose lengths (258→117→113).
# The contract block was directionally correct but the model kept emitting
# the same handful of preamble phrases. Pin them by literal match so the
# prompt explicitly refuses them.

# T6: FORBIDDEN list names each observed prose preamble verbatim.
PROMPT_BODY="$(cat "$PROMPT_FILE")"
for phrase in 'Based on my analysis' "Here is" "Here's" 'After reviewing' "I've identified"; do
    assert_contains "T6: FORBIDDEN list names '$phrase' verbatim" \
        "$PROMPT_BODY" "$phrase"
done

# T7: explicit FORBIDDEN heading present (locks the section so it can't drift
# back to interleaved soft language).
assert_contains "T7: prompt has explicit FORBIDDEN heading" \
    "$PROMPT_BODY" "FORBIDDEN"

# T8: the escape valve still exists, but ADR-060 moves it INSIDE the structured
# envelope. Supporting detail goes in missing[].reason / missing[].evidence --
# never a markdown document in a JSON string (the #1833 shape).
# PROMPT_SOURCES is concatenated SOURCE, so a COMMENT naming the retired field
# is not a declaration — llm-agent.sh explains the #1972 failure by name. Strip
# comment lines before the negative check, as sigpipe-antipattern-guard-test.sh
# does (#1884); a grep over source text cannot otherwise tell the two apart.
_t8_code="$(grep -vE '^[[:space:]]*#' "$PROMPT_FILE" || true)"
case "$_t8_code" in
    *impact_feedback_md*)
        assert_fail "T8: prompt must NOT declare the retired impact_feedback_md field (ADR-060)" ;;
    *)
        assert_pass "T8: prompt no longer declares impact_feedback_md (ADR-060)" ;;
esac
assert_contains "T8: prompt directs supporting detail into missing[].evidence" \
    "$PROMPT_BODY" "evidence"
assert_contains "T8: prompt explicitly forbids prose AROUND the envelope" \
    "$PROMPT_BODY" "before, after, or around"

# T9: defensive parser kept in place — #771 recovery still load-bearing at
# any prompt-quality level. Regression guard against accidentally removing
# the safety net when the preventive path is hardened.
assert_contains "T9: extract_json_and_surrounding_prose still in plugin (#771 safety net)" \
    "$PROMPT_BODY" "extract_json_and_surrounding_prose"

# ─── #783 postamble FORBIDDEN — model emits banned phrases AFTER `}` ────────
# Wave 2 dogfood (run_id 20260610184141-48161) impact iter 2 emitted clean
# JSON but appended "Based on my comprehensive analysis..." and "I've
# identified..." AFTER the closing brace. PR #779's FORBIDDEN list catches
# preamble; this issue extends it to postamble + adds FINAL RULE sentinel.

PROMPT_BODY_783="$(cat "$PROMPT_FILE")"

# T10: FINAL RULE sentence — last instruction the model reads before PLAN:.
assert_contains "T10: prompt has FINAL RULE sentinel" \
    "$PROMPT_BODY_783" "FINAL RULE"
assert_contains "T10: FINAL RULE says 'ends at' or 'output NOTHING'" \
    "$PROMPT_BODY_783" "output NOTHING"

# T11: extended FORBIDDEN list names the iter-2 observed variants.
for variant in 'Based on my comprehensive analysis' 'Now I have' 'Let me' 'I have all the information'; do
    assert_contains "T11: FORBIDDEN names '$variant' verbatim" \
        "$PROMPT_BODY_783" "$variant"
done

# T12: explicit PREFIX/POSTFIX or "before AND after" emphasis — the model
# must read the rule as bidirectional, not "don't START with".
case "$PROMPT_BODY_783" in
    *"AFTER"*|*"postamble"*|*"after the JSON"*)
        assert_pass "T12: prompt explicitly names POSTAMBLE / 'after the JSON'" ;;
    *)
        assert_fail "T12: prompt must explicitly name AFTER/postamble" ;;
esac

# T13: parser still in place — defensive recovery from #771/#774 is the
# safety net at any prompt-quality level (regression guard).
assert_contains "T13: extract_json_and_surrounding_prose still present (#771 safety net)" \
    "$PROMPT_BODY_783" "extract_json_and_surrounding_prose"

# ─── #911: charter mandate — existence verification before files_to_add ──────
# Regression guard: if the charter rule is removed from _impact_instructions,
# the LLM loses the explicit prohibition on hallucinated paths.

PROMPT_BODY_911="$(cat "$PROMPT_FILE")"

# T14: explicit EXISTENCE VERIFICATION heading present.
assert_contains "T14: charter has EXISTENCE VERIFICATION heading" \
    "$PROMPT_BODY_911" "EXISTENCE VERIFICATION"

# T15: prohibition on unverifiable paths — the key rule.
assert_contains "T15: charter prohibits listing paths not verified present" \
    "$PROMPT_BODY_911" "NEVER list a path you cannot verify"

# T16: directive to use Read or Grep to confirm existence first.
assert_contains "T16: charter requires existence confirmation via Read/Grep" \
    "$PROMPT_BODY_911" "confirm the file exists"

# ─── #936: relevance / adjacency charter (reduces reference-closure over-scope) ─
PROMPT_BODY_936="$(cat "$REPO_ROOT/plugins/agent/impact/plugin.sh")"
assert_contains "T_936a: charter has RELEVANCE mandate (cite the changed reference)" \
    "$PROMPT_BODY_936" "a file is a scope gap ONLY if it references"
assert_contains "T_936b: charter excludes topical/directory ADJACENCY" \
    "$PROMPT_BODY_936" "ADJACENCY IS NOT A GAP"
assert_contains "T_936c: charter forbids chasing the reference closure" \
    "$PROMPT_BODY_936" "Do NOT chase transitive references"

# ─── #908: BUDGET DISCIPLINE restatement of postamble prohibition ─────────────
# Three consecutive dogfood runs showed the model emitting correct JSON then
# appending prose commentary or a stray ```json fence after `}`. The FINAL RULE
# lives in llm-agent.sh (shared framework) but the BUDGET DISCIPLINE block —
# which the model reads last, under budget pressure — previously had no
# restatement. T17 checks plugin.sh ALONE so it fails at baseline and proves
# the sentence lives in the same closing-budget context.

PLUGIN_SH_BODY="$(cat "$REPO_ROOT/plugins/agent/impact/plugin.sh")"

# T17: BUDGET DISCIPLINE block in plugin.sh restates the postamble prohibition.
assert_contains "[SPEC-1] T17: BUDGET DISCIPLINE in plugin.sh restates postamble prohibition (output NOTHING)" \
    "$PLUGIN_SH_BODY" "output NOTHING"

# ─── #908: functional parser assertion — dogfood-observed trailing-prose pattern ─
# T18: feed the exact pattern observed in three consecutive dogfood runs
# (valid JSON envelope + forbidden phrase + stray ```json fence) through the
# parser and assert the JSON part is valid schema_version-1 and the stray
# material ends up in the prose sidecar.  This closes the gap between X4
# (generic postamble) and a test that specifically covers the impact
# contract-violation event path (prose_length > 0, json valid).

t18_raw='{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":"ok"}
Based on my comprehensive analysis, the changes look good.
```json'

t18_out="$(printf '%s' "$t18_raw" | extract_json_and_surrounding_prose 2>/dev/null)"
t18_json="$(awk '/^__JSON__$/{j=1;next} j' <<<"$t18_out")"
t18_prose="$(awk '/^__PROSE__$/{p=1;next} /^__JSON__$/{p=0;next} p' <<<"$t18_out")"

# [SPEC-2] JSON part must be a valid schema_version-1 object
if printf '%s' "$t18_json" | jq -e 'type=="object" and .schema_version==1' >/dev/null 2>&1; then
    assert_pass "T18: extracted JSON is valid schema_version-1 object"
else
    assert_fail "T18: extracted JSON is valid schema_version-1 object" "$t18_json"
fi

# [SPEC-2] prose sidecar must be non-empty (stray material captured, not lost)
t18_prose_trimmed="$(printf '%s' "$t18_prose" | tr -d '[:space:]')"
if [ -n "$t18_prose_trimmed" ]; then
    assert_pass "T18: prose sidecar is non-empty (stray postamble captured)"
else
    assert_fail "T18: prose sidecar is non-empty (stray postamble captured)" "(empty)"
fi

# ─── #908: T19 [SPEC-2] — schema-aware recovery beats LAST-wins on a
# brace-bearing postamble. The genuine envelope is emitted FIRST; the model then
# appends a postamble carrying its OWN {...}. extract_json_and_surrounding_prose
# is LAST-wins (#478) so it returns the POSTAMBLE object → schema gate fails →
# empty impact iteration (#908). _impact_recover_envelope_json re-selects the
# FIRST schema-valid envelope. Fails at merge-base (helper absent); passes after.
# [SPEC-2] is reassigned here from the tautological/orphan T18 (which only
# exercised the shared parser on a postamble with no balanced object).
t19_raw='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1","files_to_add":["x"],"reason":"r"}],"impact_feedback_md":"add x"}
Based on my analysis: {"note":"the changes look complete"}'

# Motivation guard: the SHARED parser is LAST-wins and misselects the postamble.
t19_shared="$(printf '%s' "$t19_raw" | extract_json_and_surrounding_prose 2>/dev/null | awk '/^__JSON__$/{j=1;next} j')"
if printf '%s' "$t19_shared" | jq -e '.schema_version==1' >/dev/null 2>&1; then
    assert_fail "T19: shared parser is LAST-wins and misselects the postamble (motivation)" "$t19_shared"
else
    assert_pass "T19: shared parser misselects the postamble (LAST-wins), recovery needed"
fi

# Recovery: the FIRST schema-valid envelope is returned; verdict reads from it.
t19_recovered="$(_impact_recover_envelope_json "$t19_raw" 2>/dev/null || true)"
assert_eq "[SPEC-2] T19: recovery selects the genuine schema_version envelope" \
    "1" "$(printf '%s' "$t19_recovered" | jq -r '.schema_version' 2>/dev/null)"
assert_eq "[SPEC-2] T19: recovered verdict reads from the genuine envelope" \
    "incomplete" "$(printf '%s' "$t19_recovered" | jq -r '.verdict' 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
