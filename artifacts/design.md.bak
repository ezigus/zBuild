# Design: design plugin → contract v2 + ADR-063 §1/§2 (iteration 3)

## Architectural decision summary

**Goal**: Migrate `plugins/agent/design` to the v2 result contract (always-written
`design-verdict.json` sidecar with `result_contract:2`, `verdict`, `disposition`) and
inject live `timeout_s`/`max_turns` into the prompt so the model can emit a best-effort
design before being cut off (ADR-063 §1/§2).

**Context**: The build stage added `_design_write_result` on all exit paths and injected
budget guidance. Three concrete bugs remain unfixed; they cause four test failures:

1. **`plugin.sh:651` pipe subshell** — `cat "$output_design_md" | atomic_write "$output_design_md"`
   runs `atomic_write` in a pipe subshell. The test mock sets `_SIDECAR_AT_ATOMIC_WRITE="PRESENT"`
   inside the mock, but the update is invisible to the main shell → SPEC-1 assertion
   `expected: PRESENT, got: UNSET` fails. Fix: stdin redirect (no pipe) so `atomic_write`
   runs in the current shell.

2. **`plugin.sh:292-293` heredoc split phrase** — The heredoc emits:
   ```
      ...never the answer. You MUST
      actively search the repo (Read/Grep/Glob)...
   ```
   `grep -q 'MUST actively search the repo'` never matches a multi-line file by default
   → SPEC-8 fails. Fix: join to a single line.

3. **`design-router-timeout-reiter-test.sh:252-255` stale guard** — The guard asserts
   `design-verdict.json` is ABSENT on the happy path. The v2 contract now writes
   `verdict=pass, disposition=complete` there → assertion fails. Fix: accept a
   pass-disposition sidecar as valid.

**Decision**: Three surgical edits — two in `plugin.sh`, one in the router-timeout test.
WIRING remains `manifest.yaml`; its SPEC-4 pass→fail flip becomes detectable once SPEC-1
passes at HEAD (the current test-file failure masked the flip).

## Implementation notes

### Fix 1 — `plugin.sh:651` stdin redirect (eliminates pipe subshell)

Replace:
```bash
    cat "$output_design_md" | atomic_write "$output_design_md"
```
With:
```bash
    local _dmd_tmp; _dmd_tmp="$(mktemp)"
    cp "$output_design_md" "$_dmd_tmp"
    atomic_write "$output_design_md" < "$_dmd_tmp"
    rm -f "$_dmd_tmp" 2>/dev/null || true
```
`atomic_write` is now called in the current shell via stdin redirect; the test mock's
`_SIDECAR_AT_ATOMIC_WRITE` variable update propagates to the caller.

### Fix 2 — `plugin.sh:292-293` join heredoc lines

In the `<<DESIGN_PROMPT` heredoc, the line ending in `You MUST` and the line starting with
`   actively search the repo` must be joined into one line so `grep -q 'MUST actively
search the repo'` matches:

Current (two lines — WRONG):
```
   scope. The seed above is a starting point, never the answer. You MUST
   actively search the repo (Read/Grep/Glob) and include:
```
After (one line — CORRECT):
```
   scope. The seed above is a starting point, never the answer. You MUST actively search the repo (Read/Grep/Glob) and include:
```

### Fix 3 — `design-router-timeout-reiter-test.sh:252-255` update SPEC-10-guard

Replace the binary absent/fail check:
```bash
[[ ! -e "$_F_ARTIFACTS/design-verdict.json" ]] \
    && assert_pass "[SPEC-10-guard] no design-verdict.json sidecar on happy path" \
    || assert_fail "[SPEC-10-guard] spurious did_not_finish sidecar on happy path" \
        "sidecar=$(cat "$_F_ARTIFACTS/design-verdict.json" 2>/dev/null)"
```
With a three-way check that accepts the v2 pass-sidecar:
```bash
_sc_hpv="$(jq -r '.verdict // "ABSENT"' "$_F_ARTIFACTS/design-verdict.json" 2>/dev/null || echo ABSENT)"
_sc_hpd="$(jq -r '.disposition // "ABSENT"' "$_F_ARTIFACTS/design-verdict.json" 2>/dev/null || echo ABSENT)"
if [[ ! -e "$_F_ARTIFACTS/design-verdict.json" ]]; then
    assert_pass "[SPEC-10-guard] no design-verdict.json sidecar on happy path (pre-v2)"
elif [[ "$_sc_hpv" == "pass" && "$_sc_hpd" == "complete" ]]; then
    assert_pass "[SPEC-10-guard] happy path sidecar has verdict=pass disposition=complete (v2 contract)"
else
    assert_fail "[SPEC-10-guard] spurious non-pass sidecar on happy path" \
        "sidecar=$(cat "$_F_ARTIFACTS/design-verdict.json" 2>/dev/null)"
fi
```

