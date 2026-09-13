# Design-gate: structural violations

The design contract is not build-ready. Fix these and re-emit design.md:

- GUARD_REGRESSED_AT_BASELINE SPEC-6 (tagged [guard] but its assertion FAILS at the merge-base — a guard holds there by definition; if this SPEC describes a change, tag it [change])
- GUARD_REGRESSED_AT_BASELINE SPEC-7 (tagged [guard] but its assertion FAILS at the merge-base — a guard holds there by definition; if this SPEC describes a change, tag it [change])

## Guard baseline coverage

- 3 [guard] SPEC(s) declared; 1 verified at the merge-base, 2 failed.
