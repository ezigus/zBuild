# ADR-036 — Acceptance-contract teeth (mechanical SPEC↔assertion gate)

**Status:** Accepted (2026-06-17); amended 2026-07-01 (role/strategy split + preconditions);
amended 2026-07-03 (#1218, ADR-046 — Level-1 SPEC-tag-presence shifts LEFT to a PRE-build
`design-gate`; this post-build acceptance-gate retains Level-2 negative-control/tautology +
Level-3 reachability, which cannot shift left — they need a built assertion + baseline-vs-HEAD)
**Related:** ADR-031 (behavioral acceptance contract), ADR-013 (canonical stage list),
ADR-020 (inter-stage data contract / optional inputs), ADR-022 (test-assessment),
ADR-030 (scope governance), ADR-042 (plug-and-play stage resolution),
ADR-046 (design-verify shift-left)
**Issue:** #922 (843-F). Surfaced by the dogfood of #844.

## Amendment (2026-07-01) — generic role, method-named plugin, declarative preconditions

The gate is split into a **generic slot** and a **named strategy**:

- **Role `acceptance_gate`** — the generic slot: "verify a design's acceptance
  contract." Template stage id stays `acceptance-gate` (an ADR-013 canonical
  leaf, unchanged); it binds `roles: [acceptance_gate]`.
- **Plugin `spec-acceptance`** — the method: the SPEC-block negative-control +
  wiring-reachability strategy described below. The plugin dir/manifest id was
  renamed `acceptance-gate → spec-acceptance` (method-named). Role-then-id
  resolution (ADR-042) dispatches the stage to it, so a different repo may bind
  a *different* plugin to `acceptance_gate` without adopting SPEC. The result
  artifact keeps its slot-scoped name `acceptance-gate-result.json` (readers
  resolve it via `provides.artifact_type`, not a literal).
- **Declarative `preconditions`** (manifest, machine-readable) generalize the
  old "no-op when the acceptance block is absent" (§4). When any precondition is
  unmet the gate no-ops (`verdict=pass`, `reason=precondition_unmet`,
  `precondition=<id>`): (1) `design_acceptance_block` present, (2)
  `merge_base_resolvable`, (3) `tagged_testfiles` — the block declares a
  contract to check. These gate **applicability**, not correctness: a
  declared-but-missing TESTFILE or a malformed block is still a genuine
  violation (teeth preserved), not a no-op.

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

### 4. Composability — declarative preconditions, no-op when unmet

The gate declares the design/acceptance artifact as an **optional input**
(`required: false`, ADR-020 convention) and a machine-readable `preconditions`
block (see the 2026-07-01 amendment). When any precondition is unmet — no
acceptance block, unresolvable merge-base, or a placeholder block with nothing
to check — it is a **no-op pass** (`acceptance.gate.skipped`,
`reason=precondition_unmet`), so it drops cleanly into any template (including
repos that do not use SPEC) and is omittable from any other — honoring stage
independence.

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
- **Plugin** (`plugins/agent/spec-acceptance/`, role `acceptance_gate`; renamed
  from `acceptance-gate` per the 2026-07-01 amendment): `kind: agent`, modeled on
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
| `terminal`    | not_passing_at_head, no_testfile, malformed_acceptance_block               | HALT — cycle does not converge (rc=8), pipeline.end=failed |
| `recoverable` | untagged_spec:*, tautology:*, inert_wiring:*, wiring_not_on_path:*         | NON-terminal; build feedback loop (cycle re-iterates); wiring_not_on_path also sets route_target=design |
| `advisory`    | negctl_error:* / reachability_error:* (only — resolve/worktree/timeout)    | NON-terminal AND non-blocking for convergence (infra flake)|
| `none`        | (verdict=pass)                                                             | n/a                                                        |

`terminal` outranks any lower class, so a genuine violation alongside an infra failure is still
terminal. The gate-aggregator (ADR-040 §2) reads the SAME field: `advisory` is excluded from
its fail set (non-blocking), while `recoverable`/`terminal`/absent stay blocking (fail-closed).

## Amendment (#1211, 2026-07-03) — nested-test stage-io isolated + concise operator summary

