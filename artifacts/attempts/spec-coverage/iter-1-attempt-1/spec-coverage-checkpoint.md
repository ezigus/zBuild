# Spec-coverage checkpoint

## Files read
- design.md: 7 SPECs, covers event-bus fork reduction (SPEC-1/2/6), timestamp fix (SPEC-1), sidecar self-trigger (SPEC-3/4/5), ADR amendment (SPEC-7)
- requirements.json: R-1 through R-6 confirmed

## Conclusions
- R-1 (cost reduced, measured before/after): SPEC-2 (single-jq) + SPEC-6 (FORK_BUDGET below merge-base, test fails on unpatched code) — covered
- R-2 (no malformed timestamps incl. map units on macOS): SPEC-1 (ZBUILD_PLATFORM=linux, OSTYPE=darwin* test) — covered
- R-3 (every in-stage event carries stage; redaction.applied attributed): SPEC-5 (sidecar stage attribution) + SPEC-3 (cursor reset prevents re-arm) — covered
- R-4 (watcher not re-woken by own events; no PATCH when body unchanged): SPEC-3 (cursor reset) + SPEC-4 (cmp-s skip) — covered
- R-5 (fork count pinned by test, lower than merge-base): SPEC-6 + SPEC-7 — covered
- R-6 (event contents otherwise unchanged): SPEC-2 (byte-for-byte identical output) — covered

## Status
All requirements covered. Ready to write verdict.
