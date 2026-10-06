## spec-coverage — uncovered

- SPEC-1[code] covers only the negative clause of R-4 (no sentence in ADR-028 says "not migrated"), but R-4 also requires ADR-028 to positively name both stages as migrated — a positive-presence check that no SPEC demands; the prior design's SPEC-6 covered this but was dropped in iter-2 with a claim of subsumption into SPEC-2[done]/SPEC-3[done], which cover plugin code, not the ADR document.

- NOT COVERED: R-4: "ADR-028 names both stages as migrated
- NOT COVERED: no sentence in it says otherwise" — the second clause ("no sentence says otherwise") is covered by SPEC-1[code], but the first clause ("names both stages as migrated") has no SPEC
- NOT COVERED: SPEC-2[done] and SPEC-3[done] attest the plugin code calls the right function, not that the ADR document records the migration positively
