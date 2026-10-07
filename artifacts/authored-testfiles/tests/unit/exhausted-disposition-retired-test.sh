#!/usr/bin/env bash
# tests/unit/exhausted-disposition-retired-test.sh — SPEC-3 acceptance: no live
# prescriptive uses of `exhausted` as a disposition label survive issue #2222.
#
# ADR-054 §6a (2026-09-25, #2187) retired `exhausted` from the disposition set,
# replacing it with `out_of_turns` (turn budget hit) and `timed_out` (wall-clock
# hit).  Issue #2222 cleans up six non-functional sites that still named the word
# in a prescriptive — not explicitly historical — way.
#
# Six sites are checked below, one assertion per site:
#   1. core/pipeline/dispatch-rc.sh:166 comment
#   2. plugins/agent/review-lens/plugin.sh:379 comment
#   3. docs/wiki/plugins/review-report.md:137 prose
#   4. .github/issues/keepers-manifest.yaml:1430 body
#   5. docs/adr/ADR-054-stage-contract.md:163 rc=10 table row (annotated, not removed)
#   6. docs/adr/ADR-001-plugin-contract.md:163 retirement passage (annotated, not removed)
#
# Two R-4 acceptance-grep assertions follow the per-site checks:
#   (a) `disposition: exhausted` pattern — no un-annotated occurrence in codebase
#   (b) `→ exhausted` mapping pattern — no un-annotated occurrence in codebase
#
#   SPEC-3[no-code] (#2222): Every non-historical occurrence of `exhausted` as a
#     disposition label is removed or annotated with a dated backward-pointer note
#     so the R-4 acceptance grep finds it only in explicitly historical text.
#     tag: [#2222/SPEC-3]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "exhausted disposition retired — SPEC-3 (#2222)"
setup_test_env "exhausted-disposition-retired"

DISPATCH_RC="$REPO_ROOT/core/pipeline/dispatch-rc.sh"
REVIEW_LENS="$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
REVIEW_REPORT="$REPO_ROOT/docs/wiki/plugins/review-report.md"
KEEPERS_MANIFEST="$REPO_ROOT/.github/issues/keepers-manifest.yaml"
ADR054="$REPO_ROOT/docs/adr/ADR-054-stage-contract.md"
ADR001="$REPO_ROOT/docs/adr/ADR-001-plugin-contract.md"

for _f in "$DISPATCH_RC" "$REVIEW_LENS" "$REVIEW_REPORT" "$KEEPERS_MANIFEST" "$ADR054" "$ADR001"; do
    if [[ ! -f "$_f" ]]; then
        assert_fail "[#2222/SPEC-3] required file exists" "not found: $_f"
    fi
done

# ── Site 1: dispatch-rc.sh rc-table comment ──────────────────────────────────
# The comment at line 166 listed rc=10 scope_too_large as mapping to `exhausted`.
# After the fix it must say `out_of_turns (ADR-054 §6a, #2187)` instead.
# Fails when the bare `→ exhausted` form is still present.
_dispatch_bare="$(grep -c 'scope_too_large.*→.*exhausted' "$DISPATCH_RC" 2>/dev/null || true)"
assert_eq "[#2222/SPEC-3] dispatch-rc.sh rc=10 comment does not map scope_too_large to bare exhausted (replaced with out_of_turns per §6a/#2187)" \
    "0" "$_dispatch_bare"

# ── Site 2: review-lens/plugin.sh degrade-path comment ───────────────────────
# The comment at line 379 described the degrade path as writing
# "disposition:exhausted".  After the fix it must name disposition:out_of_turns.
# The compound token `budget_exhausted` at line 382 is a reason/detail argument,
# not a disposition word, and does not match `disposition:exhausted`.
_lens_comment="$(grep -c 'disposition:exhausted' "$REVIEW_LENS" 2>/dev/null || true)"
assert_eq "[#2222/SPEC-3] review-lens/plugin.sh degrade-path comment does not name disposition:exhausted (renamed to out_of_turns)" \
    "0" "$_lens_comment"

# ── Site 3: review-report.md wiki prose ──────────────────────────────────────
# The wiki line listed `exhausted` as the disposition value emitted when a lens
# call returned non-zero.  After the fix it must name `out_of_turns`.
# Checks the whole file: any occurrence of the word is a prescriptive reference
# in this disposition-vocabulary document.
_wiki_exhausted="$(grep -c 'exhausted' "$REVIEW_REPORT" 2>/dev/null || true)"
assert_eq "[#2222/SPEC-3] review-report.md carries no occurrence of exhausted (disposition word fully replaced with out_of_turns)" \
    "0" "$_wiki_exhausted"

