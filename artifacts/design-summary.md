## design — fail

- the design fails 2 check(s)

- the issue does not ask for this, or the design gets it wrong: (none)
- marked [done], but the code its evidence points at does not do it: SKIP-1 — the evidence code (lines 3895–3900) closes with `if [[ "$stage_status" == "complete" ]]; then` immediately followed by the comment `# #507: if the primary artifact has gone missing between runs`, revealing that the complete-status branch contains additional conditional logic rather than an unconditional skip; the SPEC asserts "skips any stage with stage_statuses[s]=='complete' during resume" without qualification, but the #507 comment shows the existing code applies distinct handling when the artifact is absent, so the actual skip is conditional on artifact presence, not on status alone — the SPEC overclaims what the pre-existing code does; the new RHYD-2 spec relocates the missing-artifact path to a pre-loop exit-1, confirming the current in-loop behaviour for that case is something other than a plain skip.

This try is kept as the working copy for the next run; design.md is unchanged.
