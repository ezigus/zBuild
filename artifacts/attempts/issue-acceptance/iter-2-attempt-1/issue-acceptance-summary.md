## issue-acceptance — fail

- `tests/unit/impact-max-turns-test.sh` — one of the `impact-*-test.sh` files the issue declares must still pass — fails because it loads `simple.yaml` and reads `_TPL_STAGE_ROUTER_*` for the now-absent `impact` stage, breaking R-2; the suite failure also makes R-5 unverifiable.

- NOT MET: R-2: `impact-max-turns-test.sh` is an `impact-*-test.sh` unit test the issue says must still pass
- NOT MET: it calls `load_template simple.yaml` then reads `template_stage_router_max_turns impact`, which is now unset — all three assertions fail
- NOT MET: `template-always-run-test.sh` also fails (SPEC-2 pinned count=20, now 19) but is outside the issue scope
- NOT MET: R-5: test suite is failing, dogfood run completion cannot be confirmed.
- NOT SURE: R-1: the new assertions in `template-simple-yaml-test.sh` SPEC-18 and `deployed-template-e2e-test.sh` exist and the acceptance-gate confirms they fail on main, but "state the red step in the PR body" cannot be verified from the diff alone. — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
