## spec-correspondence — mismatch

- judged 12 SPEC(s): 9 correspond, 2 partial, 1 mismatch, 0 uncheckable, 0 unjudged

- SPEC-6 MISMATCH: The acceptance-gate's NEGCTL result shows this assertion passes at the unmodified baseline, so a passing assertion cannot establish that the previously-absent write behavior was added.
- SPEC-8 partial: The assertion tests only the empty-lenses invocation path, which establishes that the plugin returns 0 for that one input, not for the "always" the requirement claims.
- SPEC-9 partial: The assertion tests byte-for-byte equivalence on a single crafted input; a single match establishes equivalence only for that case, not the general claim.