The Level-2 negctl and Level-3 reachability checks shell out `bash <TESTFILE>` (`_negctl_run`,
`_reachability_run`). The runner dups fd 3 to the operator terminal and exports
`ZBUILD_STAGE_IO_FD=3` so stage-io banners survive `2>/dev/null` (`core/pipeline/runner.sh`, the
fd-3 contract). Those two sandbox runners redirected only fd 1+2 into the diagnostic logfile,
leaving **fd 3 and `ZBUILD_STAGE_IO_FD=3` inherited untouched** — so a nested TESTFILE that drives
real plugins (review / security-lens / test_assessment mocks) had their stage-io banners escape
straight to the operator terminal, bypassing the sandbox capture and repeating once per
baseline/HEAD run × SPEC/WIRING target. Observed in the #944 dogfood (run 20260703154556): dozens
of raw `# Review … Verdict:` fixtures, full security-lens prompts, and `_empty lens result_` lines
flooding the terminal.

Fix (two parts, both repo-agnostic — fd handling + verdict strings carry no plugin/language/path
assumptions):

1. **Close the fd-3 escape.** Both sandbox runners now `unset ZBUILD_STAGE_IO_FD` (nested banners
   fall back to fd 2, already captured by `2>&1`) and redirect/close fd 3 (`3>>"$logfile"` when a
   diagnostic log is configured, else `3>&-`). Nested output is captured into the diagnostic log,
   never the terminal.
2. **Concise operator summary.** The plugin surfaces the already-computed structured verdict lines
   (`NEGCTL PASS/FAIL <spec>`, `REACHABILITY PASS/FAIL <target>`) as ONE line per SPEC and per
   WIRING target via the acceptance-gate stage's own `[file,stdout]` stage-io (`_ag_emit_operator_summary`,
   io-gated on the stage's destinations, routed to `ZBUILD_STAGE_IO_FD`). Reuses the ADR-039
   file-only-child + prose-summary pattern (the review lenses do the same).

This is the stage-io instance of the general nested-isolation gap tracked in **#1127** (ANY nested
pipeline/test execution isolating its stage-io fd from the parent). The durable, engine-wide fix is
deferred there; #1211 closes only the two acceptance-gate sandbox runners.

## Amendment (#1219, 2026-07-04) — tautology is DESIGN-ROOTED → routes back to design

> **Superseded by Amendment #1583 (below).** #1219 routed a tautology back to design on the
> premise that design authors the assertion. #1477 (commit 8f89dd1) removed design's stub-writer,
> making **build** the author of all assertion bodies — so routing tautology to design became a
> dead end (design can only edit `design.md` declarations, which are already correct). #1583 makes
> tautology **build-fixable** instead. The text below is retained for history.

The Level-2 negative control classifies a `[change]` SPEC whose tagged assertion PASSES at the
merge-base baseline as **tautological** (`tautology:<spec>`): the test asserts nothing, the classic
"green but inert" defect. The build stage is **forbidden** to fix this — ADR-036's whole point is
that build must not touch acceptance assertions (else it games the gate). The only correct fix is to
**re-author the SPEC**, which is the province of the stage that authored it: **design**.

Therefore, on a tautology failure, the acceptance-gate adds a generic scalar `route_target: "design"`
to `acceptance-gate-result.json` (verdict / disposition / rc UNCHANGED — still `fail` / `terminal` /
rc=1, which yields the `member_terminal_failure` rc=8 the route_back guard needs). The
gate-aggregator rolls a failed gate's `route_target` up into `verdict == route_design`, and
`simple.yaml`'s `build_test_cycle` route_back (ADR-045) rewinds to `design_verify_cycle` (ADR-046)
so design re-authors the assertion, reading the focused `design-feedback.md` the aggregator wrote.

