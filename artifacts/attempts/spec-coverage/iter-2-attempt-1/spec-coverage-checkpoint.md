# spec-coverage checkpoint (updated — round 2)

## Files read
- `/home/runner/work/_temp/zbuild-state/artifacts/design.md` — prior run artifact; 7 SPECs.
- `/home/runner/work/_temp/zbuild-state/cycle-design_verify_cycle/iter-2/feedback/design.txt` — authoritative design file; also 7 SPECs (SPEC-1 through SPEC-7 only).
- Prompt ACCEPTANCE section — 10 SPECs (SPEC-1 through SPEC-10); this is what the pipeline presents as "sentences the design commits to" and is judged as authoritative.

## Key discrepancy
Design file has 7 SPECs; prompt ACCEPTANCE has 10. SPEC-8, SPEC-9, SPEC-10 appear in the ACCEPTANCE section but not in the design file. Judging against the prompt ACCEPTANCE as authoritative.

## Analysis — all 6 requirements against 10 SPECs

**R-1: A shared helper exists; all six probe sites use it.**
- SPEC-8: structurally greps each of the 5 files (6 sites); asserts ≥1 `_acceptance_timeout_prefix` AND zero old `command -v gtimeout` inline-probe pattern. Zero-occurrences check catches retained old probe at either route.sh site.
- SPEC-9: runtime behavior for all 5 non-acceptance sites including BOTH route.sh paths explicitly.
- SPEC-1/2: confirm helper exists.
- **COVERED**

**R-2: Lint fails on bare `timeout`; release.sh:629 covered or exempted.**
- SPEC-4 (lint exits 1 / exits 0 / allow-comment suppression), SPEC-5 (release.sh exempted with reason), SPEC-7 (lint exits 0 on clean repo), SPEC-8 (detects retained inline probes the lint cannot catch).
- **COVERED**

**R-3: On gtimeout-only host, each converted site bounds its command.**
- SPEC-9: all 5 non-acceptance sites → non-empty command with gtimeout as first element.
- SPEC-1: helper on gtimeout-only PATH.
- SPEC-3: acceptance-gate path end-to-end.
- SPEC-10: kill-grace env var bridge for run-tests.sh and run-mutation.sh.
- **COVERED**

**R-4: Failing acceptance testfile still yields `inert_build`.** SPEC-3. **COVERED**
**R-5: ADR-036 amended + Enforced by naming lint.** SPEC-6. **COVERED**
**R-6: npm test + npm run lint green.** SPEC-7 + all unit SPECs. **COVERED**

## Final verdict
VERDICT: covered — all 6 requirements covered by the 10 SPECs in the ACCEPTANCE section.
