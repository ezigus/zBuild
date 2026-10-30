## issue-acceptance — pass

- Every behavioral claim in the Decision block is implemented: `map.sh` now flags any non-pass outcome (`!= pass`), `runner.sh` stops the run at the map dispatch arm before `pr-delivery` when `ZBUILD_RUN_FLAGGED=yes`, the ADR amendment names both enforcing tests (which would catch reversions), `pr-delivery`'s `auto_unless_flagged` guard was already correct, and the full test suite passes with 830 assertions and 0 failures.

- every requirement the issue states is met by the change
