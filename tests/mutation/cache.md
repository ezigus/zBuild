## File
`plugins/tool/cache-local/plugin.sh`

## Mutation
Remove the atomic swap in `cache_push` — replace `mv "$dest_tmp" "$dest"` with
`: # mv removed by mutation` so the function writes to the temp directory but
never moves it into the canonical cache location. A subsequent `cache_pull`
will see a miss even though `cache_push` reported success.

## Patch
```bash
sed -i.mutbak 's|    if ! mv "\$dest_tmp" "\$dest" 2>/dev/null; then|    if false; then  # mv removed by mutation|' plugins/tool/cache-local/plugin.sh
```

## Expected failing test
`tests/integration/core-cache-local-test.sh` — asserts that content written via
`cache_push` can be retrieved via `cache_pull` (CACHE_HIT). With the atomic move
removed the canonical slot is never populated, so `cache_pull` returns CACHE_MISS
and the round-trip assertion fails.

## Test
```bash
bash tests/integration/core-cache-local-test.sh
```

## Result
The mutation is caught: the cache-local integration test fails because
`cache_push` no longer moves the temp directory into place, causing `cache_pull`
to report CACHE_MISS instead of CACHE_HIT for a key that was just stored.
