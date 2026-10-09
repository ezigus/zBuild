## spec-coverage — uncovered

- The SPECs test the helper in isolation and the acceptance path end-to-end, but no SPEC verifies the six probe sites actually call the helper (the old inline `command -v gtimeout` patterns don't use bare `timeout`, so the lint cannot detect them), and the four non-acceptance sites lack per-site regression under a no-`timeout` host.

- NOT COVERED: R-1: "all six probe sites use it" — SPEC-1 tests the helper in isolation
- NOT COVERED: SPEC-7's bare-`timeout` lint does not detect a site that retains its old `command -v gtimeout / else timeout` inline probe rather than calling the helper
- NOT COVERED: no SPEC positively asserts that any of the six sites calls `_acceptance_timeout_prefix`
- NOT COVERED: R-3: "each converted site still bounds its command (regression test simulating the no-`timeout` host)" — SPEC-1 tests the helper on a gtimeout-only PATH and SPEC-3 tests the acceptance path, but `core/router/route.sh` (sync and loop), `scripts/run-tests.sh`, `scripts/run-mutation.sh`, and `scripts/lib/gh-automation.sh` have no per-site regression test on a no-`timeout` host
- NOT COVERED: additionally, each caller must map its own kill-grace env var to `ZBUILD_NEGCTL_KILL_GRACE` before calling the helper and no SPEC tests this per-caller mapping
