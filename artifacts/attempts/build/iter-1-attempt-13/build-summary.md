## build — pass

- changed core/claim/claim.sh, plugins/claim-coordinator/github-labels/plugin.sh (+41 / -12)

- over 1 pass(es), 1 iteration(s)
- answered: RLSECURITY-1: done — broadened ANSI stripping in core/claim/claim.sh from `[mK]` terminators to `[a-zA-Z~]` plus bare ESC-X pairs, matching `_eb_strip_ansi` coverage, with fast-path guard.
- answered: RLSECURITY-2: done — fixed both `escaped_holder` assignments in `plugins/claim-coordinator/github-labels/plugin.sh` to escape `\` → `\\` before `"` → `\"`.
- answered: RLREDTEAM-1: done — same fix as RLSECURITY-1; CSI sequences with any letter/~ terminator and bare ESC-X pairs are now stripped before the holder reaches `printf '%s\n'`.
- answered: RLCORRECTNESS-1: done — replaced `grep -o '"holder":[[:space:]]*"[^"]*"'` with `jq -r '.holder // empty'` in `core/claim/claim.sh`; jq correctly handles escaped characters in the JSON string value.
- answered: RLSRE-1: done — removed `return 0` from `claim_coordinator_release` in `plugins/claim-coordinator/github-labels/plugin.sh`; `_ccgl_remove_label`'s exit code now propagates so the advisory warning in `zbuild_claim_release` fires on gh failures.
- step 1: not needed — plugins/claim-coordinator/github-labels/plugin.sh already has zbuild:claimed throughout; done in prior iterations.
- step 2: not needed — plugins/claim-coordinator/github-labels/README.md already describes zbuild:claimed with no claimed:<machine> references; done in prior iterations.
- step 3: not needed — scripts/lib/run-status-render.sh already emits <!-- zbuild-holder: ... --> in rsc_render_header; done in prior iterations.
- step 4: not needed — core/claim/claim.sh exists as the wiring bridge; done in prior iterations (this iteration fixed the ANSI/extraction quality but not the step's deliverable).
- step 5: not needed — config/event-schema.json already registers pipeline.refused.claimed; done in prior iterations.
- step 6: not needed — core/pipeline/runner.sh already has full claim wiring; done in prior iterations.
- step 7: not needed — docs/adr/ADR-005-claim-coordinator.md already has the ## Enforced by section with all named tests; done in prior iterations.
- step 8: not needed — docs/adr/ADR-059-issue-vs-run-keying.md already has the §4 Enforced by entry naming [DSCLA-3]; done in prior iterations.
