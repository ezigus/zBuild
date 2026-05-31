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

---

## Amendment v2 (2026-05-31)

**Why amended:** Operator feedback after #531/#540/#541 landed:

1. The recurring scanner closes-and-creates the triage issue on the
   1-open + no-engagement path, losing the URL, history, and external links.
2. Both `deferred-tracker` and `deferred-backfill` need to surface possible
   duplicates against open issues; today only `deferred-backfill` does so,
   via fragile single-word substring on titles.
3. `manifest-sync` uses exact-equality on titles
   (`jq .select(.title == $t)` at `scripts/manifest-sync.sh:79, 84, 102`).
   A title edit as small as adding brackets (`"Phase 0.5 cleanup: foo"` vs
   `"[Phase 0.5 cleanup] foo"`) makes manifest-sync flag the same issue
   as an orphan.

The amendment ships as 6 sequential sub-issues under epic #555:
#558 (sub-1, this section), #559 (sub-6 LLM tiebreaker), #560 (sub-2),
#561 (sub-3), #562 (sub-4), #563 (sub-5).

### Decision: Jaccard token similarity helper

New `gha_compute_similarity <text_a> <text_b>` in `scripts/lib/gh-automation.sh`
returns a `0.00`–`1.00` score via `printf '%.2f'`.

**Algorithm:**
1. Lowercase both inputs.
2. Tokenize on any run of non-alphanumeric characters (handles newlines and
   punctuation identically).
3. Filter tokens to length ≥ 4 — drops articles, code fragments, junk.
4. Drop a small stopword set (the/and/that/this/with/from/when/what/where/will/should/would/could/into/also/just/more/some/like/such/these/those/after/before/while/about/then/than/have/been/they/their/there/which).
5. Compute Jaccard `|A ∩ B| / |A ∪ B|` on deduplicated sets.
6. Divide-by-zero safety: empty filtered sets → `0.00`.

**Float comparison idiom (locked):** every adopter compares scores against
thresholds via `awk -v s="$score" -v t="$threshold" 'BEGIN{exit !(s>=t)}'`,
or equivalently the `gha_score_meets_threshold` helper. Bash integer-compare
(`[[ ]]`, `-ge`) on `%.2f` strings is forbidden.

### Decision: cascading classifier with LLM tiebreaker

Pure Jaccard misses semantic similarity. Sub-6 (#559) adds a fail-open LLM
helper invoked ONLY on borderline Jaccard scores (typically 0.20–0.40 for
annotation, 0.40–0.60 for manifest-sync's higher bar). The cascade caps LLM
volume at tens of calls per scan rather than thousands.

**Fail-open contract:** when LLM is unavailable, fails, times out, or returns
unparseable output, the helper returns the original Jaccard score plus a
machine-readable marker (`_LLM_UNAVAILABLE_NO_CREDS`, `_LLM_FAILED_TIMEOUT`,
etc.). Adopters render the marker as an operator-readable annotation in the
issue/PR body. NEVER silently fall through.

### Decision: threshold table by adopter

| Adopter | Annotation threshold | LLM tiebreaker zone |
|---|---|---|
| `deferred-tracker` (sub-2 / #560) | 0.35 | 0.20–0.40 |
| `deferred-backfill` (sub-3 / #561) | 0.35 | 0.20–0.40 |
| `manifest-sync` orphan annotation (sub-4 / #562) | 0.6 | 0.40–0.60 |
| `manifest-sync` TO_MARK_CLOSED PR-staged write (sub-5 / #563) | 0.6 | 0.40–0.60 |

Configurable via env vars `DEFERRED_SIMILARITY_THRESHOLD` and
`MANIFEST_SIMILARITY_THRESHOLD`. The manifest-sync bar is higher because a
false positive on the write path causes silent data drift in a load-bearing
file.

### Decision: update-in-place, not close-and-create

Sub-2 (#560) replaces the recurring scanner's `close_previous_triage_issue` +
`create_triage_issue` pair (on the 1-open + no-engagement path) with a single
`gh issue edit --body-file` call. Preserves issue number, URL, external
links, and the operator's history of what was surfaced.

**Race avoidance:** SHA256 fingerprint the body immediately before edit; if
it changed since fetch, abort to avoid clobbering concurrent human edits.

**Body rotation:** cap the issue body at the most recent 10 `## Update —`
sections; drop the oldest when an 11th is appended. Prevents unbounded body
growth.

**Engaged-issue path UNCHANGED:** when human comments or checked boxes exist,
fall back to `gh issue comment` instead of `gh issue edit` — body-edit would
wipe the operator's checkbox state. This preserves the v1 ADR contract for
human-engaged issues.

### Decision: manifest-sync writes are PR-gated, not auto-flip

Sub-5 (#563) does NOT auto-edit `keepers-manifest.yaml` on fuzzy matches.
The change is staged into the same manifest-sync PR the workflow already
creates (via `peter-evans/create-pull-request`), annotated as
`(fuzzy match: <id>, jaccard 0.XX — verify before merge)` in the PR body.
The PR review IS the human approval step. Operator merges to apply, or
reverts the specific hunk to reject.

### Rejected alternatives

- **Embedding-based similarity** (cosine over sentence-BERT or similar).
  Over-engineered for shell automation; adds Python dependency; cost
  comparable to LLM tiebreaker without the human-readable failure surface.
- **Auto-merging fuzzy matches in manifest-sync** (the original proposal).
  Silent data drift risk on a load-bearing YAML file. Analyst pressure-test
  flagged as highest risk. Replaced with PR-staged approval.
- **Body-edit on the engagement path.** Would wipe operator's checked boxes
  and any in-progress notes. Comment-append path retained for safety.
- **LLM-as-primary similarity (no Jaccard).** Cost-prohibitive at 50
  candidates × 200 open issues per scan = thousands of LLM calls.
  Non-deterministic, hard to test. Cascading-classifier pattern (Jaccard
  filter + LLM tiebreaker) gets most of the benefit at a tiny fraction
  of the cost.

### Future amendment hooks

If false-positive rate on the annotation threshold stays above 15% after
1 month of operator use, raise the threshold (config first; ADR amendment v3
only if the change is permanent). If LLM tiebreaker observed quality is
poor, disable globally via `LLM_TIEBREAKER_ENABLED=0` while iterating on
the prompt.
