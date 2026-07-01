# ADR-036 — Acceptance-contract teeth (mechanical SPEC↔assertion gate)

**Status:** Accepted (2026-06-17)
**Related:** ADR-031 (behavioral acceptance contract), ADR-013 (canonical stage list),
ADR-020 (inter-stage data contract / optional inputs), ADR-022 (test-assessment),
ADR-030 (scope governance)
**Issue:** #922 (843-F). Surfaced by the dogfood of #844.

## Context

ADR-031 introduced the behavioral acceptance contract: `design` emits an
```` ```acceptance ```` block of `SPEC:` lines + `TESTFILES:`, writes failing
stubs, `build` makes them pass, and `test_assessment` judges whether each SPEC
holds. But ADR-031 explicitly left the teeth as **convention, not tooling**
("*Design writes failing tests … enforced by convention, not by tooling*";
"*Don't-weaken charter … enforced by process, not automation*").

The hole: nothing links an individual SPEC to an assertion that would **fail
without the implementation**. A SPEC passes if its TESTFILES are merely green
and the (LLM) `test_assessment` believes the prose — it "passes on LLM grounding
alone."

**Live proof — #844.** The regression test
`tests/unit/cycle-g2-cross-iter-timeout-test.sh` went green **even with the
implementation's seeding loop deleted** (its abandon assertions used
`MOCK_PLAN="build:timeout"`, hitting the within-run threshold regardless of the
feature). `test_assessment` returned `pass`; the headline behavior was never
actually exercised. A tautological test the contract could not detect.

## Decision

Add a mechanical, **non-LLM** `acceptance-gate` stage (a canonical leaf stage,
ADR-013 amendment) that gives the contract teeth in two levels.

### 1. Stable SPEC ids + assertion tagging

`SPEC:` lines gain stable ids: `SPEC-1:`, `SPEC-2:`, … (permanent across
iterations). Each backing assertion must carry its id in the assert **label**,
e.g. `assert_eq "[SPEC-2] carry-over count" exp act`. (`acceptance-block.sh`
keeps parsing legacy bare `SPEC:` lines for back-compat; only `SPEC-n:` lines
carry an id the gate enforces.)

### 2. Level 1 — tag-presence (cheap, fail-fast)

`acceptance-coverage.sh`: every `SPEC-n` must have ≥1 `[SPEC-n]`-tagged
assertion across the declared TESTFILES. A SPEC with none fails the gate
(`acceptance.gate.untagged_spec`).

### 3. Level 2 — baseline negative control (the real teeth)

`acceptance-negctl.sh`: each `SPEC-n`'s tagged TESTFILE must **fail at the
merge-base baseline and pass at HEAD**. Mechanism: a detached `git worktree` at
the merge-base with the default branch (resolved by the shared
`scripts/lib/merge-base.sh`, the same basis review uses, #896), with the TESTFILE
overlaid from HEAD (implementation reverted, test current). A valid control ⇔
`rc_baseline != 0 AND rc_head == 0`. A SPEC whose tagged test passes at baseline
is **tautological** and is rejected (`acceptance.gate.tautology`); a stub that
never passes is rejected (`not_passing_at_head`). Granularity is per-TESTFILE;
author one SPEC per assertion for precise attribution.

When the merge-base equals HEAD (no implementation delta) the control is
skipped, not failed (`NEGCTL SKIP no_impl_delta`).

### 4. Composability — optional input, no-op when absent

The gate declares the design/acceptance artifact as an **optional input**
(`required: false`, ADR-020 convention). With no acceptance block present it is a
**no-op pass** (`acceptance.gate.skipped`), so it drops cleanly into any
template and is omittable from any other — honoring stage independence.

### 5. Placement

In the standard template the gate runs inside `build_review_cycle` immediately after
`build_test_cycle`, before the CQ stages — a broken acceptance contract fails
fast. Because it is its own stage it does **not** depend on `test_assessment`
changes (#867).

## Consequences

- The #844 defect class (green-but-inert tautological tests) is now caught
  mechanically, not left to LLM judgment.
- `design`/`build` prompts are updated to emit `SPEC-n:` ids and `[SPEC-n]`
  tags. Anti-patterns (tautological tag, logic-in-helper, multi-SPEC-per-label,
  unconditional mocks) are stated in the prompts.
- ADR-031's "convention / process" clauses for test-first enforcement and the
  don't-weaken charter are **superseded** by this mechanical gate.
- New events registered in `config/event-schema.json`:
  `acceptance.gate.{start,complete,skipped,untagged_spec,tautology,baseline_resolve_failed,worktree_failed}`.
- ADR-013 grows by one canonical leaf stage (`acceptance-gate`), 16 → 17.

## Implementation Notes

- **Libraries** (`scripts/lib/`): `acceptance-coverage.sh` (Level 1 tag-presence),
  `acceptance-negctl.sh` (Level 2 negative control), and `merge-base.sh`
  (`zbuild_resolve_merge_base`, extracted from review's private resolver so the
  gate does not source the review plugin). SPEC-id parsing + `acceptance_list_spec_ids`
  / `acceptance_list_testfiles` live in the existing `acceptance-block.sh`.
- **Negative-control mechanism**: a detached `git worktree add --detach <merge-base>`
  with each declared TESTFILE overlaid via `git show HEAD:<path>`; the test runs
  with `ZBUILD_TEST_QUIET` unset and a hard timeout (`ZBUILD_NEGCTL_TIMEOUT`,
  default 60s). The validity test is rc-based at the file level: `rc_baseline != 0
  && rc_head == 0`. The worktree is removed via a `RETURN` trap.
- **Stage** (`plugins/agent/acceptance-gate/`): `kind: agent`, modeled on
  `cq-preflight`; writes `acceptance-gate-result.json` (`{"verdict","failures"}`),
  returns rc=1 on fail (picked up mechanically by `runner_read_stage_verdict`'s
  `*` branch — no `verdict.sh` change). `design` is declared `required: false`.
- **Wiring**: `build_review_cycle.flow` (after `build_test_cycle`), `_ZBUILD_CANONICAL_STAGES`
  (template.sh, 16→17), `_LC_STAGE_IDS_TO_CHECK` (lint-contract.sh), the test roster
  (`_ZBUILD_STANDARD_ROSTER` + `register_standard_pipeline_stubs`, #921), ADR-013,
  and the event schema.
- **Adding a stage cost (ABS-1)**: this change touched ~14 roster/position/count
  test sites despite #921's single-source helper, because the remaining sites are
  intentional tripwires and custom-body tests. Future stage additions should reuse
  `register_standard_pipeline_stubs` wherever a test only needs a pass-through roster.

## Limitations / future work

- Per-TESTFILE granularity: a file mixing a load-bearing and a tautological SPEC
  is judged load-bearing. The prompt mandates one SPEC per assertion to mitigate.
- The review-side coverage complement (downgrade `approve` when a SPEC's test is
  untouched in the diff) is tracked separately (843-H / #923).

## Amendment (#951, 2026-06-18) — closing the coverage-gap loop to build

The gate runs as a `build_review_cycle` member after `build_test_cycle` and before
`review`, writing `acceptance-gate-result.json` (`failures[]`) and coercing review's
verdict on a coverage gap. But that finding reached build only one outer iteration
late, as prose in `review_md` — so a correct, review-approved build could exhaust
the cycle budget on a missing `[SPEC-n]` tag (#863 dogfood run 20260618181546-49266).
#951 closes the loop:

- The gate's `failures[]` — the `untagged_spec:<id>` entries ONLY — is fed back to
  build as a structured `prior_acceptance_feedback` input via a SECOND
  `build_review_cycle` feedback edge (`acceptance-gate.gate_result →
  build.prior_acceptance_feedback`). Build injects an `## ACCEPTANCE COVERAGE GAPS`
  block enumerating the exact untagged ids, authoritative over review prose; adding a
  missing `[SPEC-n]` label is explicitly permitted (NOT "weakening").
