## File
`core/state/atomic.sh`

## Mutation
Remove the `mv` (atomic rename) step from `atomic_write`, leaving the temp file in place without replacing the target. This simulates a half-written state where the temp file exists but the canonical state file is not updated.

## Expected failing test
`tests/integration/concurrent-state-test.sh` — the concurrent-state test asserts the final file contains valid content after concurrent writes; without the atomic rename the state file would be stale or missing.

## Result
The mutation is caught: the concurrent-state test fails because the state file is empty or contains the pre-mutation value after all writers complete.
