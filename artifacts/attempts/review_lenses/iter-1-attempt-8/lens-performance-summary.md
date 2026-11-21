## review-lens-performance — pass

- reviewed the change through the performance lens: found no problem

- knocked down by the check: `_zbuild_claim_find_coordinator_v` calls `discover_plugins` inside a process substitution, so the in-shell discovery cache (`_ZBUILD_DISCOVERY_CACHE`) filled inside it dies with the subshell; the function is called twice per issue-bound run (once in `zbuild_claim_acquire` and once in `zbuild_claim_release`), so each call falls through to the file memo path, which requires a `find` for the shape check on every invocation rather than once. — runner.sh calls `discover_plugins` directly (not in a subshell) at top-level scope before any stage or claim function runs, populating `_ZBUILD_DISCOVERY_CACHE` in the runner's own shell; process substitutions are bash forks and inherit that warm cache, so each `< <(discover_plugins …)` in `_zbuild_claim_find_coordinator_v` hits the inherited in-shell cache (after the shape `find`) and never reaches the file memo path
- score: 9
