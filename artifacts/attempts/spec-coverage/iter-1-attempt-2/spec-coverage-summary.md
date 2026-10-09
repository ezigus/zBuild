## spec-coverage — covered

- All six requirements are covered by the ten SPECs; the failing issue-acceptance findings trace to the build stage assigning `ZBUILD_NEGCTL_KILL_GRACE` without `export` (violating design line 11 and SPEC-10's explicit mandate) and pre-existing legacy-exclusion failures the design expressly acknowledges, neither of which is a gap in spec coverage.

- every requirement the issue states maps to a declared SPEC
