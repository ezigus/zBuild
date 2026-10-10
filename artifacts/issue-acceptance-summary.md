## issue-acceptance — pass

- The diff adds `_route_emit_model_route` and `_route_emit_outcome` (with per-iteration token variable population) to the loop path; the new integration test verifies all required fields for 1-iteration and 3-iteration loops with NEGCTL-confirmed red-before-green; the golden file is updated; all 842 tests pass; and the acceptance-gate records REACHABILITY PASS for both entry points in `core/router/route.sh`.

- every requirement the issue states is met by the change
