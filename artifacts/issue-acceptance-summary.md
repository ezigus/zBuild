## issue-acceptance — fail

- The test suite is red — the new SPEC-6 assertion introduced by this diff immediately fails because ADR-054 §11's body does not contain any of the required per-run-limit keywords (`max_run_s`, `wall-clock`, `per-run`, `run-level`, `run limit`), leaving both R-9 and R-10 unmet.

- NOT MET: R-9: ADR-054 §11 exists but its content fails the new keyword check — the §11 section does not describe the per-run limit in the terms the test requires
- NOT MET: R-10: npm test fails (1 of 45 assertions red — `[#1944/SPEC-6] ADR-054 §11 content describes the per-run limit`)
- NOT SURE: R-2: test assertions pass but both branches of the between-dispatches conditional call `assert_pass`, making the sub-requirement unfalsifiable — putting old code back would not redden it — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
- NOT SURE: R-4: issue requires both `release` AND `persist` always-run stages to fire after timeout — the diff and visible test output do not confirm `persist` is separately constructed or asserted — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
