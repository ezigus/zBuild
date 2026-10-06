# Design checkpoint — issue #2222

## What I have read
- plan.json: 6 steps, all pure comment/prose/doc changes. Part 1 (budget helpers) was shipped in #2252/#2253; only Part 2 (retire exhausted) remains.
- requirements.json: R-1/R-2/R-3 are about budget notes (already done); R-4 is the exhausted cleanup; R-5 is npm test + lint.
- dispatch-rc.sh line 166: comment says `→ exhausted`; body already emits `out_of_turns`.
- review-lens/plugin.sh line 379: comment says "Write disposition:exhausted"; code already writes `out_of_turns`.
- docs/wiki/plugins/review-report.md line 137: says "`exhausted` when a lens call returned non-zero".
- .github/issues/keepers-manifest.yaml line 1430: says "`disposition: exhausted` escalates (ADR-054 §6)".
- ADR-054 line 163 (§4 rc table): `→ exhausted (§6)` — needs dated backward-pointer.
- ADR-001 line 163 (§recovery historical note): `escalate → exhausted` — needs dated inline note.
- stage-budget-note-test.sh: EXISTS; covers N1-N6 (budget note values in prompts); evidence for R-1/R-2.
- impact-prompt-contract-test.sh: EXISTS; evidence for R-3.
- lint-disposition-words.sh: checks literal disposition values in code, NOT comment text.
- Other ADRs (036/045/019/021/029/026): `exhausted` appears only as an English verb/adjective or as event names (design_timeout_exhausted, cycle.timeout_exhausted) — NOT in R-4 scope.

## Conclusions
- All 6 changes are prose/comment/doc — no behavioral code changes.
- R-1/R-2/R-3: [done] (already shipped).
- R-4: [no-code] — updating 6 files removes/annotates all non-historical `exhausted` disposition references.
- R-5: [done] — lint does not flag comments; once changes are correct, lint stays green.
- WIRING: none (no new callable code path).
- A new test file tests/unit/exhausted-disposition-retired-test.sh can run the R-4 grep and verify each match is historical.

## Still unresolved
- None; writing final design.md now.
