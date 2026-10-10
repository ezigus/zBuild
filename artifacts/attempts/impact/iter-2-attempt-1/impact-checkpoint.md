# Impact Stage Checkpoint

## Files read / searched
- design.md: PR adds core/state/run-cap.sh (new), modifies runner.sh (source + admit + release), adds pipeline.refused.run_cap to event-schema.json, amends ADR-059 with §7. Off-by-default cap, fail-open, sourced from resume.sh for zbuild_run_is_live.
- plan.json: 4 steps, all 7 scope files confirmed.
- core/state/issue-lock.sh: reference model for run-cap.sh; sources resume.sh for zbuild_run_is_live; no pre-existing run_cap symbols.
- config/event-schema.json: existing known_types; pipeline.refused.issue_locked already present; pipeline.refused.run_cap is new.
- core/pipeline/runner.sh (lines 2295-2310, 2461-2495): issue lock acquire at 2302, _runner_abort_trap at 2461 releases issue lock at 2470. run-cap.sh will be sourced alongside issue-lock.sh; zbuild_run_cap_admit before zbuild_issue_lock_acquire; zbuild_run_cap_release in _runner_abort_trap.
- tests/golden/full-pipeline/event-sequence.golden: pins normal pipeline event sequence — no pipeline.refused.run_cap (refusal path only). NOT a gap.
- tests/golden/parity/event-sequence.golden: same — pins normal run events, no admission refusal. NOT a gap.
- tests/golden/golden-contracts-test.sh: checks only plugin lifecycle event counts (plugin.run.complete, plugin.cleanup.complete, plugin.init/finalize.complete). Adding pipeline.refused.run_cap does NOT break any assertion. NOT a gap.
- tests/unit/requires-core-resolution-test.sh (line 271-281): verifies runner.sh sources specific named files. Additive change (new run-cap.sh source) doesn't break this. NOT a gap.
- tests/unit/template-simple-yaml-test.sh: pins _TPL_STAGES count and indices. This change adds no stages — it's pre-admission. NOT a gap.
- config/adr-enforcement-baseline.txt: ADR-059 is NOT in the baseline; it already has ## Enforced by section. The new §7 adds a bullet naming run-cap-test.sh (already in scope). Lint covered.
- Repo-wide grep for run_cap/ZBUILD_MAX_CONCURRENT_RUNS/ZBUILD_NO_RUN_CAP: ZERO pre-existing references. Entirely new symbols.

## Conclusions
- All prefilter candidates are false positives:
  - shape-change-golden: event-sequence goldens pin normal flow, not refusal path
  - shape-change-numeric: "7" references are SPEC-7/ADR-069§7 in existing tests, not stage counts changed by this PR
  - shape-change-order: no stage reordering; admission check is pre-stage
- No tests reference the new symbols (entirely new module)
- Design scope is complete: 7 files cover new module, integration, dependency reads, event schema, ADR amendment, test

## Verdict
complete — no missing files
