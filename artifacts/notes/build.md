# Build Notes — #1764 GitHub Label Claim

## Status: All acceptance tests pass; all review_lenses findings addressed

## Test results (this iteration — all PASS)

### claim-coordinator-unit-test.sh: 38/38 PASS
### teardown-repeat-signal-test.sh: 29/29 PASS
### lint-adr-enforced-by-test.sh: 29/29 PASS

## Findings addressed this iteration

### RLSECURITY-1 / RLREDTEAM-1: DONE
Broadened ANSI stripping in `core/claim/claim.sh` to match `_eb_strip_ansi` coverage:
CSI sequences ending in any letter or ~ (`[a-zA-Z~]`), plus bare ESC-X pairs
(`s/\x1b.//g`). Added fast-path guard `[[ "$holder_value" == *$'\x1b'* ]]` to skip
the sed fork when no ESC byte is present.

### RLSECURITY-2: DONE
Fixed JSON encoding in both `escaped_holder` assignments in `claim_coordinator_claim`:
escape `\` → `\\` before `"` → `\"` so the holder is valid JSON even when it contains
backslashes.

### RLCORRECTNESS-1: DONE
Replaced `grep -o '"holder":[[:space:]]*"[^"]*"'` + sed extraction with
`jq -r '.holder // empty'`. jq correctly decodes escaped characters in the JSON string,
so a holder containing `"` survives round-trip through claim_coordinator_claim's
JSON encoding and zbuild_claim_acquire's extraction.

### RLSRE-1: DONE
Removed `return 0` from `claim_coordinator_release`, allowing `_ccgl_remove_label`'s
non-zero exit code to propagate. When `gh issue edit --remove-label` fails (network
error, rate limit, etc.), `claim_coordinator_release` now returns non-zero, triggering
the advisory warning in `zbuild_claim_release`.

### DSCLA-23 (was failing before this iteration): DONE
Fixed `_ccgl_read_holder` gh backend to filter comments by the authenticated GitHub
actor: calls `gh api user --jq .login`, then uses `gh api repos/$repo/issues/$issue/comments`
with jq actor-filter (`select(.user.login == $actor)`) before searching for the
`<!-- zbuild-holder: -->` field.

## Code state: complete and correct

All design steps implemented (unchanged from previous iteration):
- plugin.sh: zbuild:claimed used, _ccgl_read_holder present (now with actor filter),
  conflict JSON return, source block removed
- README.md: zbuild:claimed documented, no claimed:<machine> references
- run-status-render.sh: <!-- zbuild-holder: ... --> in rsc_render_header
- core/claim/claim.sh: wiring bridge via plugin registry (now with jq extraction
  and broad ANSI stripping)
- config/event-schema.json: pipeline.refused.claimed registered
- runner.sh: full claim wiring (acquire/release/event/printf)
- ADR-005: Enforced by section with §1 and §2 bullets
- ADR-059: §4 Enforced by entry with DSCLA-3
