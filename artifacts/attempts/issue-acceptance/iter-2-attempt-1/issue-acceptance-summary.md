## issue-acceptance — fail

- The diff added a new SPEC-5 block for review-lens and review-report coverage instead of extending the existing SPEC-2 loop; the issue explicitly requires "SPEC-2 covers review-lens and review-report" (R-2) and that re-introducing a bare call "turns SPEC-2 red" (R-3), neither of which is true after the diff.

- NOT MET: R-2: SPEC-2 covers review-lens and review-report and passes against the code as it is
- NOT MET: R-3: re-introducing a bare extract_first_json_object call (not a comment) in either plugin turns SPEC-2 red
- NOT SURE, a person must check: R-1: Red first: SPEC-3 asserts the migrated branch for review-lens — fails at the merge-base because the comment at plugin.sh:353 matches (process/TDD-order claim not verifiable from the diff alone)
