#!/usr/bin/env bash
# Guard: an ADR that claims a migration is COMPLETE must be checkable.
#
# ADR-028 §Migration says:
#
#   "All four Pattern-1 stages — plan, review, test_assessment, and
#    security-lens — are migrated to call _llm_envelope_parse --schema-gate in
#    place of their prior extract_first_json_object calls."
#
# Two things were wrong with that sentence. `review-lens` still calls bare
# `extract_first_json_object`, and `test_assessment` was DELETED in #979 — the
# ADR names a stage that has not existed for months as evidence of completeness.
#
# A reader — a person or an agent — takes "all four are migrated" as settled and
# builds on it. That is the failure mode behind this whole issue family: a claim
# nobody can check reads exactly like a claim that is true.
#
# So the claim is made falsifiable. If a stage named here stops using the shared
# parser, or stops existing, this fails and the ADR gets corrected instead of
# quietly becoming fiction.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "ADR migration claims are checkable (#2034)"
setup_test_env "adr-migration-claims"

ADR="$REPO_ROOT/docs/adr/ADR-028-shared-llm-agent-framework.md"
assert_file_exists "SPEC-0: ADR-028 exists" "$ADR"

# ── SPEC-1: a deleted stage is never named without saying it is deleted ────
# The ADR legitimately describes history in which `test_assessment` existed, so
# "the word must not appear" would be the wrong rule — it would force the ADR to
# lie about its own context. The hazard is narrower: a reader meeting the name
# with no indication the stage is gone reads it as current, and the ADR listed
# it among stages whose migration was complete.
#
# So: if the document names a stage that has no plugin directory, it must also
# say, unmissably, that the stage was deleted.
_ghosts=""
for _s in test_assessment; do
    grep -q "$_s" "$ADR" 2>/dev/null || continue
    [[ -d "$REPO_ROOT/plugins/agent/${_s//_/-}" ]] && continue
    grep -qiE "\`?$_s\`? no longer exists|$_s.*(was )?deleted in #979" "$ADR" || _ghosts+="$_s "
done
if [[ -z "$_ghosts" ]]; then
    assert_pass "SPEC-1: deleted stages are named as deleted, not as current"
else
    assert_fail "SPEC-1: deleted stages are named as deleted, not as current" \
        "named with no retirement note: $_ghosts"
fi

# ── SPEC-2: every stage claimed migrated actually uses the shared parser ───
# The claim, checked against the code rather than against itself.
_unmigrated=""
for _s in plan security-lens monitor; do
    _p="$REPO_ROOT/plugins/agent/$_s/plugin.sh"
    [[ -f "$_p" ]] || continue
    grep -qE '_llm_envelope_(parse|classify)' "$_p" || _unmigrated+="$_s "
done
if [[ -z "$_unmigrated" ]]; then
    assert_pass "SPEC-2: every stage claimed migrated uses the shared parser"
else
    assert_fail "SPEC-2: every stage claimed migrated uses the shared parser" \
        "still on the old path: $_unmigrated"
fi

# ── [#2035/SPEC-2]: review-lens/plugin.sh uses _llm_envelope_parse --schema-gate ──
# review-report's migration lives in lib/lenses.sh, checked separately below.
_rl_plugin="$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
if grep -qE '_llm_envelope_parse[^|]*--schema-gate' "$_rl_plugin" 2>/dev/null; then
    assert_pass "[#2035/SPEC-2]: review-lens/plugin.sh uses _llm_envelope_parse --schema-gate"
else
    assert_fail "[#2035/SPEC-2]: review-lens/plugin.sh uses _llm_envelope_parse --schema-gate" \
        "pattern absent in $_rl_plugin"
fi

# ── [#2035/SPEC-3]: review-report/lib/lenses.sh uses _llm_envelope_parse --schema-gate ──
_rr_lenses="$REPO_ROOT/plugins/agent/review-report/lib/lenses.sh"
if grep -qE '_llm_envelope_parse[^|]*--schema-gate' "$_rr_lenses" 2>/dev/null; then
    assert_pass "[#2035/SPEC-3]: review-report/lib/lenses.sh uses _llm_envelope_parse --schema-gate"
else
    assert_fail "[#2035/SPEC-3]: review-report/lib/lenses.sh uses _llm_envelope_parse --schema-gate" \
        "pattern absent in $_rr_lenses"
fi

# ── SPEC-3: a stage NOT migrated is not described as if it were ────────────
# review-lens was the counter-example the ADR got wrong; it has since migrated
# (#1840). This asserts the ADR and the code agree, in whichever direction —
# so a future plugin back on `extract_first_json_object` is not claimed migrated.
# The grep excludes comment-only lines so plugin.sh:394's comment
# ("schema-gated envelope parser replaces bare `extract_first_json_object`")
# does not cause a false classification as un-migrated.
_rl="$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
if [[ -f "$_rl" ]] && grep -qE '^[^#]*extract_first_json_object' "$_rl"; then
    # Not migrated: non-comment code still calls bare extract_first_json_object.
    # The ADR must say so, or say nothing about it being migrated.
    if grep -qE 'All four Pattern-1 stages.*review' "$ADR"; then
        assert_fail "SPEC-3: the ADR does not claim review-lens is migrated" \
            "review-lens still calls extract_first_json_object; the ADR says otherwise"
    else
        assert_pass "SPEC-3: the ADR does not claim review-lens is migrated"
    fi
