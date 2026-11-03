## design — fail

- the design fails 3 check(s)

- The issue asks for this and no SPEC covers it: R-9 — SPEC-7 (sole SPEC naming R-9) demands only cycle-orchestrator loop-state restoration; the requirement that all three resume entry paths (--resume flag, auto-resume on status=interrupted, `zbuild pipeline resume --run-id`) each find the interrupted run's state in `runs/<run_id>/` and each behave as R-1 is not demanded by SPEC-7; SPEC-9 ensures all three paths invoke `_runner_resume_rehydrate` but names R-12, not R-9
- The issue asks for this and no SPEC covers it: R-10 — SPEC-3 (sole SPEC naming R-10) demands --from-stage dispatch behavior; the requirement that a run with no prior state proceeds as a fresh start with no rehydration is not demanded by SPEC-3's text; SPEC-10[done] (resume.sh:247) provides exactly this guarantee but names R-13, not R-10
- The issue asks for this and no SPEC covers it: R-12 — SPEC-9 (sole SPEC naming R-12) demands that all three entry paths invoke `_runner_resume_rehydrate`; the requirement to amend ADR-006 with step 3.6 naming its enforcing tests inline is not demanded by SPEC-9's text; SPEC-5 verifies the amendment via assert_contains assertions but names R-5, not R-12

This try is kept as the working copy for the next run; design.md is unchanged.
