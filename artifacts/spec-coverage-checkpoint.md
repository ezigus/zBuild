# spec-coverage checkpoint

## Files read
- `/home/runner/work/_temp/zbuild-state/artifacts/design.md` — design has 7 SPECs, 17 files in scope; SPEC-1/2 test the shared helper in isolation; SPEC-3 tests acceptance path end-to-end; SPEC-4/5/7 cover the bare-timeout lint; SPEC-6 covers ADR-036 amendment.
- `/home/runner/work/_temp/zbuild-state/artifacts/requirements.json` — confirmed 6 requirements R-1 through R-6.
- `/home/runner/work/_temp/zbuild-state/intake.md` — full issue text; six probe sites named; old probes use `command -v gtimeout / else timeout` patterns (not bare `timeout` as a command); constraint requires env var mapping per caller.

## Conclusions

**R-2, R-4, R-5, R-6** — covered.
- R-2: SPEC-4 (lint failure/allow suppression), SPEC-5 (release.sh:629 exemption), SPEC-7 (lint exits 0 on clean repo).
- R-4: SPEC-3 (inert_build regression).
- R-5: SPEC-6 (ADR-036 dated amendment + Enforced by section).
- R-6: SPEC-7 + all unit SPECs together imply npm test + lint green.

**R-1 — uncovered (partial).**
Claim: "all six probe sites use it." SPEC-1 tests the helper exists and works in isolation. SPEC-7's lint detects bare `timeout` calls — but the OLD inline probe pattern uses `command -v gtimeout ... else timeout` in string/variable context, NOT bare `timeout` as a command. A site that retains its old inline probe would pass SPEC-7's lint. No SPEC positively verifies any of the six sites calls `_acceptance_timeout_prefix`.

**R-3 — uncovered (partial).**
Claim: "each converted site still bounds its command (regression test simulating the no-`timeout` host)." SPEC-1 tests the helper on gtimeout-only. SPEC-3 tests the acceptance path. But four non-acceptance sites — `core/router/route.sh` (×2), `scripts/run-tests.sh`, `scripts/run-mutation.sh`, `scripts/lib/gh-automation.sh` — have no per-site regression under a no-`timeout` host. The constraint also notes each caller must map its own kill-grace env var to `ZBUILD_NEGCTL_KILL_GRACE`; SPEC-1 does not test any caller's env-var mapping.

## Still unresolved
Nothing — all requirements assessed.

## If stopped now
VERDICT: uncovered. R-1 (no SPEC verifies all six sites call the helper) and R-3 (no per-site gtimeout-only regression for the four non-acceptance sites).
