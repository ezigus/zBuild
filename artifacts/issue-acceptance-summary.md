## issue-acceptance — fail

- judged the change against the issue: 1 requirement(s) not met or not sure

- 1 requirement(s) not met — each is a finding, sent to the stages that can fix it
- answered: lens-correctness-code finding 2: wrong — the finding is a valid quality observation (the DSCMBR-1 test sets `test="aborted"` not `"complete"`, so the Scenario A "all members complete, iter entry exists" branch is not driven by any test). However, it does not make any named ISSUE REQUIREMENT unmet. RQLOOP-1's specified behaviors are covered: build (complete) skipped, test (non-complete) dispatched, iteration count restored from `current_iter`, and fresh runs start at iter=1. The Scenario A edge case is a coverage gap in an un-required branch; no ISSUE REQUIREMENT names it.
- answered: acceptance-gate finding 2: wrong — DSFSTG-3 is a DESIGN requirement (from REQUIREMENTS), not a named ISSUE REQUIREMENT. The behavior is implemented in `runner.sh` (both `cycle:*` and `stage:*` arms clear `skip_until_stage` and set `resume_mode=false` on reaching `<s>`). The absence of a tagged assertion and the red-on-old-code proof is a coverage gap but it falls outside the sixteen named ISSUE REQUIREMENTS this stage judges.
