## Checkpoint — test-author, issue #2222, SPEC-3

### Files read
- design.md: six targeted prose edits to retire `exhausted` as a disposition label; no code changes; the R-4 acceptance grep must find `exhausted` only in explicitly historical text
- core/pipeline/dispatch-rc.sh:166: has `→ exhausted` in rc-table comment (site 1)
- plugins/agent/review-lens/plugin.sh:379: has `Write disposition:exhausted` in comment (site 2)
- docs/wiki/plugins/review-report.md:137: has `` `exhausted` `` as disposition value (site 3)
- .github/issues/keepers-manifest.yaml:1430: has `disposition: exhausted` escalates (site 4)
- docs/adr/ADR-054-stage-contract.md:163: scope_too_large row has `exhausted (§6)` without backward-pointer (site 5 — annotate, not remove)
- docs/adr/ADR-001-plugin-contract.md:163: `escalate → exhausted` passage has no #2187 note (site 6 — annotate, not remove)

### Conclusions
- Sites 1-4: test asserts ABSENCE of the prescriptive form (fails before change, passes after)
- Sites 5-6: test asserts PRESENCE of a backward-pointer note (fails before change, passes after)
- test-helpers.sh assert_gt(desc, actual, threshold) checks actual > threshold

### Status: COMPLETE (iteration 2)
- tests/unit/exhausted-disposition-retired-test.sh written and shellcheck-clean
- 8 assertions total: 6 per-site + 2 R-4 acceptance-grep (codebase-wide)
- All 8 pass on post-build code; spec-correspondence gap addressed
- R-4 assertion (a): disposition:exhausted codebase grep, filter non-annotated
- R-4 assertion (b): → exhausted codebase grep, filter non-annotated
- Both filter compound tokens (_exhausted/exhausted_) and require #2187/retired/superseded/out_of_turns on same line
