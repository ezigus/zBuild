## review-lens-correctness — fail

- found: medium: DSDIFF-1 and DSDIFF-2 only test the positive case (files_count=0 emits the event); a regression that removed the `"$files_count" -eq 0` guard from the elif branch would leave both tests green, because neither test asserts the event is absent when files_count > 0. (plugins/agent/build/tests/build-test.sh) (and 2 more)

- medium: DSDIFF-1 and DSDIFF-2 only test the positive case (files_count=0 emits the event); a regression that removed the `"$files_count" -eq 0` guard from the elif branch would leave both tests green, because neither test asserts the event is absent when files_count > 0. (plugins/agent/build/tests/build-test.sh)
- low: DSLOCK-3 redirects stderr into the diff capture with `2>&1`; if git cannot resolve the abbreviated SHA `6a07fa8e` (ambiguous or object absent), the error message is treated as diff output and the assert fires with 'diff is non-empty' rather than indicating the check itself failed. (tests/unit/route-loop-terminated-reasons-test.sh)
- low: The DSEND-1 extraction greps all of `route.sh` for `_ROUTE_LOOP_TERMINATED_REASON` assignments, not just those inside `route_to_model_loop`; a value assigned only in another function (e.g. the signal handler at line 1106) would be added to `_required` and force the comment to list a reason `route_to_model_loop` never produces, while the comment is scoped to that one function. (tests/unit/route-loop-terminated-reasons-test.sh)
- score: 8
