## spec-coverage — uncovered

- Several requirements from the issue's explicit checklist and "What this plugin adopts" section have no SPEC: router budgets moved to the manifest, `primary: true` output declared, `provides.events` declared for all three plugins, the `cleanup` hook handled; and deploy-release's SPEC-8/9 omit both `valid_verdicts` and `verdict` (present in SPEC-1/2 and SPEC-4/5 for merge and pr-open) and there is no deploy-release analogue of SPEC-3/SPEC-6 enforcing rc∈{0,1}; finally `provides.role` is specced only for merge (SPEC-1), not for pr-open or deploy-release.

- NOT COVERED: router budgets declared in manifest (explicit checkbox)
- NOT COVERED: `primary: true` output declared in manifest (explicit checkbox)
- NOT COVERED: `provides.events` declared for all three plugins
- NOT COVERED: `cleanup` hook presence or deliberate absence recorded
- NOT COVERED: deploy-release `valid_verdicts` absent from SPEC-8
- NOT COVERED: `verdict` field absent from SPEC-9
- NOT COVERED: no rc∈{0,1} constraint spec for deploy-release
- NOT COVERED: `provides.role` unspecced for pr-open and deploy-release
