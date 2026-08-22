[bug] build-agent scratch files (`.bak`/`.head`) void the entire iteration's commit — a timed-out turn that cannot clean up after itself loses all its in-scope work

Part of #1819 (Phase 0 — the stage↔engine contract).

*Re-parented: originally filed under #1743, closed when Initiative 1.3 (#1818) reorganised into phases.*

**Classification: ENGINE — `plugins/agent/build/lib/scope.sh` × `plugins/agent/build/lib/summary.sh`.**

## Problem

Three scratch files created by the build agent voided an entire iteration's commit:

```json
"verdict": "scope_violation",
"scope_violations": [
    "scripts/deferred-tracker.sh.head",
    "tests/unit/deferred-tracker-rotate-sections-test.sh.bak",
    "tests/unit/deferred-tracker-rotate-sections-test.sh.head"
],
"files_changed": [],
"lines_added": 0
```

```
⚠ _build_validate_scope_violations: scope violation — writing empty diff.patch
build.commit.skipped {"plugin": "build", "reason": "scope_violation", "iter": "5"}
```

These are not collateral the build *needed*. `.bak` is what `sed -i.bak` leaves behind; `.head` is what `git show HEAD:f > f.head` leaves behind. They are the residue of an agent comparing versions of the file it was legitimately editing — **both siblings of in-scope paths**.

Neither is an engine artifact. `.head` appears nowhere in `scripts/`, `core/` or `plugins/`. `.bak` is an engine convention only via `atomic_write`'s rotation (`scripts/lib/helpers.sh:107`) for state and doc files, never test files — and #1492 already established that a leftover `.bak` in the working tree is "just untracked cruft".

## Why it fired here

Iteration 5's build turns were killed by three consecutive 900s router timeouts:

```
⚠ route_to_model_loop: claude rc=124 iter=2
⚠ route_to_model_loop: claude rc=124 iter=3
⚠ route_to_model_loop: 3 consecutive timeouts — yielding to cycle (non-fatal)
⚠ _build_validate_scope_violations: scope violation — writing empty diff.patch
```

The agent never reached the point where it would have cleaned up after itself. **A transient infrastructure timeout was converted into permanent, total loss of that iteration's work** — which is precisely the #1743 boundary: recoverable upstream, terminal downstream.

Iterations 1–3 committed cleanly, so the files did not pre-exist; iteration 4 produced nothing (ten consecutive 429s). They were created in iteration 5 and stranded there.

## Why this is not #1726 or #1265

- **#1726** is the scope-expansion *resolver* being unable to reach `grant`/`escalate`. Real and related, but orthogonal: no expansion decision should be involved at all here. Granting scope for a `.bak` file is the wrong remedy — the right one is not to treat it as scope in the first place.
- **#1265** (closed) covered **pre-existing** untracked strays false-flagged by the census. These are created *during* the iteration, by the agent, as siblings of files it was authorised to edit.

## Fix

Treat well-known editor/VCS scratch suffixes as agent residue rather than scope:

1. In `_build_validate_scope_violations`, classify `*.bak`, `*.orig`, `*.rej`, `*.head`, `*.tmp`, `*~` as transient. Delete them and commit the remaining in-scope work instead of voiding the commit.
2. Emit a distinct event (`build.scratch.cleaned`) so the behaviour is visible rather than silent — an operator should be able to see that files were removed.
3. Tell the build prompt these suffixes are fatal today. The prompt currently says *"You may ONLY touch files listed here"* with no indication that a `sed -i.bak` sibling counts as touching a new file.

(1) is the load-bearing change; (3) is cheap and reduces the rate independently.

## Acceptance

- [ ] A build iteration that leaves `*.bak`/`*.head`/`*.orig` siblings of in-scope files commits its in-scope work rather than producing an empty diff.
- [ ] The cleanup is evented, not silent.
- [ ] A genuine out-of-scope **source** edit still fails closed exactly as today — the narrowing is by suffix, never by directory.
- [ ] Regression test covering a timed-out turn that strands a `.bak`; reddens at the merge-base.

Where: `plugins/agent/build/lib/scope.sh`, `plugins/agent/build/lib/summary.sh`. Refs #1726, #1265, #1492, #1685.
