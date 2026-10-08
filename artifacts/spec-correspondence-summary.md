## spec-correspondence — partial

- judged 5 SPEC(s): 4 correspond, 1 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-4 partial: The assertion exercises the reuse code path and verifies sparse is applied on that path, but the fixture starts from a worktree with NO sparse-checkout configured, whereas the requirement specifically asks about "a linked worktree that already has sparse-checkout configured" — a bug where zbuild_worktree_acquire skips re-application when sparse is already set would not be caught.

