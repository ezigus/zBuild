#!/usr/bin/env bash
# Guard: an ADR that claims a migration is COMPLETE must be checkable.
#
# ADR-028 §Migration says:
#
#   "All four Pattern-1 stages — plan, review, test_assessment, and
#    security-lens — are migrated to call _llm_envelope_parse --schema-gate in
#    place of their prior extract_first_json_object calls."
#
# Two things were wrong with that sentence. `test_assessment` was DELETED in
# #979 — the ADR named a stage that had not existed for months as evidence of
# completeness — and `review-lens` was then still on bare
# `extract_first_json_object`. review-lens (#1840) and review-report (#1843)
# have since moved to the shared parser (#2035), so all five are now checked.
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
# The claim, checked against the code rather than against itself. A stage's
# parser can live outside plugin.sh (review-report's is in lib/lenses.sh), so
# every non-test .sh file in the plugin directory counts. Only code lines count:
# a comment that names the old parser (review-lens explains why it left it) is
# not a call.
_MIGRATED_STAGES="plan security-lens monitor review-lens review-report"

# Prints why <plugin dir> is not migrated; prints nothing when it is.
_stage_unmigrated_reason() {
    local dir="$1" f calls=0 bare=""
    while IFS= read -r -d '' f; do
        grep -qE '^[^#]*_llm_envelope_(parse|classify)' "$f" && calls=1
        grep -qE '^[^#]*extract_first_json_object' "$f" && bare+="${f#"$dir"/} "
    done < <(find "$dir" -name '*.sh' -not -path '*/tests/*' -print0)
    [[ -n "$bare" ]] && { printf 'calls extract_first_json_object in %s' "${bare% }"; return 0; }
    [[ "$calls" -eq 1 ]] || printf 'never calls _llm_envelope_parse'
}

_unmigrated=""
for _s in $_MIGRATED_STAGES; do
    _d="$REPO_ROOT/plugins/agent/$_s"
    if [[ ! -d "$_d" ]]; then _unmigrated+="$_s (no plugin directory); "; continue; fi
    _why="$(_stage_unmigrated_reason "$_d")"
    [[ -z "$_why" ]] || _unmigrated+="$_s ($_why); "
done
if [[ -z "$_unmigrated" ]]; then
    assert_pass "SPEC-2: every stage claimed migrated uses the shared parser"
else
    assert_fail "SPEC-2: every stage claimed migrated uses the shared parser" \
        "still on the old path: $_unmigrated"
fi

# Negative control: SPEC-2's check must see a bare call put back. Copy each of
# the two newly migrated plugins, add one code-line call, and expect a reason.
for _s in review-lens review-report; do
    _nc="$TEST_TEMP_DIR/negctl-$_s"
    cp -R "$REPO_ROOT/plugins/agent/$_s" "$_nc"
    # shellcheck disable=SC2016  # the $1 is written into the copied plugin, not expanded here
    printf '\n_negctl() { extract_first_json_object "$1"; }\n' >> "$_nc/plugin.sh"
    _why="$(_stage_unmigrated_reason "$_nc")"
    assert_contains "SPEC-2 negative control: a bare extract_first_json_object call in $_s is caught" \
        "$_why" "extract_first_json_object"
done
# ...and a comment naming the old parser is not a call.
_nc="$TEST_TEMP_DIR/negctl-comment"
cp -R "$REPO_ROOT/plugins/agent/review-report" "$_nc"
printf '\n    # extract_first_json_object is the old parser\n' >> "$_nc/plugin.sh"
assert_eq "SPEC-2 negative control: a comment naming extract_first_json_object is not a call" \
    "" "$(_stage_unmigrated_reason "$_nc")"

# ── SPEC-3: the ADR names review-lens and review-report as migrated ────────
# The ADR said both were "**not** migrated" long after the code moved (#1840,
# #1843). The code is migrated (SPEC-2), so the ADR must say so, name each
# stage's schema gate, and keep no sentence saying the opposite.
_mig_line="$(grep -E '^\*\*Migration\.\*\*' "$ADR" || true)"
for _s in review-lens review-report; do
    assert_contains "SPEC-3: ADR-028's Migration paragraph lists $_s" "$_mig_line" "\`$_s\`"
done
for _g in _review_lens_envelope_schema_ok:review-lens _rr_lens_envelope_schema_ok:review-report; do
    _fn="${_g%%:*}"
    grep -rqE "^${_fn}\(\)" "$REPO_ROOT/plugins/agent/${_g#*:}" \
        || assert_fail "SPEC-3 setup: $_fn is defined in ${_g#*:}" "not found — update this test"
    if grep -qF "\`$_fn\`" "$ADR"; then
        assert_pass "SPEC-3: ADR-028 names the schema gate $_fn"
    else
        assert_fail "SPEC-3: ADR-028 names the schema gate $_fn" "not named"
    fi
done
# shellcheck disable=SC2016  # backticks are literal markdown in the pattern
_stale_claim="$(grep -nE '(review-lens|review-report).*\*\*not\*\* migrated|\*\*not\*\* migrated.*(review-lens|review-report)|`review-lens` was \*\*not\*\*' "$ADR" || true)"
assert_eq "SPEC-3: no sentence in ADR-028 says review-lens or review-report is not migrated" \
    "" "$_stale_claim"

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