**Design-rooted vs build-fixable.** ONLY `tautology` is design-rooted. The other terminal classes
stay build-fixable / terminal and set NO `route_target`: `not_passing_at_head` (fix the impl or the
assertion), `no_testfile` / `untagged_spec` (add the tagged assertion — recoverable, fed to build via
the #951 edge), `inert_wiring` (make the WIRING load-bearing), `malformed_acceptance_block`. The
plugin-vocabulary → generic-field (`route_target`) mapping lives ENTIRELY in the acceptance-gate
plugin (ADR-021: the engine and the aggregator know no acceptance-gate failure vocabulary).

## Amendment (#1265, 2026-07-06) — `no_impl_delta` SKIP is legit ONLY as a clean `empty_diff` resting point

The acceptance-gate negative-control + reachability checks `SKIP` with `no_impl_delta` when there is no committed diff to judge (`base_sha == head_sha`, 0 commits ahead). That SKIP is correct for a genuine **nothing-to-do** convergence — a build that reached `LOOP_COMPLETE` with an empty diff and green gates (`verdict=empty_diff`, `#1208`/`#895`). It is a **false pass** when the branch is empty for the WRONG reason: a `scope_violation` discarded the whole diff (`#1214` dogfood), so `npm test` passed on the *uncommitted* tree, the gate SKIPped, the gate-aggregator passed, and the cycle **converged on nothing** — sailing to a confusing `pr`-stage abort (`No commits between main and branch`) ~38 min later.

- **0-commit + build verdict ≠ `empty_diff` is NOT a resting point.** The cycle orchestrator adds a `no_committed_changes` guard (see ADR-021 amendment): a convergence that would fire with 0 commits ahead of the intake baseline AND `build.verdict != empty_diff` is suppressed and terminated (`no_committed_changes`, rc=5, blocked-class → halts before review/`pr`), unless a governed scope grant is pending (`#870`/`#840` — the next iter commits).
- **The `empty_diff` resting point is EXEMPT.** A true clean `empty_diff` converge with 0 real commits genuinely has nothing to ship; the `no_impl_delta` SKIP and convergence both remain correct. No `#1208`/`#895` regression.
- **`pr`-stage backstop.** `pr-open` resolves the merge-base and refuses (`plugin.run.error reason=no_committed_changes`, rc=2) BEFORE push + `gh pr create` when 0 commits ahead — belt-and-suspenders for non-cycle paths and the confusing `gh` error.


## Amendment (#1583, 2026-07-23) — tautology is BUILD-FIXABLE → routes to build with enriched diagnosis

**Supersedes the routing decision of Amendment #1219.** #1219 routed a `tautology` failure back to
**design** on the premise that design authored the assertion and build was forbidden to touch it.
That premise no longer holds: **#1477 (commit 8f89dd1) removed design's stub-writer**, so the
**build** stage now authors every test assertion body, and `design.md` carries only the acceptance
*declarations* (SPEC ids + TESTFILES bindings). Routing a tautology to design became a **deadlock** —
design can only re-emit its (already-correct) declarations, build is forbidden to touch the
assertion, so neither stage can fix it and the `build_test_cycle` route-back budget exhausts to
`rc=8`. Live evidence: issue #1576 failed this way three times (~8h) with a byte-identical
re-authored acceptance block each pass.

Decision: **a tautology is build-fixable.** Re-authoring a *false* assertion into a genuine one is
orthogonal to the don't-weaken charter (which forbids relaxing a *real* requirement). Concretely:

- The acceptance-gate **no longer sets `route_target: "design"`** for a tautology
  (`plugins/agent/spec-acceptance/plugin.sh`). Tautology stays a terminal failure but flows through
  the existing `gate_feedback -> build` edge and re-iterates inside `build_test_cycle`.
- **Build is told, precisely, what to fix.** Build reads the flagged `tautology:<id>` ids
  (`_build_read_tautology_ids`) and its prompt gains a `## TAUTOLOGICAL ASSERTIONS` section
  instructing it to re-author each so the tagged assertion FAILS at the merge-base baseline
  (reverting the change's WIRING file must break it), with the per-SPEC negctl diagnosis.
- **Build's charter is relaxed for flagged tautologies only.** A gate-flagged tautological SPEC is
  explicitly re-authorable; every other acceptance assertion remains protected by the don't-weaken rule.
- **No gaming, by construction.** The mechanical negative-control (Level 2 above) re-runs on the next
  iteration and rejects a still-tautological result; the cycle budget applies (`max_iterations` -> `rc=8`).

The generic `route_target` carrier + the `build_test_cycle` `route_back` edge are **retained but
dormant** (no failure class currently sets `route_target`), ready for any genuinely design-rooted
class a future ADR might introduce.


## Amendment (#1585, 2026-07-24) — tautology (and inert_wiring) disposition is RECOVERABLE, not terminal

**Completes #1583.** #1583 stopped routing a tautology to design (removed `route_target: "design"`),
but left its **disposition** as `terminal` — and a `terminal` disposition HALTS the `build_test_cycle`
(`member_terminal_failure`, `rc=8`) at iteration 1, so build never re-iterates. Net effect of #1583
alone: the failure mode changed from "deadlock via design" to "immediate terminal halt" — build still
could not fix it. Live evidence: #1576 re-run (30088647752) — `acceptance-gate-result.json` had
`route_target: null` (the #1583 fix working) but `disposition: terminal`, ending the cycle at iter 1/5.

Fix: `_ag_classify_disposition` classifies `tautology:*` **and** `inert_wiring:*` as **`recoverable`**
(joining `untagged_spec:*`). Both are the same "weak test" symptom — a `[change]` assertion that passes
at the merge-base baseline / a WIRING file whose revert breaks no test — that BUILD fixes by
re-authoring the assertion so it exercises the change (which resolves both at once). A `recoverable`
disposition makes the `build_test_cycle` re-iterate, feeding build the flagged ids (#1583). The
mechanical negative-control re-verifies each iteration and `max_iterations` bounds it, so an un-fixable
case exhausts the budget and terminates cleanly. A genuinely terminal class (e.g.
`malformed_acceptance_block` — design-authored, build cannot fix) still OUTRANKS recoverable and halts.

## Amendment (#1660, 2026-08-01) — the bound only binds if it escalates to KILL

The #1188 amendment above says each SPEC test runs "under `timeout ${ZBUILD_NEGCTL_TIMEOUT}`" and
enumerates rc 124/143. That description was accurate and the mechanism was still unsound: plain
`timeout` sends **TERM only**, so a child that traps or ignores TERM outruns its bound entirely.

This is not hypothetical for *this* gate specifically. The negative control runs the declared TESTFILE
at the **merge-base**, where the defect under test is present by construction — so any issue whose
subject is signal handling has a baseline that can defeat the gate's own TERM. #1611 was exactly that
(a test harness whose TERM trap cleaned up and fell through), and it hung run `20260731204401-66454`
for 9h22m.

`_negctl_run` / `_reachability_run` / `run-tests.sh` now bound each run with `-k <grace>`
(`ZBUILD_NEGCTL_KILL_GRACE` / `ZBUILD_TEST_KILL_GRACE`, default 10s), escalating to SIGKILL after the
grace. Worst-case per-run wall clock becomes `timeout + grace`.

Two things make that safe, and both are load-bearing:

- **rc 137 joins 124/143 as an infrastructure timeout.** Adding `-k` *without* this would be worse
  than the hang it replaces: the escalated exit would fall through to the ordinary control comparison
  and be reported as `tautology` / `not_passing_at_head` — a silently wrong verdict condemning a
  correct change. A hang at least announces itself. (rc 137 is also an external OOM kill; both mean
  the run's true pass/fail is unknown, which is the same INFRA disposition either way.)
- **`-k` support is probed, not assumed.** A `timeout` lacking the flag exits 125 on it, which is
  likewise not a timeout rc — every bounded run would be condemned rather than run. Support is
  verified once per process; a binary without it degrades to the old TERM-only bound.

Both gates build the bound through one helper, `_acceptance_timeout_prefix` (`acceptance-block.sh`),
which also resolves `gtimeout` — previously only `run-tests.sh` did, leaving the acceptance gates
effectively unbounded on a macOS host with GNU coreutils but no POSIX `timeout`.

## Amendment (#1686, 2026-08-03) — wiring_not_on_path: distinct class + first live route_target activation

**Problem.** When a declared WIRING target was absent from `git diff --name-only` (the file exists but
was not touched by this commit), `acceptance_reachability_check` still ran the full worktree flip-
detection. Since the target was never changed, baseline == HEAD for it, so no testfile could flip and
the result was `REACHABILITY FAIL inert_wiring`. That is the wrong class: `inert_wiring` means the
target IS in the diff but the suite fails to exercise it (a build-fixable test gap); here the author
named a file unrelated to this commit, which only design can correct.

**Fix.**

1. **`scripts/lib/acceptance-reachability.sh`** — before creating each target's worktree, check
   whether the target appears in `changed_files` (leading `./` normalised on both sides). If absent,
   emit `REACHABILITY FAIL wiring_not_on_path <target>`, set `rc=1`, and `continue`, skipping the
   expensive revert run. An empty `changed_files` with `head != base` means the `git diff` call
   failed (shallow clone, unresolvable base) and fails closed as `REACHABILITY ERROR diff_failed` —
   without that guard every target would read as off-diff and rewind every run to design.

2. **`plugins/agent/spec-acceptance/plugin.sh`** — parse the new line in the Level-3 loop;
   accumulate `wiring_not_on_path:<target>` in `failures[]`; emit
   `acceptance.gate.wiring_not_on_path`. Classify `wiring_not_on_path:*` as **`recoverable`**
   (same row as `inert_wiring:*` and `tautology:*`). After classifying, scan `failures[]` for
   `wiring_not_on_path:*` and set `route_target="design"` — the **first live activation** of the
   dormant carrier that #1583 retained. The gate-aggregator rolls this up to `verdict=route_design`,
   and `simple.yaml`'s `route_back` clause rewinds to `design_verify_cycle`.

3. **`config/event-schema.json`** — registers `acceptance.gate.wiring_not_on_path`.

**Why recoverable, not terminal?** `wiring_not_on_path` is design-rooted (only the design stage can
correct the WIRING declaration), but it must be `recoverable` for the route_back to fire: a `terminal`
disposition halts the `build_test_cycle` with `member_terminal_failure` (rc=8) BEFORE the
gate-aggregator can read `route_target` and emit `route_design`. `recoverable` lets the aggregator
run, read `route_target=design`, and produce `verdict=route_design` — which the cycle runner's
`route_back` guard matches, rewinding to `design_verify_cycle`. The cycle budget (`max_iterations`)
bounds the rewind depth.

**Known gap — the #1664 shape is NOT covered (#1711).** This amendment separates *"the target is not
part of this change"* from *"the target is part of this change but untested"*. It does **not** separate
*"untested but testable"* from *"untestable"*. #1664 (run `20260801225808-15285`) is the latter: a
policy ADR + CI-config change declared `WIRING: .github/workflows/test.yml`, which **was** in PR
#1680's diff (`+9/-2`), so it lands on `inert_wiring` — build-fixable — even though no shell testfile
can load workflow YAML. Build's only lever was to make the declaration true, and it wrote a static
grep of the YAML, which the issue had explicitly forbidden.

No static predicate separates those two cases. A bash file no test happens to reference yet (build
should write the assertion) and a YAML file no test can ever load (design should declare
`WIRING: none`) are structurally identical to any inspection of the repository; the only difference
is whether the test runner can load the file as code, and encoding that in the engine is exactly the
target knowledge ADR-049 forbids. Nor can it be settled at design time, when build has not yet
written the assertions.

Separating them requires a second measurement rather than a better guess: let `inert_wiring` stand on
first occurrence so build gets a real attempt, and escalate the same still-inert target to
`route_target=design` on a later iteration. Tracked in #1711 as the general case — a stage handed a
problem it cannot solve needs an escalation path, not a workaround.

## Amendment (#1684, 2026-08-04) — the summary states what each SPEC claims and what was asserted, and it persists

The concise operator summary above (#1211) reports a verdict per SPEC id and nothing about *what was
tested*. `NEGCTL PASS SPEC-2` asserts that some tagged assertion failed at the baseline and passes at
HEAD — not that the assertion has anything to do with what SPEC-2 claims. On run
`20260801225757-5482` it did not: design's `SPEC-2[change]` described a SIGTERM trap path, build
tagged an unrelated "killed tier prints ABORTED" assertion with the same id, and every mechanical
check was satisfied while the riskiest code in the change shipped with zero coverage.

That gap is not mechanically decidable in general (see #1670, #1675, #1691 for the cases where it
partly is). This amendment makes it **visible** instead, and costs one rendering change plus one
artifact write.

**1. Each per-SPEC line carries the design's claim and the asserted label, on their own lines.**

```
NEGCTL PASS SPEC-2
      design : SIGTERM to the --tier all orchestrator … exits non-zero (INT/TERM trap path)
      asserts: assert_eq "[SPEC-2] killed mutation tier → 'mutation: ABORTED' on stderr" …
```

The verdict token remains the leading content of its own line, so existing parsers and the
one-line-per-SPEC count are unaffected. Both strings are truncated at 100 chars with `…` — the
earlier 60 cut away the clause that distinguishes one SPEC from another, which is the only reason to
print it. Absent values render as `<no description>` / `<none found>`, never as a blank gap.

**2. The label is the first line that INVOKES an assertion helper, not the first textual match.**
These testfiles routinely carry `[SPEC-n]` as fixture text — tests-of-the-gate write sandbox repos
whose bodies contain tags. Taking the first match reported a label that was never asserted, which is
worse than reporting nothing because it reads as confirmation. Two passes: assertion-shaped lines
across all declared testfiles first, any tagged line only as fallback.

*Residual:* SPEC ids are file-global, so a testfile carrying the same id for a **different** design's
SPEC can still win pass 1. Not solvable without per-design id namespacing — tracked in #1691.

**3. The summary is written to `artifacts/acceptance-summary.txt`.** `_ag_emit_operator_summary`
writes to a terminal fd and is io-gated on the stage having a `stdout` destination: on a file-only
install it produces nothing, and when it does fire it survives only as long as the scrollback. The
review lenses and any post-hoc audit of a finished run read artifacts. Without the file the
design-vs-assertion pairing is visible to nobody once the run ends — which is precisely when someone
goes looking for why a green run shipped an untested requirement.
