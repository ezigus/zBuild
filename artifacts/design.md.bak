# Design: Surface CI persist outcome + test CI restore path

## Architectural Decision Summary

**Goal.** Three gaps remain after ADR-059 shipped the persist stage: (1) the
persist-result.json outcome is written but never surfaced in CI job logs, so an
operator must download the artifact zip to learn why a snapshot was skipped or
why the push failed; (2) the CI cold-start restore path (`refs/remotes/origin/…`)
in `_artifact_persist_restore` line 363–366 has no test, so a regression there
would be invisible; (3) `persist-result.json`'s `data.snapshot` field is written
by `_persist_write_result` but no assertion verifies it, so a caller that
short-circuits before snapshot (no-identity case) or that runs snapshot before
refusing a push (credential case) has no test proving the field flows correctly.

**Context.** A stale test-residue branch `zbuild/state/issue-4244` on origin was
created by a pre-secret-gate version of `persist-stage-test.sh`; it must be
deleted. The ADR-050 state branch contract (persist outcome visible, restorable
from origin by a cold runner) is the invariant being surfaced and tested.

**Decision.** Add two always-run CI steps to `zbuild-pipeline.yml`: one that reads
`persist-result.json` and emits `::notice::` annotations (verdict/snapshot/pushed/
reason), one that deletes the stale test-residue branch. Add a T16 test to
`artifact-persist-test.sh` exercising the `refs/remotes/origin/<branch>` restore
path. Add SPEC-6 and SPEC-7 assertions to `persist-stage-test.sh` on
`data.snapshot` in the no-identity case and the credential-refused case. No
library code changes; tests cover existing code paths that are presently dark.

```scope
.github/workflows/zbuild-pipeline.yml
tests/unit/artifact-persist-test.sh
tests/unit/persist-stage-test.sh
tests/unit/ci-state-isolation-test.sh
tests/unit/ci-transcript-collection-test.sh
core/state/artifact-persist.sh
plugins/tool/persist/plugin.sh
docs/adr/ADR-050-prior-work-reuse-contract.md
docs/adr/ADR-059-issue-vs-run-keying.md
```

```acceptance
SPEC-1[change]: _artifact_persist_restore returns rc=0 and status='restored' when the state branch exists only as refs/remotes/origin/zbuild/state/issue-N (CI cold-start path — no local branch)
SPEC-2[change]: persist-result.json data.snapshot field equals 'skipped' when persist_run is called with no issue identity (ZBUILD_ISSUE_NUMBER=0, no goal)
SPEC-3[change]: persist-result.json data.snapshot field is a non-empty string when the push is refused due to a credential finding (snapshot runs before the gate; the field must propagate)
SPEC-4[change]: zbuild-pipeline.yml contains an always-run step after 'Push work branch' that locates persist-result.json under ZBUILD_STATE_DIR and emits ::notice:: annotations for its verdict/snapshot/pushed/reason fields
WIRING: none
TESTFILES:
SPEC-1: tests/unit/artifact-persist-test.sh
SPEC-2: tests/unit/persist-stage-test.sh
SPEC-3: tests/unit/persist-stage-test.sh
SPEC-4: tests/unit/ci-state-isolation-test.sh
```
