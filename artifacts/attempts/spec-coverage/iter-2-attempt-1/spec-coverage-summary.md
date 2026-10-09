## spec-coverage — covered

- The 10 SPECs in the ACCEPTANCE section collectively cover all six requirements — SPEC-8 structurally asserts each of the six converted files calls `_acceptance_timeout_prefix` and retains no old inline probe (closing the detection gap the bare-timeout lint cannot catch), SPEC-9 confirms each of the five non-acceptance sites produces a bounded gtimeout command on a gtimeout-only host, and SPEC-10 tests the per-caller kill-grace env-var bridge, together addressing the R-1 and R-3 gaps identified by the prior run.

- every requirement the issue states maps to a declared SPEC
