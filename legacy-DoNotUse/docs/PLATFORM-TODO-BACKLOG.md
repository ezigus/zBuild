# Platform TODO/FIXME/HACK Backlog

**Source:** `shipwright hygiene platform-refactor` → `.claude/platform-hygiene.json`  
**Purpose:** Track TODO, FIXME, and HACK markers for triage; strategic agent can suggest "Resolve TODO in X" as issues.

## How to refresh

```bash
shipwright hygiene platform-refactor
jq '.counts, .findings_sample[0:10]' .claude/platform-hygiene.json
```

**File:line list for triage** (after refresh):

```bash
jq -r '.findings_sample[]? | "\(.file):\(.line)"' .claude/platform-hygiene.json
```

## Triage

- **TODO** — Create a GitHub issue or implement; add `TODO(issue #N)` in code when deferred.
- **FIXME** — Same as TODO; prefer fix or document.
- **HACK/KLUDGE** — Replace with proper fix or add comment: `# HACK: reason (tracked in #N)`.

## Current counts (from last scan: 2026-02-16)

| Marker | Count | Action                                                     |
| ------ | ----- | ---------------------------------------------------------- |
| TODO   | 37    | Triage; create issues or mark "accepted tech debt" in code |
| FIXME  | 19    | Same as TODO                                               |
| HACK   | 17    | Replace or document with tracking comment                  |

See `.claude/platform-hygiene.json` for live counts and `findings_sample` (file:line).  
Strategic agent uses this file when suggesting platform refactor issues.

## Prioritized next steps

1. **Run triage** — Use `jq -r '.findings_sample[]? | "\(.file):\(.line)"' .claude/platform-hygiene.json` to list all; batch into issues by file or theme.
2. **High-traffic scripts first** — sw-pipeline.sh, sw-daemon.sh, sw-recruit.sh have most findings; address critical path items.
3. **Dead code (Phase 4.3)** — Run `shipwright hygiene` dead-code scan; remove or refactor unused functions.
4. **Fallback reduction (Phase 4.4)** — Where policy or adaptive data exists, remove duplicate hardcoded fallbacks.
