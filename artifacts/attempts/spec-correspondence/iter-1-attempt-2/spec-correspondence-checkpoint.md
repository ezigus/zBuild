# Spec-correspondence checkpoint

## Files read
- design.md: confirms 6 specific non-historical `exhausted` sites; explicitly states `tests/` is intentionally excluded (test files use `exhausted` in grep patterns/comments as meta-references, not disposition statements); states #2187 reference serves as "date proxy" for the dated backward-pointer requirement; confirms shell-assignment forms are caught by lint-disposition-words.sh but check (c) in the assertion covers them anyway.

## Analysis of SPEC-3

REQUIREMENT: "Every non-historical occurrence of `exhausted` as a disposition label is removed or annotated with a dated backward-pointer note so the R-4 acceptance grep finds it only in explicitly historical text."

ASSERTION structure (11 checks):
1. File existence check for 6 named files
2. dispatch-rc.sh: `scope_too_large.*→.*exhausted` == 0
3. review-lens/plugin.sh: `disposition:exhausted` == 0
4. review-report.md: any `exhausted` == 0
5. keepers-manifest.yaml: `disposition: exhausted` == 0
6. ADR-054: backward-pointer note present (scope_too_large.*out_of_turns|§6a|#2187)
7. ADR-054: ISO date present in §6a heading (`6a\..*\(20[0-9]{2}-[0-9]{2}-[0-9]{2}`)
8. ADR-001: `exhausted.*#2187|#2187.*exhausted` present
9. R-4 grep (a): global `disposition[[:space:]]*:[[:space:]]*exhausted` scan across core/plugins/scripts/docs/.github/config — un-annotated hits only
10. R-4 grep (b): global `→[[:space:]]*exhausted` scan — same dirs, same annotation filter
11. R-4 grep (c): global shell-assignment `disposition="exhausted"|set_disposition exhausted` scan — core/plugins/scripts only

## Gaps

1. `tests/` excluded from all R-4 scans — design says intentional (meta-references not disposition statements), but requirement says "every non-historical occurrence as a disposition label." The assertion cannot distinguish — it simply excludes tests/ entirely.

2. "dated" aspect verified for ADR-054 (ISO date check present in check 7) but NOT for ADR-001 (only #2187 reference checked in check 8, no date format verified). The requirement says "dated backward-pointer note" for annotated occurrences; ADR-001's note is only confirmed to contain `#2187`, not to carry any date.

3. R-4 annotation filter in checks 9–11 exempts any line containing `#2187|retired|superseded|out_of_turns` — does not require a date, so an occurrence annotated `# retired` (no date) would pass the assertion but may not satisfy "dated backward-pointer note."

## Verdict: partial

The assertion establishes most of the requirement — it sweeps all production code directories and verifies the six named sites — but it does not fully establish the "dated" aspect for ADR-001 nor for any globally-scanned annotated occurrence, and it excludes tests/ from scope entirely.

## Acceptance-gate finding 1
Finding asks to add a [code] requirement with a test. My scope is read-only spec-correspondence judging; I cannot modify repository files.

## Status: complete
