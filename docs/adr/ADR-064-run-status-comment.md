# ADR-064 — One live run-status comment per run

**Status:** Proposed (2026-09-18)
**Issue:** #2131
**Keeper:** e-1 (KEEPERS §E — live-updating GitHub comment, PATCH, atomic id); tombstone `legacy/migrated/e-1.md`
**Amends:** ADR-010 §3 (the `gh-pr-comment` destination row), ADR-015 (References — per-stage `gh_comment` capture is a separate surface and unchanged)
**Related:** ADR-055 §9 (stage summaries), ADR-058 (write boundary), ADR-059 (issue-vs-run keying)

## Context

A daemon run takes 2–6 hours and the issue shows nothing between the start
and the completion comment. Runs 35184719395 and 35208118931 (2026-09-17)
took 3h09m each; the only issue-visible trace was the final
"aborted: LLM rate-limited" line. Reading what happened meant opening the job
log or the state branch.

Three comment paths existed and none was live: the daemon's post-run
`gh issue comment` (one new comment per run, after the fact); ADR-015's
per-stage `gh_comment` capture destination (one comment per stage capture, off
in every shipped template); `review-report`'s PR attach. The legacy engine had
the thing itself — `pipeline-github.sh:97-135`, one comment per run mutated
via PATCH with the id persisted atomically — and KEEPERS §E said "lift
verbatim".

Two constraints shaped where it lives:

- It must work for a run launched **locally** (`zbuild pipeline start
  --issue N`, the operator's `gh auth`) and in **CI** (the daemon workflow's
  job-level `GITHUB_TOKEN`). One code path, or one of them rots.
- The engine must not render GitHub markdown on the stage hot path, and a
  GitHub failure must never change a run's exit status.

## Decision

**A sidecar process, spawned and reaped by the runner, that reads
`events.jsonl` and edits one comment in place.**

1. **Process model.** `core/pipeline/runner.sh` starts
   `scripts/lib/run-status-comment.sh` right after the events path is fixed
   and before the issue lock (so the sidecar never inherits the lock fd), and
   reaps it in the EXIT trap — on the normal path at the `_runner_ended`
   return (after `pipeline.end` and the always-run stages are on disk) and as
   the last statement of the abnormal path (after `pipeline.aborted`). The
   engine knows how to start and stop an observer; it never knows what the
   observer renders. The job-control signal walk exempts the sidecar so its
   final render is not cut by the 1 s KILL backstop.

2. **Reader, not writer.** The sidecar polls `events.jsonl` (size change →
   re-render), reads `stage-inputs/<stage>.json`, the stage's ADR-055 §9
   summary, and `pipeline-state.json`. It writes only
   `<state_dir>/status-comment.json` (the comment id, tmp+mv) and
   `<state_dir>/status-comment.log`. It has no path to the event bus; no new
   event type exists for it.

3. **One comment per run.** `POST` once, `PATCH` forever after. The first
   body line is `<!-- zbuild-run-status run_id=<id> -->`; when the id file is
   gone (resume, a restarted sidecar) the comment is rediscovered by that
   marker before anything is created. A `PATCH` 404 (someone deleted it)
   allows one re-create per process, then gives up — a vandalised comment
   cannot fan out.

4. **Row model.** One row per stage dispatch, **newest first**, keyed by the
   envelope `seq` (`6.1.3` = runner cardinal · cycle iteration · member
   position). `plugin.run.start` opens a row (first per seq; nested hook
   calls re-emit and are ignored); `cycle.member.dispatch.complete`,
   `stage.complete`, `stage.fail` and `plugin.run.error` close it — by seq when
   they carry one, else the latest open row for that stage name (`stage.fail`
   and the cycle-unit `stage.complete` fire after the label is unset).
   `cycle.iteration.reused` collapses to one row per iteration. A row that
   never closes keeps its start and its inputs — that is the row a killed
   stage leaves behind.

   ```
   **6.1.4 test** · iter 1 · 12:20:14Z → 13:21:47Z (61m33s) · **fail** — 686/689: review-lens-test, lint, engine-isolation TIMEOUT
   **6.1.3 build** · iter 2 · 13:35:01Z → running · inputs: plan, design · 16 stage summaries (4 RESOLVE)
   ```

   "What is about to happen" = the input artifact names plus the
   `prompt.summaries.injected` counts. "What just happened" = the first line
   of the stage's own summary, cut at 200 chars. Prompt bodies stay in
   `stage-io/`.

5. **`seq` on the envelope.** `eb_emit_event` stamps `seq` from
   `ZBUILD_STAGE_IO_SEQ_LABEL` by the same present-only-while-active rule as
   `stage`, validated as digits-and-dots. The label was display-only and the
   runner cardinal was persisted nowhere; without it a consumer had no key to
   pair a stage's start with its end. The stage-less envelope keeps its 8 keys.

6. **Bounded, redacted, advisory.** The body is capped at 60,000 bytes
   (GitHub rejects 65,536): rows are added newest-first until the next would
   overflow, then `… N earlier rows omitted — see run log`. The whole body
   passes `apply_scope_redaction` when a scope manifest exists; a redactor
   failure posts nothing. Every `gh` call runs under a 30 s watchdog; every
   failure is one line in `status-comment.log` and `rc 0`. PATCHes are
   coalesced (≥ 5 s apart; terminal events flush at once).

