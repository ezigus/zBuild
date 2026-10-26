## design — fail

- the design fails 2 check(s)

- The issue asks for this and no SPEC covers it: R-3: "Every test that used it as a fixture passes on `orch-mock` or `bash-parallel`" — SPEC-11 covers only `plugins/tool/orch-sequential/tests/orch-sequential-test.sh`
- The issue asks for this and no SPEC covers it: no SPEC requires that the other in-scope files (e.g., `tests/integration/stage-time-limit-test.sh`, `tests/unit/map-strategy-test.sh`) which referenced orch-sequential as a behavioral fixture are migrated to pass on orch-mock or bash-parallel rather than simply having their orch-sequential references stripped (and the files deleted) to satisfy SPEC-3's guard.

This try is kept as the working copy for the next run; design.md is unchanged.