- Build's prompt ALSO proactively enumerates every design SPEC id
  (`acceptance_list_spec_ids`) with a tag-all/self-verify mandate (only CHANGE SPECs
  must fail at baseline; GUARD SPECs are tagged but not contorted), so the gate is a
  backstop, not the first signal.
- Only `untagged_spec` failures are surfaced to build. A `tautology:<id>` failure (a
  no-change GUARD SPEC the negative control rejects) is NOT actionable by build — the
  change-vs-guard classification that exempts guards from the negative control is
  design-side (folded into #913). `negctl_error`/`worktree_failed` (infra) are never
  surfaced as build-actionable.

## Amendment (#956, 2026-06-19) — Level 3: reachability (the wiring negative control)

Level 2 reverts the *implementation* and requires a SPEC test to fail — proving the
code does real work. It cannot prove the code is *reached by the production path*: a
new library implemented but never wired into the live dispatch still passes, because
the SPEC test exercises it directly. This is the "green but inert" class (#845 plateau
detector never wired into `standard.yaml`; #913 live-flow post-condition gated on a
token authors never emitted).

Level 3 is the **dual of the Level-2 negative control** — an integration-level ablation
that reverts the *wiring* instead of the implementation:

- **`WIRING:` declaration** in the ```acceptance block names the separable file(s) that
  activate the behavior in the live path (a `config/templates/*.yaml` flow entry, a
  dispatch/registration file), one repo-relative path per line. `WIRING: none` is an
  explicit pure-utility exemption (recorded via `acceptance.gate.wiring_exempt`, never a
  silent skip). Parsed by `acceptance_list_wiring` (`scripts/lib/acceptance-block.sh`);
  absolute / `..` paths are rejected by the path-traversal guard.
- **`acceptance-reachability.sh`** creates a detached worktree at the merge-base, overlays
  every changed file from HEAD EXCEPT the WIRING target (leaving the wiring at baseline),
  re-runs the declared TESTFILES, and requires ≥1 to flip pass→fail. No flip →
  `REACHABILITY FAIL inert_wiring <target>`.
- The gate runs Level 3 only after Levels 1+2 pass (composability); a `WIRING`-less block
  is a no-op. An `inert_wiring:<target>` failure is a **hard** gate failure (verdict=fail,
  `acceptance.gate.inert_wiring` emitted), coercing review like every other gate failure.
  Granularity is per-file; an in-file default must be extracted to a separable WIRING
  target (region-level `path:anchor` revert is deferred).

**Self-hosting note:** because Level 3 (and the `WIRING:` grammar) extends what the gate
reads from `design.md`, a dogfood that *uses* the new grammar cannot be validated by the
*installed* (pre-`WIRING`) engine in the same run — the contract reader is pinned to the
install (ADR-023) while the test runner uses the working tree. Such grammar-extending
changes are hand-landed, then installed; thereafter grammar-dependent features dogfood
normally. Build-side consumption of `inert_wiring` (so build self-corrects) is #957.

## Amendment (#1188, 2026-07-01) — timeout classification + infra failures are non-terminal

The gate is mechanical, so a false hard-fail halts the whole pipeline (rc=8) with no
recovery. Two robustness gaps caused exactly that:

1. **Timeout misclassification.** Each SPEC test runs under `timeout ${ZBUILD_NEGCTL_TIMEOUT}`
   (rc 124, or 143 when the child dies from the SIGTERM). A timeout leaves the test's true
   pass/fail *unknown*, yet the old rc-based logic folded a HEAD-run timeout into the genuine
   `not_passing_at_head` class, and a BASELINE-run timeout spuriously satisfied the valid
   control (`rc_base != 0 && rc_head == 0`) → a **false PASS**. Fix: `_negctl_run` /
   `_reachability_run` detect rc 124/143; a timeout on EITHER run is an INFRA signal that is
   never a control, a violation, or a wiring flip. It emits a distinct class
   `negctl_error:timeout:<sid>` (reachability: `reachability_error:timeout:<target>`) with a
   dedicated `acceptance.gate.negctl_timeout` / `acceptance.gate.reachability_timeout` event.

2. **Infra failures were terminal.** `_cycle_acceptance_terminal_failure` (cycle-orchestrator)
   treated every failure class except `untagged_spec:` as terminal. Now the INFRA classes
   `negctl_error:*` and `reachability_error:*` (resolve/worktree failures AND the new timeout
   class) are ALSO non-terminal — a flaky/slow sandbox must not hard-fail the pipeline as if
   the contract were violated. GENUINE violations stay terminal: `tautology`,
   `not_passing_at_head`, `inert_wiring`, `no_testfile`, `malformed_acceptance_block`.

**Configurable timeout + captured output.** `ZBUILD_NEGCTL_TIMEOUT` is an overridable per-stage
knob: templates declare `negctl_timeout_s:` on the `acceptance-gate` stage (read lazily via
`template_stage_negctl_timeout` from the loaded template source — no row-shape change); the
plugin resolves precedence **env `ZBUILD_NEGCTL_TIMEOUT` > per-stage template > 60s default**
(env wins so CI/operators can force a value) and exports it plus `ZBUILD_NEGCTL_ARTIFACT_DIR`
to the libs. Each SPEC / WIRING run now appends its combined output to a size-bounded
(`64 KiB`) `artifacts/negctl-<sid>.log` / `artifacts/reachability-<target>.log` so a failed
control is diagnosable instead of silently `>/dev/null`.

## Amendment (Phase 2, 2026-07-01) — class→disposition mapping (the engine is now generic)

The #1188 amendment above still described the **engine** classifying the gate's failure
vocabulary (`_cycle_acceptance_terminal_failure` knew the literal class strings). That coupling
is now removed: the plugin OWNS the class→disposition mapping and writes a generic
`disposition` field into `acceptance-gate-result.json`; the cycle engine reads only that field
(see ADR-021, generic member-disposition contract). Mapping (`_ag_classify_disposition`,
precedence highest-first):

| disposition   | failure classes                                                            | engine effect                                             |
| ------------- | -------------------------------------------------------------------------- | --------------------------------------------------------- |
| `terminal`    | tautology, not_passing_at_head, inert_wiring, no_testfile, malformed_acceptance_block | HALT — cycle does not converge (rc=8), pipeline.end=failed |
| `recoverable` | untagged_spec:* (only)                                                     | NON-terminal; #951 build feedback loop (cycle re-iterates) |
| `advisory`    | negctl_error:* / reachability_error:* (only — resolve/worktree/timeout)    | NON-terminal AND non-blocking for convergence (infra flake)|
| `none`        | (verdict=pass)                                                             | n/a                                                        |

`terminal` outranks any lower class, so a genuine violation alongside an infra failure is still
terminal. The gate-aggregator (ADR-040 §2) reads the SAME field: `advisory` is excluded from
its fail set (non-blocking), while `recoverable`/`terminal`/absent stay blocking (fail-closed).
