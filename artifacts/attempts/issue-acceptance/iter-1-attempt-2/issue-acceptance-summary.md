## issue-acceptance — fail

- Three tests fail: the process-group kill integration test (SPEC-6b, R-2) shows a hook child that ignores TERM still alive 5 s after the runner returned; the dispatch test (SPEC-10, R-10) finds a hand-rolled `kill -KILL` in `plugin_hook_call`; and `set -m` inside `plugin_hook_call` breaks the pre-existing job-control test, leaving npm test red (R-13).

- NOT MET: R-2: whole process group dies — `runner-release-exit-paths-test.sh` SPEC-6b fails (pid still alive 5 s after runner returned, proving the process-group kill is incomplete)
- NOT MET: R-10: no hand-rolled TERM/KILL sequence remains — `stage-timeout-dispatch-test.sh` SPEC-10 fails because `kill -KILL -- -"$_lc_hook_pid"` is present in `plugin_hook_call` after `wait`
- NOT MET: R-13: `npm test` green — 3 of 29 targeted tests fail (runner-job-control-abort-test.sh, runner-release-exit-paths-test.sh, stage-timeout-dispatch-test.sh)
