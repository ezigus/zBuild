## issue-acceptance — fail

- npm test exits non-zero (7+ failures introduced by the PR: mutation harness tests can't find `timeout-cmd.sh` because run-mutation.sh now sources it by relative `SCRIPT_DIR` that resolves to temp dirs when the script is copied; two structural tests grep for the now-removed `_RT_KILL_GRACE` literal; shellcheck SC2034 on `ZBUILD_NEGCTL_KILL_GRACE` fails lint)

- NOT MET: R-6 (npm test: run-mutation-empty-dir-clean-gate, run-mutation-kill-grace, run-mutation-stale-anchor, mutation-relevance all fail because their sandboxes copy run-mutation.sh but not lib/timeout-cmd.sh
- NOT MET: acceptance-negctl and run-tests-timeout-report fail because they grep for the literal `"-k" "$_RT_KILL_GRACE"` which the PR removed
- NOT MET: npm run lint fails via shellcheck SC2034 on ZBUILD_NEGCTL_KILL_GRACE assigned but not exported/seen in run-tests.sh and run-mutation.sh)
