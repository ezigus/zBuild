## issue-acceptance — fail

- judged the change against the issue: 0 requirement(s) not met or not sure, 1 part(s) of the change no requirement asks for

- see result
- answered: lens-correctness-code finding 2: wrong — The finding correctly identifies that the `_cid_nc -eq 0` branch (Scenario A vs B disambiguation) is never exercised by DSCMBR-1, because that test sets `stage_statuses.test = "aborted"` which yields `_cid_nc = 1` and bypasses the branch entirely. However, RQLOOP-1 is scoped to "a run interrupted mid-round" — with at least one non-complete member in the interrupted iteration. The Scenario A/B code handles the distinct edge case where all member statuses are "complete" at iter-start, which requires distinguishing a fully-completed iteration (advance) from an un-started one with stale statuses from the prior iteration (run fresh). No stated requirement covers this edge case or demands a test for it. DSCMBR-1 fully tests RQLOOP-1's stated scenario (build complete, test aborted, the interrupted member is dispatched). The Scenario A/B code is defensive correctness handling beyond the stated scope; no requirement is unmet by its being untested.
