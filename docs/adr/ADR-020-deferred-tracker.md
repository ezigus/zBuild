# ADR-020: Deferred-Work Tracker

**Status:** Proposed
**Date:** 2026-05-31

## Context

zBuild merges 15-20 PRs/day. Operators routinely call out deferred work in PR
bodies — "separate issue", "follow-up", "out of scope", "left as exercise" —
that never gets filed as a tracked GitHub issue. The signal is there at merge
time but is buried inside the PR body and is invisible after the PR closes.

This creates two failure modes:

1. **Invisible technical debt.** Work the team consciously deferred drifts out
   of memory. Six months later someone hits the same problem and re-discovers
   it from scratch.
2. **Lost design rationale.** When deferred work is filed eventually, the
   reasoning ("we'll handle this when X lands") is gone — only the bare title
   survives.

The existing `manifest-sync` workflow (`.github/workflows/manifest-sync.yml`,
`scripts/manifest-sync.sh`) already runs 3× daily and scans merged PR bodies,
but only for `Closes #N` / `Fixes #N` / `Resolves #N` patterns — to detect
orphan PRs (merged without an issue link). It does not look for deferred-work
signals.

A naïve solution is to fold deferred-work detection into `manifest-sync.sh`.
This ADR rejects that and explains why.

## Decision

Ship a **separate** workflow + script:

- `.github/workflows/deferred-tracker.yml` — 3× daily cron, independent of `manifest-sync`
- `scripts/deferred-tracker.sh` — `--report` / `--apply` modes mirroring manifest-sync.sh
- `.github/issues/deferred-scanned-prs.md` — rolling idempotency log
- New label: `deferred-candidate` (in addition to existing `automated`)
- Output: one consolidated triage GitHub issue per run, containing a checklist
  of candidate sentences extracted from PR bodies

Authentication uses the built-in `GITHUB_TOKEN` with minimal scopes; no PAT.

## Rationale

### Why a separate workflow, not folded into manifest-sync

