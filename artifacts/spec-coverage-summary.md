## spec-coverage — covered

- Every explicit issue checkbox maps to at least one SPEC — v2 result on all exits (SPEC-1), summary required:true on every verdict including the ADR-055 §9 addition (SPEC-2), no hardcoded artifact paths (SPEC-3), behavioral parity for passing runs (SPEC-4), valid_verdicts with per-verdict tests (SPEC-5), router budget handling addressed via structural inapplicability (SPEC-6), and primary:true output (SPEC-7); the remaining checkboxes ("npm test green", "Reddens at the merge-base") are process discipline constraints, not behavioral requirements needing SPEC coverage.

- every requirement the issue states maps to a declared SPEC
