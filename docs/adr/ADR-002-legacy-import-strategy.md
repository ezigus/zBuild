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

**Option (b) — plain copy, no git history.** The upstream is being sunset; full history preservation is reference-only value. Plain copy is simplest, keeps zBuild's git history clean, and the frozen tree (`legacy-DoNotUse/` since 2026-10-09, first imported as `legacy/`) shrinks to zero as keepers verify out.

### Sentinel-guard protocol (mitigates PROJECT_ROOT collision)

1. Copy the upstream source verbatim into `legacy-DoNotUse/`.
2. Add `legacy-DoNotUse/FROZEN.md` at the top of the tree with explicit "DO NOT RUN" notice.
3. Add `legacy-DoNotUse/.shipwright-disabled` sentinel file.
4. **Patch one line in `legacy-DoNotUse/scripts/sw`** to check for the sentinel at startup and refuse to run when present.

**This one-line patch is the SOLE exception to "preserve legacy verbatim."** Every other legacy file is touched only by `git rm` when a keeper's replacement lands (the 2026-10-09 move of the whole tree is a rename, not an edit: no file's content changed). The patch is documented inline in the file with a comment pointing at this ADR.

### Pruning protocol

**Superseded 2026-10-09 — see the amendment below.** As first decided: when a keeper passed its
5-test trial (KEEPERS §J), its legacy source was `git rm`'d and a one-line tombstone was written
under a `migrated/` directory inside the frozen tree, as the audit trail of what was done. There
are no tombstones any more; the amendment's pruning rule replaces this one.

> **Deferred keepers:** if a keeper's 5-test trial is blocked on a deferred issue, the keeper's issue MUST cite the relevant issue number from [PHASE-DEFERRALS.md](PHASE-DEFERRALS.md) so reviewers know why the legacy source has not yet been removed.

### Wrapper for intentional invocation

Any legitimate need to run a legacy script (e.g., generating a fixture for a 5-test trial) MUST use the wrapper:

```bash
(cd legacy-DoNotUse && \
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
- `legacy-DoNotUse/` shrinking to zero is a visible migration progress signal.
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
| `git rm` + tombstone pruning protocol | Superseded 2026-10-09 | tombstones removed; pruning is `git rm` only (see the amendment) |
| Intentional-invocation wrapper documented | Implemented | ADR §Wrapper section + KEEPERS.md §N |
| KEEPERS.md file:line citations (blame-loss mitigation) | Implemented | KEEPERS.md throughout |

## Amendment 2026-10-09 — the tree is `legacy-DoNotUse/`; no tombstones

The frozen tree was read as usable code: tests read files in it, docs pointed agents at it, and a
`migrated/` directory of tombstones inside it was the one part every issue worktree kept. Its
name now says what it is, and the bookkeeping that made it look alive is gone.

1. **The tree lives at `legacy-DoNotUse/`.** It was moved there whole (`git mv`); no file's
   content changed, so the sentinel and the one-line `scripts/sw` patch moved with it and still
   work (the patch finds the sentinel relative to itself). Nothing at the repo root is named
   `legacy`, and no live file — code, tests, CI, CLAUDE.md, the docs outside `docs/adr/` and
   `docs/audits/` — names the old path. ADRs and dated audits keep history as written.
2. **There are no tombstones.** The tree has no `migrated/` directory. Nothing is written when a
   keeper lands, and the issue generator no longer asks for one.
3. **Pruning is `git rm` only.** When a keeper's replacement lands, its legacy source is
   `git rm`'d in the same PR. Nothing else is written.
4. **What a maintainer needs to know lands in its proper home.** A behavioural fact about the
   replacement (a difference from the old code that still holds, a trap) is written into the
   plugin's README, the relevant ADR, or `docs/ARCHITECTURE.md`, as a plain statement about our
   code. Migration bookkeeping — dates, old-function → new-function tables, "pruned under #N" —
   is not kept.
5. **The tree is not zBuild code.** No test reads it (ADR-059 §2), issue worktrees leave all of
   it out (ADR-059 §2), and build may never write it (`scope_floor_denied`, ADR-030).

`legacy-DoNotUse/FROZEN.md` still describes the old pruning steps; it is inside the frozen tree,
so it is not edited, and this amendment governs.

## Enforced by

- `.github/workflows/test.yml` — §Sentinel-guard protocol: the Smoke job's "Legacy sentinel" step
  runs `legacy-DoNotUse/scripts/sw` and fails unless it refuses with "disabled".
- `tests/unit/legacy-donotuse-guard-test.sh` — Amendment §1 and §2: no `legacy` directory at the
  repo root (`[ADR-002/PATH]`), no `migrated/` directory in the tree (`[ADR-002/NO-TOMB]`), and no
  tracked file outside the tree, `docs/adr/` and `docs/audits/` names the old path or a tombstone
  (`[ADR-002/NO-REFS]`).
- `tests/unit/no-test-reads-legacy-test.sh` — Amendment §5: no test reads the tree.
- `tests/unit/worktree-sparse-legacy-test.sh` — Amendment §5: issue worktrees leave all of it out.
- `tests/unit/scope-governance-test.sh` — Amendment §5: `scope_floor_denied` refuses
  `legacy-DoNotUse` and every path under it.
- `core/redaction/tests/scope-redaction-unit-test.sh` — T-818-5: the tree's name is a repo path
  prefix to the read-scope redactor, so an out-of-scope path into it is wrapped.
- Not enforced by a test: "every other legacy file is touched only by `git rm`" (§Sentinel-guard
  protocol) and Amendment §4 (where knowledge lands) are held by review.

## References

- [KEEPERS.md §N](../KEEPERS.md#section-n--repository-creation--legacy-import) — full rationale for plain-copy decision.
- [ARCHITECTURE.md §8](../ARCHITECTURE.md#8-what-lives-where-file-system-tour) — `legacy-DoNotUse/` placement in the file-system tour.
- Legacy content audit (1,851 LoC across 12 categories) — see KEEPERS.md §N.
