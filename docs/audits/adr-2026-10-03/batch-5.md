# ADR audit — batch 5 (ADR-051 … ADR-065, PHASE-DEFERRALS)

Issue #2268. Read-only audit at main `158ee61c`. "Enforced by" names the assertion line that
would go red if the statement broke; a test that only greps ADR text or checks a function exists
is marked `UNTESTED (weak)`.

Legend: "PARTIAL" = an assertion exists but covers only part of the statement (the note names the bare part).
"CONTRADICTED" = the code (and often a test) does the opposite of the ADR text today.

**Totals:** 16 documents, ~355 normative statements. UNTESTED (incl. weak): ~93 — HIGH 10, MEDIUM 32, LOW 51; PARTIAL a further ~9 (4 HIGH).

## ADR-051 — Engine-owned, stage-keyed data provision (Accepted 2026-07-26; §3/§6/§7/§8 largely unimplemented — #1306, #1604, #1317, #1320, #1321 all OPEN)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| 1 | persona carries `role` (data, **never injected**) and `perspective` (the only injected text); framing is `{perspective}\n\n{task}` | tests/unit/persona-resolver-test.sh:80 | MEDIUM | Covers `persona_stage_framing` only; the router-seam injection it describes does not exist (§3) |
| 1 | "the engine **never enumerates** the persona set" | UNTESTED | LOW | |
| 2 | persona binding **is template data** `stage_definitions.<stage>.persona`, read by a name-mangled lazy accessor | tests/unit/persona-resolver-test.sh:391,397 | LOW | Accessor `template_stage_router_persona` (core/pipeline/template.sh:2808) |
| 2 | `core/pipeline` has **zero persona semantics**; a fictitious stage leaves mechanics byte-identical | UNTESTED (weak) | MEDIUM | verdict-stage-agnostic harness covers verdicts, not persona; runner.sh:693-744 already carries persona-specific preflight text |
| 3 | the **router** resolves the persona keyed on `ZBUILD_CURRENT_STAGE` and **prepends** its text at `_route_redact_prompt` via a provider | UNTESTED (weak) — persona-resolver-test.sh:593 only checks route.sh *sources* persona-resolve.sh | MEDIUM | **Code contradicts**: core/router/route.sh:345-400 injects scope/vision/checkpoint, no persona; route.sh:104 only sources the lib. #1306 OPEN |
| 4 | discovery spans **installed root + `.zbuild/plugins` overlay**; overlay **overrides** same id | tests/unit/persona-resolver-test.sh:546 (override), :555 (installed-only) | MEDIUM | |
| 4 | absent overlay is **silent** | tests/unit/persona-resolver-test.sh:581 | LOW | |
| 4 | overlay is an additional scan root, **never leaked via `ZBUILD_PLUGINS_ROOT`** | tests/unit/plugins-root-hermeticity-test.sh:153 | MEDIUM | |
| 5 | precedence `ZBUILD_<STAGE>_PERSONA` env **>** template binding | tests/unit/persona-resolver-test.sh:487 | MEDIUM | |
| 5 | template binding **>** manifest default **>** generic default | UNTESTED (template>default ordering); generic terminal fallback: persona-resolver-test.sh:441,564 | MEDIUM | **Drift**: step 3 is `template_config_persona` (global template key), not a "manifest default" — scripts/lib/persona-resolve.sh:77-80 |
| 5 | a divergent env override against a template value is **auditable** | UNTESTED | LOW | No event/log emitted by resolve_persona |
| 5 | one stage identity per resolution (explicit stage_id beats ambient `ZBUILD_CURRENT_STAGE`) | tests/unit/persona-resolver-test.sh:620,625 | LOW | Code-level rule, not ADR text, but load-bearing for §5 |
| 6 | persona text is prepended **before the single `apply_scope_redaction` pass**, covering both model paths | UNTESTED | MEDIUM | Not implemented (no router injection). Plugin-composed persona text does pass redaction today because it is inside the prompt file |
| 7 | stage plugins **drop** hardcoded `persona_stage_framing` pins; bindings move to the template | UNTESTED | MEDIUM | **Code contradicts**: plugins/agent/design/plugin.sh:387 (architect), plan/plugin.sh:327 (product-owner), impact/plugin.sh:239 (architect), build/plugin.sh:202 (developer). #1604 OPEN. Tests pin the *old* behaviour (design-persona-framing-test.sh:100,151) |
| 7 | a **generic default persona** reproduces each stage's baseline **byte-identically** (golden) | UNTESTED | MEDIUM | #1317 OPEN; no golden exists under tests/golden |
| 8 | **no plugin resolves its own persona (or tier)** — **lint-enforced** | UNTESTED | MEDIUM | No such lint in scripts/lib/lint-*.sh. **Code contradicts**: spec-correspondence/plugin.sh:103, issue-acceptance/plugin.sh:149, spec-coverage/plugin.sh:165 call `resolve_persona` themselves, plus the §7 pins |
| impl | startup preflight defaults to **warn**; `enforce` rc=2; `off` no-op | tests/unit/runner-startup-preflight-test.sh:47,57,130,131 | LOW | Synthetic-violation fixture only |
| impl | preflight **exempt in `--dry-run` / `--resume`** | tests/unit/runner-startup-preflight-test.sh:93,101 | LOW | |
| impl | preflight checks **persona-binding existence** (#1320) and **`requires.plugins`** (#1321) | UNTESTED | MEDIUM | Not implemented — runner.sh:731 "until one lands, the only source of a violation is the test fixture"; live path always returns 0 |

## ADR-052 — The per-run worktree is engine-owned run infrastructure (Accepted 2026-07-28; amended #1869 2026-08-13; §Decision 1 key amended by #141 / ADR-059, 2026-08-23)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| D | "**The engine acquires** the run's worktree **before the first stage dispatches**" — main checkout HEAD and branch are unmoved by a run | tests/integration/worktree-run-isolation-test.sh:131,133 | HIGH | Drives the real runner across two stages |
| D1 | `zbuild_worktree_acquire` takes **no branch** (detached) | UNTESTED (weak) | LOW | `--detach` at scripts/lib/worktree.sh:190; no assertion checks detached HEAD |
| D1/#141 | reuse is keyed on the run's **issue** (goal hash for `--goal`), **not `run_id`** — one tree per issue | tests/unit/layout-writer-test.sh:102 (runner records issue-keyed tree), :112 | HIGH | Drives `main --issue`. worktree-ownership-test.sh:207 and worktree-run-isolation-test.sh:221 still name the run_id key (stale wording; they pass because the key is opaque) |
| D2 | `_runner_enter_worktree` **records `run-worktree.txt`, exports `ZBUILD_REPO_ROOT`, and `cd`s** | tests/integration/worktree-ownership-test.sh:159 | HIGH | |
| D2/D5 | it runs as the **last step before any stage dispatch**; later stages resolve repo root to the worktree | tests/integration/worktree-run-isolation-test.sh:153 | HIGH | |
| D3 | export **and** enter (export alone is the bug) | tests/integration/worktree-ownership-test.sh:159 | HIGH | Asserts both CWD and export |
| D4 | `ZBUILD_MAIN_REPO_ROOT` preserves the operator checkout; intake's **dirty-tree preflight targets it** | tests/integration/worktree-ownership-test.sh:106 | HIGH | |
| D5 | everything before the re-root (state dir, events, overlay, restore, **`--self-host` snapshot**) is main-checkout bookkeeping | UNTESTED | LOW | **Code contradicts the snapshot clause**: runner.sh main() comment (#1783) — the self-host snapshot moved to per-dispatch from the run's own tree (`_runner_refresh_contract_snapshot`) |
| D6 | **fail-closed**: a recorded worktree that has **vanished** aborts the run | tests/integration/worktree-ownership-test.sh:170 | HIGH | |
| D6 | **fail-closed**: a **failed acquire** aborts the run (no silent in-place fallback) | UNTESTED | HIGH | runner.sh:1616-1619 returns 1 + `pipeline.worktree.acquire_failed`; no test drives acquire rc≠0 through `_runner_enter_worktree` |
| impl | a non-worktree directory squatting on the path is **rc=4**; a `git` that exits 0 without creating the tree is **rc=5** | UNTESTED | MEDIUM | worktree.sh:185,193 |
| D7 | `ZBUILD_NO_WORKTREE=1` is the opt-out, **in-place** behaviour, nothing recorded | tests/integration/worktree-run-isolation-test.sh:201; worktree-ownership-test.sh:183 | MEDIUM | "byte-identical" not asserted, only branch/commit/no record |
| intake | intake **records no worktree of its own**; runs its branch paths in the tree it was handed | tests/integration/worktree-ownership-test.sh:68,75 | MEDIUM | |
| intake/#1869 | "**no plugin decides which tree it works in**" | UNTESTED (weak) | MEDIUM | No lint forbids a plugin calling `zbuild_worktree_acquire`/`git worktree add`; today none does (grep clean) |
| intake | `zbuild_worktree_prepare` **is deleted** | UNTESTED | LOW | grep-clean today |
| #1869 | intake may only ask the engine to release **that specific holder**, by path, and retry **once** | tests/integration/intake-branch-reclaim-test.sh:91,113 | MEDIUM | "once" not asserted |
| #1869 | reclaim **refuses** a live (`in_progress`, fresh `updated_at`) run | tests/unit/worktree-reclaim-test.sh:125; tests/integration/intake-branch-reclaim-test.sh:131 | HIGH | |
| #1869 | reclaim **refuses** when liveness **cannot be established** | tests/unit/worktree-reclaim-test.sh:169 | HIGH | |
| #1869 | reclaim **never passes `--force`**; a tree holding uncommitted work is refused | tests/unit/worktree-reclaim-test.sh:147 | HIGH | |
| #1869 | reclaim **preserves the branch ref and its commits** | tests/unit/worktree-reclaim-test.sh:100,106 | HIGH | |
| #1869 | events `intake.branch.reclaimed` / `intake.branch.reclaim_refused` | UNTESTED (weak) — plugins/agent/intake/tests/intake-result-test.sh:330 lists the names | LOW | |
| #141 | issue **exclusivity lock is a precondition** of issue keying — refuse if it cannot be taken | see ADR-059 (batch partC) | HIGH | `ZBUILD_NO_ISSUE_LOCK=1` override exists (runner.sh ~2262) |
| compat | legacy `intake-worktree.txt` is still **read back** on resume | tests/integration/worktree-ownership-test.sh:197 | MEDIUM | |
| impl | `state_dir` is **absolutized** before the exports that derive from it | UNTESTED | MEDIUM | A relative state dir would split artifacts across two trees after the cd |
| impl | events `pipeline.worktree.entered` / `.missing` / `.acquire_failed` | UNTESTED | LOW | Emitted runner.sh:1605,1618,1627; no assertion on emission |
| D | a run **failing before any `pr` stage** leaves the main checkout intact | tests/integration/worktree-run-isolation-test.sh:184 | HIGH | |
| D1 | a re-run lands in the **same** worktree (resume) | tests/integration/worktree-run-isolation-test.sh:221; worktree-ownership-test.sh:207 | HIGH | |

## ADR-053 — Test flake remediation policy: cap + timing baseline (Accepted 2026-08-01, no amendments)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §1 | A "flake offender" fails ≥1 of 10 consecutive full-tier runs under default parallelism | UNTESTED | LOW | process definition; nothing measures it |
| §2.5 | "**Never** auto-retry a failing test" | UNTESTED | MEDIUM | no retry exists today in scripts/run-tests.sh or plugins/tool/test/plugin.sh, but nothing would catch one being added; a retry would hide real failures inside pipeline test stages |
| §2.4/§4 | A serial pin is allowed only with an open tracking issue, and "the pin comment names the open issue" | UNTESTED | LOW | code violates it: scripts/run-tests.sh:310-316 pin comments name no open tracking issue (only historical #1047/#1425) |
| §4/§5 table | The stale `compound-quality-pipeline-test.sh` pin "matches nothing. Remove under §4" | UNTESTED | LOW | CONTRADICTED: still present at scripts/run-tests.sh:311 (no such file under tests/), so it holds 1 of the 7 cap slots |
| §5 | `_ZBUILD_SERIAL_PIN` "MUST NOT exceed 7 entries" | tests/unit/run-tests-parallel-test.sh:325 (cap), :340 (SPEC-17b shows the counter bites at 8), :352 (NOBLOCK, not a vacuous 0) | LOW | the `ZBUILD_SERIAL_TESTS` env override (run-tests.sh:331) adds pins the cap never counts |
| §5 | Raising the cap needs an ADR-053 amendment in the same PR | UNTESTED | LOW | process; the cap number in the test is not cross-checked against the ADR text |
| §6 | `ZBUILD_TEST_TIMING_FILE` is set in the unit and integration CI jobs | tests/unit/run-tests-parallel-test.sh:371 (SPEC-17c) | LOW | static yaml grep, which suits a CI-wiring rule |
| §6 | The timing files are uploaded as CI artifacts | UNTESTED | LOW | .github/workflows/test.yml:133,190 does it; no test covers it |
| impl | Timing instrumentation changes nothing when the path is unwritable | tests/unit/run-tests-timing-test.sh:129-130 | LOW | |

## ADR-054 — Stage Contract (Accepted 2026-08-09; amended #1862, #1920, #141, #2111, #2187 §6a, #2225, #1837, #2242; §7's per-stage `cleanup(scope)` dispatch SUPERSEDED by ADR-062 — not recorded in ADR-054's own header)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §1 | Contract has "exactly **two** hooks": `run` (required) and `cleanup` (optional); init/finalize deleted | tests/unit/plugin-hook-contract-test.sh:31, :42 | LOW | ADR-062 has since retired every cleanup hook (tests/integration/cleanup-release-test.sh:173), so in practice the contract is `run`-only. See Conflicts |
| §1/ADR-056 | An absent required `run` hook fails (non-zero, `plugin.run.refused`) | tests/unit/plugin-hook-contract-test.sh:154, :160 | MEDIUM | |
| §2 | `run(stage_id, state_file, resolved_inputs)`: the engine resolves declared inputs and hands them over | tests/unit/stage-input-resolve-test.sh:197-202 | HIGH | delivered through the env var `ZBUILD_STAGE_INPUTS` (core/plugin-registry/lifecycle.sh:408), not as a 3rd positional argument as §2 states |
| §2 | "**A plugin never rebuilds a path.**" | UNTESTED (weak) | MEDIUM | stage-input-resolve-test.sh:207 checks only its own fixture; gate-v2-contract-test.sh:355 catches only literal `/stage/artifacts/` in 7 gates. Fallback rebuilds still exist: plugins/agent/design/plugin.sh:146, plugins/tool/test/plugin.sh:202, plugins/tool/design-gate/plugin.sh:78 |
| §3 | The runner exports `ZBUILD_GOAL`, `ZBUILD_ISSUE`, `ZBUILD_RUN_ID` to all hooks | UNTESTED | LOW | no direct assertion found; only indirect use |
| §3 | `ZBUILD_TARGET_PLATFORM` is set by the fan-out strategy | tests/unit/core-pipeline-strategy-test.sh:72 | LOW | |
| §3.1 | `plugin_hook_call` exports `ZBUILD_CURRENT_STAGE`/`PLUGIN`/`PLUGIN_KIND`/`PLUGIN_DIR` (stage ≠ plugin id) | tests/unit/dispatch-identity-test.sh:127, :133, :134 | HIGH | the #1862 root-cause class |
| §3.1 | Identity lasts one dispatch (`local -x`): stage N's identity is not visible during N+1 | tests/unit/dispatch-identity-test.sh:160, :195-197 | HIGH | |
| §3.1 | The `map:` arm's members receive the group's stage name and plugin identity | tests/unit/dispatch-identity-test.sh:265-267 | MEDIUM | |
| §3.1 | "`ZBUILD_PLUGINS_ROOT` is not identity and is not set here" | tests/unit/dispatch-identity-test.sh:219 | MEDIUM | |
| §3.1 | Identity does not survive `env-scrub` / `_zbuild_make_fresh_shell` | tests/unit/dispatch-identity-test.sh:207; tests/unit/env-scrub-test.sh:130, :139 | HIGH | |
| §3.2 | Data that describes the work (issue body, goal) is a declared input, never ambient env/context | UNTESTED | MEDIUM | CONTRADICTED. See ADR-055 §1.2 |
| §4/§4b | A `result_contract: 2` stage's rc is narrowed to {0,1} | tests/integration/dispatch-rc-signal-boundary-test.sh:275, :343 | HIGH | |
| §4b | A v1 stage's rc "passes through **unchanged**" | tests/integration/dispatch-rc-signal-boundary-test.sh:132, :258 | MEDIUM | |
| §4 | No engine path grows its private rc vocabulary (ratchet until #1850) | tests/unit/dispatch-rc-guard-test.sh:106 (grew), :109 (shrank) | MEDIUM | the end state ("no engine path returns an rc outside {0,1}") is not true yet: the runner exits 9 on a rate limit (tests/integration/cycle-rate-limit-aborts-run-test.sh:430 asserts 9) |
| §4 | `plugin_hook_call` returns nothing outside {0,1}; an absent cleanup returns 0 and is recorded on the event | tests/unit/dispatch-rc-guard-test.sh:123, :141; tests/unit/plugin-hook-contract-test.sh:111, :113 | MEDIUM | |
| §4 | "`rc=0` with a missing or unparseable result is a structural failure, not a warning" | PARTIAL: tests/unit/lifecycle-required-output-test.sh:48, :84 (the scanner fails a missing or empty `required:true` output) | HIGH | the verdict reader still returns `warn` for an absent JSON primary (core/pipeline/verdict.sh:329-333, :477-481) and for an absent non-JSON primary with no sidecar (:472-475). Only a `required: true` primary is held strictly |
| §4a | An rc≠0 that left no result is classified: signal → `interrupted`, nothing → `broken` (for both versions) | tests/unit/dispatch-rc-test.sh:103, :112; tests/integration/dispatch-rc-signal-boundary-test.sh:138 | MEDIUM | timeout → `interrupted` contradicts §6a. See Conflicts |
| §4a | rc 130 and 143 both map to `aborted` at the orchestrator fan-in | tests/unit/dispatch-rc-test.sh:188-189; tests/unit/dispatch-rc-guard-test.sh:237 (static grep) | LOW | |
| §5 | The result file has mandatory, non-empty `result_contract`/`verdict`/`disposition`/`reason` (v2) | tests/integration/leaf-contract-violation-halts-test.sh:106-108; tests/unit/core-pipeline-disposition-test.sh:213-215 | HIGH | |
| §5 | `data: {}` is "never interpreted by the engine" | UNTESTED | LOW | |
| §5 | `reason` is "**never branched on**" | UNTESTED | LOW | no lint covers it |
| §5 | `result_contract` is NOT `schema_version` | tests/unit/core-pipeline-verdict-test.sh:357, :363 | MEDIUM | |
| §6/#2242 | Under v2, a verdict outside the manifest's `valid_verdicts` is `contract_violation:unknown_verdict` | tests/unit/verdict-undeclared-word-test.sh:70-72 | HIGH | v1 stays lenient (:74). A manifest with no list is left to the lint (:77-79) |
| §6/#1708 | Every declared verdict is classified (lint) | scripts/lib/lint-verdict-classify.sh; tests/unit/lint-verdict-classify-test.sh:83 | LOW | |
| #2242 | `lint-verdict-words` refuses an undeclared literal verdict | tests/unit/lint-verdict-words-test.sh:39-43 | LOW | |
| §6/§6a | `disposition` is a closed, engine-owned set | tests/unit/core-pipeline-disposition-test.sh:87, :92, :100 | HIGH | |
| §6 | An off-set disposition is a structural failure carrying `contract_violation:unknown_disposition:<word>` | tests/unit/core-pipeline-disposition-test.sh:191, :195; tests/integration/dispatch-rc-signal-boundary-test.sh:286 | HIGH | |
| §6 | For an off-set word, "the reader returns the declared word unchanged rather than substituting a valid member" | CONTRADICTED | MEDIUM | tests/unit/core-pipeline-disposition-test.sh:205 asserts the disposition reader returns `broken`. The original word survives only on the reason channel |
| §6 | A dispatch that returned non-zero with no readable result resolves to `broken` | tests/unit/core-pipeline-disposition-test.sh:227, :236, :244 | MEDIUM | |
| §6 | "The engine never writes a disposition into a stage's artifact" | tests/unit/core-pipeline-disposition-test.sh:229 | MEDIUM | |
| §6 | "Retry is a property of the disposition … no plugin declares its own retry policy" | UNTESTED | LOW | nothing refuses a manifest-level retry key |
| §6a | Response table: complete → proceed; unusable/timed_out/out_of_turns/interrupted → retry; throttled → wait then retry; rate_limited/unavailable → end run (resumable); misconfigured/broken → halt | tests/unit/core-pipeline-disposition-test.sh:107-118, :126-138; tests/unit/disposition-vocabulary-test.sh:43 | HIGH | |
| §6a | `exhausted` is retired | tests/unit/disposition-vocabulary-test.sh:66 | LOW | §4a table and §6 table still list it (stale text) |
| §6a | "Did not finish" = `disposition_unfinished` (timed_out, out_of_turns, interrupted) | tests/unit/disposition-vocabulary-test.sh:69-74 | MEDIUM | |
| §6a | Retry count: template `retry:`, then `ZBUILD_DISPOSITION_REDISPATCH`, then 3, capped at 5 | tests/unit/disposition-vocabulary-test.sh:94-106 | MEDIUM | the runner's use of this budget is only grep-checked (dispatch-disposition-wiring-test.sh:64) |
| §6a | A retry is taken "only while the last attempt changed one of its declared outputs" | PARTIAL: tests/unit/disposition-vocabulary-test.sh:130; tests/unit/attempt-progress-test.sh:68-80 | HIGH | only the predicate is tested. Its gating at core/pipeline/runner.sh:2905-2909 is checked only by a static grep (disposition-vocabulary-test.sh:141) |
| §6a | `interrupted` and `throttled` are exempt from the progress rule | UNTESTED | MEDIUM | core/pipeline/runner.sh:2908. Combined with dispatch-rc.sh mapping timeout → `interrupted`, a timed-out stage that left no result retries without any progress check |
| §6a | A halting word stops the cycle through the member-terminal path; rc stays {0,1} | tests/unit/disposition-vocabulary-test.sh:158, :160 (helper); tests/integration/cycle-rate-limit-aborts-run-test.sh:419-426 (end to end, rate limit only) | MEDIUM | the `cycle-orchestrator` call site is grep-checked (:149) |
| #2111/§6a | A rate limit ends the run `aborted`/`reason=llm_rate_limited` with the reset text, state persisted for resume, no re-dispatch | tests/integration/cycle-rate-limit-aborts-run-test.sh:419-429 | HIGH | |
| §6a | Model-call failures are named in one place, `router_reason_disposition` | tests/unit/router-reason-disposition-test.sh:30, :49, :61 | MEDIUM | a second mapper, `dispatch_rc_failure_disposition`, also names them (see Conflicts) |
| §6a | `lint-disposition-words` rejects a literal off-set word | tests/unit/lint-disposition-words-test.sh:34, :41, :62 | LOW | |
| §6a/#2225 | A signal is recorded via `stage_signal_begin` as `interrupted`/`signal_interrupt`, and the caller's traps are restored | tests/unit/stage-signal-test.sh:48-49, :67-68 | MEDIUM | |
| §6a/#2225 | `lint-stage-signals` refuses a raw TERM/INT trap in plugins/ unless it carries `# signal-ok:` | tests/unit/stage-signal-test.sh:75-79, :91 | LOW | |
| §6a/#1837 | A literal `unavailable` needs a `# disposition-ok:` note naming the external service | tests/unit/stage-signal-test.sh:85-88 | LOW | |
| §6a/#1837 | Operator-caused conditions (closed issue, bad branch, dirty tree, missing goal) are `misconfigured` | UNTESTED | MEDIUM | plugins/agent/intake/tests/intake-closed-issue-test.sh:41-54 checks rc=1 and that the result file exists, never the disposition word |
| §7 | `release` "**Deletes nothing**" | tests/unit/teardown-purge-scratch-test.sh:72; tests/integration/runner-release-exit-paths-test.sh:157 | HIGH | |
| §7 | `purge` is operator-invoked only, never reachable from a run | tests/integration/runner-release-exit-paths-test.sh:157; tests/integration/zbuild-clean-purge-not-in-run-test.sh:83, :111 | HIGH | |
| §7 | `release` runs automatically at end of work, on every exit path | tests/integration/runner-release-exit-paths-test.sh:173 (+ the other exit-path cases) | HIGH | |
| §7/#1920 | `zbuild cleanup --state-dirs` refuses an `in_progress` run, `$ZBUILD_RUN_ID`, and a resumable run without `--force` | tests/unit/cleanup-state-dirs-test.sh:78, :85, :100; tests/unit/cleanup-state-dirs-reclaim-test.sh:169, :190 | HIGH | the `--age-days` default of 7 is not asserted |
| §7/#1920 | "No stage and no hook may call" `cleanup --state-dirs` | UNTESTED | MEDIUM | no reference exists in plugins/ or core/ today, but no guard enforces that |
| §7/#141 | `release` (and its `persist` sibling) is a template stage with `always-run` | tests/unit/template-always-run-test.sh:62, :107 | MEDIUM | |
| §7/#141 | An issue-scoped directory is reclaimable only when no run of that issue is live | PARTIAL: tests/unit/cleanup-worktrees-test.sh:441 (fails closed when the lock is unreadable) | HIGH | no assertion found for a live lock holder keeping the tree |
| §8 | A declared output absent after `run` exits 0 → blocking failure (fail-closed scanner) | tests/unit/lifecycle-required-output-test.sh:48, :84, :136 | HIGH | ADR text still keys on `provides.artifact_type`, which #1906 retired; the scanner keys on `outputs[].required` |
| §9 | Knob defaults: timeout 300, max_turns 25, retries 0 (max_iterations 10) | tests/unit/router-manifest-budget-test.sh:149-153 | LOW | the max_iterations=10 default is not asserted |
| §9 | Per-stage knob precedence ("manifest-declared data path before … template/global") | tests/unit/router-manifest-budget-test.sh:222-226 | LOW | the code and test order is template > env > manifest > default (core/router/route.sh:804), which is not the order the §9 prose suggests |

## ADR-055 — Inter-Stage Data Contract v2 (Accepted 2026-08-09; supersedes ADR-020; amended #1768, #1825, #1976, #1986, #2124, 2026-09-27 (#1845), 2026-09-28 (#1847/#1846))

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §1 | A consumer declares only `id` and `required`, with no stage, path, type or format | PARTIAL: tests/unit/contract-validator-input-gating-test.sh:71 (unknown `source:` refused), :232 (input `format` refused) | LOW | a restated `path:`/`type:` on an input is not refused |
| §1 | "exactly one output per manifest declares `primary: true`" | scripts/lib/lint-contract.sh:184-187 (CI lint); tests/unit/gate-v2-contract-test.sh:346 (7 gates only) | MEDIUM | the lint branch itself has no dedicated test |
| §1/#1826 | The engine resolves each input name to its producer and hands the paths to `run` | tests/unit/stage-input-resolve-test.sh:197-202 | HIGH | |
| §1/#1826 | Presence is verified before dispatch; a missing required input means the stage is never launched | tests/unit/stage-input-resolve-test.sh:245, :251, :259-262 | HIGH | |
| §1.2 | There are exactly two input kinds (stage output by default, `source: external`); `stage:`/`artifacts`/`cycle_feedback` are retired | tests/unit/contract-validator-input-gating-test.sh:71 | MEDIUM | covered by a generic BAD_SOURCE wildcard |
| §1.2 | "Stages stop reading the environment for data"; outside data comes through declared `source: external` inputs | UNTESTED | MEDIUM | CONTRADICTED: no manifest in plugins/ declares `source: external`. Intake fetches the issue directly (plugins/agent/intake/plugin.sh:170; lib/issue-state.sh:25) |
| §1.2 | Prior-run reuse is not an input kind; the engine restores the artifact area generically | UNTESTED | LOW | descriptive |
| §1.3 | "A producer must appear earlier in the resolved flow, **or** the template must declare a re-entry" | CONTRADICTED | MEDIUM | the validator checks only self-edges (core/pipeline/contract-validator.sh:487-492). tests/unit/core-pipeline-contract-validator-test.sh:233 asserts that a later producer in a flat list with no cycle or route_back passes |
| §1.3 | A self-edge outside a cycle is refused (SELF_REF); inside a cycle it is legal | tests/unit/contract-validator-input-gating-test.sh:156, :171, :179 | MEDIUM | |
| §1.4 | A map producer delivers the set of its members' outputs | tests/unit/stage-input-resolve-test.sh:224-232; tests/unit/contract-validator-input-gating-test.sh:116 | MEDIUM | |
| §1.5 | A required input with zero producers is a refused template | tests/unit/core-pipeline-contract-validator-test.sh:241-242 | HIGH | |
| §1.5 | An input name with two producers is refused (INPUT_AMBIGUOUS) | PARTIAL: tests/unit/contract-validator-output-uniqueness-test.sh:116 (via OUTPUT_DUP) | MEDIUM | INPUT_AMBIGUOUS itself (contract-validator.sh:484) has no test |
| §1.5 | An optional input that names no producer is legal | tests/unit/contract-validator-input-gating-test.sh:135 | LOW | |
| §2 | Closed templating-var set; any other `${var}` is a load-time error | tests/unit/core-pipeline-contract-validator-test.sh:317-318; resolution: tests/unit/stage-input-resolve-test.sh:281-298 | MEDIUM | |
| §3 | `source: external` ids must come from the 7-id allowlist | tests/unit/core-pipeline-contract-validator-test.sh:279-280; tests/unit/lint-contract-test.sh:227-228 | MEDIUM | tests/unit/preflight-lint-parity-test.sh:69 only greps the ADR text (does not count) |
| §4 | A template's `feedback.to.input` must name an input the target declares | tests/unit/lint-contract-cycle-feedback-test.sh:170-172, :201 | HIGH | enforced by the lint for in-repo templates. The runtime CYCLE_FB_UNDECLARED path has no test |
| §5 | Each output `id` is claimed by exactly one stage per resolved flow (OUTPUT_DUP) | tests/unit/contract-validator-output-uniqueness-test.sh:116-120, :124 | HIGH | |
| §5 | Uniqueness is scoped to the resolved flow, not the plugin tree | UNTESTED | LOW | :143 checks only that a single producer is fine |
| §6 | On resume, for every input whose producer is `complete`, the artifact must exist (checked at pre-flight) | PARTIAL: tests/unit/stage-input-resolve-test.sh:245 (caught at dispatch, required inputs only) | MEDIUM | the pre-flight validator has no `stage_statuses` / resume check (contract-validator.sh), and the startup preflight skips on resume (runner.sh:783). A stale artifact surfaces only at the consumer's dispatch |
| §7 | The validator runs after `load_template` and before the `--dry-run` short-circuit | UNTESTED | LOW | runner.sh:1807 vs :1884 is the order today; no test runs a violating template with `--dry-run` |
| §7 | `warn`: violations print and emit an event, and the run continues | tests/integration/pipeline-preflight-missing-stage-test.sh:151, :159, :169 | LOW | |
| §7 | `enforce`: writes `preflight_failed`, returns rc=2, halts before intake | tests/integration/pipeline-preflight-missing-stage-test.sh:89, :113-116, :132; tests/unit/core-pipeline-contract-validator-test.sh:208, :214 | HIGH | |
| §7 | `off`: the validator is skipped | tests/unit/contract-validator-enforce-mode-test.sh:128 | LOW | |
| §8 | `enforce` is the operative default | tests/unit/core-pipeline-contract-validator-test.sh:330 | MEDIUM | the runner's error text still prints `:-warn` (runner.sh:1808, stale comment at :1795) |
| §9/#1986 | Every stage-bound plugin carries `summary` on exactly one output | tests/unit/summary-mandatory-test.sh:68, :70 (tree); :108-113 (runtime SUMMARY_MISSING refuses) | MEDIUM | runtime SUMMARY_DUP has no test (the lint is tested at stage-summaries-test.sh:381) |
| §9 | The summary output is `required: true` | PARTIAL: tests/unit/gate-v2-contract-test.sh SPEC-14 (7 gates) | LOW | not enforced tree-wide |
| §9 | A summary is written on every terminal verdict (pass, fail, skip) | tests/unit/summary-mandatory-test.sh:155-156 | MEDIUM | |
| §9 | Completed stages' summaries are injected before `apply_scope_redaction` | tests/unit/stage-summaries-test.sh:325, :327, :336 | HIGH | |
| §9 | Latest-wins per stage, flat in iterations | tests/unit/stage-summaries-test.sh:261-269 | MEDIUM | |
| §9 | Capped per summary (8192B) and in total, with an explicit truncation marker | tests/unit/stage-summaries-test.sh:279-281, :525 | LOW | the exact 8192B cap is not asserted |
| §9 | Every body passes the LLM-output sanitizer at the renderer | tests/unit/stage-summaries-test.sh:538 | MEDIUM | |
| §9/#2124 | `prompt.summaries.injected` is emitted, and the cycle banner prints the count | tests/unit/stage-summaries-test.sh:481-486, :453 | LOW | |
| §9 | "Only stages declaring `convergence: gate` contribute" (Roster) | CONTRADICTED | MEDIUM | tests/unit/stage-summaries-test.sh:255 asserts an ADVISORY stage contributes (#1986 decided #1898). The ADR text was never updated |
| §9 | Ordering follows completion order | tests/unit/stage-summaries-test.sh:244 | LOW | |
| §9 | Backend services are exempt | tests/unit/summary-mandatory-test.sh:132 | LOW | |
| §9 | A summary output does not trip OUTPUT_UNCONSUMED; consumers declare nothing | tests/unit/stage-summaries-test.sh:427 | LOW | |
| 09-27 r1 | "A stage never sees its own earlier verdict" | tests/unit/judge-framing-test.sh:79, :98 | MEDIUM | |
| 09-27 r2 | A non-writer reader is never told to RESOLVE an unowned finding | tests/unit/judge-framing-test.sh:85, :87 | MEDIUM | narrowed by 09-28 r2 (an owner is told to fix, writer or not) |
| 09-27 r3 / 09-28 r3 | A non-writer's prompt opens with an engine scope line: may not change the repository, writes only its named outputs | tests/unit/judge-framing-test.sh:114-124, :131; tests/unit/finding-owner-under-review-test.sh:191-195 | MEDIUM | |
| 09-28 r1 | The producer of an `under_review` input owns the finding; a result's `about` wins; ambiguous → no owner | tests/unit/finding-owner-under-review-test.sh:118, :138, :150, :203-210 | MEDIUM | |
| 09-28 r2 | The owner is told to fix it, writer or not | tests/unit/finding-owner-under-review-test.sh:118, :128 | MEDIUM | |
| 09-28 r4 | A routed fault belongs to the author inside the `route_back` target unit | tests/unit/finding-owner-under-review-test.sh:252-256 | MEDIUM | |
| 09-28 | Every `under_review` input names an output some plugin produces | tests/unit/finding-owner-under-review-test.sh:221, :230 | LOW | |


## ADR-056 — run+cleanup-only plugin lifecycle (Accepted; §3 amended 2026-08-11 by #1823 / ADR-054 §4 — rc=3 sentinel removed)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| 1 | No plugin manifest declares `hooks.init` / `hooks.finalize` | tests/unit/plugin-hook-contract-test.sh:31, :42 | LOW | greps every plugins/**/manifest.yaml |
| 1 | The six `plugin.{init,finalize}.{start,complete,error}` event types are removed from the schema | UNTESTED (weak) — tests/golden/golden-contracts-test.sh:73 checks only the two `.complete` types | LOW | start/error could return unseen |
| 1 | init/finalize functions removed from every `plugin.sh` | UNTESTED | LOW | |
| 1 | `_ZBUILD_YAML_PREWARM_KEYS` drops `hooks.init`/`hooks.finalize` | UNTESTED | LOW | |
| 2 | `validate_manifest` rejects a missing `run` hook (agent/tool/orchestrator) with an error naming the plugin | tests/unit/plugin-hook-contract-test.sh:60, :62 | MEDIUM | only kind `tool` exercised; agent/orchestrator arms unasserted |
| 3 | Absent `cleanup` → emits `plugin.cleanup.absent`, returns 0 | tests/unit/plugin-hook-contract-test.sh:111, :112; tests/integration/cleanup-release-test.sh:239 | MEDIUM | |
| 3 | rc is binary; no `ZBUILD_HOOK_ABSENT`/rc=3 sentinel | tests/unit/dispatch-rc-guard-test.sh:122, :127 | LOW | |
| table | Absent `run` → `plugin.run.refused` emitted, rc=1 | tests/unit/plugin-hook-contract-test.sh:153 (rc≠0), :159 (event) | MEDIUM | asserts non-zero, not exactly 1 |
| Resume | Resume state recovery moves into `run`'s preamble: plugins check `ZBUILD_RESUMING=1` | UNTESTED — and **contradicted by code**: no file in core/, scripts/, plugins/ sets or reads `ZBUILD_RESUMING` (only docs/RESUME-CONTRACT.md:63,83,103) | HIGH | a plugin written to the documented contract never reconstructs state on resume, silently |

## ADR-057 — Build Mode criteria (Accepted 2026-08-12; amended 2026-08-22 by #1918 — gate 3 narrowed, gate 3b added; supersedes ADR-036 "Self-hosting note")

Mostly an advisory triage rule with no automated consumer (stated in the ADR itself). Rows that govern code/CI are marked as such.

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| 1 | Dogfood CI installs the engine from a `main` clone in `$RUNNER_TEMP` (outside the workspace) and fails rather than falling back to the checkout copy | UNTESTED (partial) — tests/unit/persist-push-entrypoint-test.sh:297 only pins that the run step execs `$HOME/.local/bin/zbuild`; the clone-from-main + fail-fast (.github/workflows/zbuild-pipeline.yml:111-123) is unasserted | HIGH | reverting to install-from-checkout makes every dogfood self-grading, and every gate stays green |
| 2 | Gates evaluated in order 1, 2, 3, 3b, 4; first match wins; 4 (`Dogfood`) is the default | UNTESTED (process rule, no consumer by design) | LOW | |
| 2 g2 | The gate-2 file set is the transitive closure `_runner_contract_lib_closure` derives from `_RUNNER_CONTRACT_LIB_ENTRYPOINTS` | tests/unit/runner-contract-lib-seam-test.sh:50, :52, :54 | MEDIUM | asserts transitive deps (env-scrub, impact-prefilter) are in the closure |
| 2 g3b | A diff touching `.github/workflows/**` is `By-hand` until #1780 closes | UNTESTED (process) | LOW | #1780 verified still OPEN (2026-10-03), so the gate is still live |
| 3 | Every non-`Dogfood` marking names its gate in one line in the issue body | UNTESTED (process) | LOW | |
| 4 | Blank = untriaged; an issue reaching `Up Next` has Build Mode set | UNTESTED (process) | LOW | |
| 5 | `_runner_refresh_contract_snapshot` has no once-guard — the snapshot tracks the run's tree | tests/unit/runner-contract-lib-seam-test.sh:93; tests/integration/self-host-snapshot-tracks-tree-test.sh:59 | HIGH | tested |
| 5 | The self-grade condition is surfaced once per run | UNTESTED — no test references `selfhost.contract_lib.snapshot` (emitted at core/pipeline/runner.sh:1488-1491) | MEDIUM | ADR names `_RUNNER_SELF_GRADE_REASON` as the thing emitted; the code emits the event with a `reason=` field |

## ADR-058 — The engine defines where a stage may write (Accepted 2026-08-22; amended 2026-08-23 ×3 (#1809 runtime/, #1920 retention, #141 issue lifetime/ADR-059), 2026-08-31 (fallback cost), C9/C10 (2026-09-07), C12 + C12 undo/retry (2026-09-27))

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| 1 | A stage writes only into the five areas (state dir, worktree, stage scratch, runtime/, ADR-011 stores) | tests/unit/write-boundary-sweep-test.sh:185, :189 (classifier) | MEDIUM | since C12 only the worktree half halts; shared-place hits are recorded only |
| 2b | `runtime/` is engine-owned and not a violation source (under the allowed state dir) | tests/unit/write-boundary-sweep-test.sh:185 | LOW | |
| 2b | `runtime/` is excluded from the CI artifact upload | UNTESTED — **contradicted**: .github/workflows/zbuild-pipeline.yml:528-531 excludes only scratch, and tests/unit/ci-state-isolation-test.sh:194-197 asserts the upload excludes nothing but scratch | LOW | see Conflicts |
| 2b | `runtime/` is excluded from the local-vs-CI parity walk | tests/e2e/parity-local-vs-ci-test.sh:136 (the walk's own exclusion) | LOW | structural, not an assertion |
| 2b | A reader verifies liveness before acting on a recorded PID/pgid | tests/unit/pgid-sweep-test.sh:45 | MEDIUM | |
| 2 | Scratch = `${ZBUILD_SCRATCH_ROOT:-$ZBUILD_STATE_DIR}/scratch/<stage>[-<map_element>]` | tests/unit/stage-scratch-test.sh:40, :74 | MEDIUM | |
| 2 | One dir per stage, reused across cycle iterations (no iteration key) | tests/unit/stage-scratch-test.sh:49, :55; tests/integration/stage-scratch-dispatch-test.sh:231 | MEDIUM | |
| 2 | Scratch is 0700 | tests/unit/stage-scratch-test.sh:124 | MEDIUM | holds raw prompts on shared runners |
| 2 | Key sanitised to one path component; `..` cannot escape the job folder | tests/unit/stage-scratch-test.sh:87, :93 | HIGH | tested |
| 2 | Fail-open: an unnameable stage or uncreatable dir leaves vars unset; dispatch never refused | tests/integration/stage-scratch-dispatch-test.sh:182, :213 (unnameable/relative); uncreatable-dir arm UNTESTED | MEDIUM | |
| 3 | `plugin_hook_call` exports `ZBUILD_STAGE_SCRATCH`, `TMPDIR` (same dir) and `ZBUILD_ARTIFACT_DIR=<state_dir>/artifacts` for one dispatch | tests/integration/stage-scratch-dispatch-test.sh:103, :105, :107, :120 | HIGH | tested |
| 3 | Guard is "absolute", not "non-empty": relative/empty state_file → no exports, nothing written into CWD | tests/integration/stage-scratch-dispatch-test.sh:188, :213, :219 | HIGH | tested |
| 3 | `local -x`: values and export attribute restored after dispatch; no bleed into stage N+1 | tests/integration/stage-scratch-dispatch-test.sh:132, :136, :138, :144 | MEDIUM | |
| 4 | Scratch is never under `$TMPDIR` and the resolver never reads `TMPDIR` | tests/unit/stage-scratch-test.sh:150, :162, :178 | MEDIUM | |
| 5 | CI upload excludes `scratch/**` and `**/scratch/**` (raw unredacted I/O) | tests/unit/ci-state-isolation-test.sh:171, :190 | HIGH | tested |
| 6 | Job-folder retention is 7 days | UNTESTED (weak) — tests pass `7` explicitly (cleanup-state-dirs-reclaim-test.sh:89); the default `age_days=${2:-7}` (scripts/lib/cleanup.sh:1074) is unasserted | MEDIUM | |
| 6 | An `in_progress` run is never reclaimed, even under `--force` | tests/unit/cleanup-state-dirs-reclaim-test.sh:169; tests/unit/cleanup-state-dirs-test.sh:98 | HIGH | tested |
| 6 | The run named by `$ZBUILD_RUN_ID` is never reclaimed, even under `--force` | tests/unit/cleanup-state-dirs-reclaim-test.sh:190 (non-force only); `--force` arm UNTESTED | MEDIUM | code skips unconditionally (cleanup.sh:1098) |
| 6 | Interrupted and unrecognised-status runs are skipped unless `--force` | tests/unit/cleanup-state-dirs-reclaim-test.sh:116 (named skip), :180 (`--force` releases) | MEDIUM | |
| 6 | An unreadable mtime fails closed | tests/unit/cleanup-state-dirs-reclaim-test.sh:155, :161 | HIGH | tested |
| 6 | Clock = state file → events.jsonl → dir mtime, never a bare dir mtime | tests/unit/cleanup-state-dirs-reclaim-test.sh:140 | MEDIUM | |
| 6 | A missing state file is reclaimed by default | tests/unit/cleanup-state-dirs-reclaim-test.sh:98 | LOW | |
| 6 | `runtime/` and `scratch/` are reclaimed with the folder | tests/unit/cleanup-state-dirs-reclaim-test.sh:214 | LOW | |
| 7 | The issue directory takes the issue clock; `_cleanup_is_active_run` must see live runs under the moved root | not verified here — ADR-059 scope (same batch) | HIGH | ADR says a glob matching nothing un-gates three destructive scanners |
| C9 | Each dispatch is marked before it and swept after it with `find -newer` | tests/unit/write-boundary-window-test.sh:100, :114 | MEDIUM | marker is now keyed per dispatch (window-test :133, :140), not the single `runtime/write-boundary.marker` the ADR names |
| C9 | A violation writes `runtime/write-boundary-violated`, emits `stage.write_boundary.violated`, and `plugin_hook_call` returns 1 | tests/integration/write-boundary-dispatch-test.sh:132; tests/unit/write-boundary-sweep-test.sh:152, :163 | HIGH | tested |
| C9 | Verdict precedence: either `write-boundary-violated` or `artifact-contract-violated` → `broken`, overriding `complete` | tests/integration/write-boundary-dispatch-test.sh:143, :175 | HIGH | tested |
| C9 | Watch list is 3-tier override (env > ~/.zbuild > shipped) and replaces | tests/integration/write-boundary-dispatch-test.sh:219 (env tier only) | LOW | the ~/.zbuild tier is UNTESTED |
| C9 | Allow list is additive; engine-owned roots can't be removed | tests/integration/write-boundary-dispatch-test.sh:250, :254 | MEDIUM | |
| C9 | `stage.write_boundary.violated` is never emitted on a clean dispatch | tests/unit/write-boundary-sweep-test.sh:107, :109 | MEDIUM | |
| C9 | The sweep reports regular files only (`-type f`) | UNTESTED (comments only, sweep-test:228, :340) | LOW | |
| C9 | Canonicalise with `pwd -P` (no false violation in in-place mode) | tests/unit/write-boundary-sweep-test.sh:220 | MEDIUM | |
| C9 | A strict ancestor of an allowed root is allowed; a stray dir is still a violation | tests/unit/write-boundary-sweep-test.sh:239, :247 | LOW | |
| C9 | The engine's event-log dirs are allowed roots | tests/unit/write-boundary-sweep-test.sh:263, :270 | LOW | |
| C9 | `zbuild_engine_tmpdir` prefers scratch, then `runtime/`, then system temp | tests/unit/engine-temp-dir-test.sh:35 (scratch tier only); `runtime/` tier UNTESTED | MEDIUM | code drifted: data-root `/tmp` comes before `$TMPDIR` (scripts/lib/helpers.sh:146-156, #2017) |
| C9 | No `mktemp` under core/ defaults to /tmp (atomic.sh temps sit beside the state file) | tests/unit/write-boundary-allow-and-guards-test.sh:319 | MEDIUM | |
| C10§1 | The runner exports a run-scoped `TMPDIR=<state>/scratch/run-tmp` (0700) | tests/unit/run-tmpdir-test.sh:33; tests/integration/runner-exports-state-dir-test.sh:175 (dir exists) | MEDIUM | weak: the `export TMPDIR` (runner.sh:2165) and the 0700 mode are unasserted |
| C10§1 | `run-tmp` is refused as a stage scratch key | tests/unit/run-tmpdir-test.sh:86 | LOW | |
| C10§2 | The scrub pins `TMPDIR` to the run temp root before the `ZBUILD_*` wipe; with no job folder it leaves TMPDIR alone | tests/unit/env-scrub-test.sh:228, :242 | MEDIUM | |
| C10§4 | Both early-return arms emit `plugin.run.error` with `reason=` | tests/unit/plugin-lifecycle-event-balance-test.sh:264, :277, :282 | MEDIUM | |
| C10§5 | The allow list derives `~/.zbuild` three ways (DATA_ROOT, STATE_ROOT, HOME) | tests/unit/write-boundary-sweep-test.sh:290, :299 | LOW | |
| C10§6 | The shipped watch list carries no system-temp root | tests/unit/write-boundary-allow-and-guards-test.sh:139/:142 | MEDIUM | |
| C10 | Tests don't write to hardcoded system-temp paths (SPEC-4l) | tests/unit/write-boundary-allow-and-guards-test.sh:348 | LOW | |
| C10 | `ZBUILD_WRITE_BOUNDARY_LOG` is set in the dogfood workflow and every tier job | tests/unit/write-boundary-diagnostic-wired-test.sh:34, :64 | LOW | |
| C12.1 | A shared-place hit is recorded on 3 channels with `reason=shared_location`, and check returns 0 | tests/unit/write-boundary-sweep-test.sh:125, :128, :134; tests/integration/write-boundary-ownership-test.sh:119, :123, :124 | HIGH | tested |
| C12.2 | A stage without `capabilities.writes_repository: true` that changes worktree content is a violation | tests/integration/write-boundary-ownership-test.sh:135, :149 | HIGH | tested |
| C12.2 | A declared repository writer may change the worktree | tests/integration/write-boundary-ownership-test.sh:157 | HIGH | tested |
| C12.3 | Content, not status: pre-existing dirt isn't blamed; a HEAD move on a clean tree isn't a write | tests/integration/write-boundary-ownership-test.sh:165, :171 | HIGH | tested |
| C12.4 | In-place mode (`ZBUILD_NO_WORKTREE=1`) is exempt | tests/integration/write-boundary-ownership-test.sh:176 | MEDIUM | |
| C12.5 | The settle-window witness and `ZBUILD_WRITE_BOUNDARY_SETTLE_MS` are removed | tests/integration/write-boundary-ownership-test.sh:198-201 | LOW | a source grep, acceptable for a removal |
| C12.6 | Reverting earlier work counts; every changed path is named | tests/integration/write-boundary-ownership-test.sh:185, :192-194 | LOW | |
| C12.6 | The named path list is capped at 20 | UNTESTED | LOW | write-boundary-repo.sh:86 |
| C12a | Always undo: restores an earlier stage's uncommitted work exactly (not HEAD); new files removed, deleted files back | tests/integration/write-boundary-revert-test.sh:88-91 | HIGH | tested |
| C12a | First offence → `unusable` (retried), no halting marker | tests/integration/write-boundary-revert-test.sh:94, :95; ownership-test:140 | HIGH | tested |
| C12a | Second offence by the same stage → `broken`; the count is per stage | tests/integration/write-boundary-revert-test.sh:106, :115 | HIGH | tested |
| C12a | A new dispatch of the stage clears the unusable marker | tests/integration/write-boundary-revert-test.sh:102 | MEDIUM | |
| C12a | An undo that cannot complete (worktree ≠ pre-dispatch snapshot) halts | UNTESTED | HIGH | claimed at core/pipeline/write-boundary-repo.sh:119-149; a failed undo that continued would leave a dirty or partly restored tree under the next stage |
| C12a | `stage.write_boundary.violated` carries `action=reverted` on the first offence | UNTESTED | LOW | no test greps `action=` |


## ADR-059 — What belongs to an issue, what belongs to a run (Accepted 2026-08-23; amends ADR-023/024/035/050/054 §7/058; supersedes ADR-052 §Decision 1 + its #1869 amendment)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §1 | Data root "is `~/.zbuild`, overridable as `ZBUILD_DATA_ROOT`", never ADR-023's install root | tests/unit/layout-resolver-test.sh:177, :204 | MED | |
| §1 | Run state lives at `repos/<repo>/issues/<N>/runs/<run_id>/` (pipeline-state.json etc.), not the flat path | tests/unit/layout-writer-test.sh:82, :87; tests/unit/layout-switch-test.sh:34 | HIGH | writer test drives `main` and asserts where files landed |
| §1 | `<repo>` segment "is the GITHUB owner/repo from remote.origin.url — never the local directory name"; case preserved | tests/unit/layout-resolver-test.sh:127, :128, :133 | MED | |
| §1 | A remoteless clone "falls back to `local/<dirname>`" | tests/unit/layout-resolver-test.sh:144, :146 | LOW | |
| §1 | Pool dirs live under `runs/<run_id>/pool/`, not `${TMPDIR}` | tests/unit/adr059-no-tmpdir-defaults-test.sh:56, :67, :84, :108 | MED | all three backends + fallback covered |
| §1 | "The path is the keying" — reclaimers/cleanup see a live run in the new layout | tests/unit/layout-switch-test.sh:65; tests/unit/layout-resolver-test.sh:93, :104 | HIGH | the "six silent sites" hazard |
| §2 | Worktree is keyed by the issue: "one tree per issue, reused across runs"; different issues → different trees | tests/unit/layout-writer-test.sh:99, :102, :112, :115 | HIGH | |
| §2 | "No plugin decides which tree it works in" | tests/integration/worktree-ownership-test.sh:75 | HIGH | partial: asserts intake only; no lint over all plugins |
| §3 | "Git is the store. Every run pushes" the state branch — local and CI one mechanism | tests/unit/persist-stage-test.sh:88; tests/unit/persist-push-entrypoint-test.sh:58, :157, :166 | HIGH | |
| §3 | "The local ref wins on read" over origin (may hold unpushed work); fetch never moves refs/heads | tests/unit/hydrate-stage-test.sh:150, :151; tests/unit/persist-push-entrypoint-test.sh:187, :195 | HIGH | |
| §3 | Restore extracts into a SEPARATE `restored-artifacts/`; the live path is read first | tests/unit/stage-input-resolve-precedence-test.sh:127, :137; tests/unit/own-run-artifacts-first-test.sh:75 | HIGH | |
| §3 | hydrate is first in flow (before intake) and NOT always-run | tests/unit/template-simple-yaml-test.sh:86 (loop, idx 0 = hydrate), :208; tests/unit/template-always-run-test.sh:39 | MED | |
| §3 | hydrate fetches (fresh clone sees prior work) and promotes atomically (partial tree discarded) | tests/unit/hydrate-stage-test.sh:104, :215, :218 | MED | |
| §3 | `always_run` = release then persist, "persist last"; neither is in `flow:` | tests/unit/template-always-run-test.sh:39, :58, :62 | HIGH | |
| §3 | Always-run stages run "on every exit path" (rc 0, non-zero, SIGINT, SIGTERM) | tests/integration/always-run-exit-paths-test.sh:109, :117, :123, :192 | HIGH | |
| §3 | release "Deletes nothing"; purge never reachable from a run | tests/unit/teardown-purge-scratch-test.sh:72; tests/integration/runner-release-exit-paths-test.sh:157 | HIGH | |
| §3 | release "must stay fast" — a hang there can't lock up the exit | tests/integration/always-run-exit-paths-test.sh:215, :223 | MED | |
| §3 | A failed push "degrades to 'state is local only'", never changes the run's outcome | tests/unit/persist-stage-test.sh:182, :183, :185; tests/unit/persist-push-entrypoint-test.sh:94 | MED | |
| §3 | "Persist redacts before it writes. All persisted text passes `apply_scope_redaction`" | UNTESTED | MED | code contradicts it — see Conflicts C1. The secret-refusal used instead is tested (persist-stage-test.sh:134; persist-push-entrypoint-test.sh:98) |
| §3 | "Gate verdicts are excluded from the store" | UNTESTED | HIGH | code contradicts it — see Conflicts C2 |
| §4 | A second run of the same issue is refused while the lock is held; a different issue is admitted (keyed mutex, not a cap) | tests/unit/issue-lock-test.sh:66, :67, :72 | HIGH | tests the primitive only |
| §4 | "A run acquires an exclusive lock on its issue BEFORE entering the worktree, and refuses if it cannot" | UNTESTED | HIGH | runner wiring at core/pipeline/runner.sh:2263-2276 has no test (no test greps `pipeline.refused.issue_locked`). It fails open: the lock is silently skipped when `zbuild_run_key` is undeclared or fails (:2264-2266) |
| §4 | A dead holder is "reaped first" using the `zbuild_run_is_live` predicate | tests/unit/issue-lock-test.sh:84, :97, :106, :198, :217 | HIGH | includes the orphaned-fd case and a live-holder control |
| §4 | Lock "keyed on `repos/<repo>/issues/<N>/`" | UNTESTED | MED | code contradicts it — see Conflicts C3 |
| §5 | A goal run "is keyed by a hash of its goal text" under `goals/<key>/`; same goal → same key, different goals → different keys | tests/unit/goal-identity-test.sh:35, :42; tests/unit/layout-resolver-test.sh:157 | HIGH | |
| §5 | The goal hash is whitespace-insensitive | tests/unit/goal-identity-test.sh:52; tests/unit/identity-lib-test.sh:78 | LOW | |
| §5 | A goal-derived path component "is sanitised" (no traversal) | tests/unit/issue-lock-test.sh:131, :137, :144; tests/unit/layout-resolver-test.sh:163 | MED | |
| §5 | Goal runs no longer share `zbuild/issue-0-*` | tests/unit/goal-identity-test.sh:81, :91 | MED | |
| §6 | The identity module is sourceable by cleanup.sh/worktree.sh "without pulling in anything from the plan stage" | tests/unit/identity-lib-test.sh:45, :61, :62 | LOW | |
| §6 | One slug derivation accepts every GitHub remote form (the two old parsers disagreed) | tests/unit/identity-lib-test.sh:104, :111, :144 | MED | |
| §6 | Credentials are stripped before the repo hash | tests/unit/identity-lib-test.sh:85 | MED | |
| §6 | Repo id / goal hash "computed once" — no duplicate derivation | UNTESTED | LOW | duplicates removed today (grep finds none), but nothing guards against reintroducing one |

## ADR-060 — Stages return structure; the engine renders prose (Accepted 2026-08-28; amends ADR-028 output contract)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §1 | "A stage MUST NOT declare a field whose value is a markdown document" | scripts/lib/lint-llm-envelope.sh (in `npm run lint`) + tests/unit/lint-llm-envelope-test.sh:26, :33, :40; tests/unit/llm-agent-framework-test.sh:58 (`_llm_output_contract` refusal) | MED | heuristic: catches only a `*_md` name or a placeholder that says "markdown". The ADR's "Nothing enforces §1 yet" is stale (C7) |
| §2 | Cycle feedback is structured; `impact_feedback_md` is removed from the prompt/schema | plugins/agent/impact/tests/impact-prompt-contract-test.sh:111-113 | LOW | |
| §3 | Human output is rendered by the engine from JSON; `render_impact_md` builds its narrative from `missing[]` | tests/unit/artifact-render-impact-test.sh:25-28, :36 | LOW | |
| Cons. | Legacy envelopes that still carry the field "parse and are ignored, never rendered" | tests/unit/impact-envelope-recovery-test.sh:147; tests/unit/artifact-render-impact-test.sh:111 | LOW | |
| Cons. | No `impact_feedback.md` output is written | tests/integration/impact-pipeline-test.sh:137 | LOW | |
| §4 | A markdown deliverable "is written to a file, never embedded in an envelope field" | UNTESTED | LOW | covered only indirectly by the §1 lint |
| §5 | Short plain-text fields (reason/message/summary/description/evidence) are data and are not banned | tests/unit/lint-llm-envelope-test.sh:48 | LOW | |
| §6 | "The engine MUST NOT rewrite what a model returned" — no escape repair | UNTESTED | HIGH | a silent repair would fabricate data and pass every gate |
| §6 | A malformed envelope → `verdict=incomplete` + reason + diagnostic event, rc=0, and the cycle re-runs the stage | UNTESTED | HIGH | code: plugins/agent/impact/plugin.sh:519-534. The only test asserts the event is *declared* in the manifest (impact-v2-result-contract-test.sh:375). No test drives a malformed reply through `impact_run` |
| §7 | `_llm_envelope_classify` returns exactly one of `unparseable` / `schema` / `ok`; the #1833 payload → unparseable | tests/unit/impact-envelope-recovery-test.sh:159, :163, :167 | MED | |
| §7 | `_llm_envelope_parse_error` surfaces jq's own message, clamped to 300 chars | UNTESTED | LOW | no test calls it |
| Impl | impact keeps its own two-phase recovery and must not collapse onto the shared one-phase helper | tests/unit/impact-envelope-recovery-test.sh:96, :111, :112 | MED | |
| Impl | `--markdown-fields` is removed | tests/unit/llm-agent-framework-test.sh:68-71 | LOW | grep-the-source check, but it is the statement itself |
| Impl | `impact.envelope.malformed` is declared in impact's `provides.events` (plugin namespace) | tests/unit/impact-v2-result-contract-test.sh:375 | LOW | |

## ADR-061 — Fault-class vocabulary (stages stop naming stages) (Accepted 2026-08-31; supersedes ADR-045 `route_target` and #1767; amended #2163 on 2026-09-20)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Closed set | The fault set is exactly `specification` / `scope` / `implementation`, in table order | tests/unit/fault-vocabulary-test.sh:44 | MED | |
| Absent | `environment`, `input` (and `route_design`, empty) are not members | tests/unit/fault-vocabulary-test.sh:65-69 | LOW | |
| Impl | `fault_routes`: specification/scope rewind, implementation does not, a non-member is rc 2 | tests/unit/fault-vocabulary-test.sh:84, :90, :106, :108 | MED | |
| Decision | A gate declares the fault in its standard result file, beside `verdict` | tests/integration/acceptance-guard-regressed-routes-design-test.sh:100 | MED | |
| Decision | Stages never name a destination — no plugin writes `route_target` | tests/unit/fault-vocabulary-test.sh:116 | MED | weak regex: catches only shell `route_target=` assignments, not a JSON key written via jq or printf |
| Cons. | The aggregate verdict "stays pass/fail"; the fault is mirrored | tests/unit/gate-aggregator-test.sh:149, :323 | HIGH | |
| — | A fault on a passing gate is ignored | tests/unit/gate-aggregator-test.sh:191 | MED | |
| Precedence | Across disagreeing gates, selection follows "the vocabulary's table order", replacing file-iteration order | UNTESTED (weak) | MED | TC-19 (:324) cannot tell the two orders apart: `_GA_LEGACY_MUST_PASS` lists shape-floor (specification) before coverage (scope), so roster order picks the same winner |
| Precedence | A word outside the set "is never selected and is announced" (`gate_aggregator.fault_unrecognised`) | tests/unit/gate-aggregator-test.sh:368-373 | MED | |
| Cons. | `route_design` is retired from `valid_verdicts` | UNTESTED | LOW | |
| Impl | `runner_read_stage_fault` reads the fault from the result file and the runner carries it on the dispatch into the cycle predicate blob | UNTESTED | HIGH | cycle tests stub `_CYCLE_DISPATCH_FAULT` directly (tests/lib/cycle-stall-break-fixture.sh:89); no test calls `runner_read_stage_fault`. A broken reader means no rewind, silently |
| `in` / route_back | `route_back` keys on `fault in "specification scope"` (simple.yaml), and a specification fault rewinds | tests/unit/template-simple-yaml-test.sh:290-295 (parse); tests/unit/core-pipeline-cycle-stall-break-test.sh:168, :171 (runtime, real simple.yaml) | HIGH | runtime case covers `specification` only; `scope` through `in` is not driven |
| `in` | `in` is also available to `exit_when` / `abort_when` and both load-time validators | UNTESTED | LOW | validators accept it (core/pipeline/template.sh:1311, :2566); no runtime test for exit/abort |
| `in` | `eq` / `ne` "behave identically" | tests/integration/cycle-orchestrator-route-back-test.sh:99 | LOW | |
| Amend #2163 | RESOLVE is stamped only on a failure with no declared fault; specification/scope → "context only — the engine routes this" | tests/unit/stage-boundaries-test.sh:72, :73, :75 | HIGH | `scope` is not driven, only `specification` |
| Amend #2163 | The build prompt states its testfiles are read-only for this stage and names no other stage | tests/unit/stage-boundaries-test.sh:85, :86 | MED | |
| Amend #2163 | The deny rule is rendered `Edit(//abs)`, never a single-slash project-relative rule | tests/unit/stage-boundaries-test.sh:103, :104 | HIGH | the old rule silently matched nothing |
| Amend #2163 | Findings state facts, with no remedy addressed to another stage | tests/unit/stage-boundaries-test.sh:116, :117 | LOW | |
| Amend #2163 | The build stage restores modified authored testfiles from `artifacts/authored-testfiles/` before it runs, and says so (event) | tests/unit/stage-boundaries-test.sh:146, :148, :149, :150 | HIGH | |


## ADR-062 — The engine reclaims; stages stop declaring cleanup hooks (Accepted 2026-08-31; supersedes ADR-054 §7 per-stage cleanup dispatch; amends ADR-056, ADR-058 §1; §1 "engine records at dispatch" itself reversed in-ADR by #2024 Implementation Notes)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §1 (as corrected #2024) | "whoever creates [a process group] registers it" at `runtime/stages/<stage>.pgid`, in the #2018 format (pgid + leader start time) | tests/unit/pg-register-test.sh:51 (SPEC-2, a real foreign group recorded with start time) | MEDIUM | behavioural on `zbuild_pg_register` itself |
| §1 | registering your **own** group "is refused" | tests/unit/pg-register-test.sh:34 (SPEC-1) | MEDIUM | |
| §1 | the dispatch-time write "is deleted": the dispatch seam writes no pgid record | tests/unit/pg-register-test.sh:83 (SPEC-4), tests/unit/pgid-sweep-test.sh:138 (SPEC-9) | LOW | grep-for-forbidden-pattern guards on lifecycle.sh (lint-strength) |
| §1 | the two group-creating sites (tool/test `set -m` suite, router `setsid` spawn) call `zbuild_pg_register` | UNTESTED (weak): tests/unit/pg-register-test.sh:93 only greps that the name appears in each file | MEDIUM | hard-kill-sweep-e2e uses a stand-in runner, not tool/test or route.sh; a call that went dead (wrong var, wrong stage) would stay green |
| §2 | reclamation "reads the record, not the status map": a stage killed mid-flight is freed | tests/integration/teardown-pgroup-kill-test.sh:92 (SPEC-3, a stage absent from stage_statuses is actually killed) | HIGH | runner-release-exit-paths SPEC-4/5 (:222, :282) only check fixture-hook markers, not that a group died |
| §2 | `release` "deletes nothing" | tests/unit/teardown-purge-scratch-test.sh:72 (SPEC-3); tests/integration/runner-release-exit-paths-test.sh:157 (purge never reachable from a run) | HIGH | a failed run keeps its evidence |
| §2 | `release` "drops locks" | UNTESTED | LOW | teardown/plugin.sh has no lock handling; the issue lock is released by the runner trap (core/pipeline/runner.sh:2421), not by release |
| §3 | no plugin declares a `cleanup:` hook; `test_cleanup` is gone | tests/integration/cleanup-release-test.sh:173, :182 | LOW | the "Now" and "Then: last real hook" steps are both done |
| §3 "Then" | the hook name in the plugin contract, teardown's per-stage dispatch loop, and `plugin.cleanup.*` events "retire together" with the last hook | UNTESTED — code contradicts | LOW | the hook retired but the loop and events remain: plugins/tool/teardown/plugin.sh:190-214 still dispatches `plugin_hook_call … cleanup`; config/event-schema.json:39-42 still lists `plugin.cleanup.*`; cleanup-release-test.sh:240 still asserts `plugin.cleanup.absent`. Also ADR text "tool/test keeps its hook for now" is stale |
| Cons. | purge deletes `scratch/` "and nothing else" | tests/unit/teardown-purge-scratch-test.sh:50, :60 | HIGH | artifacts and pipeline-state survive |
| Cons. | the sweep frees only groups whose start time proves identity; recycled/bare/unprovable records are skipped; never our own group | tests/unit/pgid-sweep-test.sh:65, :75, :116; :94 (apply frees the proven group) | HIGH | a wrong kill loses someone else's work silently |
| Cons. | `zbuild cleanup --pgroups` frees a SIGKILLed runner's orphan | tests/integration/hard-kill-sweep-e2e-test.sh:120 (SPEC-5) | MEDIUM | stand-in runner (see the §1 caller row) |
| Cons. | `zbuild_pg_record_pgid` is "the single reader"; "do not re-parse a `.pgid` in a caller" | partial: tests/unit/pgid-sweep-test.sh:178 (reader handles TSV/bare/junk); :189 only greps that teardown/test *mention* the reader | MEDIUM | nothing rejects a second parser elsewhere, which is the failure the ADR names (it kills nothing and reports success) |
| Cons. | reclamation bounded by `ZBUILD_RELEASE_TIMEOUT` (default 30s) | tests/integration/runner-release-exit-paths-test.sh:302 (bound with timeout=3) | MEDIUM | the 30s default is untested; exit-path-teardown-budget-guard-test.sh:38 is a grep |

## ADR-063 — Stages are told their limits, and say when they hit them (Proposed 2026-09-02; amends ADR-054 §6. §3/§4's `exhausted` is overtaken by ADR-054 §6a (#2187), which retired the word)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §0 | §1–§4 "land together, per stage, during that stage's v2 migration"; §1/§2 wait for §3/§4 "by choice" | UNTESTED — code contradicts | MEDIUM | §1 shipped alone: budget blocks are in design/plan/monitor/review-* (tests/unit/stage-budget-note-test.sh header: "#2252 E") without §2 partial forms or a general §4 gate |
| §1 | the budget block is "interpolated from the same numbers the engine will act on" (`_route_resolve_max_turns` / `_route_resolve_timeout`) | tests/unit/design-budget-prompt-injection-test.sh:74, :87; tests/unit/stage-budget-note-test.sh:40-42, :77 (N6, reaches the text sent to the model); plugins/agent/review-lens/tests/review-lens-v2-budget-test.sh:166 | MEDIUM | the tests stub the router resolvers and assert that the stub value appears |
| §1 | "One helper renders the budget block … Stages do not restate them" | UNTESTED — code contradicts | LOW | there are 5 renderers: scripts/lib/stage-budget-note.sh plus `_plan_budget_guidance` (plan/plugin.sh:55), `_design_budget_guidance` (design/plugin.sh:94), `_monitor_budget_guidance` (monitor/plugin.sh:98) and `_rr_budget_guidance` (review-report/plugin.sh:61); stage-budget-note-test.sh:55 accepts any of these names |
| §1/§2 | every LLM stage is told its limits | UNTESTED (weak): tests/unit/stage-budget-note-test.sh:57 (N4) greps each model-calling plugin for a helper name | MEDIUM | only spec-correspondence (N6) and design are behavioural |
| §2 | "Every LLM stage declares a partial form of its deliverable … in the stage's schema" | UNTESTED | MEDIUM | not implemented: no agent manifest or config schema declares a partial form for design (grep "partial" hits spec-correspondence only) |
| §3 | partial is signalled as `disposition: exhausted` | n/a — superseded | — | conflict: ADR-054 §6a (#2187) retired `exhausted` (core/pipeline/disposition.sh:28, set at :64); producers now write `out_of_turns`/`timed_out` (review-lens-v2-budget-test.sh:195). A stale comment at review-lens/plugin.sh:332 still says "disposition:exhausted" |
| §3 | "Prose is not a signal": no engine path branches on a `notes` gap | UNTESTED | LOW | negative rule; no lint |
| §4 | `exhausted → escalate` routes to `_route_escalate_timeout` and "runs" | n/a — superseded | — | `escalate` is retired with `exhausted` (#2187); retry policy is now per word |
| §4 | "Any gate reading a stage whose disposition is [partial] fails closed unless it declares otherwise" | partial: tests/unit/convergence-timeouts-never-fatal-1208-test.sh:174 (an unfinished **build** never converges the cycle) | HIGH | no general gate rule exists or is tested; a gate that accepts an unfinished design/plan is not covered. lifecycle.sh:497 deliberately skips the output check for unfinished stages (unfinished-stage-output-check-test.sh:75), so nothing else catches a partial deliverable |
| §6 | carry-forward rides on the #1986 summary channel; "Do not build a second channel" | UNTESTED | LOW | negative rule |

## ADR-064 — One live run-status comment per run (Proposed 2026-09-18; implemented and amended twice, 2026-09-19 #2145 and #2154; amends ADR-010 §3 and ADR-015 refs)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §1 | the sidecar is spawned after the events path is fixed | tests/unit/runner-status-comment-hook-test.sh:42 | LOW | a text pin on runner.sh ordering |
| §1 | spawned "before the issue lock (so the sidecar never inherits the lock fd)" | UNTESTED | MEDIUM | holds today (runner.sh:2195 spawn vs :2268 lock), but nothing pins it. An inherited flock fd would hold the issue lock past the run |
| §1 | never spawned on `--dry-run` | UNTESTED | LOW | runner.sh:2194 |
| §1 | reaped on the normal `_runner_ended` path and as the last statement of the abort trap; no sidecar outlives the run | tests/integration/run-status-comment-runner-test.sh:115, :160 (behavioural); runner-status-comment-hook-test.sh:35, :38 (text pins) | MEDIUM | |
| §1 | reap is bounded; a TERM-ignoring child is KILLed | tests/unit/runner-status-comment-hook-test.sh:114, :121 | LOW | |
| §1 | the job-control signal walk exempts the sidecar | UNTESTED (weak): runner-status-comment-hook-test.sh:39 greps the pid name inside the walk | LOW | |
| §2 | reader, not writer: writes only status-comment.json/log; "no path to the event bus" | tests/integration/run-status-comment-runner-test.sh:116; tests/unit/run-status-comment-gh-test.sh:123 | MEDIUM | |
| §2 | id persisted atomically (tmp+mv) | tests/unit/run-status-comment-gh-test.sh:78 | LOW | |
| §3 | one comment per run: POST once, PATCH after | tests/integration/run-status-comment-runner-test.sh:105; tests/unit/run-status-comment-gh-test.sh:73, :86-87 | MEDIUM | |
| §3 | a lost id is rediscovered by the run marker before any create; another run's marker is never adopted | tests/unit/run-status-comment-gh-test.sh:95, :113-114 | MEDIUM | |
| §3 | PATCH 404 → one re-create per process, then give up | tests/unit/run-status-comment-gh-test.sh:136, :139 | LOW | |
| §4 | rows newest first, keyed by seq; a nested start opens no second row; a seq-less close closes the latest open row; reused members collapse per iteration; a killed row keeps its start and inputs | tests/unit/run-status-comment-render-test.sh:97, :101, :122, :126, :146 | LOW | |
| §4 | summary first line cut at 200 chars | tests/unit/run-status-comment-render-test.sh:136 | LOW | |
| §5 | `seq` stamped only while the label is set; digits-and-dots only; the stage-less envelope keeps 8 keys | tests/unit/event-bus-seq-envelope-test.sh:36, :49-50, :67 | MEDIUM | the envelope shape is shared by every consumer |
| §6 | body capped at 60,000 bytes, newest-first, ending in an omission line | tests/unit/run-status-comment-render-test.sh:163, :170 | LOW | |
| §6 | the body passes `apply_scope_redaction` when a scope manifest exists; a redactor failure posts nothing | tests/unit/run-status-comment-render-test.sh:182, :185-186 | HIGH | the outbound path to GitHub; tested |
| §6 | every `gh` call runs under a watchdog; every failure is logged with rc 0; the run's exit status is unchanged | tests/unit/run-status-comment-gh-test.sh:120, :129, :195; tests/integration/run-status-comment-runner-test.sh:124 | MEDIUM | the 30s default is untested (tests use 1s) |
| §6 | PATCHes coalesced (≥5s); terminal events flush at once | tests/unit/run-status-comment-loop-test.sh:104, :131 | LOW | |
| §7 | gates: `ZBUILD_STATUS_COMMENT=0`, goal run, gh auth failing, non-github origin | runner-status-comment-hook-test.sh:67, :72, :76, :81; run-status-comment-runner-test.sh:133, :137 | MEDIUM | |
| §7 | gates: `NO_GITHUB=true`, `gh` missing | UNTESTED | LOW | code at scripts/lib/run-status-comment.sh:47, :49 |
| §7 | `scripts/run-tests.sh` and the parity fixture pin `ZBUILD_STATUS_COMMENT=0` | tests/unit/runner-status-comment-hook-test.sh:47, :49 | LOW | grep of the export line; adequate for a config pin |
| Am. #2145 | every row leads with its time; the zone defaults to Eastern (`ET`) | tests/unit/run-status-comment-render-test.sh:83, :106 | LOW | |
| Am. #2145 | the header shows the ceiling and "(past ceiling)" | UNTESTED | LOW | only the finalize wording is tested |
| Am. #2145 | `rsc_finalize_issue` rewrites the newest marker comment, never POSTs, and appends the cancelled-at-ceiling text | tests/unit/run-status-comment-gh-test.sh:160-164, :174-175 | LOW | |
| Am. #2154 | a closed row's summary is frozen into status-comment-rows.json, keyed by run id; a fresh process serves the snapshot | tests/unit/run-status-comment-render-test.sh:198, :202, :204 | LOW | |

## ADR-065 — Process budget: the engine's fork count is a tested contract (Accepted 2026-09-19; amended #2236, #1842, #2249)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §1 | the mocked full run's external exec count ≤ `FORK_BUDGET` (5740) | tests/e2e/fork-budget-test.sh:268 (SPEC-4) | MEDIUM | |
| §1 | the detector cannot go inert: the canary counts exactly 1; the trace names ≥20 files and ≥1,000 execs; the run exits 0 under tracing | tests/e2e/fork-budget-test.sh:168, :252, :216 | MEDIUM | |
| §1 (#1842) | words inside an assigned value are not counted | tests/e2e/fork-budget-test.sh:183 | LOW | |
| §1 (#2236) | the count must not depend on load: the pool's poll wait is exempt, and no counted pool line runs more than once per work unit | tests/e2e/fork-budget-test.sh:198, :260, :266 | LOW | |
| §1 (#2236) | the exempt marker "is only for a poll's wait, never for work" | UNTESTED | MEDIUM | nothing checks that a marked line execs only `sleep`; a marker on real work hides its forks from the budget |
| §2 | "The budget only ratchets down"; a raise needs an ADR-065 amendment | UNTESTED | LOW | process rule; no check that a FORK_BUDGET increase comes with an ADR edit |
| §3 | per-run memos are filled once in the parent at a prewarm seam; subshell lookups add no parse | tests/unit/yaml-get-cache-test.sh:215; tests/unit/manifest-index-test.sh:100, :110; :157 (sourcing runner.sh forks ≤400 awk) | LOW | covers the named memos only, not the general rule |
| §3 | file-backed memos honour the shared `ZBUILD_YAML_CACHE=0` kill switch | tests/unit/manifest-index-test.sh:120-127 | LOW | manifest index only |
| §4 | a reader over N manifests forks once, not N or N×K | tests/unit/manifest-index-test.sh:84-85; tests/unit/yaml-get-cache-test.sh:200 | LOW | |
| Cons. | CI's e2e job is Linux-only and "the ratchet is set from the Linux number" | UNTESTED — contradicted | LOW | every ratchet in the ADR amendments and the test comment (fork-budget-test.sh:43-52) is a macOS measurement (e.g. "Measured 5,685 on macOS") |

## PHASE-DEFERRALS.md — Phase Deferrals Index (index document, no status line)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Notes | "When a deferred item lands, update this table and the originating ADR's Implementation Notes" | UNTESTED — violated | LOW | #287, #288, #289, #294 and #291 are all CLOSED/COMPLETED on GitHub (2026-05-28 to 2026-07-11) but the table still lists them as deferred; only #293 is marked Closed |
| Notes | a tombstone whose keeper's trial is blocked on a deferred issue "MUST cite the relevant row … by issue number" | UNTESTED | LOW | no lint reads PHASE-DEFERRALS (the only reference is .github/issues/keepers-manifest.yaml) |


## Conflicts

### ADR-051/052


- **ADR-051 §3/§6 vs code core/router/route.sh:345-400** — ADR: the router resolves the stage persona and prepends it at `_route_redact_prompt`. Code: that function injects read-only scope, vision preamble and checkpoint block only; route.sh:104 merely sources `persona-resolve.sh`. **Code follows the pre-ADR model** (#1306 open).
- **ADR-051 §7/§8 vs plugins** — ADR: no plugin resolves its own persona, lint-enforced. Code: design/plugin.sh:387, plan/plugin.sh:327, impact/plugin.sh:239, build/plugin.sh:202 hard-pin personas; spec-correspondence/plugin.sh:103, issue-acceptance/plugin.sh:149, spec-coverage/plugin.sh:165 call `resolve_persona` themselves; no lint exists. Tests (design-persona-framing-test.sh:100,151 and siblings) **pin the behaviour the ADR forbids**. Code follows the plugin-owned model (#1604 open).
- **ADR-051 §5 vs scripts/lib/persona-resolve.sh:77-80** — ADR: third precedence step is the "manifest default". Code: third step is `template_config_persona` (a global template key). Code follows its own chain.
- **ADR-051 impl notes / ADR-020 §115 (default `warn`) vs core/pipeline/contract-validator.sh:191 and runner.sh:622 (default `enforce`)** — one env var, `ZBUILD_CONTRACT_VALIDATOR`, has default `warn` for the startup preflight (runner.sh:713) and `enforce` for the inter-stage contract validator and leaf resolvability. An operator setting nothing gets both behaviours.
- **ADR-052 §Decision 5 vs runner.sh main() (#1783 comment)** — ADR: the `--self-host` snapshot is pre-re-root bookkeeping taken from the operator's tree. Code: the snapshot is now refreshed per dispatch from the run's own tree. Code follows #1783; ADR text is stale.
- **ADR-052 §Decision 1 ("reuse keyed on `run_id`") vs ADR-052 #141 amendment / ADR-059 §2** — superseded in-document; code follows the issue key (runner.sh:2283-2289, `_runner_enter_worktree` falls back to run_id only without identity). scripts/lib/worktree.sh:150-153 header comment and worktree-ownership-test.sh:207 still describe run_id keying (stale prose only).
- **ADR-052 #141 ("issue lock is a precondition, not a follow-up") vs runner.sh ~2262** — `ZBUILD_NO_ISSUE_LOCK=1` lets a run enter the shared issue tree without the lock; tests set it routinely (layout-writer-test.sh:58). See ADR-059 for whether the override is sanctioned.

### ADR-053/054/055


1. **ADR-054 §5 / §4 vs ADR-047 §3 vs code (the known one, confirmed).**
   - ADR-054 §5 says the result is "One file. The primary artifact declared in the stage's manifest."
   - ADR-047 §3 (docs/adr/ADR-047-stage-agnostic-mechanics.md:82-83) says a non-JSON primary reports through a separate `<stage>-verdict.json`, as "the **normal** contract."
   - In core/pipeline/verdict.sh:363-370, a non-JSON primary returns `nonjson` before `result_contract` is read (:383). `_contract` stays at its default 1 (:344), and only the sidecar's `.verdict` is read (:469-470, `_verdict_read_stage_sidecar` :289-296).
   - Effect: design's sidecar (it writes `result_contract:2`, `disposition:timed_out`, per tests/unit/design-v2-result-contract-test.sh:144) is read as v1. Its disposition and verdict are never checked against the closed set or `valid_verdicts`.
   - It is also invisible to the #2252 "unfinished" skip in core/plugin-registry/lifecycle.sh:495-496, which reads `_lcr_disp` from the same reader.
   - Code follows ADR-047.

2. **ADR-054 §6a vs core/pipeline/dispatch-rc.sh:120-122.**
   - §6a gives one word per cause: a timeout is `timed_out`, an account rate limit is `rate_limited`. It names the defect directly: "every timeout was reported `interrupted`."
   - `dispatch_rc_failure_disposition` still maps `timeout` → `interrupted` and a rate limit → `unavailable`, and tests/unit/dispatch-rc-test.sh:105, :110 pin both.
   - `router_reason_disposition` (scripts/lib/router-rc-classify.sh:262-264) uses the §6a words, so there are two mappers with different answers.
   - Behavioural effect: `interrupted` is exempt from the progress rule (runner.sh:2908), so a no-result timeout retries without a progress check.
   - Code follows the pre-§6a table on the no-result path and §6a on the router path.

3. **ADR-054 §6 vs code.**
   - §6 says that for an off-set disposition "the reader returns the declared word unchanged rather than substituting a valid member."
   - `runner_read_stage_disposition` returns `broken`, which tests/unit/core-pipeline-disposition-test.sh:205 asserts deliberately. The word survives only on the reason channel.
   - Code follows the test, not the ADR.

4. **ADR-054 §1/§7 vs ADR-062.**
   - ADR-054 §1 makes `cleanup` one of exactly two contract hooks, and §7 dispatches it per stage with `scope` because "only the stage knows what it spawned."
   - ADR-062 supersedes §7's per-stage dispatch and deletes the hooks. tests/integration/cleanup-release-test.sh:173 asserts that zero cleanup hooks remain.
   - ADR-054's header lists no ADR-062 supersession.
   - Code follows ADR-062.

5. **ADR-054 §1 vs ADR-054 §4 / ADR-056.**
   - §1 says ADR-056 owns "the `rc=3` sentinel that distinguishes an absent optional hook."
   - #1823 (§4) removed that sentinel: lifecycle.sh:416-430 returns 0, and tests/unit/plugin-hook-contract-test.sh:111 and dispatch-rc-guard-test.sh:130 assert it is gone.
   - ADR-056 was annotated; ADR-054 §1's text is stale.
   - Code follows §4.

6. **ADR-054 §4a/§6 tables vs §6a (internal).**
   - The §4a rows ("rate limit → `unavailable`", "`10` → `exhausted`") and the §6 table (`exhausted`, "throttled … retained") were superseded by §6a, which retired `exhausted` and added `rate_limited`/`timed_out`.
   - The older tables were not struck through.
   - Code follows §6a (core/pipeline/disposition.sh:64), except for item 2.

7. **ADR-054 §4 "rc=0 with a missing result is a structural failure" vs core/pipeline/verdict.sh:329-333, :472-481.**
   - The verdict reader deliberately keeps an absent primary at `warn` until #1824/#1850.
   - Only the lifecycle scanner (lifecycle.sh:503-515) fails a missing output, and only one marked `required: true`.
   - Code follows the reader's deferral.

8. **ADR-055 §9 Roster vs code.**
   - The ADR says "Only stages declaring `convergence: gate` contribute."
   - tests/unit/stage-summaries-test.sh:255 (SPEC-4, #1986) asserts that an advisory stage contributes.
   - Code follows #1986; the ADR text is stale.

9. **ADR-055 §1.3 vs core/pipeline/contract-validator.sh:487-492.**
   - The ADR requires an earlier producer or a declared re-entry.
   - The validator enforces only the self-edge case, and tests/unit/core-pipeline-contract-validator-test.sh:233 asserts that a later producer with no re-entry passes.
   - Code is more permissive than the ADR.

10. **ADR-055 §1.2/§3 (and ADR-054 §3.2) vs plugins.**
    - The ADR says outside data arrives only as declared `source: external` inputs.
    - Zero manifests declare one. Intake calls `gh issue view` directly (plugins/agent/intake/plugin.sh:170; plugins/agent/intake/lib/issue-state.sh:25).
    - Code follows the old ambient model.

11. **ADR-055 §8 / Context ¶2 vs ADR-054 #2242 amendment.**
    - ADR-055 says `valid_verdicts` is "declared … under `outputs:`; never read by the runner." ADR-054 (2026-09-30) and the code (`scripts/lib/manifest-valid-verdicts.sh`, verdict.sh:420-428) read `config.valid_verdicts` and refuse an undeclared v2 verdict.
    - Code follows ADR-054.

12. **ADR-055 §6 vs code.**
    - The resume-mode artifact-existence check is specified at pre-flight.
    - It is not implemented there: contract-validator.sh has no `stage_statuses` read, and runner.sh:783 skips the startup preflight on `--resume`.
    - A missing artifact is caught later, at the consumer's dispatch (core/pipeline/input-resolve.sh:480).
    - Code follows a dispatch-time check.

13. **ADR-053 §4/§5 vs scripts/run-tests.sh:311.**
    - The ADR's own table says to remove the stale `compound-quality-pipeline-test.sh` pin, and no such file exists.
    - It is still listed and consumes 1 of the 7 cap slots.

14. **ADR-054 §9 wording vs core/router/route.sh:804.**
    - The prose implies the manifest layer is consulted before template/global.
    - Code and test (router-manifest-budget-test.sh:222) order it template > env > manifest > default.
    - LOW; the wording is ambiguous.

### ADR-056/057/058


1. **ADR-058 C9 "What the sweep does not cover" vs ADR-058 C10 §6.** C9's SUPERSEDED banner (adr:255-258) says *"C10 shipped and the roots are back. `config/write-boundary-watch.txt` carries `${TMPDIR:-/tmp}` and `/tmp` again."* C10 §6 says restoring them was *"tried and reverted … the roots ship commented"*. The code follows C10 §6: config/write-boundary-watch.txt:22-50 has no system-temp root, pinned by tests/unit/write-boundary-allow-and-guards-test.sh:139.
2. **ADR-058 §2b vs code.** §2b says `runtime/` is *"excluded from the CI artifact upload"*. .github/workflows/zbuild-pipeline.yml:528-531 excludes only `scratch/**`, and tests/unit/ci-state-isolation-test.sh:194-197 asserts the upload *"excludes nothing except scratch"*. Today the code uploads `runtime/`.
3. **ADR-058 C9 (`zbuild_engine_tmpdir`) vs C10 §1 / §2b, and vs code.** C9 says engine temps go to scratch → `runtime/` → system temp. C10 §1 puts throwaway temp roots under `scratch/` **not** `runtime/`, because §2b defines runtime/ as *"deliberately not throwaway"*. scripts/lib/helpers.sh:141-143 still sends engine temps into `runtime/`, then data-root `/tmp`, then `$TMPDIR` (:146-156, #2017). The ADR order is stale, and the runtime tier contradicts §2b.
4. **ADR-056 "Resume contract" (plus docs/RESUME-CONTRACT.md:83, "the engine sets `ZBUILD_RESUMING=1`") vs code.** Nothing in core/, scripts/ or plugins/ sets or reads `ZBUILD_RESUMING`, so the documented resume hook is dead.
5. Minor drift (not conflicts):
   - ADR-057 §5 names `_RUNNER_SELF_GRADE_REASON` as "emitted"; the code emits `selfhost.contract_lib.snapshot reason=…` (runner.sh:1490).
   - ADR-058 C9 names one `runtime/write-boundary.marker` and "six watch locations"; the code keys the marker per dispatch, and the shipped list has four entries.
   - ADR-058 §1's table still gives the worktree a lifetime of "the run", although §7 / ADR-052 #141 changed it to the issue.

### ADR-059/060/061


- **C1 — ADR-059 §3 vs code.**
  - ADR-059 §3: "Persist redacts before it writes. All persisted text passes `core/redaction/apply_scope_redaction`."
  - Code: plugins/tool/persist/plugin.sh:38-57, :160-171 never calls it. It scans for credential patterns and refuses the push (`degraded`, `pushed=false`). scripts/lib/secret-patterns.sh:14-16 says outright that reaching for `apply_scope_redaction` here "would be security theatre".
  - **Code follows:** secret refusal. The ADR was never amended to match.
- **C2 — ADR-059 §3 (and ADR-050 §3, "always re-evaluated fresh") vs code.**
  - ADR-059 §3: "Gate verdicts are excluded from the store."
  - Code: core/state/artifact-persist.sh:274-276 snapshots every file under `artifacts/` (`find "$art_dir" -type f`), gate `*-result.json` included, with no exclusion anywhere. Restore then makes them available as the fallback tier (own-run-artifacts-first O3/O7), so a stale gate verdict could be served to a consumer that runs before the gate re-runs.
  - **Code follows:** no exclusion.
- **C3 — ADR-059 §4 vs code.**
  - ADR-059 §4: the lock is "keyed on `repos/<repo>/issues/<N>/`".
  - Code: core/state/issue-lock.sh:56-57 puts it at `${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}/locks/issue-<key>.lock`. That path is not repo-scoped, so issue #N in two different repos shares one lock (a false refusal). It also sits outside the §1 layout the worktree uses.
  - Separately, the runner's wiring fails open when no key resolves (core/pipeline/runner.sh:2263-2266).
  - **Code follows:** a global, non-repo-scoped lock.
- **C4 — ADR-059 §1 internal inconsistency.**
  - The pool-dir paragraph says pool dirs go "under `$ZBUILD_HOME`". The same section's 2026-08-23 correction says `$ZBUILD_HOME` is ADR-023's install root and must not hold run state.
  - **Code follows:** the data root, `runs/<id>/pool` (adr059-no-tmpdir-defaults-test.sh:56).
- **C5 — ADR-059 §5 vs code (minor).**
  - ADR-059 §5: `goals/<goal_hash>/`, where the hash is sha256 of the goal text.
  - Code: scripts/lib/identity.sh:162-172 uses `goal-<12 hex>`, a truncated hash, with the reason documented there.
  - **Code follows:** the 12-hex truncation. The ADR text was not updated.
- **C6 — ADR-052 §Decision 1 vs ADR-059 §2.** The `run_id` key is superseded by issue keying. This is recorded in ADR-052's #141 amendment, so it is consistent. Run-id keying survives only as the no-identity fallback (layout-writer-test.sh:124).
- **C7 — ADR-060 Consequences vs code.**
  - ADR-060 Consequences: "Nothing enforces §1 yet … this ADR is a habit rather than a rule."
  - Code: §1 is now enforced by scripts/lib/lint-llm-envelope.sh (#1993, wired into `npm run lint`) and by scripts/lib/llm-agent.sh:65-90.
  - The ADR text is stale.
- **C8 — ADR-061 §"What is deliberately absent" vs ADR-054 §6 (terminology).**
  - ADR-061 says infra failures "map to `disposition: advisory`" in the same breath as the ADR-054 §6 words `interrupted`/`throttled`/`unavailable`/`broken`.
  - `advisory` belongs to ADR-021's separate member-disposition set (`terminal|recoverable|advisory|none`). It is not in the ADR-054 §6 set at core/pipeline/disposition.sh:64. ADR-054 §6 itself records the two sets as a colliding `.disposition` field name.
  - **Code follows:** both sets, each on its own consumer path. ADR-061 conflates them.

### ADR-062–065, PHASE-DEFERRALS


- **ADR-063 §3/§4 vs ADR-054 §6a (#2187).** ADR-063 says a partial deliverable is signalled as `disposition: exhausted`, and that `exhausted → escalate` must fire. ADR-054 §6a retired both `exhausted` and `escalate`. The code follows ADR-054 §6a: core/pipeline/disposition.sh:28 and :64 have no `exhausted`, review-lens writes `out_of_turns`, and `disposition_unfinished` is the predicate. ADR-063 was never amended, and a stale comment remains at plugins/agent/review-lens/plugin.sh:332.
- **ADR-063 §1 ("one helper … stages do not restate") vs the code.** There are five budget renderers (scripts/lib/stage-budget-note.sh plus the plan, design, monitor and review-report helpers). The code follows neither "one helper" nor a single source.
- **ADR-063 §0 ("all four land together") vs the code.** §1 budget blocks shipped across all LLM stages (#2252) without §2 partial forms or a general §4 fail-closed gate, which is the "quiet failure" ordering §0 rejects.
- **ADR-062 §3 "Then" vs ADR-001 (:43, :134) and the code.** The last `cleanup:` hook is retired, but teardown's per-stage dispatch loop (plugins/tool/teardown/plugin.sh:190-214), the hook in the plugin contract (ADR-001 still lists `cleanup` as OPTIONAL) and the `plugin.cleanup.*` events (config/event-schema.json:39-42) all remain. ADR-062 says these retire together. The code is between the two steps.
- **ADR-062 §1 text vs its own Implementation Notes (#2024).** §1 still says "the engine writes … at the dispatch chokepoint", while the notes and the code (pg-register-test SPEC-4) say that write is deleted and the creator registers. The decision text was never edited.
- **ADR-062 §2 "release … drops locks" vs the code.** Teardown's release does not touch locks; the issue lock is released by the runner's trap (core/pipeline/runner.sh:2421).
- **ADR-065 Consequences ("ratchet set from the Linux number") vs its own amendments.** Every recorded ratchet is a macOS measurement.
- **PHASE-DEFERRALS table vs GitHub.** Five rows are listed as deferred, but their issues are closed as completed.

