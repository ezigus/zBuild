# Design notes — issue #1801 (revision 15)

## What changed from revision 14

### Issue-acceptance findings (revision 15)

Three requirements remain unmet — all are build-stage failures, not design gaps.
The design already specifies the required fixes correctly; the build stage did not
implement them. This revision adds a findings section and makes the code-level
instructions more explicit.

#### Finding 1 (R-4): runner.sh disposition gate not added

The static assertion in `orch-backend-misconfigured-test.sh` (line 218):
```bash
if grep -q '_ZBUILD_ORCH_BACKEND_DISPOSITION' "$REPO_ROOT/core/pipeline/runner.sh"
```
FAILS — `runner.sh` contains no `_ZBUILD_ORCH_BACKEND_DISPOSITION` check anywhere.

Confirmed at HEAD: `grep -n '_ZBUILD_ORCH_BACKEND_DISPOSITION' core/pipeline/runner.sh`
returns only the `misconfigured` use inside a dispatch block unrelated to backend loading
(line ~2917 for cycle dispatch), not the startup gate that needs to be added at line ~68
(immediately after `source "$_ZBUILD_ROOT/core/orch/contract.sh"`).

The e2e test (lines 264–297) runs `runner.sh` and gets `backend.missing: orchestrator=sequential`
in output — the old stub behavior — not `misconfigured bash-parallel`. This confirms the
disposition check never runs.

**What the build stage MUST add to runner.sh (line 68, after sourcing contract.sh):**
```bash
# #1801 (ADR-011 §3): if contract.sh's auto-load set _ZBUILD_ORCH_BACKEND_DISPOSITION=misconfigured,
# fail the pipeline immediately before dispatching any stage.
if [[ "${_ZBUILD_ORCH_BACKEND_DISPOSITION:-}" == "misconfigured" ]]; then
    _ZBUILD_BACKEND_ALIAS="$(zbuild_config_get_backend "orchestrator" 2>/dev/null || echo "${ZBUILD_ORCHESTRATOR_BACKEND:-bash-parallel}")"
    zbuild_emit_event pipeline.failed disposition=misconfigured reason="backend '${_ZBUILD_BACKEND_ALIAS}' not found or not readable" 2>/dev/null || true
    printf 'pipeline failed: backend.misconfigured: orchestrator=%s\n' "${_ZBUILD_BACKEND_ALIAS}" >&2
    exit 1
fi
```
(The exact variable name and error message format must match what the test checks:
`grep -q 'misconfigured' <<< "$_E2E_S4_OUT"` and `grep -q 'bash-parallel' <<< "$_E2E_S4_OUT"`)

#### Finding 2 (R-5): template-resolver.sh always_run propagation not added

`always-run-spec5p.yaml` declares `always_run: [release, persist]`.
After template resolution via the OLD-shape merge path in `template-resolver.sh`
(lines 87–108), the merged file retains only the base's `always_run: [release]`
because the merge path extracts `stages:` and `stage_definitions:` from the
per-repo file but NOT `always_run:`.

The test assertion at line 314:
```bash
assert_file_exists "[#1801/SPEC-5] persist hook was entered" "$_SPEC5P_ENTERED"
```
FAILS — the persist hook is never entered.

**What the build stage MUST add to template-resolver.sh (after the stage_definitions block,
lines 103–108, in the OLD-shape merge path):**

After the existing `stage_definitions:` extraction block, add an analogous block to
extract and replace `always_run:` from the per-repo file when it declares one:

```bash
# Extract and replace always_run: block from per-repo file (if present).
# The per-repo file's always_run: list overrides the base's; without this
# extraction, the base always_run: [release] silently wins even when the
# per-repo overlay declares always_run: [release, persist].
_per_repo_has_always_run=0
if awk '/^always_run:/{found=1;exit} END{exit !found}' "$per_repo_file"; then
    _per_repo_has_always_run=1
fi
if [[ "$_per_repo_has_always_run" -eq 1 ]]; then
    # Remove base always_run: block from merged file.
    awk '
        /^always_run:[[:space:]]*$/ { in_block=1; next }
        in_block && /^[a-zA-Z_]/ { in_block=0 }
        in_block { next }
        { print }
    ' "$merged_file" > "${merged_file}.tmp" && mv "${merged_file}.tmp" "$merged_file"
    # Inline form: always_run: [release, persist]
    awk '
        /^always_run:[[:space:]]*\[/ { print; next }
    ' "$per_repo_file" >> "$merged_file"
    # Block form: always_run:\n  - release\n  - persist
    awk '
        /^always_run:[[:space:]]*$/ { in_block=1; print; next }
        in_block && /^[a-zA-Z_]/ { in_block=0 }
        in_block { print }
    ' "$per_repo_file" >> "$merged_file"
fi
```

Note: This is the build stage's implementation guidance. The exact awk code may differ;
what matters is that `always_run:` from the per-repo file replaces the base's `always_run:`
in the merged file. The test will verify the result.

#### Finding 3 (R-9): follows from 1 and 2

Five assertions fail; all are caused by the two missing code changes above.

### Status: COMPLETE (revision 15)

Design written to /home/runner/work/_temp/zbuild-state/artifacts/design-draft.md

Key changes vs revision 14:
- Added revision 15 findings documenting the two unimplemented code changes
- Made the required code changes for runner.sh and template-resolver.sh explicit
  with the exact location and approach the build stage must use
- No scope changes — both files are already in scope
- No SPEC changes — the existing SPECs correctly describe the required behavior;
  the build failure is that the implementation was missing

## Invariants for build stage (carried from revision 14, emphasis added)

1. **MUST ADD** to runner.sh after line 67 (`source contract.sh`): check
   `_ZBUILD_ORCH_BACKEND_DISPOSITION == "misconfigured"` and exit 1 naming
   the backend before any stage dispatches.

2. **MUST ADD** to template-resolver.sh's OLD-shape merge path (after the
   `stage_definitions:` extraction block): extract `always_run:` from the
   per-repo file and replace the base's `always_run:` when the per-repo
   declares one.

3. Hard-kill path (runner.sh): `_runner_abort_trap` → `_runner_dispatch_always_run`
   must complete within kill grace. With `_SPEC5_KILL_GRACE=15` s and 3 s
   watchdog, 12 s slack — achievable if abort trap correctly wires to EXIT trap.

4. SPEC-5 cleanup test MUST fail at baseline (old code) and pass at HEAD.