7. **Gates.** Nothing is posted when: `ZBUILD_STATUS_COMMENT=0`;
   `NO_GITHUB=true`; no issue number (a `--goal` run); `--dry-run`; `gh`
   missing or `gh auth status` failing; the target repo's `origin` is not
   github.com. The last gate is what keeps a test's temp repo off GitHub;
   `scripts/run-tests.sh` and the parity fixture additionally pin
   `ZBUILD_STATUS_COMMENT=0`, set there rather than inherited because the
   dogfood's nested suite re-enters through a scrubbed shell (ADR-024).

## Permissions

| | CI (`zbuild-daemon.yml` → `zbuild-pipeline.yml`) | Local |
|---|---|---|
| Token | `secrets.GITHUB_TOKEN`, already job-level env in the pipeline job; `gh` reads `GH_TOKEN` then `GITHUB_TOKEN`. Author: `github-actions[bot]`. | The operator's `gh auth login`. A stray `GH_TOKEN` wins over it. Author: the operator. |
| Scope | `permissions: issues: write` — already declared in both workflows. **No workflow change.** | Classic PAT `repo`; fine-grained *Issues: read and write*. |
| Calls | `POST /repos/{o}/{r}/issues/{n}/comments` once, then `PATCH /repos/{o}/{r}/issues/comments/{id}`. PR numbers work too (PR comments are issue comments). Fork PRs get a read-only token → 403 → logged. | Same. |
| Rate budget | 1,000 req/hr per repo for `GITHUB_TOKEN` in Actions (not the 5,000 user-PAT figure). Coalescing keeps a run at ~60–100 requests. | 5,000 req/hr per user. |

## Consequences

- The daemon's post-run completion comment is unchanged; the live comment
  is a second, earlier surface on the same issue.
- `zbuild status-comment --run <id> | --state-dir <dir> [--once]` re-attaches
  by hand. `--attach` now resolves the ADR-059 `issues/<N>/runs/<id>` layout.
- Under `ZBUILD_RUNNER_JOB_CONTROL=1` (opt-in) a signal's KILL backstop may
  still cut the final render; the sidecar is exempt from the TERM walk but a
  CI 6 h kill sends its own signals.
- A TERM delivered while a **cycle member** runs is answered by
  `_cycle_on_signal`, which emits `cycle.aborted` and `return`s from the
  handler — the run then carries on to completion. Observed while building
  this; filed separately. The comment shows exactly that (a `cycle.aborted`
  with rows continuing after it).
- macOS event timestamps have 1 s resolution: durations there are whole
  seconds and an instantaneous stage renders `<1s`.

## Implementation Notes

- `scripts/lib/run-status-render.sh` (pure), `scripts/lib/run-status-comment.sh`
  (gate, GitHub I/O, loop, `main`), `core/pipeline/runner.sh`
  (`_runner_status_comment_spawn` / `_reap`), `core/event-bus/event-bus.sh`
  (`seq`), `scripts/zbuild status-comment`.
- Tests: `event-bus-seq-envelope`, `run-status-comment-{render,gh,loop}`,
  `runner-status-comment-hook`, `cli-status-comment`, `legacy-e1-tombstone`
  (unit); `run-status-comment-runner` (integration — the real runner, a
  GitHub that fails every call leaves the exit status alone). Mutation notes
  in `tests/mutation/run-status-comment.md`.
- Tunables: `ZBUILD_STATUS_COMMENT_{MIN_INTERVAL,POLL,GH_TIMEOUT,MAX_BYTES,SUMMARY_CHARS,REAP_TIMEOUT}`.

## Amendment 2026-09-19 (#2145) — time first, Eastern, the ceiling

Run 35412141973 was cancelled at GitHub's 360-minute ceiling and the comment said only "running". Three changes:

- **Every row leads with WHEN**: `**9:39 PM ET → 10:38 PM ET (58m16s)** · **6.1.4 test** · iter 1 · **fail** — …`. The seq and stage stay bold and second; a running row reads `**9:39 PM ET → running**`.
- **The reader's zone, Eastern by default.** Events and logs stay UTC; the comment renders `ZBUILD_STATUS_TZ` (default `America/New_York`, labelled `ET` in either season). Any zoneinfo name works; the label is the zone's abbreviation for zones without a fixed label.
- **The ceiling is in the header**: `started 9:16 PM ET · ceiling 3:16 AM ET (1h 20m left)` (`ZBUILD_STATUS_CEILING_MIN`, default 360), and after it `(past ceiling)`. The daemon's post-run step finalizes the comment — `rsc_finalize_issue` finds the newest marker comment on the issue, rewrites **running** to the result, drops `current:`, and on `cancelled` appends `**cancelled at the 360-minute ceiling** — state persisted — re-add `zbuild-run` to resume`.

## Amendment 2026-09-19 (#2154) — a closed row is a record

A stage writes one summary file and a later iteration overwrites it; re-reading it on
every render made iteration-1 rows change after the fact (#1840 run 5: the
spec-correspondence and build rows for iteration 1 came to show iteration 2's numbers).
The first render after a row closes freezes its summary line into
`<state_dir>/status-comment-rows.json` (`{run_id, rows: {seq: line}}`); every later render —
the sidecar loop, the post-run finalize, a fresh process — serves the snapshot. Only a
non-empty line is frozen, so a row whose summary lands later still reads live until it has
one. Keyed by run id: a resumed run has its own comment and its own record. The file
persists with the state. The design row's "N acceptance SPEC(s)" now counts SPEC
declarations only, not the TESTFILES bindings that start the same way.
