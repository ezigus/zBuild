## design — fail

- the design fails 1 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: design finding 1: done — Rewrote DSCLA-8 and DSCLA-17. DSCLA-8 `Then:` now reads "the coordinator's claim hook is not called" (was "no gh label command is invoked"). DSCLA-17 `Then:` now reads "the coordinator's release hook is not called" (was "no gh label command is invoked"). The `claim.sh` step also explicitly states that `zbuild_claim_acquire` "returns 0 immediately without calling `discover_plugins` or any coordinator hook when issue is empty" and `zbuild_claim_release` "returns 0 immediately without calling any coordinator hook when `_ZBUILD_CLAIM_ACQUIRED` is unset."
- answered: design finding 2: done — Changed DSADR-7: replaced `teardown-repeat-signal-test.sh [DSCLA-9]: refused output names holder` with `claim-coordinator-unit-test.sh [DSCLA-9]: refused output names holder`. Both DSCLA-3 and DSCLA-9 are about the refused-run path and belong in `claim-coordinator-unit-test.sh`, which the design already names for DSCLA-3.
- answered: design finding 3: done — Updated the ADR-005 step: replaced `teardown-repeat-signal-test.sh [DSCLA-9] (refused output names holder)` with `claim-coordinator-unit-test.sh [DSCLA-9] (refused output names holder)`.
- answered: design finding 4: done — Same fix as findings 2 and 3: DSADR-7 now reads `claim-coordinator-unit-test.sh [DSCLA-9]: refused output names holder` instead of `teardown-repeat-signal-test.sh [DSCLA-9]: refused output names holder`.
