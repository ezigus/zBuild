## issue-acceptance — fail

- `npm test` is red — `dispatch-rc-guard-test` reports lifecycle.sh grew two new rc=2 return paths (the TERM-trap `exit 143` violates the ADR-054 §4 `{0,1}` constraint), and `stage-timeout-precedence-test` finds no `sleep 5400` watchdog spawned when neither template nor env sets the timeout, so the 5400 s default tier is not wired.

- NOT MET: R-3: precedence — isolation variant fails, no `sleep 5400` captured in fake-sleep log
- NOT MET: R-13: npm test red — `dispatch-rc-guard-test` (lifecycle.sh rc outside {0,1}) and `stage-timeout-precedence-test` (5400 s default not observed) both fail
- NOT SURE: R-1: lifecycle.sh's `exit 143` in the TERM trap makes plugin_hook_call return a code outside {0,1} — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
- NOT SURE: whether the per-dispatch watchdog fires correctly on every route cannot be confirmed while that constraint is broken — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
- NOT SURE: R-10: the `always_run` hand-rolled kill is replaced in this diff, but lifecycle.sh's SPEC-10 check (no `kill -KILL` after `wait` in plugin_hook_call) is not visible in the diff and its prior finding was open — the current test run does not list `stage-timeout-dispatch-test` as failing, but the dispatch-rc-guard failure means lifecycle.sh is in a broken state that could mask other assertions — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