# ── Site 4: keepers-manifest.yaml issue body ─────────────────────────────────
# The manifest body at line 1430 contained "`disposition: exhausted` escalates".
# After the fix it must use `disposition: out_of_turns`.
# Fails when the prescriptive `disposition: exhausted` form is still present.
_manifest_exhausted="$(grep -c 'disposition: exhausted' "$KEEPERS_MANIFEST" 2>/dev/null || true)"
assert_eq "[#2222/SPEC-3] keepers-manifest.yaml does not prescribe disposition: exhausted (replaced with out_of_turns per §6a/#2187)" \
    "0" "$_manifest_exhausted"

# ── Site 5: ADR-054 rc=10 table row — annotated with backward-pointer ────────
# The table row at ADR-054 line 163 retains `exhausted` as a historical record
# of what §6 originally said, but must carry a dated backward-pointer note so
# it is unambiguously marked superseded.  The note must mention §6a, #2187, or
# the replacement word `out_of_turns` on the same table row as `scope_too_large`.
# Fails when the row has not been annotated.
_adr054_note="$(grep -c 'scope_too_large.*out_of_turns\|scope_too_large.*§6a\|scope_too_large.*#2187' "$ADR054" 2>/dev/null || true)"
assert_gt "[#2222/SPEC-3] ADR-054 rc=10 scope_too_large table row carries a backward-pointer note (§6a, #2187, or out_of_turns) marking it superseded" \
    "$_adr054_note" "0"

# ── Site 6: ADR-001 retirement passage — inline backward-pointer added ────────
# The ADR-001 retirement note listed `escalate → exhausted` as a disposition
# mapping.  After the fix that passage must carry an inline note citing #2187
# so a reader knows the word is retired vocabulary, not a current prescription.
# Fails when the passage has not been annotated with a reference to #2187.
_adr001_note="$(grep -c 'exhausted.*#2187\|#2187.*exhausted' "$ADR001" 2>/dev/null || true)"
assert_gt "[#2222/SPEC-3] ADR-001 exhausted passage carries a backward-pointer note naming #2187 (marks the word as retired vocabulary)" \
    "$_adr001_note" "0"

# ── R-4 acceptance grep (a): disposition:exhausted — codebase-wide ───────────
# Searches core/, plugins/, scripts/, docs/, .github/, and config/ for any
# occurrence of `disposition: exhausted` (the assignment form) that is NOT on a
# line already carrying a backward-pointer annotation (#2187, retired, superseded,
# or out_of_turns).  Such a line is a non-historical prescriptive use that must
# not survive.  Compound tokens (_exhausted / exhausted_) are excluded because
# they are reason/detail strings, not disposition labels.
#
# [#2222/SPEC-3]
_r4_assign=0
while IFS= read -r _hit; do
    _line="${_hit#*:*:}"
    grep -qE '_exhausted|exhausted_' <<< "$_line" && continue
    grep -qE '#2187|retired|superseded|out_of_turns' <<< "$_line" && continue
    _r4_assign=$((_r4_assign + 1))
    printf 'UNACCEPTABLE (disposition:exhausted): %s\n' "$_hit" >&2
done < <(grep -rn 'disposition[[:space:]]*:[[:space:]]*exhausted' \
    "$REPO_ROOT/core" \
    "$REPO_ROOT/plugins" \
    "$REPO_ROOT/scripts" \
    "$REPO_ROOT/docs" \
    "$REPO_ROOT/.github" \
    "$REPO_ROOT/config" \
    2>/dev/null || true)
assert_eq "[#2222/SPEC-3] R-4 acceptance grep (a): no un-annotated disposition:exhausted assignment survives in the codebase" \
    "0" "$_r4_assign"

# ── R-4 acceptance grep (b): → exhausted mapping — codebase-wide ─────────────
# Searches the same directories for any `→ exhausted` disposition-mapping pattern
# (arrow notation used in comments and ADR tables) that is NOT on a line carrying
# a backward-pointer annotation.  An unannotated arrow mapping is a prescriptive
# statement that `exhausted` is a live disposition word.
#
# [#2222/SPEC-3]
_r4_arrow=0
while IFS= read -r _hit; do
    _line="${_hit#*:*:}"
    grep -qE '_exhausted|exhausted_' <<< "$_line" && continue
    grep -qE '#2187|retired|superseded|out_of_turns' <<< "$_line" && continue
    _r4_arrow=$((_r4_arrow + 1))
    printf 'UNACCEPTABLE (→ exhausted): %s\n' "$_hit" >&2
done < <(grep -rn '→[[:space:]]*exhausted' \
    "$REPO_ROOT/core" \
    "$REPO_ROOT/plugins" \
    "$REPO_ROOT/scripts" \
    "$REPO_ROOT/docs" \
    "$REPO_ROOT/.github" \
    "$REPO_ROOT/config" \
    2>/dev/null || true)
assert_eq "[#2222/SPEC-3] R-4 acceptance grep (b): no un-annotated → exhausted disposition mapping survives in the codebase" \
    "0" "$_r4_arrow"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
