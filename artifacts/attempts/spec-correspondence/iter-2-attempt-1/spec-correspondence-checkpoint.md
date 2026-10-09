# spec-correspondence checkpoint

## Files read
- design.md: 17 files in scope, 10 SPECs. Key context: _acceptance_timeout_prefix moves to timeout-cmd.sh; six inline probes replaced; lint-bare-timeout.sh added; kill-grace bridged per caller via ZBUILD_NEGCTL_KILL_GRACE.

## Conclusions reached
- SPEC-1: corresponds — assertion checks [0]=gtimeout on gtimeout-only PATH, exactly matching requirement
- SPEC-2: corresponds — assertion checks rc=0 AND empty array, both conditions from requirement
- SPEC-3: corresponds — exit 1 maps to inert_build signal; failing path returned
- SPEC-4: corresponds — all three cases (bad/clean/allow) tested with matching exits
- SPEC-5: corresponds — first grep checks presence, second regex checks allow comment is on timeout invocation line
- SPEC-6: partial — assertion checks for string presence of key identifiers but does NOT check "dated" paragraph, does NOT check "bare timeout call is a lint failure" text, does NOT verify ## Enforced by section heading or that entries are under it
- SPEC-7: corresponds — checks package.json contains linter reference AND runs linter live on repo
- SPEC-8: corresponds — assertion checks both (a) _acceptance_timeout_prefix present and (b) no command -v gtimeout, for all 5 enumerated files
- SPEC-9: partial — loop calls same _acceptance_timeout_prefix 60 for every label; labels are only in assert messages, not used to source/exercise site-specific code; tests helper 5 times identically rather than each site's actual call
- SPEC-10: corresponds — checks -k flag and grace value in array for both bridges; if both blocks pass, both callers are wired correctly

## Revision to SPEC-6 after re-read of assertion
Prior checkpoint wrongly said "does NOT check 'dated' paragraph" and "does NOT check 'bare timeout call is a lint failure'". Re-reading the assertion: it DOES check date+#1752 regex and DOES check "bare.*timeout.*lint failure" text, and DOES use awk to verify entries appear under ## Enforced by. Partial verdict stands but for a narrower reason: the "every timeout bound in core/, scripts/, and plugins/ resolves through" scope clause is only covered by string presence of _acceptance_timeout_prefix, not the full statement.

## All 10 SPECs judged. Nothing unresolved.

## Findings answer
All test/issue-acceptance findings are implementation bugs. spec-correspondence stage produces verdicts only; no code changes are within scope.
