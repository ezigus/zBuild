# Shipwright Issue Template

Use this template when creating issues that will be processed by the Shipwright autonomous pipeline.
Good issue quality directly reduces wasted pipeline iterations.

---

## Template

```
# Title: <imperative verb-first, 60-char max>

## Problem
<1-3 sentences. What's wrong / missing / why now.>

## Behavior change (acceptance criteria)
- [ ] <observable behavior 1 — testable without a human>
- [ ] <observable behavior 2>
- [ ] <observable behavior 3>

## Out of scope
- <what this issue is NOT solving>

## How to verify (autonomous)
<Commands the pipeline can run to confirm — `npm test`, `bash scripts/sw-X-test.sh`,
specific assertions. No "I'll smoke test on the PR" — that's manual scope.>

## Toggles / config (if any)
- Env var: `SHIPWRIGHT_X` (default: ...)
- Config: `daemon-config.json` key `...`

## Related
- Prior PRs: #...
- Related issues: #...
```

## Key rules for Shipwright-compatible issues

1. **No manual-only DoD items.** "I'll smoke test on the PR" blocks the autonomous loop forever. Use `npm test` or `bash scripts/sw-X-test.sh` instead.
2. **Acceptance criteria must be testable by a script.** If you can't write a command that checks it, it belongs in the PR description.
3. **Number your criteria once.** Avoid duplicate numbering (1/2/3 appearing twice with different content).
4. **Keep scope tight.** Mixed scopes cause the plan stage to invent DoD items that don't match the issue.
