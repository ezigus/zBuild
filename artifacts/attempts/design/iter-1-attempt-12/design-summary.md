## design — fail

- the design fails 4 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: design finding 1: done — Redesigned `claim.sh` to call the public hooks `claim_coordinator_claim` and `claim_coordinator_release` instead of `_ccgl_*` internals. `claim_coordinator_claim` is now amended (in the plugin.sh step) to return `{"acquired": false, "holder": "<extracted_holder>"}` on conflict, so `claim.sh` parses the JSON output. The step for `plugin.sh` explicitly removes the `source` of `core/claim/claim.sh` currently at plugin.sh lines 251-260 (the circular dependency from the previous implementation). The dependency arrow is strictly: `runner.sh` → `claim.sh` → `plugin.sh`.
- answered: design finding 2: done — Changed `DSCLA-18` from `[no-code]` to `[code]` and added Given/When/Then. Test fails on base code because `claim_coordinator_claim` adds `claimed:<machine>` (not `zbuild:claimed`); passes after.
- answered: design finding 3: done — Changed `DSCLA-19` from `[no-code]` to `[code]` and added Given/When/Then. Test fails on base code because `core/claim/claim.sh` does not exist; passes after the file is created.
- answered: design finding 4: done — Restructured the Decision section so each major component is a single bold bullet with concise, self-contained description. Removed the multi-line "Startup process budget" prose paragraph (not a decision) and the complex multi-line `claim.sh` paragraph that embedded `_ccgl_*` function names. The amended `claim.sh` decision bullet now cleanly states it calls `claim_coordinator_claim` and `claim_coordinator_release`, matching the step text verbatim.
