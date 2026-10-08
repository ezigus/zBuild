# design-checkpoint

## Files read and key findings

- `design.md` (existing) — SPEC-1 already has behavioral wording from prior iteration. SPEC-2/3/4 still use "git ls-files inside the worktree reports no path" — same pattern the gate flagged for SPEC-1.
- `scripts/lib/worktree.sh` — zbuild_worktree_acquire (lines 154-206) and zbuild_worktree_enter (lines 227-285). No sparse-checkout machinery today.
- `docs/adr/ADR-059-issue-vs-run-keying.md` — No ## Enforced by section. Still in baseline.
- Scope block: complete — no new files to add.

## Conclusions reached

- SPEC-1 wording already fixed (prior iteration). SPEC-2, SPEC-3, SPEC-4 still say "git ls-files reports" — same pattern the gate objected to. Fixing all three to describe observable behavior (working directory contains no checked-out path...).
- SPEC-5/6/7 are fine as-is.
- Scope block is unchanged.

## Writing design.md now (iteration 5 / final).
