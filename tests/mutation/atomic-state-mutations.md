## File
`scripts/lib/helpers.sh` — `atomic_write` lives here (referenced by `core/state/atomic.sh::locked_state_update`).

## Mutation
Neutralize the `mv "$tmp" "$target"` atomic rename step in `atomic_write`, leaving the temp file in place without replacing the target. Simulates a half-written state where the canonical file is never updated. (#1773 wrapped the `mv` in an rc check, so the patch targets the guarded form.)

## Patch
```bash
sed -i.mutbak 's|    if ! mv "\$tmp" "\$target"; then|    if ! : ; then|' scripts/lib/helpers.sh
```

## Expected failing test
`tests/integration/concurrent-state-test.sh` — asserts that after concurrent writers, the final state file contains a valid increment count.

## Test
```bash
bash tests/integration/concurrent-state-test.sh
```

## Result
The mutation is caught: the concurrent-state test fails because `atomic_write` writes to a temp file but never moves it into place, so the canonical state file is stale or missing.
