# Spec-correspondence checkpoint

## Files read
- design.md: confirms 6 specific non-historical `exhausted` sites across 6 named files; design scopes the assertion to those exact sites.
- Full SPEC-3 assertion: re-read from prompt — includes R-4 acceptance grep loops at the end (prior checkpoint was wrong to say R-4 grep was absent).

## Corrected Analysis of SPEC-3

REQUIREMENT: "Every non-historical occurrence of `exhausted` as a disposition label is removed or annotated with a dated backward-pointer note so the R-4 acceptance grep finds it only in explicitly historical text."

ASSERTION structure (8 checks):
1. File existence check for 6 named files
2. dispatch-rc.sh: `scope_too_large.*→.*exhausted` == 0
3. review-lens/plugin.sh: `disposition:exhausted` == 0
4. review-report.md: any `exhausted` == 0
5. keepers-manifest.yaml: `disposition: exhausted` == 0
6. ADR-054: backward-pointer note present (`scope_too_large.*out_of_turns|§6a|#2187`)
7. ADR-001: `exhausted.*#2187|#2187.*exhausted` present
8. R-4 grep (a): global `disposition[[:space:]]*:[[:space:]]*exhausted` scan across core/plugins/scripts/docs/.github/config — only un-annotated hits (no `_exhausted|exhausted_`, no `#2187|retired|superseded|out_of_turns`) count
9. R-4 grep (b): global `→[[:space:]]*exhausted` scan — same annotation filter

REMAINING GAPS (after correcting prior analysis):
- `tests/` directory is NOT in R-4 grep scope; exhausted-as-disposition there escapes.
- Shell assignment forms (`disposition="exhausted"`, `set_disposition exhausted`) escape both grep patterns.
- "dated" aspect of backward-pointer note: assertion checks annotations contain #2187/superseded/etc. but never verifies a date is present.
- The exemption criterion is "annotation present" not "explicitly historical text" — broader than requirement allows.

VERDICT: partial — the assertion runs the R-4 sweep globally (correcting the prior checkpoint) and tests the right property, but `tests/` is excluded from the sweep, common shell-assignment forms of the disposition escape both patterns, and the "dated" aspect of backward-pointer notes is never verified.

## Acceptance-gate finding
Finding 1 asks to add a [code] requirement with a test for edited code files. My scope is read-only spec-correspondence judging only — I cannot modify repository files.

## Status: complete — verdict and finding answer ready.
