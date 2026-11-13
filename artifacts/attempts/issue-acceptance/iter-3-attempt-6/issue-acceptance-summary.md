## issue-acceptance — fail

- judged the change against the issue: 0 requirement(s) not met or not sure, 1 part(s) of the change no requirement asks for

- see result
- answered: lens-correctness-code finding 2: wrong — RQLOOP-1 and DSCMBR-1 are both scoped to a run "interrupted mid-round": at least one cycle member was not yet complete when the run stopped. Setting `stage_statuses.test = "aborted"` matches that exact scenario. The untested path the finding names — where ALL members are "complete" in the interrupted iteration before the restart — is not a mid-round interruption and no ISSUE REQUIREMENT covers it. The test correctly covers what DSCMBR-1 requires; the edge case is outside this issue's scope.
