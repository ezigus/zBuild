## File
`scripts/lib/cleanup.sh` — `_cleanup_scan_worktrees` refuses to report a worktree with uncommitted work (`git status --porcelain` non-empty). This is the guard that makes worktree reclamation safe: #1621 lost two unpushed commits and an uncommitted file to a hand-run `git worktree remove --force`, and this check is why the automated reclaimer cannot repeat that.

Issue #1635 reported this guard's test (`[SPEC-3]`) as inert — that removing the guard reddened nothing. That report was mistaken; this spec pins the correction mechanically so the question cannot be re-opened by assertion.

## Mutation
In `_cleanup_scan_worktrees`, make the uncommitted-work check unreachable so a dirty worktree is treated as reclaimable.

## Patch
```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("scripts/lib/cleanup.sh")
src = p.read_text()
marker = "_cleanup_scan_worktrees()"
i = src.index(marker)
old = '        if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then\n'
new = '        if false; then # MUTATED: dirty guard removed\n'
# Scope to _cleanup_scan_worktrees; the applier has its own defence-in-depth
# dirty check (SPEC-3 defence-in-depth) that must NOT be the thing under test.
assert old in src[i:], "dirty-guard target not found inside _cleanup_scan_worktrees"
head, tail = src[:i], src[i:]
p.write_text(head + tail.replace(old, new, 1))
PY
```

## Expected failing test
`tests/unit/cleanup-worktrees-test.sh` — the assertion `[SPEC-3] a worktree with uncommitted work is kept` asserts the scanner does NOT report `WT_DIRTY`, which holds an untracked `uncommitted.txt` and is backdated 30 days. With the dirty check bypassed, the fixture is old and pushed, so nothing else excludes it: it appears in the scan and the assertion fails with `[SPEC-3] never reclaim a worktree holding uncommitted work`.

## Test
```bash
bash tests/unit/cleanup-worktrees-test.sh
```

## Result
The mutation is caught: `[SPEC-3] never reclaim a worktree holding uncommitted work` fails because a worktree holding uncommitted work becomes a reclamation candidate once the dirty check no longer excludes it.
