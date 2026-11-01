# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Research summary

### The five gaps

**Gap 1 — No artifact rehydration at resume entry** (runner.sh:2759-2783)  
The resume entry point only clears the abort sentinel and emits `pipeline.resume`. No call to
`_artifact_persist_restore` or any artifact restoration. On a cross-machine resume or after a
disk wipe, "complete" stages have no artifacts on disk, so subsequent stages that depend on those
outputs fail silently.

**Gap 2 — Stale artifact detection warns instead of failing closed** (runner.sh:3727-3751)  
When `stage_statuses[s] == "complete"` AND the primary artifact is missing, the runner emits a
`stage.verdict.stale_artifact` event and a warning to stderr, then **continues** (skips the stage).
The stage's dependents then run without the input they need. After rehydration, a still-missing
artifact is a corrupt state and must cause exit 1.

**Gap 3 — `--from-stage` skips stages with no artifact check** (runner.sh:3755-3760)  
The from-stage path unconditionally skips all stages before the named target. No artifact check,
no rehydration. R-11 requires refusing if a pre-target stage has no prior output anywhere.

**Gap 4 — Cycle orchestrator always resets to iter=1** (cycle-orchestrator.sh:2229)  
`_cycle_orchestrator_run_body` starts `for ((iter=1; iter <= max; iter++))`. The persisted
`cycle_iterations[X].current_iter` is written on each iteration but is **never read** at resume
entry. Mid-cycle interrupt → always re-runs from iteration 1.

**Gap 5 — ADR-006 and ADR-050 gaps**  
ADR-006 resume sequence step 5 says "Continue from last in_progress stage" with no mention of
artifact restoration. ADR-050 §6 ("never skip a stage on basis of prior output") does not draw
the boundary between resume and new-run reuse, causing ambiguity.

---

### Architecture decision for shared restore path

`_hydrate_put_back` (the copy operation in hydrate plugin) cannot be called from the runner
directly because the runner must not source plugin implementations (ADR-001). The solution is to
extract the copy logic into `core/state/artifact-persist.sh` as `_artifact_persist_put_back`,
which both the hydrate plugin and the runner call. Hydrate already sources `artifact-persist.sh`.

The extract is a clean, minimal change: the function body is identical to the current
`_hydrate_put_back` (no-clobber copy, skip `stage-io/`). The hydrate plugin's call site is
redirected to the new function. No behavioral change for hydrate.

---

### Affected existing tests

**`tests/integration/pipeline-resume-test.sh`** — integration section (~line 229):  
Manufactures `stage_statuses["intake"]="complete"` but never writes `intake-result.json`. 
Currently: stale-artifact warns + continues → exit 0.  
After SPEC-2: fail closed → exit 1. P2 "integration: --resume exits 0" breaks.  
**Fix**: pre-write `ZBUILD_ARTIFACT_DIR/intake-result.json` before the `--resume` run.

**`tests/integration/resume-after-sigint-test.sh`** — Phase 2:  
Phase 1 uses `mock_plugin_factory "intake" "agent" 0`. Whether this stub writes a primary
artifact (as declared in the manifest) determines whether the stale-artifact check fires.  
If it does NOT write the artifact: stale-artifact currently warns+skips (P2.T1 rc=0 passes),
but after SPEC-2 it would fail closed (P2.T1 breaks).  
**Fix**: verify Phase 1 stub behavior during implementation. If the stub does not write the
declared primary artifact, update the Phase 1 intake stub to write `intake-result.json` before
returning 0, so Phase 2 rehydration (or disk presence) finds it.

**`tests/e2e/crash-resume-test.sh`** — likely unaffected:  
The SIGKILL lands while intake is sleeping (15s sleep). Intake's stage_statuses is likely
`in_progress` or absent, not `complete`. The stale-artifact check only fires for `complete`
stages, so the SPEC-2 fail-closed path is not triggered. Verify during implementation.

**`tests/unit/hydrate-stage-test.sh`** — update required:  
If any test calls `_hydrate_put_back` directly, redirect to `_artifact_persist_put_back`.

---

### Three resume entry paths (R-12)

1. `--resume` flag to runner.sh — the primary path
2. Auto-resume: runner detects `status=interrupted` on startup and self-resumes
3. `zbuild pipeline resume --run-id X` CLI — scripts/zbuild:595-654, which calls runner.sh `--resume`

All three paths converge on runner.sh's resume entry point. Adding `_runner_resume_rehydrate`
at the single resume entry point in runner.sh covers all three.

---

### Cycle state reading (R-9)

`_cycle_state_init` (cycle-orchestrator.sh:1151) uses `//=` (only-if-absent assign), so
`cycle_iterations[X].current_iter` IS preserved across calls. The bug is in
`_cycle_orchestrator_run_body` (line 2229): the for loop reads neither the state field nor a
local variable. The fix: before the for loop, read
`cycle_iterations[CYCLE_ID].current_iter` via `get_state_field`, default to 1 if absent,
and use that as the loop start value.

---

### ADR enforcement baseline

`docs/adr/ADR-006-resume-contract.md` is listed in `config/adr-enforcement-baseline.txt`.
No `## Enforced by` section is required for it. The amendments in this issue do not change
that baseline status.
