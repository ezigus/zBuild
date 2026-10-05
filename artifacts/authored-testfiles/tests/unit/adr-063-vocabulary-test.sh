#!/usr/bin/env bash
# tests/unit/adr-063-vocabulary-test.sh
#
# [#2032]: verifies that ADR-063 has been amended to reflect the vocabulary
# changes introduced by #2187 (exhausted/escalate retired) and the per-stage
# budget-guidance helper architecture.
#
# SPEC-7 [#2032/SPEC-7] [change]: ADR-063 status reads "Accepted" and the
#   document contains no prescriptive use of `exhausted` as the §3 disposition
#   word or `escalate` as the §4 engine action — vocabulary updated to
#   timed_out/out_of_turns per #2187.
#   Test FAILS on old code (Status: Proposed; prescriptive exhausted/escalate present).
#
# SPEC-8 [#2032/SPEC-8] [change]: ADR-063 §1 uses per-stage budget-guidance
#   helpers language — each stage has its own _<stage>_budget_guidance helper that
#   reads the enforcing values; the baseline single-helper "One helper renders the
#   budget block" language is absent.
#   Test FAILS on old code ("One helper renders the budget block" is present).
#
# SPEC-9 [#2032/SPEC-9] [change]: ADR-063 contains an amendment back-pointer
#   that explicitly names #2187 (the issue that retired exhausted/escalate).
#   Test FAILS on old code (no such back-pointer present).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "ADR-063: vocabulary amendment — timed_out/out_of_turns, per-stage helpers, #2187 pointer (#2032)"
setup_test_env "adr-063-vocabulary"
_test_cleanup_hook() { cleanup_test_env; }

ADR_063="$REPO_ROOT/docs/adr/ADR-063-budget-disclosure-and-partial-output.md"

if [[ ! -f "$ADR_063" ]]; then
    assert_fail "ADR-063 file must exist at docs/adr/ADR-063-budget-disclosure-and-partial-output.md" \
        "file not found: $ADR_063"
    print_test_results
    exit 1
fi

_adr() { cat "$ADR_063"; }

# ── SPEC-7 [#2032/SPEC-7]: status Accepted; retired vocabulary absent ─────────
print_test_section "SPEC-7 [#2032/SPEC-7]: Status=Accepted; no prescriptive exhausted/escalate"

# Status header must read "Accepted" (old: "Proposed").
# FAILS on old code: old header is "**Status:** Proposed".
if grep -q 'Status.*Accepted' "$ADR_063" 2>/dev/null; then
    assert_pass "[#2032/SPEC-7] ADR-063 Status reads Accepted"
else
    assert_fail "[#2032/SPEC-7] ADR-063 Status must read Accepted (was Proposed before this change)" \
        "$(grep 'Status' "$ADR_063" | head -1)"
fi

# §3's prescriptive disposition must no longer be "exhausted".
# Old §3 header: "### 3. Partial is signalled as `disposition: exhausted`"
# Old decision table row: "| §3 | partial is signalled as `disposition: exhausted` |"
# FAILS on old code: both are present.
if grep -qE 'disposition:.*exhausted|disposition: exhausted' "$ADR_063" 2>/dev/null; then
    assert_fail "[#2032/SPEC-7] prescriptive 'disposition: exhausted' must be removed from ADR-063" \
        "found: $(grep -E 'disposition:.*exhausted|disposition: exhausted' "$ADR_063" | head -1)"
else
    assert_pass "[#2032/SPEC-7] no prescriptive 'disposition: exhausted' in ADR-063"
fi

# §4's prescriptive engine action must no longer be "escalate".
# Old §4 text: "`exhausted → escalate` already routes to `_route_escalate_timeout`"
# FAILS on old code: the arrow expression is present.
if grep -q 'exhausted.*→.*escalate' "$ADR_063" 2>/dev/null; then
    assert_fail "[#2032/SPEC-7] prescriptive 'exhausted → escalate' engine action must be removed from ADR-063" \
        "found: $(grep 'exhausted.*→.*escalate' "$ADR_063" | head -1)"
else
    assert_pass "[#2032/SPEC-7] no prescriptive 'exhausted → escalate' engine action in ADR-063"
fi

# The updated vocabulary (timed_out / out_of_turns) must appear in the document
# as the replacement for the old exhausted disposition word.
# FAILS on old code: these words do not appear as the disposition vocabulary in §3.
if grep -q 'timed_out' "$ADR_063" 2>/dev/null; then
    assert_pass "[#2032/SPEC-7] timed_out appears in ADR-063 as updated vocabulary"
else
    assert_fail "[#2032/SPEC-7] timed_out must appear in ADR-063 (replaces exhausted per #2187)" \
        "word 'timed_out' not found in $ADR_063"
fi

if grep -q 'out_of_turns' "$ADR_063" 2>/dev/null; then
    assert_pass "[#2032/SPEC-7] out_of_turns appears in ADR-063 as updated vocabulary"
else
    assert_fail "[#2032/SPEC-7] out_of_turns must appear in ADR-063 (replaces exhausted per #2187)" \
        "word 'out_of_turns' not found in $ADR_063"
