## shape-floor — fail

- files that spell out a count, order or list this change alters were not updated

This change alters a count, order or list that these files also spell out, and they were not updated.
Update any that are now wrong. A file that is still correct can stay as it is: the full test run on this change shows that.
- tests/golden/full-pipeline/event-sequence.golden
- tests/golden/parity/event-sequence.golden
- tests/unit/shape-floor-content-stable-test.sh
- tests/unit/build-oos-pass-request-test.sh
- tests/unit/change-scope-floor-test.sh
- tests/unit/core-pipeline-template-test.sh
- tests/unit/template-resolvability-preflight-test.sh
- tests/unit/impact-prefilter-order-detector-test.sh
- tests/unit/shape-floor-summary-plain-test.sh

