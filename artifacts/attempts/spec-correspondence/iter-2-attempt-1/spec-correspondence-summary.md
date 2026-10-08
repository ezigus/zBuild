## spec-correspondence — partial

- judged 5 SPEC(s): 3 correspond, 2 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-2 partial: the provided assertion covers only the create mode; the requirement demands all three modes (create, adopt_local, adopt_remote), and the other two modes are tested in the file only under sub-tags ([#1802/SPEC-2 adopt_local], [#1802/SPEC-2 adopt_remote]) that were not recognised as the SPEC-2 assertion.
- SPEC-4 partial: the requirement states the pre-condition is "a linked worktree that already has sparse-checkout configured", but the fixture creates a plain worktree with no sparse at all; the assertion exercises the reuse code path but not the re-apply-over-existing-sparse scenario the requirement describes.

