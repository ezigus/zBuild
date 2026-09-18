# Design: Throwaway verification run for #2131 live run-status comment

**Issue:** #2137 — no code changes; the pipeline execution itself is the deliverable.

## Architectural decision summary

**Goal.** Produce one real pipeline run against issue #2137 to verify that the live
run-status comment mechanism (merged in PR #2136, tracing back to issue #2131) fires
correctly in both local CLI and CI daemon contexts.

**Context.** Two comment paths exist in the current codebase:

1. **In-run comment** — `core/output/destinations.sh:_dest_gh_comment` calls
   `gh issue comment $ZBUILD_ISSUE` whenever `ZBUILD_ISSUE` is set and
   `ZBUILD_OUTPUT_GH_COMMENT != 0`. This is invoked from `plugins/tool/output-github-comment/plugin.sh`
   via `emit_output`, and also from `core/output/stage-io.sh` whenever a stage declares
   `gh_comment` as a destination.

2. **Post-run comment** — `.github/workflows/zbuild-daemon.yml`'s `post-run` job
   calls `gh issue comment` with a `**zbuild pipeline completed**` body (or an
   abort/failure variant) that includes the Actions run URL. This fires after the
   reusable `zbuild-pipeline.yml` finishes (pass or fail).

Both paths were exercised on the branch; neither has been live-tested against a real
GitHub issue number since PR #2136 landed. Running the pipeline against issue #2137
(a real, open issue) proves both paths reachable end-to-end.

**Decision.** No source files are created or modified. The build stage adds `[SPEC-n]`
assertion labels to the two existing unit/integration tests that cover each comment
path, satisfying the acceptance-gate tagging rule. The pipeline run against issue #2137
then constitutes the live end-to-end proof.

---

## Scope

```scope
core/output/destinations.sh
core/output/stage-io.sh
plugins/tool/output-github-comment/plugin.sh
plugins/tool/output-github-comment/tests/output-test.sh
.github/workflows/zbuild-daemon.yml
.github/workflows/zbuild-pipeline.yml
tests/unit/core-output-destinations-test.sh
tests/integration/daemon-workflow-test.sh
tests/integration/stage-io-gh-comment-ansi-strip-test.sh
```

**Rationale for each entry:**

| File | Why in scope |
|---|---|
| `core/output/destinations.sh` | Implements `_dest_gh_comment`; the live comment path under test |
| `core/output/stage-io.sh` | Invokes `gh_comment` destination when a stage declares it |
| `plugins/tool/output-github-comment/plugin.sh` | Calls `emit_output` → `_dest_gh_comment`; the in-run comment author |
| `plugins/tool/output-github-comment/tests/output-test.sh` | Covers the output plugin; baseline reference for guard assertions |
| `.github/workflows/zbuild-daemon.yml` | Owns the post-run `gh issue comment` step |
| `.github/workflows/zbuild-pipeline.yml` | The reusable pipeline called by the daemon; sets `ZBUILD_ISSUE` |
| `tests/unit/core-output-destinations-test.sh` | SPEC-1 test file: Test 3 already asserts `_dest_gh_comment` calls `gh issue comment` |
| `tests/integration/daemon-workflow-test.sh` | SPEC-2 test file: Test 13 already asserts post-run job has a comment step |
| `tests/integration/stage-io-gh-comment-ansi-strip-test.sh` | Integration test that exercises the gh_comment destination path end-to-end |

---

## Acceptance

```acceptance
SPEC-1[guard]: _dest_gh_comment invokes `gh issue comment <issue>` when ZBUILD_ISSUE is set and ZBUILD_OUTPUT_GH_COMMENT is not 0
SPEC-2[guard]: the daemon workflow post-run job contains a step that posts `gh issue comment` with the run URL on the triggering issue
WIRING: none
TESTFILES:
SPEC-1: tests/unit/core-output-destinations-test.sh
SPEC-2: tests/integration/daemon-workflow-test.sh
```

**Build-stage task.** Add `[SPEC-1]` to the label of the assertion in
`tests/unit/core-output-destinations-test.sh` Test 3 that checks `gh` is called with
`comment` and the issue number. Add `[SPEC-2]` to the assertion in
`tests/integration/daemon-workflow-test.sh` Test 13 that checks post-run steps include
a comment step. No logic changes in either test.
