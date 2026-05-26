## File
`core/router/route.sh`

## Mutation
Swap the candidate picker from `candidates[0]` to `candidates[1]` (intentional off-by-one). The default `config/models.json` has a single candidate per tier, so this causes every route to read `null` and either select an empty model_id or fail outright.

## Patch
```bash
sed -i.mutbak 's|candidates\[0\]|candidates[1]|g' core/router/route.sh
```

## Expected failing test
`tests/integration/core-router-route-test.sh` — asserts deterministic tier→model_id selection (e.g., T2 → claude-sonnet-4-6, T3 → claude-opus-4-7).

## Test
```bash
bash tests/integration/core-router-route-test.sh
```

## Result
The mutation is caught: router tests fail because the wrong candidate index is read; `model_id` ends up empty or pointing at a non-existent second candidate.
