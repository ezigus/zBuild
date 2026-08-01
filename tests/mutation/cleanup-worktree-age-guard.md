## File
`scripts/lib/cleanup.sh` — `_cleanup_scan_worktrees` refuses to report a worktree whose directory mtime is newer than the `--age-days` cutoff. Dropping that guard makes the reclaimer eligible to delete a worktree a run is plausibly still using, which is the "a pruner that can eat work is worse than none" failure the whole SPEC set exists to prevent.

Issue #1635 reported this guard's test (`[SPEC-2]`) as inert — that removing the guard reddened nothing. That report was mistaken; this spec pins the correction mechanically so the question cannot be re-opened by assertion.

## Mutation
In `_cleanup_scan_worktrees`, delete the age cutoff check so every worktree passes the age gate regardless of mtime.

## Patch
```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("scripts/lib/cleanup.sh")
src = p.read_text()
marker = "_cleanup_scan_worktrees()"
i = src.index(marker)
old = '        [[ "$mtime" -gt "$cutoff" ]] && continue\n'
new = '        : # MUTATED: age guard removed\n'
# Scope the replacement to _cleanup_scan_worktrees — the identical line also
# appears in _cleanup_scan_state_files, and mutating that one proves nothing here.
assert old in src[i:], "age-guard target not found inside _cleanup_scan_worktrees"
head, tail = src[:i], src[i:]
p.write_text(head + tail.replace(old, new, 1))
PY
```

## Expected failing test
`tests/unit/cleanup-worktrees-test.sh` — the assertion `[SPEC-2] a worktree newer than --age-days is kept` asserts the scanner does NOT report `WT_NEW` (mtime ≈ now) at `--age-days 14`. With the age guard removed, `WT_NEW` is clean and pushed, so nothing else excludes it: it appears in the scan and the assertion fails with `[SPEC-2] a fresh worktree must not be reclaimed`.

## Test
```bash
bash tests/unit/cleanup-worktrees-test.sh
```

## Result
The mutation is caught: `[SPEC-2] a fresh worktree must not be reclaimed` fails because a brand-new worktree becomes a reclamation candidate once the age cutoff no longer excludes it.
