## issue-acceptance — fail

- judged the change against the issue: 1 requirement(s) not met or not sure

- see result
- answered: build-tests finding 1: done — RQFROM-4 is UNMET and the finding is part of that verdict. The guard in `runner.sh` must be broadened to fire for all statuses (not just `interrupted`), and S6 in `from-stage-rehydrate-test.sh` must be updated to use `--resume --from-stage build`. Both changes are required by RQFROM-4; neither is mine to make, but the requirement is unmet either way.
- answered: lens-correctness-code finding 2: wrong — RQLOOP-1 asks that a run interrupted mid-round resumes at the interrupted stage of that round with the loop's iteration count restored. DSCMBR-1 covers exactly this: build=complete, test=aborted in iter k, resume dispatches test. The untested edge case (test has status "complete" from a prior iter while build completed in the current iter) is an internal implementation path not named by any ISSUE REQUIREMENT. RQLOOP-1 is met by the passing test; the gap is a test-coverage refinement beyond what the requirements ask for.
- answered: issue-acceptance finding 1: done — confirmed in this run. RQFROM-4 is UNMET. The test failure in `pipeline-resume-test.sh` "--from-stage without --resume exits 1" is directly traceable to the `interrupted`-only guard in `runner.sh`. The comment in `runner.sh` names the behavior as deliberate. The requirement says this must refuse for all auto-resume conditions. The finding holds.
- answered: issue-acceptance finding 2: done — `scripts/lib/run-status-text.sh` is not listed in THE CHANGE. The build stage reverted it. The finding is closed.