else
    assert_pass "SPEC-3: review-lens migrated — no stale claim possible"
fi

# ── [#2035/SPEC-1]: ADR-028 has no stale "not migrated" claim for review-lens or review-report ──
# PRs #1840 and #1843 migrated both plugins. The ADR's Amendment v1.2 paragraph
# that described them as not migrated is stale. This assertion fails while that
# paragraph remains, and passes after the ADR is corrected.
# Bold or plain, either order, within one sentence: "review-lens is not migrated",
# "Not migrated: review-lens". The correction note's "described them as not
# migrated was stale" names neither stage in its sentence, so it does not match.
if grep -qiE '(review-lens|review-report)[^.]*(is|are|was|were|remains|stays)[[:space:]]+(\*\*)?not(\*\*)?[[:space:]]+migrat|(\*\*)?not(\*\*)?[[:space:]]+migrat[^.]*(review-lens|review-report)' "$ADR"; then
    assert_fail "[#2035/SPEC-1]: ADR-028 has no stale \"not migrated\" claim for review-lens or review-report" \
        "ADR-028 still describes review-lens or review-report as not migrated"
else
    assert_pass "[#2035/SPEC-1]: ADR-028 has no stale \"not migrated\" claim for review-lens or review-report"
fi

# ── [#2035/SPEC-4]: comment-excluding grep guard ─────────────────────────────
# review-lens/plugin.sh has a comment at plugin.sh:394 that mentions
# extract_first_json_object. A comment-inclusive grep would match it and falsely
# classify review-lens as un-migrated, taking the wrong branch in SPEC-3 above.
# This guard asserts: the comment EXISTS (proving the risk is real) AND no
# non-comment code line uses extract_first_json_object (confirming the
# comment-excluding grep `^[^#]*extract_first_json_object` is the correct test).
_rl_guard="$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
if [[ -f "$_rl_guard" ]]; then
    _has_comment=false
    _has_noncomment=false
    grep -qE '#.*extract_first_json_object' "$_rl_guard" && _has_comment=true
    grep -qE '^[^#]*extract_first_json_object' "$_rl_guard" && _has_noncomment=true
    if $_has_comment && ! $_has_noncomment; then
        assert_pass "[#2035/SPEC-4]: comment-excluding grep (^[^#]*) correctly ignores plugin.sh:394 comment; no non-comment use"
    else
        assert_fail "[#2035/SPEC-4]: comment-excluding grep (^[^#]*) correctly ignores plugin.sh:394 comment; no non-comment use" \
            "comment present: $_has_comment, non-comment code present: $_has_noncomment"
    fi
else
    assert_fail "[#2035/SPEC-4]: comment-excluding grep (^[^#]*) correctly ignores plugin.sh:394 comment; no non-comment use" \
        "$_rl_guard is missing"
fi

# ── [#2035/SPEC-5]: review-lens/plugin.sh uses _llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok ──
_rl_spec5="$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
if grep -q '_llm_envelope_parse.*--schema-gate.*_review_lens_envelope_schema_ok' "$_rl_spec5" 2>/dev/null; then
    assert_pass "[#2035/SPEC-5]: review-lens/plugin.sh uses _llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok"
else
    assert_fail "[#2035/SPEC-5]: review-lens/plugin.sh uses _llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok" \
        "pattern absent in $_rl_spec5"
fi

# ── [#2035/SPEC-6]: review-report/lib/lenses.sh uses _llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok ──
_rr_spec6="$REPO_ROOT/plugins/agent/review-report/lib/lenses.sh"
if grep -q '_llm_envelope_parse.*--schema-gate.*_rr_lens_envelope_schema_ok' "$_rr_spec6" 2>/dev/null; then
    assert_pass "[#2035/SPEC-6]: review-report/lib/lenses.sh uses _llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok"
else
    assert_fail "[#2035/SPEC-6]: review-report/lib/lenses.sh uses _llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok" \
        "pattern absent in $_rr_spec6"
fi

# ── SPEC-4: no live code cites a RETIRED ADR as its authority ──────────────
# llm-agent.sh cited "ADR-022 v2" for envelope validation. ADR-022 is Retired
# (#979) and is about the test_assessment STAGE — a different subject entirely.
# A retired ADR as a citation sends the next reader to a document whose own
# header tells them it no longer applies.
_stale=""
for _adr in $(grep -rlE '^\*\*Status:\*\* Retired' "$REPO_ROOT"/docs/adr/*.md 2>/dev/null); do
    _id="$(basename "$_adr" | grep -oE '^ADR-[0-9]+')"
    [[ -n "$_id" ]] || continue
    if grep -rqE "Per .*$_id|$_id v[0-9]" "$REPO_ROOT"/scripts/lib/*.sh "$REPO_ROOT"/core/*/*.sh 2>/dev/null; then
        _stale+="$_id "
    fi
done
if [[ -z "$_stale" ]]; then
    assert_pass "SPEC-4: no live code cites a retired ADR as authority"
else
    assert_fail "SPEC-4: no live code cites a retired ADR as authority" \
        "cited as authority though Retired: $_stale"
fi

print_test_results