```scope
plugins/agent/design/manifest.yaml
plugins/agent/design/plugin.sh
tests/unit/design-v2-result-contract-test.sh
tests/unit/design-budget-prompt-injection-test.sh
tests/unit/design-router-timeout-reiter-test.sh
tests/unit/design-timeout-exhaustion-halt-1261-test.sh
tests/unit/design-acceptance-block-test.sh
tests/unit/design-persona-framing-test.sh
tests/unit/design-summary-switch-test.sh
tests/unit/design-stage-banner-content-test.sh
tests/unit/design-stray-file-recovery-test.sh
tests/unit/design-prompt-override-section-test.sh
tests/unit/design-prompt-scope-charter-test.sh
tests/unit/design-prior-gate-feedback-test.sh
tests/unit/lint-verdict-classify-test.sh
tests/unit/verdict-no-forbidden-strings-guard-test.sh
tests/unit/stage-input-resolve-test.sh
tests/integration/design-build-decisions-flow-test.sh
tests/integration/design-impact-cycle-integration-test.sh
tests/integration/design-impact-cycle-self-feedback-test.sh
tests/integration/design-pipeline-test.sh
tests/integration/design-prompt-override-pipeline-test.sh
core/pipeline/verdict.sh
core/router/route.sh
scripts/lib/router-rc-classify.sh
docs/adr/ADR-063-budget-disclosure-and-partial-output.md
docs/wiki/plugins/design.md
plugins/agent/plan/plugin.sh
```

```acceptance
SPEC-1[change]: success path calls atomic_write for design.md without a pipe (stdin redirect); when atomic_write is called, design-verdict.json already exists on disk with result_contract=2, verdict=pass, disposition=complete
SPEC-2[change]: error path (missing plan.json) writes design-verdict.json with result_contract=2, verdict=error, disposition=broken before returning rc=1
SPEC-3[guard]: timeout path (router_timeout) writes design-verdict.json with verdict=incomplete, disposition=interrupted (existing contract — must not regress)
SPEC-4[change]: manifest.yaml declares provides.result_contract=2 and config.valid_verdicts contains pass, error, and incomplete
SPEC-5[change]: design_stage_run reads scope_manifest and plan file paths from ZBUILD_STAGE_INPUTS index when the env var is set and the file exists, ignoring the hardcoded default paths
SPEC-6[change]: prompt file contains a WALL CLOCK BUDGET block whose timeout_s value matches the live output of _route_resolve_timeout
SPEC-7[change]: prompt file contains a TURN BUDGET block whose max_turns value matches the live output of _route_resolve_max_turns
SPEC-8[change]: prompt file contains the scope charter instruction 'MUST actively search the repo' as a single grep-matchable phrase after budget guidance is injected
WIRING: plugins/agent/design/manifest.yaml
TESTFILES:
SPEC-1: tests/unit/design-v2-result-contract-test.sh
SPEC-2: tests/unit/design-v2-result-contract-test.sh
SPEC-3: tests/unit/design-v2-result-contract-test.sh
SPEC-4: tests/unit/design-v2-result-contract-test.sh
SPEC-5: tests/unit/design-v2-result-contract-test.sh
SPEC-6: tests/unit/design-budget-prompt-injection-test.sh
SPEC-7: tests/unit/design-budget-prompt-injection-test.sh
SPEC-8: tests/unit/design-budget-prompt-injection-test.sh
```

LOOP_COMPLETE
