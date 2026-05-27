# ADR-002: Legacy Import Strategy

**Status:** Accepted
**Date:** 2026-05-24

## Context

zBuild is a rearchitecture of an upstream system. The original Keepers Spec argued for starting clean; a content audit found **1,851 LoC of incident-hardened content** across 12 categories (compound-audit prompts, sentinels, gate-signal regex, scope parser, skill .md fragments, pessimist template, simulation personas, error-classifier rules, hallucination filter, dedup, safe_git_stage). This content is the product of years of incident response; retyping from spec re-introduces the bugs each block defends against.

Three import options were considered:
- **(a) `git subtree add` the upstream as `legacy/`**, preserving history. Pros: full git blame; cons: grafted history confuses `git log`, complicates future updates.
- **(b) Plain copy without history.** Pros: simplest, clean zBuild history, easy to prune; cons: lose blame trail (mitigated by file:line citations in KEEPERS.md).
- **(c) `git filter-repo` to rewrite upstream history under `legacy/` prefix, then merge.** Pros: blame survives; cons: slow on 1160 commits, merge-risky, high effort for reference-only value.

The dominant concern is the **PROJECT_ROOT collision** risk: legacy scripts derive `PROJECT_ROOT` from `git rev-parse --show-toplevel`, so running any legacy script from inside the zBuild repo writes state to zBuild's `.claude/`, claims labels in zBuild's GitHub issues, and pollutes shared event logs.

## Decision

**Option (b) — plain copy, no git history.** The upstream is being sunset; full history preservation is reference-only value. Plain copy is simplest, keeps zBuild's git history clean, and the `legacy/` tree shrinks to zero as keepers verify out.

### Sentinel-guard protocol (mitigates PROJECT_ROOT collision)

1. Copy the upstream source verbatim into `legacy/`.
2. Add `legacy/FROZEN.md` at the top of `legacy/` with explicit "DO NOT RUN" notice.
3. Add `legacy/.shipwright-disabled` sentinel file.
4. **Patch one line in `legacy/scripts/sw`** to check for the sentinel at startup and refuse to run when present.

**This one-line patch is the SOLE exception to "preserve legacy verbatim."** Every other legacy file is touched only by `git rm` during the pruning protocol. The patch is documented inline in the file with a comment pointing at this ADR.

### Pruning protocol

When a keeper passes its 5-test trial (see KEEPERS §J):
1. `git rm` the legacy source file(s) for that keeper.
2. Create `legacy/migrated/<keeper-id>.md` with one line:
   ```
   <keeper-id> migrated to <new-path> on <YYYY-MM-DD> (issue #<N>)
   ```
3. Commit both in one commit: `migrate: <keeper> → <path>, remove legacy sources`.

The `legacy/migrated/` tombstone tree is the audit trail. `ls legacy/migrated/` answers "what's done." The `legacy/` tree shrinks to zero by end-of-migration.

### Wrapper for intentional invocation

Any legitimate need to run a legacy script (e.g., generating a fixture for a 5-test trial) MUST use the wrapper:

```bash
(cd legacy && \
 PROJECT_ROOT="$(pwd)" \
 SHIPWRIGHT_HOME="$(pwd)/.shipwright-legacy" \
 SHIPWRIGHT_OVERRIDE_DISABLED=1 \
 ./scripts/sw <args>)
```

The override env var is recognized only when the sentinel still exists, preventing accidental enablement.

## Consequences

**Good:**
- 1,851 LoC of hardened content survives the move.
- File:line citations in KEEPERS.md resolve immediately after import.
- `legacy/` shrinking to zero is a visible migration progress signal.
- Sentinel-guard prevents the most likely accidental damage (a developer running a legacy script).
- One-line exception is auditable.

**Bad:**
- Lose git blame for legacy content. Mitigation: KEEPERS.md citations include line numbers; `git log --follow` on the upstream repo remains available.
- Sentinel-guard is bypassable by sufficiently determined developers. We accept this; the goal is to prevent accidents, not to enforce a security boundary.
- Two `.gitignore`s, two `.claude/` directories, two LICENSE files exist briefly. Documented as expected; the legacy versions remain unreachable.

## Implementation Notes (Phase 0.5 — issue #291)

| Item | Status | PR / Notes |
|------|--------|------------|
| Plain-copy import of `legacy/` | Implemented | commit `5484736` (#0.5 import) |
| `legacy/.shipwright-disabled` sentinel file | Implemented | commit `5484736` |
| `legacy/FROZEN.md` "DO NOT RUN" notice | Implemented | commit `5484736` |
| `legacy/scripts/sw` one-line sentinel patch | Implemented | commit `5484736` (sole edit exception per ADR) |
| `git rm` + `legacy/migrated/<keeper-id>.md` pruning protocol | Active | 1 keeper pruned so far: `security-lens` (commit `048343b`); remaining keepers pending 5-test trials |
| Intentional-invocation wrapper documented | Implemented | ADR §Wrapper section + KEEPERS.md §N |
| KEEPERS.md file:line citations (blame-loss mitigation) | Implemented | KEEPERS.md throughout |

## References

- [KEEPERS.md §N](../KEEPERS.md#section-n--repository-creation--legacy-import) — full rationale for plain-copy decision.
- [ARCHITECTURE.md §8](../ARCHITECTURE.md#8-what-lives-where-file-system-tour) — `legacy/` placement in the file-system tour.
- Legacy content audit (1,851 LoC across 12 categories) — see KEEPERS.md §N.
