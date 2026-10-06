# Spec-correspondence checkpoint

## Files read
- design.md: confirms 6 specific non-historical `exhausted` sites across 6 named files; design scopes the assertion to those exact sites.

## Analysis of SPEC-3

REQUIREMENT: "Every non-historical occurrence of `exhausted` as a disposition label is removed or annotated with a dated backward-pointer note so the R-4 acceptance grep finds it only in explicitly historical text."

ASSERTION: checks 6 specific files for 6 specific patterns:
1. dispatch-rc.sh: `scope_too_large.*→.*exhausted` == 0
2. review-lens/plugin.sh: `disposition:exhausted` == 0
3. review-report.md: `exhausted.*lens call` == 0
4. keepers-manifest.yaml: `disposition: exhausted` == 0
5. ADR-054: backward-pointer note present for scope_too_large row
6. ADR-001: `exhausted.*#2187|#2187.*exhausted` present

GAPS:
- "Every non-historical occurrence" is a global claim; assertion only checks 6 specific files — does not verify there are no other files in the repo containing `exhausted` as a disposition label.
- Within those files, only specific grep patterns are checked — not all forms of `exhausted` as disposition.
- Requirement specifies the test should pass "so the R-4 acceptance grep finds it only in explicitly historical text" — the assertion never runs this R-4 grep to confirm the final state.
- Backward-pointer checks do not verify the "dated" aspect required (requirement says "dated backward-pointer note").

VERDICT: partial — tests the right property (removing/annotating specific `exhausted` occurrences) but cannot establish the universal claim "every" since it only checks 6 specific files and specific patterns, and does not run the R-4 acceptance grep.

## Status: complete — verdict ready.
