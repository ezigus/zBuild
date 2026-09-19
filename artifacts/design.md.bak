# Design: Throwaway verification run for #2131 live run-status comment

**Issue:** #2137 — no code changes; the pipeline execution itself is the deliverable.

## Architectural decision summary

**Goal.** Produce one real pipeline run against issue #2137 to verify that the live
run-status comment mechanism (merged in PR #2136, tracing back to issue #2131) fires
correctly in both local CLI and CI daemon contexts.

**Context.** PR #2136 introduced a sidecar architecture for live run-status comments
(ADR-064). The mechanism is distinct from the older `_dest_gh_comment` destination:

1. **Live sidecar comment** — `core/pipeline/runner.sh` spawns
   `scripts/lib/run-status-comment.sh` as a background process that tails
   `events.jsonl`, renders via `scripts/lib/run-status-render.sh`, and maintains a
   SINGLE GitHub comment (one POST then repeated PATCHes) for the duration of the run.
   Stages appear newest-first; the body is bounded at 60 KB. The sidecar is reaped by
   `_runner_status_comment_reap` on both normal exit and abort.

2. **Post-run daemon comment** — `.github/workflows/zbuild-daemon.yml`'s `post-run`
   job calls `gh issue comment` after the reusable `zbuild-pipeline.yml` finishes.

Both paths were tested in PR #2136 unit/integration tests that already carry
`[SPEC-n]` assertion labels. Running the pipeline against the live issue #2137 proves
both paths reachable end-to-end in the real GitHub environment.

**Decision.** No source files are created or modified. The acceptance-gate's guard
checks use the `[SPEC-1]` and `[SPEC-2]` assertions already present in
`tests/integration/run-status-comment-runner-test.sh`. WIRING is declared `none`
because there is no new wiring to prove load-bearing.

---

## Scope

```scope
scripts/lib/run-status-comment.sh
scripts/lib/run-status-render.sh
core/pipeline/runner.sh
core/output/destinations.sh
core/output/stage-io.sh
plugins/tool/output-github-comment/plugin.sh
.github/workflows/zbuild-daemon.yml
.github/workflows/zbuild-pipeline.yml
tests/integration/run-status-comment-runner-test.sh
tests/lib/run-status-comment-mock-roster.sh
tests/unit/run-status-comment-gh-test.sh
tests/unit/run-status-comment-render-test.sh
tests/unit/runner-status-comment-hook-test.sh
tests/unit/core-output-destinations-test.sh
tests/integration/daemon-workflow-test.sh
tests/integration/stage-io-gh-comment-ansi-strip-test.sh
tests/mutation/run-status-comment.md
```

**Rationale for each entry:**

| File | Why in scope |
|---|---|
| `scripts/lib/run-status-comment.sh` | Primary sidecar implementation under live test; `rsc_upsert`, `rsc_comment_patch`, `rsc_enabled` |
| `scripts/lib/run-status-render.sh` | Renderer called by the sidecar; `rsc_render_body`, `rsc_bound_body`, `rsc_byte_len` |
| `core/pipeline/runner.sh` | Spawns/reaps the sidecar; `_runner_status_comment_spawn`, `_runner_status_comment_reap`, abort trap |
| `core/output/destinations.sh` | Implements `_dest_gh_comment`; the older per-stage comment path (guard) |
| `core/output/stage-io.sh` | Invokes `gh_comment` destination when a stage declares it (guard) |
| `plugins/tool/output-github-comment/plugin.sh` | Calls `emit_output` → `_dest_gh_comment` (guard) |
| `.github/workflows/zbuild-daemon.yml` | Owns the post-run `gh issue comment` step and triggers the pipeline |
| `.github/workflows/zbuild-pipeline.yml` | The reusable pipeline called by the daemon; sets `ZBUILD_ISSUE` env |
| `tests/integration/run-status-comment-runner-test.sh` | SPEC-1/SPEC-2 test file: integration assertions through the real runner |
| `tests/lib/run-status-comment-mock-roster.sh` | Mock plugin roster used by the runner integration test |
| `tests/unit/run-status-comment-gh-test.sh` | GitHub I/O unit tests for the sidecar (SPEC-0 through SPEC-6) |
| `tests/unit/run-status-comment-render-test.sh` | Render unit tests (SPEC-0 through SPEC-7, 60 KB bound, newest-first) |
| `tests/unit/runner-status-comment-hook-test.sh` | Trap placement and gate tests (SPEC-1 through SPEC-4) |
| `tests/unit/core-output-destinations-test.sh` | Guards the older `_dest_gh_comment` path (Test 3) |
| `tests/integration/daemon-workflow-test.sh` | Guards the daemon post-run comment step (Test 13) |
| `tests/integration/stage-io-gh-comment-ansi-strip-test.sh` | Integration test exercising the gh_comment destination ANSI-strip path |
| `tests/mutation/run-status-comment.md` | Mutation coverage record for the sidecar; references the files under live test |

---

## Acceptance

```acceptance
SPEC-1[guard]: the sidecar issues exactly one POST and at least one PATCH, the final body is marked with the run id, and no sidecar process is left behind after a healthy run
SPEC-2[guard]: GitHub API failures during sidecar operation leave the runner exit status unchanged and are recorded in the status-comment log
WIRING: none
TESTFILES:
SPEC-1: tests/integration/run-status-comment-runner-test.sh
SPEC-2: tests/integration/run-status-comment-runner-test.sh
```

**No build-stage tagging work required.** The `[SPEC-1]` and `[SPEC-2]` assertion
labels already exist in `tests/integration/run-status-comment-runner-test.sh`
(added in PR #2136). The acceptance-gate will find them as-is; no test file
modifications are needed before the pipeline run.
