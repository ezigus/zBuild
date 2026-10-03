## ADR-021 — Pipeline Cycle Semantics (Outer-Cycle Framework) (Accepted; heavily amended in place: #2117, #511, #527/#528, #585, #608, v3 #796, v4 #842, v5 #895, #845, #936, #937, Phase 2, #1208, #945, #1261, #1265; amended by ADR-042, ADR-045; template syntax superseded by ADR-027 recursive `flow:`, `until:` generalised to `exit_when` by ADR-047; `source: cycle_feedback` retired by ADR-055 §4; `test_assessment`/standard.yaml amendments historical — ADR-022 Retired #979)

Historical / superseded parts listed WITHOUT statements: §Decision point 6 (priority order — superseded by #528, #845, then #1208), §Decision point 8 (flag default off — superseded by #511 Pin 4), F1/F2 split table, §"test_assessment as until source" (#572; stage + standard.yaml deleted, ADR-022 Retired), Pin 5 (`_build_read_prior_failures` no longer exists), Amendment v4 design_impact_cycle (no such cycle; `impact` is a leaf in config/templates/simple.yaml:39), §Flat-velocity plateau (removed as terminator by #1208; detector dormant), plateau/divergence window rules (dormant per #1208).

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Amend #2117 | iter≥2 + build `empty_diff` + unchanged tree fingerprint → members that passed are REUSED (blob copied, `cycle.iteration.reused`, no dispatch) | tests/unit/core-pipeline-cycle-stall-break-test.sh:129-130 | HIGH | negative control (changed tree → no reuse) at :150-152 |
| Amend #2117 | "a member that FAILED re-runs" | CONTRADICTED — tests/unit/core-pipeline-cycle-reuse-and-route-back-test.sh:46 asserts the failing test member is dispatched once and reused 4x | HIGH | code (#2170, cycle-orchestrator.sh:1675-1696) reuses non-iteration-aware failures; only iteration-aware members (acceptance-gate) re-run (:52). See Conflicts |
| Amend #2117 | Pin-8 cleanup is per member, right before dispatch (reused member keeps artifact) | UNTESTED | MEDIUM | `_cycle_pre_iter_cleanup` is stubbed to `:` in the two tests that mention it |
| Amend ADR-042 | cycle members resolve plugin role-then-id via `resolve_stage_plugin` | tests/unit/stage-resolution-parity-test.sh:68-76 | MEDIUM | |
| Amend ADR-045 | rc=11 route_back is non-halt; budget default 2 total passes | tests/unit/route-back-budget-config-test.sh:75-79; tests/integration/route-back-budget-exhausted-test.sh:73-80 | HIGH | |
| Amend ADR-045 | only `term_rc ∈ {2,8}` is reclassified to route_back | CONTRADICTED — tests/unit/core-pipeline-cycle-reuse-and-route-back-test.sh:105-108 asserts rc=7 blocked_on_scope routes back | HIGH | see Conflicts |
| DP1 | cycles are an overlay; dispatch units are `stage:<id>`/`cycle:<id>`, flat `_TPL_STAGES[]` keeps canonical order | tests/unit/core-pipeline-template-cycles-test.sh:29,40-46,240 | MEDIUM | |
| DP2 | `until`/`exit_when` field whitelist `verdict|status`, ops `eq|ne` | tests/unit/core-pipeline-cycle-convergence-test.sh:37-48,81 | MEDIUM | ADR-047 adds op `in` (template.sh:1312) — extension, not conflict. No test that an unknown field/op is REJECTED at load |
| DP2 | field missing → UNCONVERGED (never falsely converge) + `cycle.iteration.verdict_missing` | tests/unit/core-pipeline-cycle-convergence-test.sh:54,63; tests/unit/core-pipeline-cycle-high-banner-integration-test.sh:43 | HIGH | |
| DP3 | feedback copied to `${state_dir}/cycle-<id>/iter-<N>/feedback/<to>.txt`; `ZBUILD_CYCLE_FEEDBACK_DIR` exported | tests/unit/core-pipeline-cycle-feedback-test.sh:28-31 | MEDIUM | |
| DP3 | missing REQUIRED from-field fails loud (`cycle.feedback.missing`, rc≠0), never empty-substitutes | tests/unit/core-pipeline-cycle-feedback-test.sh:39-40,78-79 | HIGH | |
| DP4 | one atomic `locked_state_update` per iteration boundary (current_iter + iter[] + status, "NEVER split") | UNTESTED | MEDIUM | orchestrator-run test checks the iter[] entry exists (:144-146), not atomicity/single-write |
| DP5 | runner owns EXIT trap; cycle installs INT/TERM only | tests/integration/cycle-orchestrator-sigint-test.sh:220 (nested TERM ownership) | MEDIUM | "cycle never installs EXIT" not asserted |
| DP5 | cycle RE-INSTALLS INT/TERM after every dispatched stage (route.sh clobbers) | UNTESTED | HIGH | a lost handler = Ctrl-C mid-cycle swallowed; no test drives a clobbering stage then signals |
| DP7 | `max_iterations` REQUIRED, 1..10 (`_CYCLE_ABSOLUTE_MAX=10`), invalid → fail-closed at template load | tests/unit/core-pipeline-template-cycles-test.sh:93-94,111-112 | HIGH | only 11 and missing tested; 0/negative not tested; `cycle.config.invalid` emission for this case not asserted |
| Events | all listed cycle events registered in `config/event-schema.json::known_types` | tests/unit/core-pipeline-cycle-events-test.sh:35 | LOW | |
| State | older state without `.cycle_iterations` upgraded in place (`//= {}`) | UNTESTED | LOW | cycle-orchestrator.sh:1388 |
| Orch surface | rc 0 converged / 4 config_invalid / 130 aborted; sets `_CYCLE_LAST_*` | tests/unit/core-pipeline-cycle-orchestrator-run-test.sh:69-86,133; tests/integration/cycle-orchestrator-sigint-test.sh:79-81 | MEDIUM | rc 1/3 no longer produced by #1208 cascade |
| #526 | HIGH events emit BOTH JSONL and a one-line `⚠` stderr banner; informational events no banner | tests/unit/core-pipeline-cycle-high-banner-integration-test.sh:33-75; tests/unit/event-high-banner-test.sh:20-34 | MEDIUM | |
| #526 | banner emit failure MUST NOT abort the cycle | tests/unit/event-high-banner-test.sh:52-55 | MEDIUM | |
| #524 | `cycle.complete` emitted FIRST, then the exit hook (single fan-in) | UNTESTED | LOW | no ordering assertion found |
| #1177 | `exit_when` target that is convergence-marked must be a cycle MEMBER declaring `convergence: gate`; advisory/non-member fails preflight in contract-validator AND lint-contract | tests/unit/lint-contract-convergence-test.sh:168,274 (lint side, advisory/agent target) | HIGH | runtime contract-validator side (`CYCLE_AGG_NOT_MEMBER`/`CYCLE_AGG_TYPE`, contract-validator.sh:779) has NO test; non-member case untested anywhere |
| #1177 | untyped `exit_when` targets are NOT retro-checked | tests/unit/lint-contract-convergence-test.sh:199 | LOW | |
| Impl notes | numeric inputs validated → `cycle.metric.invalid` | tests/unit/core-pipeline-cycle-high-banner-integration-test.sh:49-52; tests/unit/core-pipeline-cycle-convergence-test.sh:75 | LOW | |
| #511 consumer decl | `feedback.to.input` MUST be declared `source: cycle_feedback`; `CYCLE_FB_UNWIRED`/`CYCLE_FB_UNDECLARED` enforce both directions | RETIRED — ADR-055 §4 | — | codes retired; tests/unit/lint-contract-cycle-feedback-test.sh:175,205 document retirement. See Conflicts |
| #511 Pin 2 | feedback source resolved via from-stage manifest `outputs[].path`, not `artifacts/<stage>/<output>` | tests/integration/core-pipeline-cycle-build-test-wiring-test.sh:157-158 | MEDIUM | |
| #511 Pin 8 | before each iter dispatch, stage primary outputs are deleted (`cycle.artifacts.cleared`) so a stale artifact cannot satisfy `until` | UNTESTED | HIGH | the stale-artifact false-convergence class; no test asserts deletion or the event (two tests stub the function out) |
| #511 Pin 16 | test-results.json overwritten each iter (final iter visible downstream) | UNTESTED | LOW | |
| #511 Pin 7 / #528 | runner CONTINUES on cycle rc∈{0,1,2,3}; HALTS (`status=interrupted`, review skipped) on rc∈{4,5,130} | tests/integration/build-test-cycle-fallthrough-to-review-test.sh:194-282; tests/unit/runner-cycle-rc-action-mapping-test.sh:102 | HIGH | rc-action-mapping's "continue" check (:109) only proves `intake` (BEFORE the cycle) ran — weak; fallthrough test is the real check |
| #511 Pin 14 | `--from-stage <S>` REFUSED rc=2 when S is a cycle member OR strictly after a cycle; `pipeline.from_stage.rejected` | tests/integration/core-pipeline-cycle-build-test-wiring-test.sh:180-185 | MEDIUM | only the "inside cycle" case; "after a cycle" and the event untested |
| #511 Pin 4 | cycles auto-enabled when template declares any; `ZBUILD_CYCLES_ENABLED=0` forces off with `cycle.disabled reason=env_override` + banner | UNTESTED | MEDIUM | many tests SET =0 as fixture, none assert the override event/banner or auto-enable event |
| #527 | orchestrator MUST NOT mutate `pipeline_status` | UNTESTED | MEDIUM | code complies (only `.cycle_iterations[$id].status` written, cycle-orchestrator.sh:1421) |
| #527 | on rc∈{1,2,3} runner sets `stage_statuses[<until-stage>]=failed` and emits `cycle.unconverged` | tests/unit/runner-cycle-rc-action-mapping-test.sh:125-126 (event only) | MEDIUM | `stage_statuses[until]=failed` itself UNTESTED (runner.sh:3363, best-effort `|| true`) |
| #528 | blocked fires on raw verdict ∈ {error, corrupt_diff, block}; NOT on fail / missing / scope_violation | tests/unit/core-pipeline-cycle-blocked-test.sh:44-81 | HIGH | |
| #528 | blocked bypassed when `until.value == error` | tests/unit/core-pipeline-cycle-blocked-test.sh:87 | LOW | |
| #528 | rc=5 blocked halts the pipeline (review does not run) | tests/integration/core-pipeline-cycle-blocked-integration-test.sh:81-83; tests/integration/build-test-cycle-fallthrough-to-review-test.sh:272-274 | HIGH | |
| #528 | jq parse failure / empty verdict blob → fail-CLOSED + `cycle.metric.invalid` | tests/unit/core-pipeline-cycle-blocked-test.sh:93-102 | MEDIUM | |
| #528 | event order iteration.complete → cycle.blocked → cycle.complete(reason=blocked) | tests/integration/core-pipeline-cycle-blocked-integration-test.sh:111 | LOW | |
| #585 | top-level `cycles:` block is refused, pointing at migrate-template-v2.sh | tests/unit/core-pipeline-template-cycles-test.sh:217-219 | MEDIUM | |
| #585 | every cycle member MUST have a `stage_definitions` entry | tests/unit/core-pipeline-template-cycles-test.sh:271-272 | MEDIUM | |
| #585 | `until.stage` MUST be in the cycle's stages | tests/unit/core-pipeline-template-cycles-test.sh:132-133 | MEDIUM | template.sh:1319 also enforces for multi-condition exit_when; not separately tested here |
| #585 | migrate-template-v2.sh is idempotent | UNTESTED | LOW | no test invokes the script |
| #608.1-3 | build commits each iteration (pipeline, not LLM) as `zbuild-pipeline <pipeline@local>` | tests/integration/cycle-commits-per-iter-test.sh:151,158 | HIGH | |
| #608.2 | the LLM is forbidden from `git commit` (prompt `### Rules`) | UNTESTED | LOW | text exists at plugins/agent/build/lib/prompt.sh:107; no assertion |
| #608.4 | commit uses `--no-verify` | UNTESTED | MEDIUM | plugins/agent/build/lib/commit.sh:140; a target-repo hook would block mid-cycle |
| #608.5 | scope_violation / empty staged diff → NO commit + `build.commit.skipped reason=<scope_violation|empty_diff>` | tests/integration/cycle-scope-violation-no-commit-test.sh:129-143 | HIGH | test asserts reason=`empty_diff` on a scope_violation run (:134), not `scope_violation` |
| #608.6 | `build.commit.created sha=… iter=N`; orchestrator populates `cycle.iter.N.commit_sha` | tests/integration/cycle-commits-per-iter-test.sh:170-172 (event only) | LOW | `commit_sha` state population is NOT implemented (no `commit_sha` in core/ or plugins/) — code contradicts |
| v3 R1 | `on_max: continue` exhaustion does not by itself fail the pipeline (downstream pass → complete); `on_max: abort` → failed | tests/unit/cycle-on-max-continue-pipeline-status-test.sh:57-89; tests/integration/runner-cycle-on-max-halt-test.sh:85-101 | HIGH | code yields `complete_unconverged`; `on_max: halt` (#2241) stops before the next unit |
| v3 R2 | `route_to_model` returns rc=124 and rc=137 verbatim (never → 1) | tests/unit/router-rc124-propagation-test.sh:60,70 | HIGH | |
| v3 R2/#1237 | rate limit: rc stays 1, honest message, `router.rate_limited` event, NOT auto-retried | tests/unit/router-rate-limit-test.sh:73-84,140-148 | MEDIUM | the "remains NON-blocking / verdict=fail recoverable" half is contradicted by #2111 (see Conflicts) |
| v3 R3 | NO pre-LLM gates in cycle members (must call the LLM with this iter's feedback); lint-contract static check | UNTESTED | HIGH | the proposed lint rule was never written (no match in scripts/lib/lint-*.sh); a re-introduced #789-style short-circuit passes every gate |
| v5 #895 / #1208.4 | empty_diff + gates green = converge (iter 1); empty_diff + red = re-iterate | tests/unit/core-pipeline-cycle-stall-break-test.sh:177-186; tests/unit/convergence-timeouts-never-fatal-1208-test.sh:195-197 | HIGH | |
| #936 | `_impact_converge_on_overscope` flips incomplete→complete ONLY when iter≥2, identical non-floor set, all collateral, no floor, no shape-change | tests/unit/impact-scope-plateau-test.sh:60-138 | LOW | inert in production: `impact` is a top-level leaf (simple.yaml:39), so `ZBUILD_CYCLE_ITER>=2` never holds. "every file exists" condition not separately asserted |
| #937 | impact router timeout (rc=124) → best-effort `verdict=incomplete`, `reason=router_timeout`; rc=137 keeps `error` | tests/integration/impact-router-timeout-782-test.sh:69-76,150-160 | MEDIUM | |
| Phase 2 | member `disposition: terminal` + verdict fail → HALT rc=8 + `cycle.member.terminal_failure member=<id>` | tests/unit/core-pipeline-cycle-acceptance-terminal-test.sh:91-92; tests/integration/cycle-acceptance-terminal-failure-test.sh:370-389 | HIGH | |
| Phase 2 | recoverable / advisory / ABSENT disposition → non-terminal (fail-safe) | tests/unit/core-pipeline-cycle-acceptance-terminal-test.sh:122-132; tests/integration/cycle-acceptance-terminal-failure-test.sh:405-427 | HIGH | |
| Phase 2 | engine names no plugin id / artifact filename (generic roster resolution) | tests/unit/core-pipeline-cycle-acceptance-terminal-test.sh:144-145 | MEDIUM | behavioral (custom member id); no grep guard on cycle-orchestrator.sh |
| #1208.1 | a build timeout is NEVER fatal: router loop yields rc 0 + `router_timeout`, cycle keeps iterating | tests/unit/convergence-timeouts-never-fatal-1208-test.sh:153-160 | HIGH | |
| #1208.3 | a mid-flight (timed-out) build cannot ratify convergence; `cycle.build_unfinished.suppressed_convergence` | tests/unit/convergence-timeouts-never-fatal-1208-test.sh:170-176 | HIGH | |
| #1208.5 | single fatal = exhaustion without convergence; tests failing → rc=8 HALT, tests passing-but-unclean → rc=2 | tests/unit/convergence-timeouts-never-fatal-1208-test.sh:215,220,287 | HIGH | |
| #1208 | plateau/divergence/velocity/stall-break are NOT terminators; cycle runs all tries | tests/unit/core-pipeline-cycle-stall-break-test.sh:113-120; tests/integration/cycle-velocity-plateau-early-exit-test.sh:60-64 | MEDIUM | |
| #1208 | orchestrator keys only on repo-neutral signals (no runner/language hardcode) | tests/unit/convergence-timeouts-never-fatal-1208-test.sh:291-296 | LOW | grep guard |
| #945 | design router timeout → overwrite design.md with a gate-FAILING marker, emit `design.timeout.stub_written`; marker-write failure → `marker_write_failed` rc=1 | CONTRADICTED — tests/unit/design-router-timeout-reiter-test.sh:140-164 asserts the #2186 behaviour (keep a changed design / delete a stale one; `design.timeout.no_design`) | MEDIUM | see Conflicts |
| #945 | timeout yield → design returns rc=0 (non-terminal); non-timeout rc≥2 (e.g. 137) → rc=1 terminal | tests/unit/design-router-timeout-reiter-test.sh:151,221-233 | MEDIUM | |
| #1261 | interrupted design + NO test signal at exhaustion → `design_timeout_exhausted` rc=8 HALT (overrides on_max continue) + `cycle.timeout_exhausted` | tests/unit/design-timeout-exhaustion-halt-1261-test.sh:197-207 | HIGH | negative controls :218-244 |
| #1261 | `design_timeout_exhausted` is NEVER rerouted (route_back) | UNTESTED | MEDIUM | guard at cycle-orchestrator.sh:2859, no assertion |
| #1265 | zero commits ahead of intake baseline + build ≠ empty_diff → convergence suppressed + rc=5 terminal `no_committed_changes` | tests/integration/cycle-no-committed-changes-fail-fast-test.sh:100-113 | HIGH | |
| #1265 | empty_diff resting point is EXEMPT | tests/integration/cycle-no-committed-changes-fail-fast-test.sh:168-174; tests/unit/core-pipeline-cycle-stall-break-test.sh:186 | HIGH | |
| #1265 | scope `grant` → does NOT terminate; absent baseline → predicate false; never route_back | UNTESTED | MEDIUM | three sub-rules, no assertions found |
| Decision factor | "mid-cycle kill -9 must not lose history or restart from iter 1" (Mandatory) | UNTESTED; code contradicts | HIGH | the loop always starts at 1 (cycle-orchestrator.sh:2435); `current_iter` is written (:1420) but never read; fixture tests/fixtures/templates/cycle-resume.yaml is referenced by no test |


## ADR-022 — Test Assessment Stage — LLM-Interpreted Test Verdict (Retired, #979 / EPIC #1277)

Retired: the `test_assessment` plugin and `standard.yaml` were deleted when the compound-quality lattice was retired; `simple.yaml` converges `build_test_cycle` on the `gate-aggregator` verdict (ADR-040 §5). Pins 1–10 and Amendments v2–v6 are historical. They are not listed as statements. Only the retirement note is normative.

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Status | the `test_assessment` stage plugin "was deleted" (no plugin present) | tests/unit/adr-migration-claims-test.sh:41-45 (checks only that a doc naming the stage also says it was deleted, keyed on plugin dir absence) | LOW | Doc-consistency check, not a code check. Nothing asserts that `plugins/agent/test_assessment/` stays absent. `ls` confirms it is absent today. |
| Status | `simple.yaml` `build_test_cycle` converges on the `gate-aggregator` verdict, not `test_assessment` | tests/unit/template-simple-yaml-test.sh:265-272 (SPEC-15: UNTIL_STAGE == gate-aggregator, field verdict, op eq, value pass); :255 (SPEC-14: cycle roster excludes test_assessment) | HIGH (tested) | Real assertion on the parsed template. |

Residue that visibly contradicts the retirement (dead declarations, not behaviour):
- plugins/tool/test/manifest.yaml:43-47 still declares 5 `test_assessment.*` events (`acceptance_fail`, `advisory_mode`, `downgrade`, `missing_baseline`, `missing_input`) that nothing emits.
- plugins/agent/review-aggregator/manifest.yaml:64 still declares `review.test_assessment.consumed`.
- tests/unit/event-schema-emitted-coverage-test.sh:123 still lists `test_assessment` as a plugin namespace.

## ADR-023 — Install isolation: copy pipeline runtime into `$ZBUILD_HOME` (Accepted #595; amended #888 2026-07-27 and #141 2026-08-23 → ADR-059)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| D1 | `$ZBUILD_HOME` is "the single source of truth"; default `~/.local/share/zbuild`, overridable | UNTESTED for the default value (install-copy-flow-test always sets ZBUILD_HOME explicitly); override covered by tests/integration/install-copy-flow-test.sh:50 | MEDIUM | Default visible at install.sh:62 and scripts/zbuild:282. scripts/install-remote.sh:44 installs to `~/.zbuild` instead (see Conflicts). |
| D2 | rsync copies `scripts/ core/ plugins/ config/` | tests/integration/install-copy-flow-test.sh:57-62 | MEDIUM | Checks each directory is non-empty. Code also copies `.github/issues/` (install.sh:91), which the ADR doesn't list. |
| D2 | `tests/ docs/ legacy/ .git/` "are excluded" | tests/integration/install-copy-flow-test.sh:66-75 (tests/, docs/ only) | LOW | `legacy/` and `.git/` exclusion is UNTESTED. It holds only because the copy is an allowlist. |
| D2 | `--delete` "makes re-installs idempotent" (stale files removed) | UNTESTED | MEDIUM | No test plants a stale file and re-installs. If `--delete` were dropped, deleted plugins would stay live in the installed engine and nothing would catch it. |
| D3 | shim is a regular file, "never a symlink" | tests/integration/install-copy-flow-test.sh:87-90 | HIGH (tested) | |
| D3 | shim exports `ZBUILD_HOME` and execs `$ZBUILD_HOME/scripts/zbuild` | tests/integration/install-copy-flow-test.sh:93-94 | MEDIUM | Weak: substring greps of the shim text. Nothing runs the shim and checks which tree executes. |
| D3 | shim exports `ZBUILD_FROM_INSTALL=1` | UNTESTED | LOW | No consumer in code (scripts/zbuild:529 says explicitly that it is path-based, not ZBUILD_FROM_INSTALL-based), so the flag is dead. |
| D4 | version file records `sha=` `branch=` `installed_at=` (ISO-8601 UTC) `source=` | tests/integration/install-copy-flow-test.sh:81-82 (sha, branch only) | LOW | `installed_at` and `source` are UNTESTED. The version-subcommand test uses a hand-written fixture. |
| D5 | `zbuild version` prints the contents of `$ZBUILD_HOME/version` | tests/integration/zbuild-version-subcommand-test.sh:38-40 | LOW | |
| D5 | falls back to `git rev-parse` of the source clone when there's no version file | UNTESTED (weak) | LOW | zbuild-version-subcommand-test.sh:45 covers only the non-git branch ("re-run install" notice). The git fallback path at scripts/zbuild:292-295 is never exercised. |
| D6 | `zbuild upgrade` "--from flag is required" | tests/integration/zbuild-upgrade-subcommand-test.sh:42 | LOW | Weak: asserts the hint text only, not the nonzero exit (rc=2 at scripts/zbuild:383). Drift: `--tag` is now an alternative (scripts/zbuild:381, ADR-048), so `--from` is no longer strictly required. |
| D6 | upgrade runs `git pull --ff-only` in the source, then execs its `install.sh` | tests/integration/zbuild-upgrade-subcommand-test.sh:58-66 (install re-run → version file changes) | MEDIUM | `pull --ff-only` is UNTESTED: the fixture has no remote, and a pull failure only warns (scripts/zbuild:395). |
| D7 | migration: an existing symlink is removed, a shim is written, and a "migrating" notice prints | tests/integration/install-copy-flow-test.sh:103-109 | LOW | |
| D8 | CI invokes `bash scripts/zbuild` directly from the source clone | UNTESTED | LOW | Describes the workflow, not the engine. |
| Impl | install smoke test execs the *copied* `scripts/zbuild --version` | UNTESTED | LOW | install.sh:155. A failure would exit 1 and every install test would fail anyway, so it's indirectly covered. |
| Context/Consequences | installed runtime "is immune to … any mid-run edit of the source clone" | tests/integration/install-copy-flow-test.sh:124 (runner.sh hash unchanged after source commit) | HIGH (tested) | Checks one file only, but it is the core invariant. |
| Am.#888 | "nothing the pipeline owns lives inside the repo it is working on" | tests/unit/worktree-location-test.sh:105 (a worktree inside the repo is refused); :116-120 (empty args refused) | HIGH | Covers worktrees only. State dir and engine location outside the repo are UNTESTED as a general rule. |
| Am.#888 | worktree-by-default; "`--no-worktree` opts out" | tests/unit/worktree-location-test.sh:96; tests/integration/worktree-run-isolation-test.sh:201 (`ZBUILD_NO_WORKTREE=1`) | MEDIUM | Code contradiction: no `--no-worktree` CLI flag exists (grep finds nothing in scripts/ or core/). The opt-out is env-only. |
| Am.#888 | default worktree root "deliberately avoids `$TMPDIR`" | tests/unit/worktree-location-test.sh:47-51 | HIGH (tested) | |
| Am.#888 | overridable via `ZBUILD_RUN_ROOT`, `ZBUILD_WORKTREE_ROOT`, template `config.worktree_root` | tests/unit/worktree-location-test.sh:57, :71, :76 | MEDIUM | Precedence is env > template > co-located (:76). |
| Am.#888 | a branch already checked out elsewhere "is refused, not forced" | tests/unit/worktree-location-test.sh:159 (rc=3, "already checked out") | HIGH (tested) | |
| Am.#141 | layout re-keyed to `…/repos/<repo>/issues/<N>/worktree/`, with run state at `runs/<run_id>/` below it | tests/unit/layout-writer-test.sh:99 (issue-keyed tree path), :102 (the run records it) | HIGH (tested) | The ADR text writes the base as `$ZBUILD_HOME`, which is wrong (see Conflicts). Code uses data_root `~/.zbuild` (scripts/lib/worktree.sh:69). The pre-#141 per-run path is still pinned for bare run_ids at tests/unit/worktree-location-test.sh:38. |


## ADR-024 — Subprocess Environment Isolation Contracts (Accepted)

Accepted 2026-06-03 (#671/#673). Amended in place: #674 (two-layer contract), #897 (TMPDIR), #1127 (`ZBUILD_STATE_ROOT` fence), #141 (widen fence before layout move), #1270 (`ZBUILD_TEMPLATES_DIR` reverted), #1274 (`ZBUILD_PLUGINS_ROOT` excluded), #1272 (tests honor fence vars), #2103 (fixture cd/push fence). Partly overridden by ADR-058 C10 (TMPDIR pinning), which the ADR does not record.

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Decision | Fresh-user-shell spawns "scrub the entire `ZBUILD_*` namespace" before exec (`_TPL_*` too, #683) | tests/unit/env-scrub-test.sh:37-38, :84-88; double binding (#1873) :130; empty arrays/hashes :167-170 | HIGH | Tests the helper directly. |
| Decision | Fresh-user-shell "close fd 3" before exec | tests/unit/env-scrub-test.sh:62 | MEDIUM | |
| Decision / #674 L1 | Helper "preserves user-shell vars (PATH, HOME, USER, SHELL, TERM, TMPDIR…)" | tests/unit/env-scrub-test.sh:39 (one non-ZBUILD var only) | LOW | TMPDIR is NOT preserved: env-scrub.sh:82 overwrites it (ADR-058 C10). See Conflicts. |
| Decision / Members | Test plugin's suite spawn calls `_zbuild_make_fresh_shell` (no `ZBUILD_*`, fd 3 closed) | tests/integration/test-plugin-fresh-shell-test.sh:88, :102 | HIGH | Child probes only RUN_ID / EVENTS_JSONL / STAGE_IO_FD. Wildcard coverage comes from the helper unit test. |
| Decision / Members | "All four" router `claude` spawns use the helper | sync path: tests/integration/route-fresh-shell-test.sh:91, :94. Loop path: tests/integration/route-loop-fd-isolation-test.sh:157-158 only | HIGH | Partial. Sync: only the one `_tout_cmd` branch the host takes (route.sh:1045 vs :1050). Loop (route.sh:1949/:1956): the child checks only `ZBUILD_STAGE_IO_FD` and fd 3, so a loop spawn that leaked `ZBUILD_RUN_ID` (the Wave 13 bug) would pass. No static guard pairs every `claude` exec with the helper. |
| Boundary | Scrub happens "at the inner subshell … NOT at plugin entry, NOT at runner dispatch"; the plugin keeps full `ZBUILD_*` after the spawn | UNTESTED | MEDIUM | No test checks that the parent still has `ZBUILD_RUN_ID` / `EVENTS_JSONL` after `_test_run_inner` / `route_to_model`. |
| Pipeline-internal | Agent plugins and cycle orchestrators get "no scrub" | UNTESTED | LOW | Only implied by other suites passing. |
| #674 L1 | Helper "neutralizes shell options (`set +e +u +o pipefail`)" | UNTESTED | MEDIUM | No test reads `$-` / `shopt -o` after the helper. |
| #674 L2 | Harness sets RUN_ID, STATE_DIR, EVENTS_JSONL, EVENT_SCHEMA, ARTIFACT_DIR | tests/unit/test-harness-init-test.sh:46-50 | LOW | |
| #674 L2 | Harness EXIT trap composes "additively" onto an existing trap | tests/unit/trap-chain-robust-test.sh:51, :72 | LOW | |
| #674 L2 | Scoped helpers' mutations "do not leak" into the caller | tests/unit/test-harness-init-test.sh:100, :115, :143 | LOW | |
| #674 boundary | "Tests MUST source the harness (or run via tests/run-all.sh)" rather than inherit | UNTESTED | LOW | Not enforced. |
| #674 boundary | "Nothing in core/, plugins/, scripts/ imports tests/lib/test-harness.sh" | UNTESTED | LOW | True today by grep; no guard. |
| #897 | A test asserting over `${TMPDIR}` artifacts "MUST pin TMPDIR" under TEST_TEMP_DIR | UNTESTED | MEDIUM | No lint. Prior-art files comply individually. |
| #1127 | State root is `${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}` at every live site; unset = default unchanged | tests/integration/state-root-isolation-test.sh:111, :136, :157 (fenced); :196-199 (default); :214 (`--resume-latest`) | HIGH | Covers runner and `scripts/zbuild` only. No per-site guard for event-bus / common.sh / discovery.sh / stage-io.sh / platforms.sh / route.sh. |
| #1127 | Test stage exports `ZBUILD_STATE_ROOT` (plus ledger/cache) inside the subshell AFTER the scrub; nested runs never touch the parent root | tests/integration/state-root-isolation-test.sh:292-307, :316 | HIGH | |
| #141 | Fence must widen to `ZBUILD_RUN_ROOT` / `ZBUILD_WORKTREE_ROOT` "BEFORE the layout moves" | UNTESTED | HIGH | Code does the opposite: core/state/layout.sh:237-242 deliberately never fences `ZBUILD_RUN_ROOT`, and the ADR-059 per-issue layout is live. See Conflicts. |
| #1270 | Engine no longer reads `ZBUILD_TEMPLATES_DIR`; fence set is "state/ledger/cache only" | tests/integration/suite-under-teststage-env-test.sh:71, :100 | MEDIUM | Fence set now also re-exports `ZBUILD_TEST_TIMING_FILE` and `ZBUILD_TIER_CONCURRENCY` (plugin.sh:621, :627). #1274 lists the timing file, not the tier var. |
| #1274 | `ZBUILD_PLUGINS_ROOT` "must never be added" to the fence set | tests/unit/plugins-root-hermeticity-test.sh:64 (red-first check :79) | MEDIUM | |
| #1272 | Tests "MUST NOT hardcode a bare `$HOME/.zbuild/*`" path | UNTESTED (weak) | MEDIUM | suite-under-teststage-env-test.sh:142 runs one file (router-budget-test) under the fence. No tree-wide lint. |
| #2103 SPEC-1 | A fixture `cd` "MUST be fatal on failure" (no bare cd + git) | tests/unit/fixture-cd-escape-guard-test.sh:135 (scanner self-test :116-125) | HIGH | |
| #2103 SPEC-5 | run-tests.sh fails any file that changes the checkout's HEAD / branch / tree | tests/unit/fixture-cd-escape-guard-test.sh:214-216 | HIGH | |
| #2103 SPEC-6 | Pushes to the real origin URL are rewritten to a dead path; own temp origin unaffected | tests/unit/fixture-cd-escape-guard-test.sh:218-222, :229, :255 | HIGH | |

## ADR-025 — Abort Propagation Contract (Accepted)

Accepted 2026-06-04 (#684). Amended in place by #905 (synchronous reap). Amended by ADR-054 §7 (cleanup / teardown ownership, #1829), but ADR-025's header does not cite it. ADR-054 §4 plans to retire the rc vocabulary. The classifier has been widened past the ADR (rc 6 per ADR-027; rc 9 and 10 per #1024 / #1052).

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| L1 | `_zbuild_propagate_abort <rc>` "returns <child_rc> if abort rc (130, 143), else 0", not a hard-coded 130 | tests/unit/abort-propagation-test.sh:29, :36, :62-74 | HIGH | rc 6 is in the classifier but has no case in this unit test. |
| L2 | `_zbuild_check_abort` returns 130 iff `${ZBUILD_STATE_DIR}/.abort.signal` exists | tests/unit/abort-propagation-test.sh:84, :91, :105, :120 | HIGH | |
| L2 | Runner's INT/TERM trap "creates the sentinel file as the first action" | UNTESTED (weak) | MEDIUM | runner-signal-rearm-test.sh:60/:99 asserts trap install parity only (its header says so). No test fires the trap and observes the sentinel. Code does it at runner.sh:2493. |
| Dispatch contract | "Every dispatcher MUST" call `_zbuild_check_abort` before each child and `_zbuild_propagate_abort $?` after | UNTESTED | HIGH | No guard enumerates dispatchers. Code: only cycle-orchestrator.sh (:1665, :2008, :2482) and the runner pre-flight (:3718). strategies/{sequential,fanout,map,composite}.sh and parallel-orchestrator.sh call neither; route.sh calls neither (see next row). |
| Members: cycle orch | `_cycle_iter_dispatch` post-flight propagates rc=130 and stops iterating | tests/integration/cycle-orchestrator-sigint-test.sh:79-81 | HIGH | |
| Members: cycle orch | Cycle pre-flight sentinel stops the next iteration | tests/integration/cycle-orchestrator-sigint-test.sh:114-117, :151-153 | HIGH | |
| Members: runner | Linear stage loop runs the sentinel pre-flight before each stage | UNTESTED (weak) | MEDIUM | full-pipeline-sigint-test.sh:146 has build arm the sentinel AND return 130, so the old rc path alone also passes. The pre-flight is not isolated. |
| Members: router | `route_to_model_loop` runs a "pre-flight sentinel check before each claude exec spawn" and calls the helpers post-spawn | UNTESTED | MEDIUM | Not implemented: no `_zbuild_check_abort` / `_zbuild_propagate_abort` / `.abort.signal` in core/router/. |
| Cleanup | EXIT trap removes the sentinel so a later invocation sees no stale file | tests/integration/full-pipeline-sigint-test.sh:163; tests/integration/runner-job-control-regression-test.sh:119 | MEDIUM | ADR says remove "after emitting the event". Code removes BEFORE `pipeline.aborted` (runner.sh:2429 vs ~:2461). Benign. |
| Cleanup | Stale sentinel cleared at runner (resume) entry | tests/integration/resume-after-sigint-test.sh:226 | MEDIUM | |
| Cleanup | Trap composition "additive": the signal trap still exits 130 / 143 and emits `pipeline.aborted` | tests/integration/sigint-aborts-pipeline-test.sh:144, :172; tests/integration/sigterm-aborts-pipeline-test.sh:186; full-pipeline-sigint-test.sh:151 | HIGH | |
| SIGTERM | rc=143 carries the same semantics as 130 | tests/unit/abort-propagation-test.sh:36; sigterm-aborts-pipeline-test.sh:186 | MEDIUM | |
| #905 | `_route_loop_on_signal` "MUST NOT return until the child tree it signalled has been reaped" (local watchdog, final group KILL) | tests/integration/route-fast-abort-test.sh:224 (synchronous), :421 (no leftover stub), :429 (rc=130) | HIGH | |
| #905 | Abort latency: loop returns within the 2.5s ceiling | tests/integration/route-fast-abort-test.sh:200 | LOW | |
| #905 | Process group "comes from spawn-site `setsid -w`"; does "not reintroduce `set -m`" | UNTESTED | LOW | Contradicted by code: route.sh:1947 uses `set -m` (#2056, route.sh:286). See Conflicts. |


## ADR-026 — Review Remediation Cycle (Retired)

Status: **Retired** (#979, EPIC #1277). Originally Accepted (#707), amended #951 (second feedback edge, max 2→3). `build_review_cycle` lived only in `standard.yaml`, which was deleted; `simple.yaml` uses the advisory `review_lenses` group + `review-aggregator` (ADR-040 §3) instead.

Verified retired in code: no template declares `build_review_cycle`, and `prior_review_feedback` appears nowhere in `plugins/` or `config/` (only stale comments at `core/pipeline/cycle-orchestrator.sh:1756`, `core/pipeline/runner.sh:1118`, `:2838`). Several tests still use `build_review_cycle` as a fixture name (e.g. `tests/unit/cycle-on-max-continue-pipeline-status-test.sh:134`), but they test the generic cycle mechanism, not ADR-026.

No statements are listed because the ADR is historical.

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| — | (retired — no live normative statements) | — | — | Its rc=5 "cycle_abort" text is already annotated as historical (rc=6). |

## ADR-027 — Recursive Flow Template Format (Accepted; amended by ADR-045 #1217/#1225)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| 1 | Reserved top-level keys are **exactly** `{id, name, extends, defaults, flow, _comment}`; "every other top-level key is a stage section" | UNTESTED (weak) | MEDIUM | `tests/unit/template-loader-recursive-flow-test.sh:130` only shows that id/name/extends/defaults do not enter `_TPL_STAGES`, but `_TPL_STAGES` is built from `flow:` anyway. Nothing asserts that a reserved key never becomes a defs row. **Code drift:** the reserved set also includes `merge_policy` and `always_run` (`core/pipeline/template.sh:1809-1811`). The ADR-016 amendment (line 430) restates the old 6-key set. |
| 2 | `flow:` is an ordered list at the top level AND inside each cycle; "the runner walks any `flow:` the same way at any depth" | `tests/unit/template-loader-recursive-flow-test.sh:130`, `:157`; `tests/integration/cycle-orchestrator-nested-cycle-test.sh:109`, `:115` | MEDIUM | Nested T3 checks that the members were dispatched, not their order. |
| 2 | "There is no parallel `stages:` / `stage_definitions:` split" | UNTESTED (contradicted) | LOW | The old shape is still parsed by the back-compat shim (`core/pipeline/template.sh:141-155`), and `tests/unit/template-loader-back-compat-test.sh:94` pins the shim as working. |
| 3 / Loader 4 | `type:` discriminates stage class; "default is `leaf` if absent"; `type: cycle` triggers recursive parse | `tests/unit/template-loader-recursive-flow-test.sh:141-144`, `:157` | LOW | |
| 3 | A stage's section "is the single source of truth" for its attrs (cycle members included) | `tests/unit/template-loader-recursive-flow-test.sh:166-172` | LOW | |
| 4 | `exit_when` ends THIS cycle; "control returns to the next sibling in the OUTER scope's `flow:`" | `tests/integration/cycle-orchestrator-nested-cycle-test.sh:115` | MEDIUM | Shows only that the sibling (`test_assessment`) ran after the inner cycle converged. The order is not asserted. |
| 4 | `abort_when` "propagates outward and terminates the pipeline" | Top-level cycle: `tests/integration/cycle-orchestrator-abort-when-test.sh:96` (rc=6). Pipeline level: `:119` is a structural grep of runner.sh only (weak). Nested: **UNTESTED and CONTRADICTED** | MEDIUM | **Probe:** an inner cycle's abort_when, nested in an outer cycle, returns outer **rc=4 reason=error**, not 6/cycle_abort. `_cycle_iter_dispatch` returns 6 (`cycle-orchestrator.sh:1849-1854`), but `cycle_orchestrator_run` has no `-eq 6` arm, so the `-ne 0` catch-all collapses it (`cycle-orchestrator.sh:2534-2541`). The runner still halts on rc=4 (`runner.sh:3271`), but the run is labeled as an error / config_invalid. |
| 4 | `on_max: continue` "behaves as if `exit_when` fired (next sibling)" | `tests/integration/cycle-on-max-pipeline-continues-test.sh:328`; `tests/integration/runner-cycle-on-max-halt-test.sh:93` | HIGH | |
| 4 | `on_max: abort_pipeline` "behaves as if `abort_when` fired (terminate)" | UNTESTED for the ADR word. CONTRADICTED by code | MEDIUM | The code vocabulary is `continue\|halt` (`cycle-orchestrator.sh:323-327`); the runner also accepts `abort` (`runner.sh:3380`). **Probe:** `on_max: abort_pipeline` loads rc=0, then `_cycle_load_template` returns rc=4 `on_max_invalid`. The `halt` behaviour is tested at `runner-cycle-on-max-halt-test.sh:85-89`. H3 (`:97`, "abort stops the run") stubs `cycle_orchestrator_run`, so it never sees the real orchestrator reject `abort`. |
| 4 | "Exactly one of these three paths (exit_when, abort_when, max_iterations+on_max) terminates every cycle" | UNTESTED (contradicted) | LOW | Cycles also end by plateau, divergence (ADR-021), blocking-member rc=8, route_back rc=11 (ADR-045), rc=9 and signals (`cycle-orchestrator.sh:2495-2541`). |
| 5 | Predicates use structured `{stage, field, op, value}` | `tests/unit/template-loader-recursive-flow-test.sh:148-153` | LOW | |
| 5 | `op` ∈ `{eq, neq, gt, gte, lt, lte, contains, matches}` | UNTESTED. CONTRADICTED | MEDIUM | The runtime accepts only `eq\|ne` for exit_when (`cycle-orchestrator.sh:373-374`, `:412-415`). The evaluators also implement `in` (`:499-504`, `:856-861`). The template preflight for multi-condition exit_when accepts `eq\|ne\|in` (`template.sh:1311-1312`), but the runtime rejects `in` there (`cycle-orchestrator.sh:373`), so the two layers disagree. **Probe:** `op: gt` and `op: neq` load rc=0 and are rejected only at cycle start (rc=4 `until_op_invalid`). No test covers the rejection. |
| 5 | Feedback edges are `from: {stage, output}` → `to: {stage, input, required}` | `tests/unit/template-loader-recursive-flow-test.sh:162`; `tests/unit/lint-contract-cycle-feedback-test.sh:161`, `:170` | MEDIUM | |
| Boundary / Loader 3, 5 | "Every stage ID referenced by any `flow:` MUST resolve to a top-level section" (validator enforces) | Cycle members: `tests/unit/core-pipeline-template-cycles-test.sh:270-272` (old-shape fixture; the same check at `template.sh:374` fires for the new shape, confirmed by probe). Top-level flow: **UNTESTED and CONTRADICTED** | MEDIUM | **Probe:** a top-level `flow:` naming `ghost` with no section loads **rc=0**, and `_TPL_STAGES` includes `ghost`. The translator emits an `S\|` row with an empty payload (`template.sh:2391-2393`). Failure is deferred to dispatch. |
| Boundary | Validator enforces "`on_max` is one of `{continue, abort_pipeline}`" | UNTESTED | MEDIUM | There is no load-time check. **Probe:** `on_max: bogus` loads rc=0 and is rejected only at cycle start (`cycle-orchestrator.sh:323`, rc=4), after the earlier stages have already run. |
| Boundary | Validator enforces "predicate `op` is in the supported set" (exit_when AND abort_when) | **UNTESTED, CONTRADICTED for abort_when** | **HIGH** | **Probe:** `abort_when: {op: gt}` passes both `load_template` and `_cycle_load_template` (rc=0). `_cycle_check_abort_when` has no default case (`cycle-orchestrator.sh:852-861`), so the abort guard **silently never fires** and the pipeline continues. |
| Loader 3 | `extends` merge: "merges per-stage sections by ID (child wins on conflict)" | UNTESTED. CONTRADICTED | MEDIUM | `load_template` ignores `extends:`. `resolve_template_file` copies a new-shape override **verbatim** (`core/pipeline/template-resolver.sh:79-83`), so base-only sections are dropped, not kept. The ADR-016 amendment step 5 (`ADR-016:448`) also says that base-only keys are KEPT. `tests/unit/template-resolver-new-shape-overlay-test.sh:55-57` tests only the flow replacement. |
| Loader 6 | Cycle membership cannot form a reference cycle; "the validator catches this at load time" | `tests/unit/template-route-back-validate-test.sh:47` | MEDIUM | This calls `_tpl_validate_flow_acyclic` directly. The `load_template` call site (`template.sh:736`) is not exercised end-to-end. |
| Migration | Old shape → shim "emits a `template.format.deprecated` event" | `tests/unit/template-loader-back-compat-test.sh:77-81` | LOW | The name differs: the code and schema use `template.deprecated_shape` (`template.sh:151`, `config/event-schema.json:164`). |
| Migration | The shim "is removed in the release after Wave 17-C" | UNTESTED (contradicted) | LOW | The shim is still live; `template-loader-back-compat-test.sh:94` pins it. |
| Amend. ADR-045 | `route_back` is permitted iff `to` is a strictly earlier dispatch unit and `max` is a finite positive int; `_tpl_validate_flow_acyclic` is unchanged | `tests/unit/template-route-back-validate-test.sh:47`, `:55`, `:67-102`, `:141`, `:233` | HIGH | Covers forward, self, own-member, zero, non-numeric and empty max, plus an unsupported op. |
| Impl note #1177 | `aggregate:` on a parallel group is exported as `_TPL_PARALLEL_AGGREGATE_<id>` (empty when omitted) | `tests/unit/core-pipeline-template-parallel-test.sh:305-306`; `tests/integration/template-constructs-test.sh:135` | LOW | |
| Note #762 | `router.max_turns: 0` is a sentinel that omits `--max-turns` | `tests/unit/router-claude-flags-test.sh:186-190` | LOW | Tested through the `ZBUILD_ROUTER_MAX_TURNS` env path, not from a template value. |


## ADR-028 — Shared LLM-agent stage framework (Proposed; amended v1.1, v1.2, ADR-060 2026-08-28)

Status note: header still says "Proposed → Accepted when implemented"; the framework is implemented in `scripts/lib/llm-agent.sh` (v1.1 renamed it from `llm-agent-stage.sh`). `test_assessment` deleted (#979). ADR-060 retired `--markdown-fields`.

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Framework | `_llm_output_contract` renders the canonical block: "FORBIDDEN list, FINAL RULE, and the 'begins with `{`' rules come from the framework" | tests/unit/llm-agent-framework-test.sh:30-34, :98 (C6 forbidden phrases) | MEDIUM | |
| Framework | a missing `--stage` is refused | tests/unit/llm-agent-framework-test.sh:26 | LOW | |
| v1.1 | "`--verdicts none`": the contract "MUST omit the verdict enum line" | tests/unit/llm-agent-framework-test.sh:42 | LOW | |
| v1.1 | with `--verdicts none` "the schema validator MUST NOT assert `.verdict`" | UNTESTED | LOW | `_llm_envelope_validate` takes the caller's schema expr; no test checks a verdict-less stage passes validation |
| Framework | `_llm_envelope_parse` handles "prefix prose, postfix prose, fences" | partial: prefix tests/unit/llm-agent-framework-test.sh:115-116; postfix :306 (R5); fences UNTESTED | MEDIUM | no fenced-JSON case in the framework test |
| Framework | `_llm_envelope_validate` "distinguishes parse failure (with column + context) from structural failure" (rc 2 vs 3) | tests/unit/llm-agent-framework-test.sh:134-146 | MEDIUM | |
| v1.1 | escape-repair deferred: v1 is fail-soft, no automatic repair (unescaped quote = parse error) | tests/unit/llm-agent-framework-test.sh:153-155 (V4) | LOW | |
| v1.1 | `_llm_emit_violation` event class is "positional, not env" — no cross-invocation leak | UNTESTED (weak) | LOW | E1 (:204, :210) only asserts rc=0 "doesn't crash"; never reads the emitted event's type or checks a second call isn't affected |
| Framework | `_llm_router_classify` rc=124 → verdict=error reason=router_timeout; rc=137 → error; rc=0 → empty | tests/unit/llm-agent-framework-test.sh:163-172 | MEDIUM | |
| v1.1 | `_llm_with_json_output` forces `ZBUILD_ROUTER_JSON_OUTPUT=1` for the callback, restores the caller's value (or unset), propagates rc | tests/unit/llm-agent-framework-test.sh:181-195 | MEDIUM | |
| v1.1 | "Per-stage OUTPUT CONTRACT goldens" `tests/golden/llm-contract/<stage>-output-contract.golden` byte-pin each rendered block | UNTESTED | MEDIUM | directory does not exist; no `*output-contract*.golden` anywhere. Contract drift in plan/impact/monitor is unpinned |
| v1.1 | `_llm_envelope_parse` "MUST produce byte-identical splits with `_artifact_split_prose_json`" | tests/integration/llm-agent-renderer-interop-test.sh:31-32 | MEDIUM | |
| v1.2 | `--schema-gate`: when LAST-wins fails the gate, recover "only when exactly one passes the gate" | tests/unit/llm-agent-framework-test.sh:277-278 (R1), :306 (R5 end-to-end) | HIGH | |
| v1.2 / Invariant | "≥2 passers or 0 passers" → fail closed, "the caller's existing schema-violation path fires" | tests/unit/llm-agent-framework-test.sh:284-297 (R2-R4) | HIGH | asserted at `_llm_recover_envelope_json` level (rc=1); that `_llm_envelope_parse` then returns the LAST-wins result unchanged is not asserted |
| v1.2 | `plan`, `security-lens`, `monitor` call `_llm_envelope_parse --schema-gate` | behavioural: plugins/agent/plan/tests/plan-resume-test.sh:258-260; plugins/agent/security-lens/tests/security-lens-test.sh:436-456; plugins/agent/monitor/tests/monitor-test.sh:107,120. Static: tests/unit/adr-migration-claims-test.sh:62 | HIGH | |
| v1.2 | plan gate requires `schema_version==1` and non-empty `steps[]` | tests/unit/plan-context-lib-test.sh:129,136; plugins/agent/plan/tests/plan-resume-test.sh:240 | MEDIUM | |
| v1.2 | plan's `_plan_recover_envelope_json` delegates to `_llm_recover_envelope_json` (duplicate awk grammar retired) | tests/unit/plan-context-lib-test.sh:113-136 | LOW | |
| v1.2 | plan's STRICT validator stays authoritative: "a recovered-but-invalid envelope remains a `schema_violation`" | UNTESTED (weak) | MEDIUM | plugins/agent/plan/tests/plan-test.sh:223 covers a malformed plan, not a recovered envelope that fails the strict `files[]` check |
| v1.2 | `impact` keeps its stage-local `_impact_recover_envelope_json` | tests/unit/impact-envelope-recovery-test.sh:41-55 | LOW | |
| v1.2 | "`review-lens` and `review-report` are **not** migrated: both still call bare `extract_first_json_object`" | CONTRADICTED BY CODE | LOW | plugins/agent/review-lens/plugin.sh:358 now calls `_llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok` (#2035); review-report does not call either parser. adr-migration-claims-test.sh:83 passes on its "migrated — no stale claim possible" branch, so the stale ADR text is not flagged |
| ADR-060 amend | `--markdown-fields` retired; a schema declaring a markdown-document field (name `*_md` or markdown placeholder) is refused | tests/unit/llm-agent-framework-test.sh:58-82; tests/unit/lint-llm-envelope-test.sh (non-framework stages) | MEDIUM | |

## ADR-029 — Context budget management in cycle iterations (Proposed; G2 removed by #1208; amended #1230)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| G1 | an over-budget feedback field is `tail_truncate`d (oldest dropped, newest kept) with a visible marker | tests/unit/cycle-g1-feedback-budget-test.sh:55-75 | MEDIUM | implemented per *feedback field* via env `ZBUILD_CYCLE_MAX_FIELD_CHARS`, not the assembled prompt |
| G1 | default budget 50000 chars; invalid override falls back to the default | tests/unit/cycle-g1-feedback-budget-test.sh:97, :136 | LOW | |
| G1 | emit `cycle.context.compressed` "with `original_chars`, `final_chars`, `strategy`" | partial: tests/unit/cycle-g1-feedback-budget-test.sh:81, :100 (event emitted / not emitted) | LOW | fields not asserted |
| G1 | YAML `context_budget: {max_prompt_chars, compress_strategy}` on a cycle; strategies `tail_truncate`/`head_keep`/`summary` | UNTESTED — NOT IMPLEMENTED | LOW | core/pipeline/cycle-orchestrator.sh:1293-1296 states the YAML schema is deferred |
| G2 (amended) | a build-stage timeout is "NEVER fatal"; no `cycle.member.timeout_abandoned` / return 4 | tests/unit/cycle-g2-cross-iter-timeout-test.sh:92, :108-116; tests/unit/cycle-g3-maxturns-escalation-test.sh:102 | HIGH | |
| G2 (amended) | per-member timeout counter + `cycle.member.timeout` event retained; counter persists across nested re-entry, resets on non-timeout | tests/unit/cycle-g2-cross-iter-timeout-test.sh:95-137 | MEDIUM | `cycle.member.timeout` event itself not asserted |
| G3 | after a timeout, the member's next dispatch gets `max_turns` +50% (capped at 2× base); cleared after a pass | tests/unit/cycle-g3-maxturns-escalation-test.sh:109-119, :138, :162-165 | MEDIUM | the 2× cap can never bite (always base×1.5 from a fixed base); ADR's "on the SAME cycle iter retry" is implemented as the *next* iteration; ADR's `cycle.iter.N.stage.<name>.turns_exhausted=true` state field does not exist (event `cycle.member.max_turns.escalated` instead) |
| #1230 | `router.retries` N: on rc=124 re-spawn up to N times, emitting `router.timeout.retry` per attempt; default 0 = no retry | tests/integration/router-retries-test.sh:128-148 | MEDIUM | |
| #1230 | escalation `secs = min(base*1.5^k, 2*base)` | tests/integration/router-retries-test.sh:153-155 | LOW | |
| #1230 | per-stage `router.retries` wins over env | tests/integration/router-retries-test.sh:160-164 | LOW | |
| #1230 | in the loop, retries are intra-iteration and never double-count `timeout_recur`; the #1208 non-fatal yield after 3 iteration timeouts is unchanged | tests/integration/router-loop-retries-test.sh:116-145 | HIGH | |

## ADR-030 — Scope model: read/write split, security floor, governed expansion (Proposed; amendments v1 #870, v2 #842, v3 #879, v4 #1265, v5 #2185)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| L1 | floor always denies `legacy/*`, `.env`, `*secret*`, `*credential*`, `*.pem`, absolute paths, `../` escapes | tests/unit/scope-governance-test.sh:20-35 | HIGH | |
| L1 | floor denies `*.key`, `*.p12`, `*.pfx` | UNTESTED | MEDIUM | not in the test's path list |
| L1 | "EVERY write-scope grant — from plan, design, build-expansion, or a re-plan escalation — must pass through" `scope_floor_denied` | UNTESTED — CODE CONTRADICTS | HIGH | `scope_floor_denied` is called only from `scope_resolve_request` and scripts/lib/prompt-overrides.sh:65. The plan/design scope that becomes `ZBUILD_SCOPE_ALLOWLIST` (core/pipeline/runner.sh:530-557) never passes the floor, so a plan listing `legacy/x` or `.env` grants it |
| L1 | the floor "is **not** in the template"; a template cannot widen it | tests/unit/scope-governance-test.sh:108 (floor path denied regardless of policy) | HIGH | |
| L2 | `scope_policy` is a closed enum; an unknown `auto_grant` class or invalid `expandable` is rejected at load | tests/unit/template-cycle-scope-policy-test.sh:203, :240 | MEDIUM | |
| L2 | "Omitted `scope_policy` ⇒ `expandable: false` ⇒ requests denied ⇒ clean abandon" | tests/unit/template-cycle-scope-policy-test.sh:82-84, :131; tests/unit/scope-governance-test.sh:93 | HIGH | |
| L2 | `scope_policy` is per cycle; no leak between cycles | tests/unit/template-cycle-scope-policy-test.sh:129-132 | LOW | |
| L3 | build "does NOT touch the out-of-scope file that iteration" and emits `scope_expansion_request {files:[{path,category,evidence,reason}]}` | tests/unit/build-timeout-scope-violation-preserves-inscope-test.sh:124-133, :197-206; tests/unit/build-scope-expansion-test.sh:33-36 | HIGH | |
| L3 | evidence: the resolver grants only if the token "actually appears in the file" | tests/unit/scope-governance-test.sh:67-74, :102 | HIGH | |
| L3 / v1(c) | collateral class by directory-anchored path shape; `core/`, `scripts/`, `plugins/` are `structural` regardless of extension | tests/unit/scope-governance-test.sh:48-60, :120-138 | HIGH | |
| L3 | resolver: floor→deny; structural+escalate→escalate else deny; collateral enabled+evidence→grant else deny | tests/unit/scope-governance-test.sh:86-118 | HIGH | |
| L3 | "any file denies → overall deny … else any escalate → escalate" (mixed-set aggregation) | UNTESTED | MEDIUM | every resolver case uses a single-file request |
| L3 | escalate (v1): "surface + abandon with reason" | UNTESTED | LOW | orchestrator escalate path has no integration case |
| L3 | deny → `terminated_reason=blocked_on_scope`, rc=7, "**Never a loop**" (abandon in iter 1, floor or class disabled) | tests/integration/cycle-scope-expansion-test.sh:85-98 | HIGH | |
| L3 | grant → write-scope widened and the next build iteration sees it (`prior_scope_grant`) | partial: tests/integration/cycle-scope-expansion-test.sh:113-118 (grant event + grant file) | MEDIUM | build's merge of the grant (plugins/agent/build/lib/context.sh:229, `build.scope_grant_applied`) is not asserted by any test (the integration uses a mock build) |
| R2 | `standard.yaml` opts in to `scope_policy` | NOT TRUE TODAY | MEDIUM | `standard.yaml` no longer exists; none of config/templates/{simple,clean,deployed}.yaml declares `scope_policy`, so governed expansion is off in every shipped template (every request → blocked_on_scope) |
| Review / R3 | `review` charter: when the diff has scope-expanded test edits, "verify no assertion was weakened or deleted" | UNTESTED — not implemented as written | MEDIUM | no review-lens charter for it (plugins/agent/review-lens/lib/charters.sh); the guarantee moved to read-only acceptance testfiles (plugins/agent/build/lib/prompt.sh:170, ADR-036) |
| v1(a) | build-created collateral (`created: true`) is granted on floor-pass + collateral class + class enabled + file exists, without a token; `created` cannot grant floored, source, missing or symlink paths | tests/unit/scope-governance-test.sh:148-166; tests/unit/build-scope-expansion-test.sh:67-80; tests/integration/cycle-scope-expansion-test.sh:144-149 | HIGH | |
| v1(b) | `blocked_on_scope` is terminal, "visited exactly once"; an enclosing cycle treats it as completed-abandoned, "never as a re-iteration trigger" | partial: tests/integration/cycle-scope-expansion-test.sh:87 (inner, iter 1) | HIGH | the enclosing-cycle half is UNTESTED |
| v2 | design's ` ```scope ` block is the authoritative write-scope baseline; plan `files[]` is a seed | partial: tests/unit/change-scope-floor-test.sh:62-74 | MEDIUM | v2's `design_impact_cycle` topology is stale (simple.yaml uses design_verify_cycle) |
| v3 | build requests needed out-of-scope collateral even on `verdict=pass`; not on scope_violation/empty_diff; source → structural | tests/unit/build-oos-pass-request-test.sh:41-66; tests/integration/cycle-scope-expansion-test.sh:170-175 | HIGH | |
| v3 | honesty: build summary carries `reason=scope_request_pending` + `out_of_scope_files[]` when that branch fires | UNTESTED (weak) | MEDIUM | tests/unit/build-oos-pass-request-test.sh:83 only *builds a fixture* with that reason; nothing asserts plugins/agent/build/lib/summary.sh:236-280 writes it |
| v4 | intake writes `intake-untracked-baseline.txt` and emits `intake.untracked_baseline.captured`, even under `ZBUILD_INTAKE_ALLOW_DIRTY=1` | tests/unit/intake-writes-untracked-baseline-test.sh:74-84 (runs with ALLOW_DIRTY=1, :58) | HIGH | |
| v4 | a pre-existing untracked stray never enters `diff.patch` or the census | tests/integration/build-preexisting-untracked-not-violation-test.sh:139-157 | HIGH | `diff.patch` exclusion not asserted, only no violation |
| v4 | a build-*created* OOS file (absent from the baseline) still raises `build.scope.violation` | tests/integration/build-created-oos-still-violation-test.sh:136-157 | HIGH | |
| v4 | no baseline file → legacy blanket `git add -N .` | UNTESTED | LOW | |
| v5 | every scope violation reverts only OOS paths, keeps and **commits** the in-scope diff (commit stages plan files only), regardless of router rc | tests/unit/build-timeout-scope-violation-preserves-inscope-test.sh:113-130, :155 | HIGH | |
| v5 | the violation stays reported (verdict `scope_violation`, request) and `build.scope.inscope_preserved` replaces `build.timeout.partial_work_preserved` | tests/unit/build-timeout-scope-violation-preserves-inscope-test.sh:133-143 | MEDIUM | |
| v5 | OOS-only work → no commit, HEAD unchanged | tests/integration/cycle-scope-violation-no-commit-test.sh:129-143 | MEDIUM | |

## ADR-031 — Behavioral acceptance contract (Implemented 2026-06-17; superseded in part by ADR-036 #922)

Note: the whole "test_assessment consumption" section (and Amendment #867) describes a stage deleted in #979 and is historical. "Design writes failing tests" is superseded (#1477/#1583). Test-first ordering and the don't-weaken charter are replaced by the ADR-036 acceptance-gate.

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Block format | `extract_acceptance_block` returns the block (SPEC lines, `TESTFILES:` sentinel, paths); absent → rc 1, empty | tests/unit/acceptance-block-test.sh:36-86 | HIGH | |
| Block format | "`TESTFILES:` sentinel is required" (missing → non-zero) | tests/unit/acceptance-block-test.sh:121 | MEDIUM | "must appear after all SPEC lines" (ordering) is not asserted |
| Block format | only the acceptance block is extracted alongside a ` ```scope ` block | tests/unit/acceptance-block-test.sh:147-148 | LOW | |
| Amend #865 | design without an acceptance block "fails closed (`reason=missing_acceptance_block`, rc=1)" | tests/unit/design-acceptance-block-test.sh:114-120; tests/unit/design-v2-result-contract-test.sh:279 | HIGH | ADR says it emits `plugin.run.error`; code emits `plugin.result verdict=error` (plugins/agent/design/plugin.sh:814). Tests follow the code |
| Rules | "`TESTFILES:` do not grant write-scope" | UNTESTED | MEDIUM | no test checks that a TESTFILES path missing from the scope block stays out of `ZBUILD_SCOPE_ALLOWLIST` |
| Rules | "Test files named in `TESTFILES:` must be written (or amended) by `build`" | SUPERSEDED / CONTRADICTED | — | plugins/agent/build/lib/prompt.sh:170: acceptance testfiles are "read-only for this stage" (test-author writes them, ADR-036) |

## ADR-032 — Per-repo prompt overrides (Proposed; amended 2026-09-27 repo rules)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| D1 | the shipped design charter states the generic enumerated-set principle and carries "zero target vocabulary" | tests/unit/design-prompt-override-section-test.sh:65-80 | MEDIUM | the zero-vocabulary check covers design only |
| D2 | `load_prompt_override <stage>` reads `${repo_root}/.zbuild/prompts/<stage>-overrides.md` from the target repo, silent-on-absent/empty (rc 0) | tests/unit/prompt-overrides-load-test.sh:27-40, :75-94 | MEDIUM | |
| D3 | additive: appended under `## Project-specific guidance (operator override)` AFTER the core contract / LOOP_COMPLETE | tests/unit/design-prompt-override-section-test.sh:84-99; tests/unit/build-prompt-override-test.sh:94-115; tests/unit/plan-prompt-override-test.sh:73-86; tests/unit/impact-prompt-override-test.sh:99-111 | MEDIUM | |
| Safety | appended BEFORE `apply_scope_redaction` (survives real redaction) | tests/integration/design-prompt-override-pipeline-test.sh:90-103; tests/unit/build-prompt-override-test.sh:124; tests/unit/plan-prompt-override-test.sh:94 | HIGH | |
| Safety | absent → byte-identical prompt (no delimiter noise) | tests/unit/design-prompt-override-section-test.sh:117; tests/unit/build-prompt-override-test.sh:143; plan :106; impact :138 | LOW | |
| Safety | containment: stage regex `^[a-z][a-z0-9_-]*$`, floor (absolute/`../`), symlink-out and hardlink-out refused | tests/unit/prompt-overrides-load-test.sh:44-68, :84, :113; tests/integration/design-prompt-override-pipeline-test.sh:134-138 | HIGH | |
| Safety | size cap `ZBUILD_PROMPT_OVERRIDE_MAX_BYTES` (default 32 KiB) with a visible marker | tests/unit/prompt-overrides-load-test.sh:100-104 | LOW | default value not asserted |
| OV-2 | review and test_assessment honor overrides | NOT TRUE TODAY | LOW | only design, build, impact, plan call the loader; review-lens does not; test_assessment deleted |
| Amend 1 | a manifest with `prompt.repo_rules: true` gets the repo's rules injected in `_route_redact_prompt`, exactly once; a non-declaring stage's prompt is unchanged | tests/unit/repo-rules-test.sh::104 (R5), :111 (R6) | HIGH | |
| Amend 2 | repo `.zbuild/prompts/rules.md` else `config/prompts/default-rules.md`; the block names its source; `<!-- -->` stripped; escaping symlink refused → default | tests/unit/repo-rules-test.sh:61-92 | MEDIUM | |
| Amend 3 | "Replace, not merge" | tests/unit/repo-rules-test.sh:65-67 | LOW | |
| Amend 4 | declared on `test-author`; "The lens stages do not declare it" | test-author: tests/unit/repo-rules-test.sh:121; lens half CONTRADICTED | LOW | plugins/agent/review-lens/manifest.yaml:70-71 declares `repo_rules: true`, and repo-rules-test.sh:130 asserts that it does |

## ADR-033 — Compile/typecheck gate for typed targets (Proposed — design only, implementation deferred)

No normative statements are enforceable. The ADR says "No code lands in this issue". There is no typecheck command config and no gate stage. The two-layer model is design intent. The one present-tense claim ("Prompt layer (shipped, OV-1/OV-2)") is covered under ADR-032.

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| — | (none — deferred design) | n/a | — | |


## Conflicts

### (from part 021)

- **ADR-021 header Amend #2117 ("a member that FAILED re-runs") vs code** core/pipeline/cycle-orchestrator.sh:1675-1696 (#2170): failures from members that are not iteration-aware are reused too. Pinned by tests/unit/core-pipeline-cycle-reuse-and-route-back-test.sh:46-48. The code follows #2170; the ADR header is stale.
- **ADR-045 §(line 58-62) / ADR-021 #1265 ("only rc=2/rc=8 reroute; blocked_on_scope (7) never reroutes") vs code** core/pipeline/cycle-orchestrator.sh:2882 (#2178): a denied scope request (rc=7) is rerouted to design. Pinned by core-pipeline-cycle-reuse-and-route-back-test.sh:105-108. Mid-cycle `route_back.early` (#2119, stall-break-test:168) is also outside the "exhaustion" ladder. The code follows #2178/#2119.
- **ADR-021 v3 R2/#1237 ("a rate limit stays rc=1, NON-blocking, verdict=fail, recoverable") vs #2111 code**: design plugin.sh:718-726 (and build) write `disposition: unavailable`/`rate_limited` and return 1. The run then ENDS aborted with `llm_rate_limited`, rc=9 (tests/integration/cycle-rate-limit-aborts-run-test.sh). `_router_rc_classify` still returns `fail` (scripts/lib/router-rc-classify.sh:17-25), but the plugins override it. The code follows #2111.
- **ADR-021 #945 (gate-failing marker overwrites design.md; `design.timeout.stub_written`; `marker_write_failed`) vs code** plugins/agent/design/plugin.sh:667-714 (#2186): if this call changed design.md it is kept, otherwise it is deleted. There is no marker, and `stub_written`/`marker_write_failed` are never emitted. The code follows #2186.
- **ADR-021 #511 consumer-side declaration (`source: cycle_feedback`, CYCLE_FB_UNWIRED/UNDECLARED both directions) vs ADR-055 §4**: §4 retires `cycle_feedback` and all four CYCLE_FB_* codes. Only a renamed CYCLE_FB_UNDECLARED survives (contract-validator.sh:548). The code follows ADR-055.
- **ADR-021 v3 R1 ("on_max: continue → final status from the LAST unit") vs ADR-021 #1208 rule 5 (tests failing at exhaustion → rc=8 HALT, never rescued) vs #527 ("_RUNNER_CYCLE_UNCONVERGED → final status failed")**: these are internally inconsistent. The code follows #1208 for failing tests (rc=8). With passing tests it follows R1 and labels the result `complete_unconverged` (cycle-on-max-continue-pipeline-status-test.sh:57). #2241 adds `on_max: halt`, which none of the ADR text describes, and simple.yaml:122 uses it for design_verify_cycle.
- **ADR-021 §Decision points 6 / Pin 7 halt set {4,130} vs #528 {4,5,130} vs code**: the runner also halts on rc 6/7/8/9/10/143 (ADR-045 lists these). The ADR has no single current halt table.
- **ADR-021 Decision factor (resume must not restart from iter 1) vs code** cycle-orchestrator.sh:2435 (`for (( iter=1; …`). `current_iter` is persisted but never read back.
- **ADR-021 #608.6 (`cycle.iter.N.commit_sha` populated from events) vs code**: no `commit_sha` exists anywhere in core/ or plugins/.
- **ADR-021 #608.5 (`build.commit.skipped reason=scope_violation`) vs test** tests/integration/cycle-scope-violation-no-commit-test.sh:134, which asserts `reason=empty_diff` on a scope-violation run.
- **ADR-021 #936 vs ADR-046/simple.yaml topology**: the over-scope convergence needs `ZBUILD_CYCLE_ITER>=2`, but impact is now a top-level leaf (simple.yaml:39). The rule is green-but-inert.
- **ADR-021 §v2 syntax (#585: inline `type: cycle` + `stage_definitions`) vs ADR-027**: shipped templates use the recursive `flow:` format with `exit_when` (ADR-047). The #585 rules still hold for the legacy shape, which the loader still accepts.

### (from part 022)

- **ADR-022 Status (Retired) vs ADR-013 §stage list and table (Accepted).** ADR-013 still lists `test_assessment` as a canonical leaf stage, `blocking: true`, membership "unchanged" (ADR-013:16, :44, :80, :94, :367). tests/unit/docs-adr-013-test.sh:54 pins its presence there. The code follows ADR-022: no plugin, not in any template.
- **ADR-022 Status vs ADR-019 §7 and the ADR-021 amendment "test_assessment as until: source".** Both still read as normative (verdict precedence `test_assessment` > `test`; cycle `until:` on `test_assessment.verdict`) and carry no retirement note. The code follows ADR-022/ADR-040: review-aggregator still declares a dead `review.test_assessment.consumed` event (plugins/agent/review-aggregator/manifest.yaml:64).
- **ADR-023 Amendment #141 text vs ADR-059 §1 correction and ADR-023 D1.** The amendment puts the new layout at `$ZBUILD_HOME/repos/<repo>/issues/<N>/worktree/`. ADR-023 D1 defines `$ZBUILD_HOME` as the immutable install root, which `install.sh --delete` reaps. ADR-059:88-94 explicitly corrects this to `ZBUILD_DATA_ROOT` (default `~/.zbuild`). The code follows ADR-059 (scripts/lib/worktree.sh:69, core/state/layout.sh). ADR-023's amendment was never updated.
- **ADR-023 D1/D3 vs code scripts/install-remote.sh:44,74.** The curl installer extracts to `~/.zbuild`, not `$ZBUILD_HOME`, and creates a **symlink** at `BIN_DIR/zbuild` (`ln -sf`). That breaks "never a symlink" and the single-source-of-truth var. tests/unit/installer-test.sh:228-232 (TC-7) asserts the symlink, so the test enforces the opposite of the ADR. It also puts the engine inside the ADR-059 data root `~/.zbuild`.
- **ADR-023 Am.#888 "`--no-worktree` opts out" vs code.** No such CLI flag exists. Only `ZBUILD_NO_WORKTREE=1` works (scripts/lib/worktree.sh `zbuild_worktree_enabled`).
- **ADR-023 D6 "--from flag is required" vs ADR-048 / scripts/zbuild:381.** `upgrade --tag` is an accepted alternative. The code follows the later behaviour.

### (from part 024)

- **ADR-024 #674 Layer 1 vs ADR-058 C10 (and the code).** ADR-024 says the helper "preserves … TMPDIR". ADR-058 C10 says it pins TMPDIR to the run scratch, and scripts/lib/env-scrub.sh:71-83 does that. The code follows ADR-058. ADR-024 is stale, and ADR-058:21 also still says "TMPDIR is explicitly preserved".
- **ADR-024 Amendment #141 vs code core/state/layout.sh:237-242.** ADR-024 says the fence MUST widen to `ZBUILD_RUN_ROOT` / `ZBUILD_WORKTREE_ROOT` before the ADR-059 layout moves. layout.sh deliberately never fences `ZBUILD_RUN_ROOT`, and the per-issue layout is live. The code follows layout.sh. ADR-024's obligation is unmet and undocumented as dropped.
- **ADR-024 #1270 ("fence set is state/ledger/cache only") vs #1274 list vs plugins/tool/test/plugin.sh:621-640.** The code also re-exports `ZBUILD_TEST_TIMING_FILE`, `ZBUILD_TIER_CONCURRENCY` and `ZBUILD_TEST_RESULTS_JSON`. #1274 lists the timing file and results JSON; neither amendment lists the tier var. This is drift, not a hazard.
- **ADR-025 L1 (rc 130/143 as the propagation channel) vs ADR-054 §4.** ADR-054 says no engine path returns or interprets an rc outside {0,1}; signals move to the `interrupted` disposition, owned by #1823 / #1850. Today the code follows ADR-025: abort-propagation.sh:51-58 classifies 130/143/6/9/10, and tests/unit/dispatch-rc-guard-test.sh only ratchets the count. ADR-025 does not mention its own planned retirement.
- **ADR-025 dispatch contract vs code.** "Every dispatcher — runner, cycle orchestrator, future strategy plugins — participates in both layers." core/pipeline/strategies/*.sh, parallel-orchestrator.sh and core/router/route.sh call neither helper; the ADR's router member item is unimplemented. The code follows the narrower set: cycle orchestrator plus the runner pre-flight.
- **ADR-025 alt (b) / #905 ("process group from `setsid -w`, no `set -m`") vs code core/router/route.sh:1947 (`set -m`, #2056) and ADR-062:125 ("the router's `setsid` spawn").** The code uses `set -m`. Both ADR texts are stale.
- **ADR-025 header vs ADR-054:13, :385.** ADR-054 says it amends ADR-025 (cleanup becomes a `teardown` stage, §7). ADR-025's status line does not record the amendment.

### (from part 026)

- **ADR-027 §4 / Boundary (`on_max: continue | abort_pipeline`) vs the code.** `cycle-orchestrator.sh:323` accepts only `continue|halt`, and `runner.sh:3380` halts on `halt|abort`. ADR-026 §4 also says `abort_pipeline`. The code follows the `halt` vocabulary (from #2176 and #2241, recorded in ADR-019). An ADR-conformant `abort_pipeline` is rejected at runtime with rc=4.
- **ADR-027 §5 (8-op set) vs the code.** The code supports `eq|ne|in` (ADR-045/#1987 added `in`). There is also an internal split: template.sh's multi-condition preflight accepts `in` (`:1312`), but the orchestrator rejects it (`:373`). The code follows the narrower set.
- **ADR-027 §4 ("abort_when propagates outward") vs `cycle-orchestrator.sh:2534-2541`.** A nested cycle's rc=6 collapses to rc=4 reason=error in the outer cycle (confirmed by probe). Only rc 8, 9, 11 and 130 have propagate arms. The code does not follow the ADR here.
- **ADR-027 §4 ("exactly one of three paths terminates every cycle") vs ADR-021 v2 (plateau/divergence) and ADR-045 (route_back rc=11).** ADR-027's own Boundary says the plateau and divergence paths are unchanged, so the ADR contradicts itself. The code follows ADR-021 and ADR-045.
- **ADR-027 Loader rule 3 and ADR-016 amendment step 5 (per-section merge; base-only keys kept) vs `template-resolver.sh:79-83`.** The code does a verbatim full replace, citing ADR-016 lock 1. ADR-016 lock 1 and its own ADR-027 amendment disagree. The code follows the strict "lock 1 = whole-file replace" reading.
- **ADR-027 §1 (reserved set of exactly 6 keys) vs ADR-037 §4 `merge_policy` and the `always_run` key.** Both are reserved in `template.sh:1809-1811`, and the ADR-016 amendment line 430 restates the stale 6-key set. The code follows the extended set.
- **ADR-027 Migration (event `template.format.deprecated`, shim removed after one release) vs `template.sh:141-155` and `event-schema.json:164`.** The code emits `template.deprecated_shape`, and the shim is still active.

### (from part 028)

- ADR-028 v1.2 Migration ("review-lens … not migrated … bare `extract_first_json_object`") vs code plugins/agent/review-lens/plugin.sh:358, which uses `_llm_envelope_parse --schema-gate` (#2035). The code follows #2035. The ADR text is stale, and tests/unit/adr-migration-claims-test.sh does not catch it because its SPEC-3 passes on the "migrated" branch.
- ADR-030 Layer 1 ("EVERY write-scope grant — from plan, design … — must pass through `scope_floor_denied`") vs core/pipeline/runner.sh:530-557. The allowlist is exported from stage-reported scope files plus the shape floor, with no floor call. The code does not follow the ADR.
- ADR-030 R2 ("`standard.yaml` opt-in") vs config/templates/*.yaml, none of which has `scope_policy`. The code ships with expansion disabled everywhere.
- ADR-030 "Review assertion-integrity" charter vs ADR-036 and plugins/agent/build/lib/prompt.sh:170. The code follows ADR-036: acceptance testfiles are read-only for build, and no review charter exists.
- ADR-031 Rules ("TESTFILES must be written (or amended) by `build`") vs ADR-036 (test-author) and plugins/agent/build/lib/prompt.sh:170 ("read-only for this stage"). The code follows ADR-036.
- ADR-031 Amendment #865 ("emits `plugin.run.error`") vs plugins/agent/design/plugin.sh:814 (`plugin.result verdict=error`). The code follows the v2 result contract (ADR-054/055).
- ADR-032 Amendment §4 ("The lens stages do not declare it") vs plugins/agent/review-lens/manifest.yaml:70-71 (`repo_rules: true`), with tests/unit/repo-rules-test.sh:130 asserting it. The code follows the later change.
- ADR-029 G3 ("cap and abandon per G2") vs ADR-029's own #1208 amendment and ADR-021 #1208, which removed G2. The code follows #1208. scripts/lib/llm-agent.sh's fail threshold comment still says "matching ADR-029 G2".
- ADR-029 G1 (YAML `context_budget.max_prompt_chars` on the assembled prompt) vs core/pipeline/cycle-orchestrator.sh:1288-1300 (per-feedback-field env `ZBUILD_CYCLE_MAX_FIELD_CHARS`, YAML deferred). The code follows the env-var variant.