A pressure-test of the original separation rationale ("manifest-sync's
pending-PR guard would suppress deferred candidates") found that argument is
**factually wrong** — the guard at `.github/workflows/manifest-sync.yml:45-56`
only gates *PR creation*, not the script run. Detection would still execute.

The real arguments for separation are weaker but still hold:

1. **Failure isolation.** A regex bug or rate-limit hit in deferred-work
   detection should not break or mask manifest-sync's drift alerts. Today
   manifest-sync exits non-zero on real drift; co-mingling concerns means
   any failure becomes ambiguous.
2. **Independently disableable.** If deferred-tracker generates too much
   noise during a sprint, the operator can pause one workflow without
   pausing the other.
3. **Different output channel.** manifest-sync produces a PR (manifest
   edits). deferred-tracker produces an issue (operator triage). Mixing
   them in one workflow run with two output steps gated independently
   would work — but doubles the surface area of the manifest-sync
   workflow.

The follow-up to this work (see Implementation Notes) extracts shared
helpers — `idempotency_log_check`, `bot_author_skip`, `consolidated_issue_create` —
into `scripts/lib/gh-automation.sh` so both scripts share the same scanner
logic without sharing process lifetime.

### Why GITHUB_TOKEN, not a PAT

The workflow needs:

| Scope                 | Reason                                  |
|-----------------------|-----------------------------------------|
| `pull-requests: read` | fetch merged PR bodies via `gh pr list` |
| `issues: write`       | create/close the triage issue           |
| `contents: write`     | commit the idempotency log to `main`    |

`GITHUB_TOKEN` covers all three within the same repo. A PAT would only be
required if commits made by this workflow needed to trigger *other*
workflows — they don't. `GITHUB_TOKEN`-authored pushes are intentionally
blocked from triggering workflow events by GitHub, which is the desired
behavior here (matches the cascade-loop lesson from issue #248).

Using `GITHUB_TOKEN` follows least-privilege and removes credential rotation
from the operator's plate.

### Why 3× daily cron, offset from manifest-sync

Same cadence as manifest-sync (`02:00`, `10:00`, `18:00` UTC) keeps the
operator's mental model consistent. The cron times are **offset by 30 minutes
(`02:30`, `10:30`, `18:30`)** to prevent races where both workflows commit
to `.github/issues/*.md` simultaneously.

A `concurrency:` group at the workflow level (`group: deferred-tracker`)
prevents parallel runs of deferred-tracker itself if a previous run is slow.

PR-merge-triggered detection was rejected per the cascade-loop lesson in
issue #248 (manifest-sync's noise reduction work).

### Why one consolidated issue per run, not one per candidate

At 15-20 PRs/day × ~2 candidates per PR, per-candidate issues would generate
30-40 GitHub issues/day. Operators stop reading at that volume; the signal
becomes noise. A single checklist-style triage issue keeps the operator's
review window small (~5 minutes per run) and keeps control over what
actually gets filed.

Scaling consideration: at ~120 candidates/week, the consolidated issue body
risks exceeding the 65,536-char GitHub limit in roughly 6 weeks. The script
paginates: if a single run yields more than **25 candidates**, additional
candidates open into `Part 2/N`, `Part 3/N` issues cross-linked from the
first. In practice no single run should hit this.

### Duplicate-issue and human-comment handling

Before opening a new triage issue, the script:

1. Searches for open issues labeled `deferred-candidate`.
2. If **zero** open issues — proceed with creation.
3. If **one** open issue:
   - If it has zero human comments — close it, open a fresh one (clean slate).
   - If it has human comments or checked boxes — **append** a new
     `## Run YYYY-MM-DD HH:MM UTC` section to the existing issue and leave
     it open. Preserves human discussion.
4. If **more than one** open issue — fail loud (`exit 2`, write
   `.deferred-drift` sentinel). This is unexpected state; the operator must
   intervene.

### Idempotency, rollback, and time anchoring

The idempotency log `.github/issues/deferred-scanned-prs.md` records PR
numbers, not candidate hashes. Once a PR is scanned, it is never re-scanned.
This is intentional: dismissed candidates do not re-surface.

"Since last run" is anchored to **`max(mergedAt) over the log entries`**, not
wall-clock. This handles missed runs (workflow disabled, outage) without
losing PRs.

The log is written **after** successful `gh issue create` (or after the
search-before-create short-circuit). If `gh issue create` fails, the log is
not updated and the next run retries.

## Consequences

### New files

- `.github/workflows/deferred-tracker.yml`
- `scripts/deferred-tracker.sh`
- `.github/issues/deferred-scanned-prs.md` (empty rolling log header)

### New label

- `deferred-candidate` (in addition to existing `automated`)

### New failure mode

False positives. Signal phrases will match non-deferred usage occasionally
("the test failed for a separate issue" → not actually a deferred-work
candidate). The triage-issue checklist is the operator's filter; false
positives cost a checkbox click. Acceptable.

### Bot-author skip

Bot PRs are skipped via `author.type == "Bot"` from the GraphQL/`gh` JSON
schema, **not** name-substring matching. Substring matching can be spoofed
by a human account named `dependabot-helper`. The bot type field cannot.

### Markdown-injection mitigation

Sentences extracted from PR bodies are written into the triage issue as
fenced code blocks with `#` and `@` escaped to prevent fake `Closes #N`
auto-close vectors or notification spam via `@mention` injection.
Excerpts are truncated to 200 characters.

### Shell-injection mitigation

PR body text is read via `jq -r`, quoted on every expansion, and passed to
`gh issue create --body-file` (never `--body "$var"`). The script forbids
`eval`, `bash -c "$var"`, and unquoted command substitution. Shellcheck
gates enforced.

## Signal phrases (v1, locked)

Case-insensitive, word-boundary anchored, with negative lookaround for
past-tense usage:

```
separate issue, follow-up, follow up, deferred to, out of scope,
not in scope, file separately, future issue, separate PR,
tracked separately, won't fix here, left as exercise,
TODO(followup), stretch goal, nice-to-have, punt
```

Excluded after pressure-test: `phase \d+` (too many false positives —
"phase 1 of the rollout" is not deferred work). Expansion of this list
requires a v2 amendment to this ADR.

## Implementation Notes

(Per ADR-009 appendix pattern.)

### Mode split

`scripts/deferred-tracker.sh --report` is read-only (no issue creation, no
log writes). `--apply` is the workflow path. Match manifest-sync.sh exit
codes: `0` = no candidates, `10` = changes applied, `2` = error.

### Test layout

- `tests/unit/deferred-tracker-signal-match-test.sh` — pattern matcher
- `tests/unit/deferred-tracker-bot-filter-test.sh` — author.type == "Bot"
- `tests/unit/deferred-tracker-idempotency-test.sh` — log read/write
- `tests/unit/deferred-tracker-sanitize-test.sh` — markdown escape, truncation
- `tests/integration/deferred-tracker-integration-test.sh` — end-to-end with
  mocked `gh` CLI fixture

### Reuse from existing infrastructure

- `zbuild_sed_inplace` from `scripts/lib/compat.sh` for log updates
- Structural pattern from `scripts/manifest-sync.sh` (data collection →
  detection → mode-specific output)
- `peter-evans/create-pull-request` is NOT reused — this workflow creates
  an issue, not a PR

### GitHub Actions hardening

- SHA-pin any third-party actions (first-party `actions/*` may use tags)
- `concurrency:` group on the workflow
- `if: github.repository == 'ezigus/zBuild'` to prevent fork execution
- `workflow_dispatch` input for `report` / `apply` mode (default `apply`)

### Follow-up work (separate issues)

1. Extract `idempotency_log_check`, `bot_author_skip`,
   `consolidated_issue_create` into `scripts/lib/gh-automation.sh` so
   `manifest-sync.sh` can adopt them. Filed after this ADR's implementation
   ships.
2. One-shot historical backfill script: scan all PRs and issues ever, dedupe
   candidates, present to operator in terminal for bulk-file decision. Filed
   after this ADR's implementation ships.

## References

- ADR-009 — Implementation Notes appendix pattern
- ADR-015 — chokepoint pattern referenced for `--report`/`--apply` mode split
- Issue #248 — cascade-loop lesson (why not PR-merge triggered)
- Issue #531 — implementation issue for this ADR
- `scripts/manifest-sync.sh` — structural template and existing scanner
- `.github/issues/orphan-prs.md` — idempotency log pattern
