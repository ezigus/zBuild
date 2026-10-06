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

# ── [#2035/SPEC-5]: review-lens and review-report use the shared parser ────
# The SPEC-2 loop only checks plugin.sh for plan/security-lens/monitor.
# review-report's migration lives in lib/lenses.sh, so we check every non-test
# .sh file in each plugin directory: at least one must call _llm_envelope_parse.
_unmigrated_rl=""
for _rl_dir in review-lens review-report; do
    _rl_dir_path="$REPO_ROOT/plugins/agent/$_rl_dir"
    [[ -d "$_rl_dir_path" ]] || continue
    _dir_found=0
    while IFS= read -r -d '' _f; do
        if grep -qE '_llm_envelope_(parse|classify)' "$_f"; then
            _dir_found=1
        fi
    done < <(find "$_rl_dir_path" -name '*.sh' -not -path '*/tests/*' -print0)
    if [[ "$_dir_found" -eq 0 ]]; then
        _unmigrated_rl+="$_rl_dir "
    fi
done
if [[ -z "$_unmigrated_rl" ]]; then
    assert_pass "[#2035/SPEC-5]: review-lens and review-report have _llm_envelope_parse in non-test sh files"
else
    assert_fail "[#2035/SPEC-5]: review-lens and review-report have _llm_envelope_parse in non-test sh files" \
        "no _llm_envelope_parse in non-test code: $_unmigrated_rl"
fi

# [#2035/SPEC-5] structural: this test's loop uses find -not -path to exclude test files
if grep -qF "find \"\$_rl_dir_path\" -name '*.sh' -not -path '*/tests/*'" "${BASH_SOURCE[0]}"; then
    assert_pass "[#2035/SPEC-5]: SPEC-2 loop uses find with -not -path to exclude test files"
else
    assert_fail "[#2035/SPEC-5]: SPEC-2 loop uses find with -not -path to exclude test files" \
        "find with -not -path '*/tests/*' not found in the review-lens/review-report loop"
fi

# [#2035/SPEC-5] absence: no bare extract_first_json_object in review-lens/review-report non-test code
_bare_rl=""
for _rl_dir2 in review-lens review-report; do
    _rl_dir2_path="$REPO_ROOT/plugins/agent/$_rl_dir2"
    [[ -d "$_rl_dir2_path" ]] || continue
    while IFS= read -r -d '' _f2; do
        if grep -qE '^[^#]*extract_first_json_object' "$_f2"; then
            _bare_rl+="$_rl_dir2 "
            break
        fi
    done < <(find "$_rl_dir2_path" -name '*.sh' -not -path '*/tests/*' -print0)
done
if [[ -z "$_bare_rl" ]]; then
    assert_pass "[#2035/SPEC-5]: no bare extract_first_json_object in review-lens/review-report non-test code"
else
    assert_fail "[#2035/SPEC-5]: no bare extract_first_json_object in review-lens/review-report non-test code" \
        "bare extract_first_json_object found in: $_bare_rl"
fi

# ── SPEC-3: a stage NOT migrated is not described as if it were ────────────
# review-lens is the counter-example the ADR got wrong. It is allowed to stay on
# `extract_first_json_object` — it fails visibly, emitting review_lens.unparseable
# and a summary that says the lens reviewed nothing — but the ADR must not claim
# otherwise. This asserts the two agree, in whichever direction they agree.
#
# The grep uses ^[^#]* to exclude comment lines: a comment at plugin.sh:403
# mentions extract_first_json_object but the actual call is _llm_envelope_parse.
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

# ── [#2035/SPEC-4]: comment-excluding grep does not fire on review-lens ─────
# The SPEC-3 grep uses ^[^#]* so a comment at plugin.sh:403 that mentions
# extract_first_json_object does not trigger the not-migrated branch.
# After migration, the comment-excluding grep must return no match on plugin.sh.
_rl_spec4="$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
if [[ ! -f "$_rl_spec4" ]] || ! grep -qE '^[^#]*extract_first_json_object' "$_rl_spec4"; then
    assert_pass "[#2035/SPEC-4]: comment-excluding grep does not trigger on review-lens/plugin.sh"
else
    assert_fail "[#2035/SPEC-4]: comment-excluding grep does not trigger on review-lens/plugin.sh" \
        "non-comment extract_first_json_object found; SPEC-3 not-migrated branch would fire"
fi

# [#2035/SPEC-4] structural: the SPEC-3 grep in this file uses the comment-excluding pattern
if grep -qF "grep -qE '^[^#]*extract_first_json_object' \"\$_rl\"" "${BASH_SOURCE[0]}"; then
    assert_pass "[#2035/SPEC-4]: SPEC-3 grep uses comment-excluding ^[^#]* pattern"
else
    assert_fail "[#2035/SPEC-4]: SPEC-3 grep uses comment-excluding ^[^#]* pattern" \
        "SPEC-3 grep does not use '^[^#]*extract_first_json_object' with the \$_rl variable"
fi

# ── [#2035/SPEC-1]: ADR-028 has no stale "not migrated" claim ───────────────
# After migration, no sentence in ADR-028 should call review-lens or
# review-report "not migrated". Fails on the current ADR (lines 189 and 193
# contain that text) and passes once those lines are replaced.
if grep -qE '(review-lens|review-report).*\*\*not\*\*.*migrat|\*\*not\*\*.*migrat.*(review-lens|review-report)' "$ADR"; then
    assert_fail "[#2035/SPEC-1]: ADR-028 has no text calling review-lens or review-report not migrated" \
        "stale not-migrated claim still present in ADR-028"
else
    assert_pass "[#2035/SPEC-1]: ADR-028 has no text calling review-lens or review-report not migrated"
fi

# ── [#2035/SPEC-6]: ADR-028 names the schema-gate functions in its migration record ─
# After migration, ADR-028 Amendment v1.2 (the migration record) must positively
# name _review_lens_envelope_schema_ok and _rr_lens_envelope_schema_ok. Checks only
# the Amendment v1.2 section so a name added elsewhere does not satisfy the requirement.
_v12_text=$(awk '/^## Amendment v1\.2/{found=1} found{print}' "$ADR")
_missing_gates=""
for _fn in _review_lens_envelope_schema_ok _rr_lens_envelope_schema_ok; do
    grep -qF "$_fn" <<< "$_v12_text" || _missing_gates+="$_fn "
done
if [[ -z "$_missing_gates" ]]; then
    assert_pass "[#2035/SPEC-6]: ADR-028 Amendment v1.2 names both schema-gate functions"
else
    assert_fail "[#2035/SPEC-6]: ADR-028 Amendment v1.2 names both schema-gate functions" \
        "missing from ADR-028 Amendment v1.2: $_missing_gates"
fi

print_test_results
