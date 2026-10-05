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

# ── SPEC-2 [#2035/SPEC-2] [#2035/SPEC-3]: every stage claimed migrated uses the shared parser ───
# The claim, checked against the code rather than against itself.
# plan/security-lens/monitor use _llm_envelope_classify; review-lens and review-report
# use _llm_envelope_parse --schema-gate. Expanded (#2035) to include review-lens and
# review-report: these plugins were migrated in #1840/#1843 but were missing from this
# loop. For review-lens and review-report the search covers all non-test .sh files under
# the plugin dir, since review-report's migration lives in lib/lenses.sh, not plugin.sh.
# The grep for review-lens/review-report checks --schema-gate specifically, not just any
# envelope call, so a bare _llm_envelope_parse without --schema-gate would still fail [#2035].
_unmigrated=""
for _s in plan security-lens monitor; do
    _p="$REPO_ROOT/plugins/agent/$_s/plugin.sh"
    [[ -f "$_p" ]] || continue
    grep -qE '_llm_envelope_(parse|classify)' "$_p" || _unmigrated+="$_s "
done
for _s in review-lens review-report; do
    _dir="$REPO_ROOT/plugins/agent/$_s"
    if [[ -d "$_dir" ]]; then
        _2035_found=""
        while IFS= read -r -d '' _f; do
            grep -qE '_llm_envelope_parse.*--schema-gate' "$_f" && _2035_found=1 && break
        done < <(find "$_dir" -name '*.sh' ! -path '*/tests/*' -print0)
        [[ -n "$_2035_found" ]] || _unmigrated+="$_s "
    fi
done
if [[ -z "$_unmigrated" ]]; then
    assert_pass "SPEC-2 [#2035/SPEC-2] [#2035/SPEC-3]: every stage claimed migrated uses _llm_envelope_parse --schema-gate"
else
    assert_fail "SPEC-2 [#2035/SPEC-2] [#2035/SPEC-3]: every stage claimed migrated uses _llm_envelope_parse --schema-gate" \
        "still on the old path or missing --schema-gate: $_unmigrated"
fi

# ── SPEC-3: a stage NOT migrated is not described as if it were ────────────
# The grep now excludes comment-only lines [#2035/SPEC-4]: a comment at
# plugin.sh:394 ("schema-gated envelope parser replaces bare
# extract_first_json_object") would otherwise match and send SPEC-3 into the
# "not migrated" branch, causing a false pass against the old stale ADR text.
_rl="$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
if [[ -f "$_rl" ]] && grep -qE '^[^#]*extract_first_json_object' "$_rl"; then
    # Not migrated. The ADR must say so, or say nothing.
    if grep -qE 'All four Pattern-1 stages.*review' "$ADR"; then
        assert_fail "SPEC-3: the ADR does not claim review-lens is migrated" \
            "review-lens still calls extract_first_json_object; the ADR says otherwise"
    else
        assert_pass "SPEC-3: the ADR does not claim review-lens is migrated"
    fi
else
    assert_pass "SPEC-3: review-lens migrated — no stale claim possible"
fi

# ── [#2035/SPEC-1]: ADR-028 contains no stale "not migrated" claim ──────────
# Fails when the ADR still says review-lens or review-report are **not** migrated
# (e.g. "review-lens and review-report are **not** migrated"); passes once the
# §Migration paragraph is corrected in the same PR (#2035).
_2035_s1_stale=""
for _s in review-lens review-report; do
    if grep -qE "${_s}[^.]*\*\*not\*\*[^.]*migrated|\*\*not\*\*[^.]*migrated[^.]*${_s}" \
            "$ADR" 2>/dev/null; then
        _2035_s1_stale+="$_s "
    fi
done
if [[ -z "$_2035_s1_stale" ]]; then
    assert_pass "[#2035/SPEC-1] ADR-028 has no stale 'not migrated' claim for review-lens or review-report"
else
    assert_fail "[#2035/SPEC-1] ADR-028 must not contain stale 'not migrated' claim for review-lens or review-report" \
        "stale claim found for: $_2035_s1_stale"
fi

# ── [#2035/SPEC-4]: comment-excluding grep correctly ignores plugin.sh:394 ──
# The comment "schema-gated envelope parser replaces bare extract_first_json_object"
# is the only line in review-lens/plugin.sh containing that string. A code-level
# (non-comment-line) grep must find zero matches, confirming the plugin is fully
# migrated and that SPEC-3's grep no longer triggers the wrong branch.
# Passes both before and after this issue's changes — the migration was done in
# #1840; only the test grep was wrong.
if [[ -f "$_rl" ]]; then
    if grep -qE '^[^#]*extract_first_json_object' "$_rl"; then
        assert_fail "[#2035/SPEC-4] extract_first_json_object must not appear in non-comment lines of review-lens/plugin.sh" \
            "found in non-comment line(s)"
    else
        assert_pass "[#2035/SPEC-4] extract_first_json_object appears only in a comment in review-lens/plugin.sh"
    fi
else
    assert_fail "[#2035/SPEC-4] review-lens/plugin.sh must exist for comment-grep guard to run" "absent"
fi

# ── [#2035/SPEC-5]: review-lens/plugin.sh uses _llm_envelope_parse --schema-gate ──
# Pre-existing migration (#1840); confirmed by the SPEC-2 loop expansion above and
# by review-lens-v2-result-test.sh [SPEC-4]. Guard: passes both before and after.
_rl_p="$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
if grep -q '_llm_envelope_parse.*--schema-gate.*_review_lens_envelope_schema_ok' \
        "$_rl_p" 2>/dev/null; then
    assert_pass "[#2035/SPEC-5] review-lens/plugin.sh uses _llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok"
else
    assert_fail "[#2035/SPEC-5] review-lens/plugin.sh must use _llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok" \
        "absent"
fi

# ── [#2035/SPEC-6]: review-report/lib/lenses.sh uses _llm_envelope_parse --schema-gate ──
# Pre-existing migration (#1843); confirmed by the SPEC-2 loop expansion above.
# Guard: passes both before and after.
_rr_l="$REPO_ROOT/plugins/agent/review-report/lib/lenses.sh"
if grep -q '_llm_envelope_parse.*--schema-gate.*_rr_lens_envelope_schema_ok' \
        "$_rr_l" 2>/dev/null; then
    assert_pass "[#2035/SPEC-6] review-report/lib/lenses.sh uses _llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok"
else
    assert_fail "[#2035/SPEC-6] review-report/lib/lenses.sh must use _llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok" \
        "absent"
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