fi

# The §3 section header must not prescribe 'exhausted' as the disposition word.
# Old header: "### 3. Partial is signalled as `disposition: exhausted`"
# This catches prose forms like "Partial is signalled as `exhausted`" not caught by the
# disposition: prefix regex above. FAILS on old code.
_sec3_header="$(grep -E '^### 3\.' "$ADR_063" 2>/dev/null || true)"
if grep -q 'exhausted' <<< "$_sec3_header" 2>/dev/null; then
    assert_fail "[#2032/SPEC-7] §3 section header must not prescribe 'exhausted' as the disposition word" \
        "header text: $_sec3_header"
else
    assert_pass "[#2032/SPEC-7] §3 section header does not prescribe 'exhausted' as the disposition word"
fi

# ── SPEC-8 [#2032/SPEC-8]: per-stage helpers, no single-helper baseline text ──
print_test_section "SPEC-8 [#2032/SPEC-8]: per-stage _<stage>_budget_guidance helpers; old single-helper text absent"

# The old §1 says "One helper renders the budget block".
# FAILS on old code: this text is present.
if grep -q 'One helper renders the budget block' "$ADR_063" 2>/dev/null; then
    assert_fail "[#2032/SPEC-8] old single-helper baseline 'One helper renders the budget block' must be removed from §1" \
        "found: $(grep 'One helper renders the budget block' "$ADR_063" | head -1)"
else
    assert_pass "[#2032/SPEC-8] 'One helper renders the budget block' is absent (per-stage helpers language used)"
fi

# The new §1 uses per-stage helpers language with the _<stage>_budget_guidance pattern.
# FAILS on old code: per-stage helper names are not present.
if grep -qE '_[a-z_]+_budget_guidance' "$ADR_063" 2>/dev/null; then
    assert_pass "[#2032/SPEC-8] per-stage _<stage>_budget_guidance helper pattern present in ADR-063"
else
    assert_fail "[#2032/SPEC-8] per-stage _<stage>_budget_guidance helpers must be named in ADR-063 §1" \
        "no _*_budget_guidance pattern found in $ADR_063"
fi

# The pattern must appear specifically in §1 (between "### 1." and "### 2." headers).
# FAILS on old code: §1 body has the single-helper baseline, not the per-stage helper names.
_sec1_body="$(awk '/^### 1\./{f=1; next} /^### [0-9]+\./{if(f){exit}} f{print}' "$ADR_063" 2>/dev/null || true)"
if grep -qE '_[a-z_]+_budget_guidance' <<< "$_sec1_body" 2>/dev/null; then
    assert_pass "[#2032/SPEC-8] per-stage _<stage>_budget_guidance language is in §1 body specifically"
else
    assert_fail "[#2032/SPEC-8] per-stage _<stage>_budget_guidance helpers must be defined in ADR-063 §1" \
        "pattern absent from §1 (between '### 1.' and '### 2.')"
fi

# "Each stage has its own" — at least 2 distinct helper names must be present.
# FAILS on old code: old §1 names no per-stage helpers at all.
_helper_count="$(grep -oE '_[a-z_]+_budget_guidance' "$ADR_063" 2>/dev/null | sort -u | wc -l | tr -d ' ' || true)"
if [[ "${_helper_count:-0}" -ge 2 ]]; then
    assert_pass "[#2032/SPEC-8] ≥2 distinct per-stage _<stage>_budget_guidance helpers named (each stage has its own)"
else
    assert_fail "[#2032/SPEC-8] ADR-063 must name ≥2 distinct per-stage budget_guidance helpers (got ${_helper_count:-0})" \
        "found: $(grep -oE '_[a-z_]+_budget_guidance' "$ADR_063" 2>/dev/null | sort -u | tr '\n' ' ' || true)"
fi

# ── SPEC-9 [#2032/SPEC-9]: amendment back-pointer explicitly names #2187 ──────
print_test_section "SPEC-9 [#2032/SPEC-9]: amendment back-pointer naming #2187 present"

# The amendment must name #2187 (the issue that retired exhausted/escalate).
# FAILS on old code: no such back-pointer exists.
if grep -q '#2187' "$ADR_063" 2>/dev/null; then
    assert_pass "[#2032/SPEC-9] ADR-063 contains a reference to #2187"
else
    assert_fail "[#2032/SPEC-9] ADR-063 must contain an amendment back-pointer naming #2187" \
        "#2187 not found in $ADR_063"
fi

# The #2187 reference must appear in the context of an amendment (not just any mention).
# It should accompany the vocabulary retirement note.
_2187_ctx="$(grep -A2 -B2 '#2187' "$ADR_063" 2>/dev/null || true)"
if grep -qiE 'amend|retired|vocabulary|timed_out|out_of_turns' <<< "$_2187_ctx" 2>/dev/null; then
    assert_pass "[#2032/SPEC-9] #2187 reference is in an amendment/vocabulary-retirement context"
else
    assert_fail "[#2032/SPEC-9] #2187 must appear in an amendment context naming the vocabulary retirement" \
        "context around #2187: $_2187_ctx"
fi

print_test_results
exit $((FAIL > 0))
