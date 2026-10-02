## issue-acceptance — fail

- The test suite fails — `lint-verdict-words` flags `complete` and `unavailable` as undeclared verdict literals in `plugin.sh` (lines 123, 242, 253, 273, 280), `lint-disposition-words` fails on the same strings, and `stage-signal-test.sh` fails `[G5] every literal unavailable names its service`; the manifest's `valid_verdicts` declares only `pass` and `error`, but the lint scanner treats the disposition argument strings in `_pr_delivery_write_result` calls as verdict writes.

- NOT MET: `npm test` green with the tree committed first (4 tests fail: lint-verdict-words-test.sh, lint-disposition-words-test.sh, stage-signal-test.sh
- NOT MET: SPEC-7 and SPEC-16 accepted as tautological by acceptance-gate)
