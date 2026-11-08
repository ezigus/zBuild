## build — pass

- changed docs/adr/ADR-006-resume-contract.md (+60 / -0)

- over 1 pass(es), 1 iteration(s)
- answered: issue-acceptance finding 1: done — added "## Amendment — full resume and `--from-stage` contract (issue #1805)" section to `docs/adr/ADR-006-resume-contract.md` documenting all four missing items: (1) the dispatch-loop skip guard conditioned on `resume_mode`; (2) cycle iteration restoration via `_ZBUILD_RESUME_ACTIVE` + `current_iter` and the DSCMBR-1 `resume_first_iter=true` member-skip behavior within the interrupted iteration; (3) the `--from-stage <s>` pre-flight contract (`_runner_from_stage_preflight`); (4) auto-resume state discovery via the `latest` symlink for the per-run layout. The section also explicitly supersedes the contradictory step 3.5 prose ("re-run iter N from scratch" / "start iter N+1 with feedback already wired"). The DSAMDR-1 test assertions still pass (47/47 — they check only for the step 3.6 text which is unchanged).
- not answered: lens-performance-code finding 1
- not answered: lens-red-team-code finding 1
- not answered: lens-red-team-code finding 2
- not answered: lens-red-team-code finding 3
- not answered: lens-correctness-code finding 1
- not answered: lens-correctness-code finding 2
- not answered: lens-correctness-code finding 3
- not answered: lens-scope-code finding 1
- not answered: lens-sre-code finding 1
- not answered: lens-sre-code finding 2
- not answered: lens-correctness-design finding 1
