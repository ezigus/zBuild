## issue-acceptance — fail

- `npm test` and `npm run lint` both fail — all four new test files use `set +e; ...; set -e` mid-file (rejected by lint-test-errexit), `run-limit-precedence-test.sh` aborts with a bash syntax error (env-var assignment cannot prefix a subshell `(...)` on line 173), and three existing integration tests time out.

- NOT MET: R-4: test only exercises `release` on the timed-out exit path
- NOT MET: `persist` is never put in the always_run list, constructed, or asserted
- NOT MET: R-5: `run-limit-precedence-test.sh` crashes with a syntax error before its end-to-end misconfigured-runner assertions run, and the template-layer path is never exercised in a full runner invocation (acceptance-gate confirmed `template.sh` is inert)
- NOT MET: R-2: P2 in `run-timed-out-test.sh` calls `assert_pass` in both branches of its conditional, making the "watchdog fires when engine is idle between dispatches" sub-requirement unfalsifiable
- NOT MET: R-10: `npm run lint` fails (lint-test-errexit: 8 files), `npm test` fails (syntax error + 3 integration timeouts)
- NOT SURE: R-9: the issue acceptance criterion says "ADR-054 §9 amended" but §9 already exists as "Per-stage router configuration surface" (untouched) — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
- NOT SURE: the diff adds §11 with the correct run-limit content — whether the issue intended to amend the existing §9 or used §9 as a draft placeholder for the new (now §11) section cannot be determined without issue history — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
