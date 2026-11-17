## issue-acceptance — fail

- judged the change against the issue: 0 requirement(s) not met or not sure, 1 part(s) of the change no requirement asks for

- see result
- answered: acceptance-gate finding 1: not mine — the finding is correct: no test verifies that `core/claim/claim.sh` belongs in `config/shape-change-paths.txt`. As shown above under UNASKED, no requirement in this issue asks for that entry at all. Fixing it means either removing the entry or writing a test for it — both are code changes that belong to the build stage, not to this read-only acceptance judgment.
