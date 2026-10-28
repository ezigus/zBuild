# Design notes — issue #1801 (revision 14)

## What changed from revision 13

### Scope gap fixed in revision 14

The revision 13 notes said `core/pipeline/template.sh` and
`core/pipeline/template-resolver.sh` were to be added to scope, but the
scope block in design-draft.md did not contain them. Added in revision 14.

### Root cause of R-5 Finding 2 confirmed (persist hook never entered)

Confirmed by reading `template-resolver.sh` directly (lines ~60-120).

The OLD-shape merge path (entered when per-repo file lacks top-level `flow:`)
performs three steps:
1. Copy base file minus `stages:` and `stage_definitions:` blocks
2. Append `stages:` from per-repo file
3. Append `stage_definitions:` from per-repo file

`always_run:` is NOT extracted from the per-repo file. When
`always-run-spec5p.yaml` (extends: always-run-minimal, declares
`always_run: [release, persist]`) is resolved, the merged file only has
the base's `always_run: [release]`. `_tpl_parse_always_run` reads the
merged file → `_TPL_ALWAYS_RUN = [release]` → persist never dispatched.

The fix belongs in `template-resolver.sh`: add an `always_run:` extraction
step analogous to the `stages:` step, replacing the base's block when the
per-repo file declares its own `always_run:`.

`template.sh`'s `_tpl_parse_always_run` (line 1592) already handles both
block and inline forms correctly and needs no code change. It is in scope
as the consumer of the resolved file.

### Template resolver call chain

```
runner.sh:53   — source "template-resolver.sh"
runner.sh:1788 — template_file="$(resolve_template_file ...)"
template.sh:58 — load_template "$template_file"
template.sh:697 — _tpl_parse_always_run "$template_file"
```

WIRING: `runner.sh` is already in WIRING and is the direct caller of
`resolve_template_file` from `template-resolver.sh`. No change needed to WIRING.

### R-7 scope discovery re-run at HEAD (revision 14)

- `grep -rl 'orch-sequential' tests/` → 1 file (orch-sequential-absent-guard-test.sh) ✓
- `grep -rl 'ZBUILD_ORCH_TIMEOUT' tests/` → 0 hits ✓
- `grep -rl 'ZBUILD_RELEASE_TIMEOUT' tests/` → 2 files
  (always-run-exit-paths-test.sh, runner-release-exit-paths-test.sh) — both in scope ✓
- `grep -rl '_orch_local_kill_slot' tests/` → 1 file
  (orch-kill-uses-pg-kill-guard-test.sh) — in scope ✓
- `grep -rl 'router\.timeout_s' tests/` → 21 files; 2 pin always-run watchdog
  (in scope); 19 test per-call model timeout (unchanged) ✓

No new test file is required in scope beyond what revision 13 established.

## Invariants for build stage (carried from revision 13)

1. runner.sh: check `_ZBUILD_ORCH_BACKEND_DISPOSITION` at startup (after
   sourcing contract.sh), fail pipeline before any stage dispatch when
   disposition is `misconfigured`.

2. template-resolver.sh: in the old-shape merge path, extract `always_run:`
   from per-repo file (if present) and replace the base's `always_run:`.
   This is the root cause of the persist hook never entering.

3. Hard-kill path (runner.sh): `_runner_abort_trap` → `_runner_dispatch_always_run`
   must complete within kill grace. With `_SPEC5_KILL_GRACE=15` s and 3 s
   watchdog, 12 s slack — achievable if abort trap correctly wires to EXIT trap.

4. SPEC-5 cleanup test MUST fail at baseline (old code) and pass at HEAD.

## Status: COMPLETE (revision 14)

Design written to /home/runner/work/_temp/zbuild-state/artifacts/design-draft.md

Key changes vs revision 13:
- Added `core/pipeline/template-resolver.sh` and `core/pipeline/template.sh`
  to the scope block (the gap the revision 13 notes identified but the
  design-draft.md scope block did not reflect)
- Revision 14 findings section added to design-draft.md Findings
- Root cause of R-5 Finding 2 fully documented with file/line evidence
- R-7 greps re-run at HEAD and confirmed complete
