## issue-acceptance — fail

- The test specifically written to prove R-2 (watchdog fires in the idle window between stage dispatches) explicitly fails — fast-two's sentinel file was found, proving the engine dispatched fast-two before the watchdog could fire — and `npm test` therefore exits non-zero.

- NOT MET: R-2: watchdog fires when engine is idle between dispatches — [#1944/SPEC-1] P2 asserts fast-two never started, but the sentinel was present, meaning the watchdog did not fire before the engine forked fast-two
- NOT MET: R-10: `npm test` fails (1 test failure, exit code 1) — the single code change in runner.sh (`{_RUNNER_ERR_FD}>&-`) was intended to fix the FD-leak that delayed watchdog delivery, but the test result shows it did not close the gap between fast-one completing (~t=2s) and fast-two being dispatched before the t=3s watchdog fires
