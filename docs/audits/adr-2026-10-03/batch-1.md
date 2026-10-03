# ADR audit — batch 1 (ADR-001 … ADR-015)

Method: for every normative statement, the enforcing assertion was opened and read. "UNTESTED (weak)" = something greps/mentions the rule, or exercises only a helper that no production path calls, but nothing fails if the rule is broken in a real run. Test paths are relative to the repo root.

## ADR-001 — Plugin Contract (Accepted; amended by ADR-042, ADR-054 (#1820/#1823), ADR-055 §1 (#1768), #1900 (recovery kind retired), #1717 (events), ADR-065, #2065 (requires.core))

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Manifest | manifest "REQUIRED" identity fields `id/name/kind/version`; invalid manifest is skipped at discovery | tests/integration/core-plugin-registry-test.sh:91, :102-104 | MEDIUM | |
| Manifest | `kind` ∈ closed set (agent, tool, orchestrator, claim-coordinator, daemon, + persona) | tests/unit/recovery-kind-retired-test.sh:60-61, :103 | MEDIUM | |
| Manifest | optional `summary`/`usage` "must be a non-empty string" if declared | tests/integration/core-plugin-registry-test.sh:505, :522; tests/unit/manifest-validation-doc-fields-test.sh:70 | LOW | |
| Required hooks | `hooks.run` "REQUIRED" (agent/tool/orchestrator); claim-coordinator needs claim/release/heartbeat/list_claims; daemon needs tick | tests/integration/core-plugin-registry-test.sh:240, :256, :272; tests/unit/recovery-kind-retired-test.sh:90-95 | MEDIUM | |
| Required hooks | absent required hook → non-zero + `plugin.run.refused` | tests/unit/plugin-hook-contract-test.sh:154, :160 | MEDIUM | |
| Lifecycle (ADR-056) | no `init`/`finalize` hooks — only `run` and `cleanup` | tests/unit/plugin-hook-contract-test.sh:31, :42 | LOW | |
| Convergence | `convergence: advisory` "must not appear on a must-pass / exit_when path" | tests/unit/lint-contract-convergence-test.sh:132, :168 | HIGH | an advisory member on a must-pass path would block or falsely converge |
| Hook signature | hooks receive `(stage_id, state_file)` positionally | tests/integration/core-plugin-registry-test.sh:207 | LOW | only asserts args pass through |
| Hook signature | run-time context "via env vars … never via positional args" | UNTESTED | LOW | |
| Hook signature | plugins "MUST … return rc=2 if state_file is empty" | UNTESTED | LOW | contradicted by binary rc; see Conflicts C1 |
| Lifecycle | absent `cleanup` emits `plugin.cleanup.absent` and returns rc=0 | tests/unit/plugin-hook-contract-test.sh:111, :113; tests/integration/core-plugin-registry-test.sh:548 | LOW | |
| Lifecycle | `cleanup` is "released by a teardown stage" | plugins/tool/teardown/tests/teardown-schema-test.sh:229 (hook invoked → outcome=ok), :180 (failing cleanup does not fail teardown) | MEDIUM | |
| Lifecycle | state reconstruction on resume is the run preamble's job "(check `ZBUILD_RESUMING=1`)" | UNTESTED | MEDIUM | `ZBUILD_RESUMING` is never set by any code (0 hits in core/scripts/plugins); the runner exports `ZBUILD_RESUME` (tests/unit/resume-default-test.sh:57), which means something else. See C6 |
| Error semantics | plugin rc is "binary" (0/1); legacy codes collapse to 1 | tests/unit/dispatch-rc-test.sh:60-74; tests/unit/dispatch-rc-guard-test.sh:101-106 (pins the legacy rc returns that remain) | HIGH | |
| Error semantics | "`rc=0` with a missing or unparseable result is a structural failure" | tests/integration/leaf-contract-violation-halts-test.sh:106-108 | HIGH | |
| Error semantics | `kind: recovery` retired: gone from ZBUILD_PLUGIN_KINDS, manifest refused, `recovery.*` events removed | tests/unit/recovery-kind-retired-test.sh:40, :60, :84, :111 | LOW | |
| Fail-closed scanner | declared output missing after rc=0 → blocking failure ("Absent evidence IS blocking evidence") | tests/integration/core-plugin-registry-test.sh:391, :398; required:false exemption :578 | HIGH | implemented as a non-zero hook rc, not the "synthetic blocking finding" the ADR describes; Implementation Notes still say "not yet implemented (#288)" (stale) |
| Discovery | manifests found by filesystem glob; walk costs one pass, memo filled in the parent (ADR-065) | tests/unit/discover-plugins-memo-test.sh:37, :49 | LOW | |
| Lockfile | set is recorded in `plugins.lock`; checksum mismatch → "warn by default" | tests/integration/core-plugin-registry-test.sh:125, :145, :167-169 | MEDIUM | |
| Lockfile | `strict_plugin_lock: true` → fail (and do not execute tampered code) | tests/integration/core-plugin-registry-test.sh:152-156 | HIGH | |
| Discovery | `config/plugins.disabled` excludes plugins | tests/integration/core-plugin-registry-test.sh:214-216 | LOW | |
| Cross-plugin deps | `requires.plugins` "enforced at discovery time: the engine refuses to start if a required plugin is missing"; cycles refused | UNTESTED | MEDIUM | **not implemented**: no resolver in core/plugin-registry; the same ADR says (line 310) it "remains unlanded under #1321". See C2 |
| Declared events | a plugin "may NOT emit an event in its own namespace without declaring it" | tests/unit/event-schema-emitted-coverage-test.sh:112-115 | LOW | |
| Declared events | engine schema carries no plugin-owned namespace (ownership rule) | tests/unit/event-schema-emitted-coverage-test.sh:126 | LOW | |
| Declared events | known set = event-schema.json + every manifest's `provides.events` | tests/unit/event-schema-manifest-composition-test.sh:136 | LOW | |
| Declared events | composed once per process and once per run (steady-state emit forks nothing) | tests/unit/event-schema-manifest-composition-test.sh:163, :198-199, :218 | LOW | |
| Declared events | unknown type "is logged and never blocks" | tests/unit/core-event-bus-test.sh:54-61; tests/unit/event-schema-manifest-composition-test.sh:152-153 | LOW | |
| requires.core | vocabulary "CLOSED … anything else is a load-time error" | tests/unit/requires-core-resolution-test.sh:147-152 | MEDIUM | |
| requires.core | `router` declared must be sourced (plugin-loaded) | tests/unit/requires-core-resolution-test.sh:161-199, :204 | HIGH | an unsourced router means the stage reports a degraded verdict rather than failing (#2060-2062) |
| requires.core | `redaction` conditional: satisfied by route.sh (transitively) or scope-redaction.sh; model-reaching plugin with no redactor refused | tests/unit/requires-core-resolution-test.sh:218-234, :258 | HIGH | |
| requires.core | `event-bus`/`state` engine-ambient: runner pre-loads them into the dispatch shell | tests/unit/requires-core-resolution-test.sh:277, :283 | MEDIUM | |
| requires.core | the parser reads through comment and blank lines (#2083) | tests/unit/requires-core-parser-test.sh:157, :166 | MEDIUM | |
| Amend. ADR-042 | stage→plugin resolution is "role-then-id everywhere" | tests/unit/stage-resolution-parity-test.sh:68-90 | HIGH | |
| Amend. ADR-055 | consumer declares the artifact name only; engine resolves it to the single producer | tests/unit/stage-input-resolve-test.sh:196-202 | MEDIUM | |
| Manifest | output `id` "unique across the resolved flow" | tests/unit/contract-validator-output-uniqueness-test.sh:116-119 | MEDIUM | |

## ADR-002 — Legacy Import Strategy (Accepted)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Sentinel | `legacy/scripts/sw` "refuse[s] to run" while `legacy/.shipwright-disabled` exists | .github/workflows/test.yml:19 (CI smoke: `bash legacy/scripts/sw … grep -q disabled`) | MEDIUM | CI-only check; no file under tests/ |
| Sentinel | `SHIPWRIGHT_OVERRIDE_DISABLED=1` "recognized only when the sentinel still exists" | UNTESTED | LOW | legacy/scripts/sw:13 |
| Sentinel | `legacy/FROZEN.md` and the sentinel exist | UNTESTED | LOW | present on disk; nothing fails if removed |
| Freeze | the one-line patch is "the SOLE exception"; every other legacy file "touched only by `git rm`" | UNTESTED | MEDIUM | no lint/CI guard rejects edits under legacy/ |
| Pruning | tombstone `legacy/migrated/<keeper-id>.md` "with one line: `<keeper-id> migrated to <new-path> on <date> (issue #N)`" | UNTESTED (weak) — tests/unit/legacy-e1-tombstone-test.sh:14-25 checks only e-1.md | LOW | code contradicts: all 12 tombstones are multi-line (21-65 lines) in 3 different formats. See C9 |
| Pruning | tombstone + `git rm` "in one commit" | UNTESTED | LOW | process rule |
| Pruning | a deferred keeper's tombstone "MUST cite the relevant issue number" | UNTESTED | LOW | legacy/migrated/security-lens.md says "NOT pruned"; the ADR's Implementation Notes say security-lens is pruned (stale) |

## ADR-003 — Models as Data (Accepted; amended #960/#1230/#1231, #1252, provider modules 2026-09-26)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Decision | code references models "only by tier ordinal T0–T4"; no hardcoded model names | scripts/lib/lint-model-names.sh:18,43 (run by .github/workflows/test.yml:29 and `npm run lint`) | MEDIUM | weak: the regex only catches `claude-haiku/-sonnet/-opus`, `gpt-N`, `llama-N`, `mistral-`. A bare `sonnet` passes. The lint has no test of its own |
| Manifest | "A plugin that names a model directly fails manifest validation" | UNTESTED | LOW | validate_manifest has no model check; only the CI lint above catches `claude-*` in plugins/*.yaml |
| Router contract | `route(tier, complexity, budget_state) → {model_id, provider, fallback_chain}` is "the single API" | UNTESTED | LOW | code contradicts: `route_to_model <tier> <prompt> [--model]` (core/router/route.sh:135); no complexity, budget_state or fallback_chain |
| Tiers | tier must match `^T[0-4]$` | tests/unit/tier-resolve-test.sh:59, :62 | LOW | |
| Tiers | T0 = "Skip LLM entirely" (agent-booster) | UNTESTED | LOW | route.sh:153 returns rc=2 "T0 not implemented" |
| Migration | `weight: 0` on a candidate "gracefully drain[s] it" | UNTESTED | MEDIUM | code contradicts: the router always takes `candidates[0]` (core/router/route.sh:4, :681). Weight is ignored, so a drained model keeps running |
| Migration | a model change edits `config/models.json` only and bumps `version` | UNTESTED | LOW | the file's key is `schema_version` |
| Tier SoT | a plugin's tier "lives in exactly one place": `config.tier_default`; no `${ZBUILD_*_TIER:-T?}` literal in plugin.sh | tests/unit/impact-tier-test.sh:41, :64 | MEDIUM | |
| Tier SoT | precedence: env `ZBUILD_<ID>_TIER` > template `router.tier` > manifest > fail loud | tests/unit/tier-resolve-test.sh:37, :96-108, :51 | MEDIUM | |
| Tier SoT | "no central stage→tier map in the engine" | UNTESTED | LOW | |
| Provider §1 | candidate names `{provider, family}`; an `id` pin wins; models.json carries no prices | tests/unit/router-provider-modules-test.sh:84, :89, :135-139 | MEDIUM | |
| Provider §2 | a tier naming a provider with no module "fails loudly (rc=2)" | tests/unit/router-provider-modules-test.sh:94-95 | MEDIUM | |
| Provider §3 | anthropic resolves to the family alias; router always requests the JSON envelope and unwraps `.result` | tests/unit/router-provider-modules-test.sh:84, :103-104 | MEDIUM | |
| Provider §4 | "Cost is recorded for every call": single-shot, each loop iteration, billed failures; `model_used` rides `model.outcome` | tests/unit/router-provider-modules-test.sh:101, :124, :131, :102 | HIGH | `cost_usd` on `model.outcome` is not asserted |
| Provider §5 | "An unknown cost is never 0": `router.cost.unknown`; under a cap further calls are refused | tests/unit/router-provider-modules-test.sh:110, :112, :114 | HIGH | |
| Provider §6 | price tables live only in the provider module | UNTESTED | LOW | |

## ADR-004 — Redaction Chokepoint (Accepted; superseded in part by ADR-043; amended for #467 and ADR-039)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Chokepoint | "one function" emits LLM-bound text; no raw `claude`/`curl…anthropic` outside core/redaction and core/router | tests/unit/redaction-chokepoint-test.sh:111-114 (scanner), :162 (sentinel proves the scanner fires) | HIGH | |
| Signature | `apply_scope_redaction <text_var> <scope_manifest_path> <allowlist_csv> <cycle_id>` | UNTESTED | LOW | code contradicts: `<input> <output> <manifest> [allowlist] [cycle_id]` (core/redaction/scope-redaction.sh:40) |
| Behaviour 1 | "Refuse to emit" if the manifest is unset, empty or unreadable; return non-zero | tests/unit/core-redaction-test.sh:31, :37, :44; core/redaction/tests/scope-redaction-unit-test.sh:33-37 | HIGH | |
| Behaviour 1 | the refusal emits a blocking event | UNTESTED (weak) | MEDIUM | tests/unit/engine-event-shape-test.sh:156 emits `redaction.refused` itself and checks the shape; nothing asserts the redactor emits it. The router path is covered: tests/integration/router-precondition-test.sh:128 |
| Behaviour 2-3 | out-of-allowlist paths are wrapped in `<out-of-scope-context>`; code fences preserved verbatim | tests/unit/core-redaction-test.sh:57-63, :82-92 | HIGH | |
| Behaviour 4 | `redaction.applied` emitted with `{prompt_size, redactions_count, scope_hash, cycle_id}` | core/redaction/tests/scope-redaction-unit-test.sh:69 (event); tests/integration/router-precondition-test.sh:156 (scope_hash) | LOW | payload keys in code are `size_before/size_after/redactions/scope_hash/cycle` (scope-redaction.sh:272-279). tests/golden/redaction-applied-shape.golden pins only `{"event","version"}` |
| Behaviour 5 | idempotent: running twice gives identical output | tests/unit/redaction-idempotence-test.sh:44; tests/unit/core-redaction-test.sh:106 | MEDIUM | |
| Enforcement | a `kind: agent` without `requires.core: [redaction]` is refused | tests/integration/core-plugin-registry-test.sh:91, :320, :345; tests/unit/requires-core-resolution-test.sh:345 | MEDIUM | |
| Enforcement (ADR-043) | every `model.route` is preceded by `redaction.applied` for the same run_id+stage; the router redacts if the plugin did not | tests/integration/router-precondition-test.sh:49-53, :97-107 | HIGH | |
| Enforcement | `route_to_model[_loop]` is "the ONLY model-call path" | tests/unit/redaction-chokepoint-test.sh:111 | HIGH | same scanner as row 1 |
| Enforcement | fail closed with no run_id or no events log | tests/integration/router-precondition-test.sh:64, :76, :126-132 | HIGH | |
| Stage-level | T0 stages (`test`, `pr`, `deploy`, `validate`) "MUST never emit LLM-bound text" | UNTESTED | MEDIUM | `pr` is now `pr-delivery`, `kind: agent`, `tier_default: T2` (plugins/agent/pr-delivery/manifest.yaml:3,31). See C4 |
| Scope manifest | the fenced `scope` block in design.md is the allowlist | tests/unit/scope-manifest-b1-regression-test.sh:32-62 | HIGH | |
| Override | override needs `ZBUILD_SCOPE_OVERRIDE=1` and a token file equal to the run_id; emits `redaction.refused.overridden` | UNTESTED (redactor branch, scope-redaction.sh:52-60) | HIGH | only the router's `--skip-precondition` override is tested (router-precondition-test.sh:199-226). No test proves the redactor refuses a stale or mismatched token, and that branch copies the input unredacted |
| Override | the token is "one-shot" and carries "operator-identifying metadata"; "the agent CANNOT self-grant" | UNTESTED | MEDIUM | code: the token is never consumed or deleted, and the event carries only run_id and input |
| Amend. #467 | `route_to_model_loop` emits `redaction.applied` "on EVERY iteration" | UNTESTED | HIGH | implemented at core/router/route.sh:1776, but every loop test (core-router-loop-banner-test.sh:37, build-loop-banner-test.sh:29, build-changed-files-summary-test.sh:33) sets the operator override to bypass it |
| Amend. ADR-039 | the C6 check is per (run_id, stage); a member cannot ride a sibling's redaction | tests/integration/router-precondition-parallel-test.sh:85, :101-126 | HIGH | |
| Amend. ADR-039 | `eb_emit_event` stamps `stage` when `ZBUILD_CURRENT_STAGE` is set | tests/integration/router-precondition-parallel-test.sh:108, :126 | MEDIUM | |

## ADR-005 — Claim Coordinator Plugin (Accepted)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Decision | claim coordination is a `kind: claim-coordinator` plugin; "the engine has no built-in mechanism" | tests/e2e/claim-race-test.sh:51 (manifest validates as claim-coordinator) | LOW | |
| Contract | `claim` emits `{"acquired": bool, "lease_id"}` | tests/e2e/claim-race-test.sh:108-115, :147 | MEDIUM | the e2e test is `skip_unless_platform linux` (line 31), so it never runs on macOS |
| Contract | hook names are `<plugin-id>_<verb>` (e.g. `github_labels_claim`) | UNTESTED | LOW | code contradicts: `claim_coordinator_claim` etc. (plugins/claim-coordinator/github-labels/manifest.yaml:19-22) |
| Default | race → at most one winner; losers remove their label | tests/e2e/claim-race-test.sh:132-134, :159-165 | MEDIUM | runs against the `local-fs` flock backend (claim-race-test.sh:37), not the gh-label TOCTOU path |
| Default | `release` removes `claimed:<host>`; `heartbeat` is a no-op rc=0; `list_claims` lists | plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh:55-58, :69; tests/e2e/claim-race-test.sh:180, :200 | LOW | |
| Default | backoff 300-1100 ms, then re-verify exclusivity | UNTESTED | LOW | |
| Selection | `claim_coordinator:` in config/zbuild.yaml picks the plugin | UNTESTED | LOW | not implemented (no reader in core/scripts) |
| Selection | "The engine refuses to start with multiple claim-coordinator plugins enabled" | UNTESTED | MEDIUM | not implemented: no such check in core |
| Consequences | every coordinator's `init` self-tests its consistency assumptions | UNTESTED | LOW | `init` hooks were deleted by ADR-056. See C5 |

## ADR-006 — Resume Contract (Accepted; amended for ADR-020 preflight_failed, ADR-021 cycle_iterations, #909/#946 atomic_replace)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Persisted | `current_iteration` is persisted and survives resume ("fixes legacy resume gap") | UNTESTED (weak) — tests/unit/core-state-test.sh:34-39 exercises `increment_iteration` | HIGH | nothing in core/scripts/plugins calls `increment_iteration` or writes `.current_iteration`; it is initialised to 0 (core/state/resume.sh:73) and never moves. The test is green but proves nothing about a run |
| Persisted | `scope_manifest_hash`, `cost_ledger_pointer`, `claim_lease_id`, `self_heal_count`, `plugin_state` survive | UNTESTED | MEDIUM | only initialised to empty/0 in init_state (resume.sh:73-77); no production writer |
| Persisted | `events_db` SQLite mirror of the event log | UNTESTED | LOW | not implemented |
| Atomic write | write via temp + `mv` + `.bak` rotation; corrupt read recovers from `.bak` | tests/unit/core-state-test.sh:44-65; tests/unit/scripts-lib-atomic-replace-test.sh:81-87, :134-142 | HIGH | |
| Atomic write | disk-space precheck, `flock` on a sidecar, `fsync` | UNTESTED | LOW | |
| Resume seq 1 | load fails → try `.bak` → if `.bak` fails, refuse (fail closed) | tests/integration/state-corruption-failclosed-a-test.sh:310 | HIGH | |
| Plugin resp. | every manifest "MUST declare" `state.persisted`/`state.reconstructed`; engine validates a `write_plugin_state` call per persisted key | UNTESTED | MEDIUM | not implemented: `write_plugin_state` and `read_plugin_state` do not exist anywhere |
| Plugin resp. | missing reconstructed key → "plugin refuses to run" / engine refuses to resume | UNTESTED | MEDIUM | not implemented |
| Idempotency | external side effects in `run` "MUST be guarded by a sentinel key in persisted state" | UNTESTED | MEDIUM | |
| Resume seq 3 | plugins run with `ZBUILD_RESUMING=1` | UNTESTED | MEDIUM | not implemented (see ADR-001 row and C6) |
| Resume seq 4-5 | engine emits `pipeline.resume`; continues from the first incomplete stage, skipping complete ones | tests/integration/pipeline-resume-test.sh:252-259; tests/integration/resume-after-sigint-test.sh:231-257 | HIGH | |
| Impl. note | in_progress <24h → `auto_resume`, else `manual_resume_only`; empty `updated_at` → manual | tests/integration/resume-24h-boundary-test.sh:62-90 | MEDIUM | |
| Amend. ADR-020 | enforce-mode contract failure writes `status: preflight_failed` | tests/unit/contract-validator-enforce-mode-test.sh:61; tests/unit/core-pipeline-contract-validator-test.sh:214 | MEDIUM | |
| Amend. ADR-020 | `preflight_failed` is "NOT resumable"; resume should show a "fix the contract first" hint | UNTESTED | LOW | get_resume_recommendation falls into the `*` arm → `fresh_start` (core/state/resume.sh:282); no hint |
| Amend. ADR-021 | `cycle_iterations` added on write via `(.cycle_iterations //= {})` | UNTESTED | LOW | |
| Amend. ADR-021 step 3.5 | mid-cycle resume: re-validate the last artifact, emit `cycle.iter.stale_artifact`, rehydrate history, fail closed with `cycle.history.lost` | UNTESTED (weak) — tests/unit/core-pipeline-cycle-events-test.sh:30 only checks the name is registered | HIGH | `cycle.iter.stale_artifact` has no emitter; there is no rehydration path in cycle-orchestrator.sh. `cycle.history.lost` is emitted only on a history *write* failure (cycle-orchestrator.sh:467,472). A kill -9 mid-cycle restarts the cycle |
| Amend. #909/#946 | `.bak` rotation and restore via `atomic_replace`; failed restore fails closed | tests/unit/scripts-lib-atomic-replace-test.sh:83, :136; tests/unit/core-state-test.sh:62-65 | HIGH | |

## ADR-007 — Test Strategy (Accepted)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Pillar 1 | co-located plugin tests: `*-unit-test.sh` → unit tier, other `*-test.sh` → integration | UNTESTED | MEDIUM | implemented at scripts/run-tests.sh:596-607; a regression would silently drop the co-located tests |
| Pillar 1 | "Every test file is idempotent on re-source" (`_<name>_TEST_LOADED` guard) | UNTESTED | LOW | code contradicts: 0 test files carry the guard. The harness instead refuses nested runs (tests/unit/test-helpers-reentry-guard-test.sh:41) |
| Pillar 1 | the master cleanup trap kills children; tests cannot leak | tests/unit/test-helpers-cleanup-test.sh:58-78 | MEDIUM | |
| Pillar 2 | goldens are checked "every CI run" | .github/workflows/test.yml:235-241 (golden job), :307 (required by the summary) | MEDIUM | |
| Pillar 2 | update flow `ZBUILD_UPDATE_GOLDEN=1` | UNTESTED | LOW | the variable is actually `UPDATE_GOLDEN` (scripts/lib/golden.sh:13) |
| Pillar 2 / CI | "workflow comment lists changed golden files" | UNTESTED | LOW | not implemented |
| Pillar 3 | 5-test trial checklist in `.github/issues/keepers-manifest.yaml`; trial gates `git rm` | UNTESTED | LOW | process gate |
| CI | per PR: lint, unit, golden; nightly: full E2E | UNTESTED (weak) | LOW | e2e actually runs on every PR (test.yml:194-208); there is no nightly schedule |
| Claim race | "assert exactly one wins"; runs on PRs touching claim-coordinator | tests/e2e/claim-race-test.sh:132 | MEDIUM | the test asserts ≤1 winner, not exactly one, and is Linux-only |

## ADR-008 — Dependency Policy (Accepted)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Actions | pin to a major version (`@vN`), "not SHA or minor" | UNTESTED | LOW | scripts/lib/lint-action-versions.sh enforces *consistency* only and accepts SHA pins (tests/unit/lint-action-versions-test.sh:113) |
| Actions | one action, one version across workflows (implied by "latest stable major") | tests/unit/lint-action-versions-test.sh:50, :150 | LOW | |
| Actions | Dependabot weekly PRs, limit 5, no auto-merge | UNTESTED | LOW | .github/dependabot.yml matches |
| Node | CI runs Node LTS (22) | UNTESTED | LOW | code contradicts: no workflow uses setup-node or node-version |
| Node | `engines.node` declares the minimum (`>=20.0.0`) | UNTESTED | LOW | matches package.json:26 |
| npm | `package-lock.json` committed | UNTESTED | LOW | absent, but there are no npm deps, so it is moot today |
| Enforcement | quarterly audit / pre-release `gh run list` review | UNTESTED | LOW | process |


## ADR-009 — Platform-Aware Modularity (Accepted; resolution fallback effectively amended by ADR-042 §2, not recorded in the header)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| 1 | `platform`, `provides.role`, `detect.signals` are all **optional**; a plugin with no `platform` is generic | tests/unit/core-pipeline-resolver-test.sh:40, :62 | LOW | |
| 1 | `platform_overrides:` gives per-platform config "without forking" | UNTESTED | LOW | Not implemented: nothing in core/, scripts/ or plugins/ reads `platform_overrides`. |
| 3 | Resolver: a plugin whose `platform ==` the requested platform **wins over** the generic one | tests/unit/core-pipeline-resolver-test.sh:52 | MEDIUM | |
| 3 | No platform match → fall back to the generic (`platform` null) plugin | tests/unit/core-pipeline-resolver-test.sh:62 | MEDIUM | |
| 3 | No match → emit `registry.role-unresolved`, rc=1 | tests/unit/core-pipeline-resolver-test.sh:70, :82 | LOW | |
| 3 | Tie on `(role, platform)`: **highest `version` wins** | tests/unit/core-pipeline-resolver-test.sh:94 | MEDIUM | |
| 3 | Version tie: alphabetical `id` wins **"with a warning"** | id order: tests/unit/core-pipeline-resolver-test.sh:106; warning: UNTESTED | LOW | The code never warns: core/pipeline/resolver.sh:46-48 has no warn/emit. |
| 4 | Default stage strategy is **`fanout`** | tests/unit/core-pipeline-template-test.sh:159, :162 | MEDIUM | |
| 4 | Strategy can be overridden per stage | tests/unit/core-pipeline-template-test.sh:174, :178 | LOW | |
| 4 | `fanout` runs the role **once per detected platform** | tests/integration/core-pipeline-runner-test.sh:313 | MEDIUM | |
| 4 / Impl | Each fanout/sequential invocation gets **`ZBUILD_PLATFORM=<p>`** | tests/integration/strategy-platform-env-test.sh:60, :74 | MEDIUM | Only checks the generated work-unit text. |
| 4 | `sequential` halts on the first failure **only if `per_platform_halt_on_fail: true`** | UNTESTED (weak) | MEDIUM | The code always halts (core/pipeline/strategies/sequential.sh:2, :57-62), and the flag exists nowhere in the code. tests/unit/core-pipeline-strategy-test.sh:229 only checks rc≠0 and never checks that the next platform is skipped. |
| Impl | `composite` → the runner **exits with an error** | tests/unit/core-pipeline-strategy-test.sh:250, :283, :294; tests/integration/core-pipeline-strategy-test.sh:353 | LOW | |
| Auto-det | Detection runs before any stage and **writes `state/platforms.json`** | tests/unit/core-detect-platforms-a-test.sh:107, :111 | LOW | Nothing tests that it runs *before* the stages. |
| Auto-det | Signals are ranked by strength (**high > medium > low**) | UNTESTED (weak) | MEDIUM | tests/unit/core-detect-platforms-b-test.sh:249 only checks that `ios` is present. Its own comment says it is "only meaningful once the engine enforces strength-based ranking". |
| Auto-det | Tie → emit a **`detection.conflict`** event | tests/unit/core-detect-platforms-b-test.sh:265, :358 | LOW | |
| Auto-det | Tie plus a config override → the override wins and no conflict event is emitted | tests/unit/core-detect-platforms-b-test.sh:290-297 | LOW | |
| Auto-det | Unknown platform → **"warn + skip the folder"** unless `fallback_platform` is set | fallback set: tests/unit/core-detect-platforms-b-test.sh:192; skip: CONTRADICTED | LOW | The code returns `generic` when nothing is detected (core/detect/platforms.sh:424-430), and tests/unit/core-detect-platforms-a-test.sh:59 asserts `generic`. Detection is whole-repo (`find -maxdepth 3`), not "folder-by-folder". |
| Cost | **Per-platform cost ceilings** enforced, so one platform hitting its cap doesn't downgrade others | UNTESTED | MEDIUM | Not implemented: `cost_overrides` and `max_tokens_per_stage` appear only in tests. core-detect-platforms-b-test.sh:213 only checks that the key parses with rc=0. |
| Impl cache | `platforms.json` SHA == HEAD → **return the cached result without re-walking** | tests/integration/core-pipeline-runner-test.sh:313 (indirect: a pre-seeded 2-platform cache must be honoured) | MEDIUM | |
| Impl cache | Config overrides still apply on a cache hit | tests/unit/detect-platforms-signals-test.sh:357 | LOW | |
| CLI | `--platform-override <p>` / `ZBUILD_PLATFORM_OVERRIDE` forces a single platform | tests/integration/cli-platform-scope-flags-test.sh:42 | LOW | |
| Back-compat 1 | Stage has **no roles** → direct stage-id match (`_find_plugin_for_stage`) | UNTESTED (weak) | LOW | tests/unit/core-pipeline-dispatch-test.sh §7 tests `_find_plugin_for_stage` directly, not the no-roles path of `resolve_stage_plugin` or the leaf path. |
| Back-compat 2 | Roles are declared but **none resolve → fall back to id match** | CONTRADICTED: tests/unit/stage-resolution-parity-test.sh:115 and tests/unit/template-resolvability-preflight-test.sh:295 assert the opposite (fail-closed) | HIGH | See Conflicts C1. The leaf path still follows ADR-009 (core/pipeline/runner.sh:3875-3890), the cycle/parallel path follows ADR-042. |
| Impl (stale) | "`detect.signals` in manifests — deferred" | n/a | — | Out of date: core/detect/platforms.sh:38-170 parses `detect.signals`. |

## ADR-010 — CI / CLI Parity (Accepted; bootstrap/teardown and the cache backend deferred to Phase 1)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| 1 | The CI lifecycle is **always** `zbuild bootstrap` → `pipeline start` → `zbuild teardown` | UNTESTED | LOW | Not implemented: scripts/zbuild has no `bootstrap` or `teardown` verb. ADR-054 §7's teardown *stage* and `zbuild clean` are a different thing. |
| 1 | Bootstrap validates prereqs, the plugin lockfile and auth | UNTESTED | LOW | Deferred. |
| 1 | Teardown snapshots state, uploads artifacts and renders the step summary | UNTESTED | LOW | Deferred. |
| 2 | Cache backend picked from `.zbuild/cache.yaml` (or env); **falls back to `local`** | default: tests/unit/core-config-load-test.sh:49 | LOW | `.zbuild/cache.yaml` is never read. Selection is `backends.cache` in config.yaml or `ZBUILD_CACHE_BACKEND` (core/cache/contract.sh:74-86). |
| 3 | `stdout` destination **always** | tests/unit/core-output-destinations-test.sh:55 | LOW | |
| 3 | `state/report-<run_id>.md` **always** | tests/unit/core-output-destinations-test.sh:66, :68 | LOW | |
| 3 | `gh-pr-comment` when `ZBUILD_ISSUE` is set: **one comment per run, edited in place** (run-status-comment.sh) | in-place: tests/unit/run-status-comment-gh-test.sh:85-86, :94-95; gating: tests/unit/core-output-destinations-test.sh:87-90, :208 | MEDIUM | The `emit_output` destination posts a *new* comment on every call (core/output/destinations.sh:58, `gh issue comment`). See C3. |
| 3 | `gh-check-run` when in Actions **and `ZBUILD_EMIT_CHECK_RUN=true`** | off by default: tests/unit/core-output-destinations-test.sh:154; on-path UNTESTED | LOW | The code gates on `ZBUILD_OUTPUT_GH_CHECK_RUN=1` (core/output/destinations.sh:66), not the env var the ADR names. |
| 3 | `step-summary` when `$GITHUB_STEP_SUMMARY` is set | tests/unit/core-output-destinations-test.sh:118, :132 | LOW | |
| 3 | Output goes through a **`kind: tool` plugin `output-destinations/`** | UNTESTED | LOW | Lives in core/output/destinations.sh and is called by plugins/tool/output-github-comment (role `output`). No template in config/templates names that role, so it is unreachable in default runs. |
| Ctx | Same command → **same state, artifacts and event sequence** locally and in CI | tests/e2e/parity-local-vs-ci-test.sh:73, :78, :108, :150, :200 | HIGH | Tested. CI mode is simulated with `GITHUB_ACTIONS=true CI=true`. |
| Plat | The CI workflow **does NOT inspect the target repo's platform** | UNTESTED | LOW | |
| Wf | Two reusable composite actions (`bootstrap`, `teardown`) ship with zBuild | UNTESTED | LOW | Not implemented: `.github/actions/` does not exist. |

## ADR-011 — Pluggable Backends (Memory, Orchestrator, Cache) (Accepted; Retention amended 2026-08-22)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Dec | A backend is a `kind: tool` plugin with `provides.role: memory-backend` / `orchestrator-backend` / `cache-backend` | UNTESTED (weak) | LOW | tests/integration/core-config-backends-test.sh:58, :67 only exercise `find_plugin_for_role` alias matching. |
| Mem | Backend implements the 6 required fns (`memory_put/get/search/list_namespaces/namespace_exists/namespace_clear`) | tests/unit/core-memory-contract-test.sh:151; tests/integration/core-memory-contract-test.sh:145-286 | MEDIUM | Both run against **mock-memory** only. The default `memory-sqlite` backend's contract behaviour is untested; tests/unit/plugin-memory-sqlite-rc-test.sh only checks the init rc. |
| Mem | Optional fns: **callers MUST handle their absence** | UNTESTED (weak) | LOW | tests/unit/core-memory-contract-test.sh:175 tests a capability missing from the list, not a missing `memory_capabilities` function (core/memory/contract.sh:24). |
| Mem | Default memory = SQLite at `~/.zbuild/state/memory.db` | default name: tests/unit/core-config-load-test.sh:47; path UNTESTED | MEDIUM | The code prefers `${ZBUILD_STATE_DIR}/memory.db` (plugins/tool/memory-sqlite/plugin.sh:43-44), and the runner exports ZBUILD_STATE_DIR (core/pipeline/runner.sh:2141). See C5. |
| Orch | `orch_collect` exits **0 all-pass / 1 all-fail / 2 partial — "all implementations must honour this"** | mock only: tests/integration/core-orch-contract-test.sh:71, :95, :154 | MEDIUM | Untested for orch-sequential, orch-bash-parallel (core/orch/local_engine.sh:149-153) and orch-ruflo-hive. No test drives a real backend to rc=2, and none checks the runner's `reason=partial`. |
| Orch | Phase 0.5 **default orchestrator = `orch-sequential`** | CONTRADICTED | MEDIUM | core/config/config.sh:11 defaults to `bash-parallel`, and tests/unit/core-config-load-test.sh:48 asserts `bash-parallel`. See C4. |
| Cache | `cache_pull <key> <dest_dir>` / `cache_push <key> <src_dir>`; a miss prints `CACHE_MISS` and returns 0 | tests/unit/core-cache-contract-test.sh:54-55, :81-82; tests/integration/core-cache-local-test.sh:92-95 | MEDIUM | |
| Cache | Default cache = `local` under `$ZBUILD_CACHE_DIR` | tests/unit/core-config-load-test.sh:49; tests/unit/core-cache-contract-test.sh:81 | LOW | |
| Sel | Model routing is **not** a selectable backend (ADR-003) | UNTESTED | LOW | |
| Sel | A selected but missing backend → **`zbuild doctor` flags it** | UNTESTED (weak) | LOW | tests/integration/core-config-backends-test.sh:91 checks that `zbuild_config_validate_backends` warns, which runs from config init (core/config/config.sh:117), not from doctor. |
| Degr 2 | `fallback_to_default_on_error: true` → fall back and emit **`backend.degraded`**; **false → hard-fail with a clear error** | UNTESTED | HIGH | No test mentions `backend.degraded`. Memory reads env `ZBUILD_MEMORY_FALLBACK`, not the declared key, and on "false" it warns and returns 0 (core/memory/contract.sh:63-76). Orch and cache *always* fall back silently with no event (core/orch/contract.sh:175-181; core/cache/contract.sh, `_zbuild_cache_load_backend` "falling back to local"). See C2. |
| Degr 3 | Capabilities are declarative; callers choose a code path from `<backend>_capabilities` | tests/unit/core-memory-contract-test.sh:165, :175; tests/unit/core-cache-contract-test.sh:37, :45 | LOW | |
| Manifest | `requires.bin: [...]` = required binaries | UNTESTED | LOW | Not enforced anywhere in core/ (plugins/tool/memory-ruflo/manifest.yaml:10 declares it). |
| Manifest | `zbuild plugin list --role memory-backend` | UNTESTED | LOW | Not implemented (no `--role` in scripts/zbuild). |
| Ret | Cache is reclaimable by `zbuild cleanup --cache`, aged from last touch | tests/unit/cleanup-new-reclaimers-test.sh:187, :189 | LOW | |
| Ret | **The memory store is NEVER reclaimed**; no cleanup target may name it | tests/unit/cleanup-new-reclaimers-test.sh:197 (textual grep of scripts/lib/cleanup.sh) | HIGH | The test is textual, and the store's actual location can be a reclaimable run state dir (C5). It would pass while the store is deleted. |

## ADR-012 — Test Tiering and CI Gating (Accepted; amended #1129 lint tier, #1184 mutation harness, #1761 coverage denominator)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Tiers | unit = single-module, **no subprocess**, no FS outside tmp, **<1s/test** | UNTESTED | LOW | Widely violated. For example tests/unit/run-tests-tier-concurrency-test.sh spawns run-tests.sh and needs serial ≥3s (:104-114). |
| Tiers | integration <10s/test; e2e = full `scripts/zbuild` CLI, no real network | UNTESTED | LOW | tests/e2e/parity-local-vs-ci-test.sh runs a fixture script, not the CLI. |
| Name | `tests/<tier>/<area>-test.sh` | UNTESTED | LOW | run-tests.sh also discovers `core/**/tests/*-test.sh` and plugin tests (scripts/run-tests.sh:~600-619). Plugin `*-test.sh` lands in integration. |
| Runner | `run-tests.sh --tier {unit,integration,e2e,golden,mutation,lint,all}`; output **`<tier>: N/M passed`** | tests/unit/run-tests-tier-concurrency-test.sh:133, :250 | MEDIUM | N/M counts files, not assertions. |
| Runner | Any failing tier → `--tier all` exits non-zero | tests/unit/run-tests-tier-concurrency-test.sh:151, :153 | HIGH | |
| Amend #1129 | `--tier all` **includes `lint`**, and **a lint failure fails the suite** | lint present: tests/unit/run-tests-tier-concurrency-test.sh:133; lint-failure path UNTESTED | MEDIUM | Every test stubs `ZBUILD_LINT_CMD=true`, so none forces lint to fail. simple.yaml dropped its lint gate on the strength of this rule. |
| Golden | `assert_golden` in scripts/lib/golden.sh; `UPDATE_GOLDEN=1` regenerates | UNTESTED (weak) | LOW | tests/unit/run-tests-tier-concurrency-test.sh:238 only checks that stdout matches serial mode. |
| Mut | One doc per core file, named **`<file>-mutations.md`** | UNTESTED | LOW | Violated: tests/mutation/cache.md, event-bus.md, orch.md, memory.md and others. |
| Mut | The mutation tier "**validates doc structure (not behavior)**" | structural: tests/integration/mutation-parallel-equivalence-test.sh:151 | LOW | Contradicted by the #1184 amendment in the same ADR and by the code: `--tier mutation` runs scripts/run-mutation.sh, which applies mutants in worktrees (scripts/run-tests.sh:816). |
| Mut #1184 | Bounded-retry the worktree add and verify `## File` before patching | UNTESTED | LOW | |
| Mut #1184 | `infra` outcome **excluded from the score and exit code**, on its own line, never verdict=fail | tests/integration/mutation-infra-nonfatal-test.sh:118, :120, :122, :140 | MEDIUM | |
| Cov | Floor **29%** on core/ + scripts/lib/, enforced by check-coverage.sh in CI | gate arithmetic: tests/unit/coverage-untraced-file-test.sh:156, :159; floor value UNTESTED | MEDIUM | 29 lives only in .github/workflows/test.yml:281. check-coverage.sh:10 defaults to **70**. Nothing pins the value. |
| Cov #1761 | Denominator enumerated **from disk**; legacy/ excluded | tests/unit/coverage-untraced-file-test.sh:85, :143-149 | MEDIUM | |
| Cov | "`kcov` over **unit + integration** tiers" | CONTRADICTED | LOW | check-coverage.sh uses an xtrace over `--tier unit` only (scripts/check-coverage.sh:19). |
| Cov #1129 | Coverage is **NOT** in `--tier all`; the CI `coverage` job enforces it | UNTESTED | LOW | |
| CI | `coverage` needs unit+integration; `summary` needs all Tier-1 jobs | UNTESTED | LOW | Matches .github/workflows/test.yml:269, :307, but nothing pins it. |
| Empty | An empty tier **passes green with a warning annotation** | UNTESTED (weak) | LOW | scripts/run-tests.sh:623 prints `(empty tier)`, rc 0, with no annotation. Only the mutation 0/0 path is tested (run-tests-tier-concurrency-test.sh:135). |
| Neutral | `tests/run-all.sh` / `run-unit.sh` delegate to run-tests.sh | UNTESTED | LOW | True by inspection (tests/run-all.sh exec line). |
| e2e | Real-Claude e2e out of scope until a budget-capped, labelled workflow exists | UNTESTED | LOW | |

## ADR-014 — Backend Contract Init Timing: Eager Auto-Load (Accepted)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Dec | `memory/contract.sh` **calls `_memory_load_backend` at file end** (eager) | UNTESTED | LOW | Every memory test calls `memory_init` right after sourcing (tests/unit/core-memory-contract-test.sh:144; tests/integration/core-memory-contract-test.sh:138), so a revert to lazy loading stays green. |
| Dec | `memory_init` kept as an **idempotent** wrapper | UNTESTED (weak) | LOW | tests/unit/core-memory-contract-test.sh:237 only checks rc=0 on the second call. |
| Dec | Backend load failures are **non-fatal** (warn and degrade to stubs); sourcing never kills the caller | UNTESTED | MEDIUM | Conflicts with ADR-011 Degr 2 (C2). Because the load never fails, `memory_init \|\| exit 2` at core/pipeline/runner.sh:43 is dead. |
| Impl | `_ZBUILD_MEMORY_INITIALIZED` prevents double init | UNTESTED (weak) | LOW | tests/unit/core-memory-contract-test.sh:267 only checks that the flag is 1. |
| Cons | All three contracts auto-load at source time | cache: tests/unit/core-cache-contract-test.sh:37 (implicit, no init call); orch: UNTESTED; memory: UNTESTED | LOW | The orch tests pre-source orch-mock before the contract, so they bypass auto-load. |
| Cons | A fourth backend contract **must** use the eager pattern | UNTESTED | LOW | |


## ADR-013 — Canonical Stage List (Accepted; enumeration DEMOTED by ADR-047 §5 #1277; amended by ADR-046, ADR-037 §6, ADR-054 §10, #757, #1208, #2188; lifecycle hooks superseded by ADR-056)

Most of this ADR is now historical: the closed 15/16/18-entry `_ZBUILD_CANONICAL_STAGES` list, the kind/tier/expected_artifact table, the CQ stages (no `cq-*` plugin exists), `test_assessment`, `objective-gate`, phase gating, and the `init`/`finalize` hook column all describe things that were retired or never built. Only the clauses below still read as live rules. Superseded clauses that the code now contradicts are listed under Conflicts.

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Stage sequence / Template integration 1 (as re-expressed by ADR-047 §5) | an unknown or unresolvable leaf id in a template "errors at load" (non-zero rc, names the id) | tests/unit/template-resolvability-preflight-test.sh:130-132 | HIGH | The template layer itself now ACCEPTS unknown ids (tests/unit/core-pipeline-template-test.sh:207, "[no fence]"). Rejection moved to the runner preflight. |
| Template integration 2 | leaf stages "must appear in the same relative order as the canonical sequence" | UNTESTED (superseded) | — | Replaced by the upstream-input DAG check (ADR-047 §5 / ADR-055 §5). ADR-047 accepts a swap of independent stages as a known gap. |
| Stage sequence | templates "may omit stages (subtractive composition)" | tests/unit/template-simple-yaml-test.sh:207-215 (simple.yaml loads a subset) | LOW | Implicit only: no test names this as the rule. |
| Fail-closed rule | plugin exits 0 but a declared output "does not exist or is empty" → engine fails the stage | tests/integration/artifact-contract-test.sh:184-203 (synthetic blocking finding, `plugin.contract.violated`); tests/unit/lifecycle-required-output-test.sh:48,84; tests/unit/artifact-enforcement-survives-retirement-test.sh:95-99 | HIGH | The mechanism is tested, but the event names differ from this ADR: the code emits `plugin.artifact.missing` / `plugin.contract.violated`, not `stage.fail reason=missing_artifact`. |
| Fail-closed rule (#2252, code) | a stage reporting an unfinished disposition is exempt from the output check | UNTESTED in this audit's sweep (lifecycle.sh:492-499) | MEDIUM | This exemption is not written in the ADR. It belongs to ADR-054. |
| Canonical vs secondary (#361) 2 | every `outputs[]` path is enforced for existence on a 0-exit run (`scan_plugin_outputs`) | tests/unit/lifecycle-required-output-test.sh:48,136,213 | HIGH | `required: false` is exempt (core/plugin-registry/lifecycle.sh:79-85). The ADR does not mention this exemption. |
| Canonical vs secondary 2 | secondary artifacts "MUST NOT appear in `provides.artifact_type`" and "no downstream stage wiring is allowed to depend on them" | UNTESTED | MEDIUM | Code reads a secondary `pr-result.json` across plugins: plugins/tool/merge/plugin.sh:97, and pr-delivery reads pr-open's (#2250). |
| Canonical vs secondary 3 | the canonical artifact "MUST be the first entry in `outputs[]`"; `_check_artifact_contract` reads the first `outputs[].path` | UNTESTED; contradicted | — | `_check_artifact_contract` is retired (tests/unit/artifact-enforcement-survives-retirement-test.sh:136). `primary: true` replaces first-entry. pr-open's first output is `pr_open_errors` (plugins/tool/pr-open/manifest.yaml:74 vs :80). |
| Skip conditions 1 | a stage whose status is `complete` is skipped on resume | tests/integration/resume-after-sigint-test.sh:231-234 (intake marker absent on resume) | HIGH | tests/integration/pipeline-resume-test.sh:130 is a tautology: it re-implements the `if`. It does not count. |
| Skip conditions 2-3 | `disabled_stages` skips a stage; `validate` is skipped when `deploy` was skipped; `monitor` is skipped when `ZBUILD_MONITOR_ENABLED` is unset; skipped stages emit `stage.skip` with `reason` | UNTESTED; not implemented | MEDIUM | No `disabled_stages`, `ZBUILD_MONITOR_ENABLED` or `stage.skip` emitter exists in core/, scripts/ or plugins/. `stage.skip` is only registered (config/event-schema.json:15). |
| Skip / ADR-021 note | `--from-stage <s>` is refused when `<s>` is inside or after a cycle | tests/integration/core-pipeline-cycle-build-test-wiring-test.sh:179,184 | MEDIUM | |
| Cycle composition 1/4 | `until.stage` MUST be in `cycle.stages[]` | tests/unit/core-pipeline-template-cycles-test.sh:132-133 | MEDIUM | |
| Cycle composition 2 | cycle stages are a "contiguous subsequence" | UNTESTED (weak) | LOW | T7 (core-pipeline-template-cycles-test.sh:155-161) fails on "until.stage required", not on contiguity. The test's own comment admits this. Contiguity is moot in the v2 inline shape. |
| Cycle composition 3 | cycles "MUST NOT overlap" | UNTESTED (weak) | MEDIUM | T8 (core-pipeline-template-cycles-test.sh:189) asserts rc=1 only. Its fixture uses the same unparsed inline `until: {…}` form, so the reason for the failure is unverified. |
| Cycle composition | first stage of a cycle → one `cycle:<id>` unit; the other members are absorbed; other leaves → `stage:<id>` | tests/unit/core-pipeline-template-cycles-test.sh:60-61; tests/unit/template-simple-yaml-test.sh:208-215 | MEDIUM | |
| ADR-027 amendment | a cycle stage id "MUST NOT collide with any canonical leaf ID" | UNTESTED | LOW | No collision guard found in core/pipeline/template.sh. The rule is moot now that the leaf vocabulary is open. |
| Tier rationale / #757 | T0 stages (`test`, `pr`, `deploy`, `validate`) make "no model call, ever"; deploy/validate agents never call `route_to_model` | UNTESTED | HIGH | plugin-route-source-guard-test only checks that a caller of `route_to_model` sources route.sh. Nothing asserts these stages make no call. tests/unit/deploy-release-v2-result-test.sh:65-68 pins `tier_default: T0` and no `router:` block for deploy-release only (manifest only). |
| Kind rationale | `tool` stages "never declare `requires.core: [redaction]`" | UNTESTED | LOW | |
| #1208 amendment | 3 consecutive per-turn timeouts → warn, `_ROUTE_LOOP_TERMINATED_REASON=router_timeout`, emit `loop.timeout_yield`, return 0 ("no path in the router loop kills the pipeline") | tests/integration/router-loop-retries-test.sh:137,139 | HIGH | Nothing asserts that `loop.timeout_yield` is emitted. |
| #1208 amendment | build maps `router_timeout` to `verdict=did_not_finish` and returns 0 | tests/unit/convergence-timeouts-never-fatal-1208-test.sh:338-339 (asserts `disposition: timed_out`) | MEDIUM | Wording is stale: `did_not_finish` was removed (core/pipeline/verdict.sh:111), replaced by an ADR-054 disposition. |
| #1208 amendment | only exhausting `max_iterations` without clean convergence is fatal | tests/unit/convergence-timeouts-never-fatal-1208-test.sh:153,215,220 | HIGH | |
| blocking column + #2188 | `blocking: true` member failure halts (the cycle stops); `test-author` is blocking, so authoring nothing stops the cycle before `build` | UNTESTED (weak) | HIGH | tests/unit/test-author-test.sh:162-163 only checks that the `blocking: true` config is parsed. No test drives `_cycle_member_is_blocking` (core/pipeline/cycle-orchestrator.sh:247) to a halt. tests/unit/template-blocking-reset-test.sh only covers export reset. |
| #2188 | test-author testfiles are committed after every attempt, partial included | tests/unit/test-author-test.sh:196,206-207 | MEDIUM | |
| Push mechanics | push reconcile is "never the default branch" | tests/unit/git-remote-push-reconcile-test.sh:174-195 | HIGH | |
| #757 hardening | validate propagates the probe rc; deploy fails closed when the gate-aggregator result is absent; health-check allows only http(s) (SSRF); deploy-release sanitizes the tag, rolls the tag back on push failure, builds JSON via `jq -n` | UNTESTED | MEDIUM (SSRF: HIGH) | No test exercises `validate.health_check.rejected`, `deploy.gate.missing` or tag rollback. The SSRF guard is at plugins/tool/health-check/plugin.sh:41. |
| #757 / ADR-056 | stage plugins have no `init` hook | tests/integration/deployed-template-e2e-test.sh:175-177,231-233,271-273 | LOW | Contradicts this ADR's own `lifecycle_hooks` column. |
| †† | `ZBUILD_TEST_ASSESSMENT_ADVISORY=1` suppresses `test_assessment` pass-coercion | UNTESTED; dead | — | No `test_assessment` plugin, and no reader of the variable anywhere. |

## ADR-015 — Stage I/O Capture Chokepoint (Accepted 2026-05-29; amended v2–v6, §F, §G, §H, Issue OUT; cross-ref ADR-064)

The header says Accepted, but "Implementation Notes (Proposed — 2026-05-29)" still says "No code has been written yet". That note is stale.

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| 1 | kinds are exactly `llm`/`command`/`computed` (+`cycle`, §G); an unknown kind → rc=2 | tests/unit/core-output-stage-io-test.sh:68,79; tests/unit/stage-io-cycle-kind-test.sh:147 | LOW | |
| 2 | one chokepoint: "nothing else writes to `state/artifacts/stage-io/`" | UNTESTED; contradicted | LOW | The router writes forensic files there directly (core/router/route.sh:1136-1137, 2118). That is sanctioned by §F (see Conflicts). |
| 3 | a stage "without an `io:` block produces nothing" (opt-in, fail-closed) | tests/unit/core-output-stage-io-test.sh:96-97; tests/unit/scripts-lib-run-captured-command-test.sh:115-117; tests/unit/core-pipeline-template-test.sh:302 | HIGH | |
| 3 | capture is skipped when `ZBUILD_CURRENT_STAGE` is unset | tests/integration/stage-io-capture-test.sh:101-102 | LOW | |
| 4 | "Unknown tokens fail-closed at template load time" | tests/unit/core-pipeline-template-test.sh:293 | MEDIUM | |
| 5 | record envelope `schema_version=1` with run_id/stage/kind/seq/input/output/exit_code/duration_ms/metadata/ts at `stage-io/<stage>-<seq>.json` | tests/unit/core-output-stage-io-test.sh:107-118,131-132; tests/integration/stage-io-capture-test.sh:82-89 | MEDIUM | |
| 5 | written "via `atomic_write`" | UNTESTED | LOW | |
| 5 | `seq` is per stage | tests/unit/core-output-stage-io-split-test.sh:138-140 | LOW | |
| 6 | `llm` prompt "MUST already be post-redaction" in the record | UNTESTED | MEDIUM | No test checks that the `.input` of a stage-io record contains redacted text. |
| 6 / v3 | outbound redaction on `gh_comment`; `llm` "ALWAYS redacts"; `command`/`computed` honor `redact: false` | tests/unit/core-output-stage-io-test.sh:606,627-631,652 | HIGH | |
| 6 | the `redact: false` opt-out "is recorded in the artifact metadata" | UNTESTED; not implemented | LOW | core/output/stage-io.sh writes no redact flag into the record. It only reads the template (:1363-1367). |
| 6 / v3 | redaction failure → drop the comment, emit `stage.io.error reason=redaction_failed`, return 0 | tests/unit/core-output-stage-io-test.sh:674-682 | MEDIUM | |
| v3 | redact before truncate | UNTESTED (weak) | MEDIUM | T45 checks the cap and T46 checks redaction. No test combines a path token straddling the cap. |
| v3 | `gh_comment` body cap is 60 000 bytes, with a truncation marker naming the artifact path | tests/unit/core-output-stage-io-test.sh:576-582 | LOW | |
| v3 | `gh_comment` is a silent no-op when `ZBUILD_ISSUE` is unset/0 or `ZBUILD_OUTPUT_GH_COMMENT=0` | tests/unit/core-output-stage-io-test.sh:482,501 | MEDIUM | |
| v3 | `gh` post failure → `stage.io.error reason=gh_comment_post_failed`, return 0 | tests/unit/core-output-stage-io-test.sh:703-706 | MEDIUM | |
| v3 | `tail_lines` is an int in 1..10000, default 40 | tests/unit/core-pipeline-template-test.sh:384,407; tests/unit/core-output-stage-io-test.sh:436 | LOW | |
| 7 | `stage.io.captured` event with stage/kind/seq/dest_list/artifact_path | tests/unit/core-output-stage-io-test.sh:138-143; tests/integration/stage-io-capture-test.sh:160-161 | LOW | |
| v2 | `run_captured_command` is transparent: rc and stdout pass through; errexit is preserved; returns rc=2 when `capture_stage_io` is not loaded; 1 MiB cap with `[truncated:` marker | tests/unit/scripts-lib-run-captured-command-test.sh:80,88,132,140,160-161 | MEDIUM | |
| v2 | NUL bytes are stripped | UNTESTED | LOW | |
| v4 | input banner "BEFORE the action", output banner "AFTER" | tests/integration/stage-io-ordering-invariant-test.sh:291; tests/unit/core-output-stage-io-split-test.sh:209 | MEDIUM | Chokepoint-level only. The table rows call `route_to_model` and `run_captured_command` directly with a stage id; they do not dispatch the real plugins. |
| v4 | the chokepoint redirects banners to `ZBUILD_STAGE_IO_FD`, so `$()` cannot capture them | tests/unit/core-output-stage-io-test.sh:735,754 | MEDIUM | |
| v4 | `ZBUILD_STAGE_IO_FD` of 0 or 1 is refused at module load (`return 2`) | tests/unit/stage-io-ordering-negative-test.sh:53,59 | MEDIUM | |
| v4 | a closed (not-open) fd "aborts the `source`" | contradicted; code and test assert fallback | — | #586 relaxed this to warn and fall back to fd 2: core/output/stage-io.sh:73-86, tests/unit/core-output-stage-io-fd-fallback-test.sh:46-47. |
| v4 | lint rejects `2>/dev/null` on the same line as `route_to_model`/`_loop`/`run_captured_command`; wired into `npm run lint` | tests/unit/lint-no-route-stderr-discard-test.sh:34,49,63,77; package.json:22 | MEDIUM | |
| v4 | the ADR must reference the invariant test path | tests/unit/docs-adr-015-references-invariant-test.sh | LOW | A doc grep, but this statement is itself about the doc. |
| v5 | colors only on the fd-2 banner; the `gh_comment` body has zero ESC bytes; `─` survives the strip | tests/integration/stage-io-gh-comment-ansi-strip-test.sh:91,103,110 | MEDIUM | |
| v5 | NO_COLOR / non-tty → no ANSI, glyphs kept; FORCE_COLOR re-enables | tests/unit/core-output-stage-io-visual-test.sh:96,120,220-225 | LOW | |
| v5 | `HH:MM:SS UTC` timestamp, ✓/✗ trailer, truncation hint with artifact path | tests/unit/core-output-stage-io-visual-test.sh:85-91,141-143,177-178 | LOW | |
| v5 / #505 | `--persist-input`: the banner is deduped but the artifact `.input` and the `claude -p` argv carry the full prompt | tests/unit/core-router-loop-banner-test.sh:171,196-214,226 | MEDIUM | |
| v5 addendum #506 | `ZBUILD_ROUTER_BANNER_INPUT_OVERRIDE` swaps only the banner body; the persisted record keeps the original | UNTESTED | LOW | No test sets it, and no shipped plugin sets it any more (core/output/stage-io.sh:1001 is its only reader). |
| v5 #508 | stage boundary lines carry started/finished timestamps and duration | tests/unit/core-pipeline-runner-stage-timestamps-test.sh:41-46; tests/unit/core-pipeline-runner-stage-banner-goldens-test.sh | LOW | |
| v5.1 | stage glyph is derived from the manifest primary-output verdict (pass ✓ / warn ⚠ / fail ✗), not from rc | tests/integration/core-pipeline-verdict-indicators-test.sh:135,161,179,194 | MEDIUM | |
| v5.2 | `pipeline.end` banner is emitted AFTER the `pipeline.end`/`pipeline.abort` event, with the status→glyph map | tests/unit/runner-pipeline-end-test.sh:56-71 (glyph/word) | LOW | Event-before-banner ordering is UNTESTED. |
| v6 | cycle chrome is fd-2 only, never `gh_comment`; the exit banner comes after the last iteration divider | tests/integration/core-pipeline-cycle-orchestrator-test.sh:205-230 | LOW | |
| v6 | durable event FIRST, banner SECOND; `cycle_exit_hook` fires once per cycle | UNTESTED | LOW | |
| §F | on claude rc≠0, persist the envelope and stderr at predictable paths, even when empty; emit `*.diagnostic`; the original `router.error` / `loop.iteration.error` still fires | tests/integration/router-sync-preserves-error-artifacts-test.sh:104-150; tests/integration/router-loop-preserves-error-artifacts-test.sh:140-187 | HIGH | The "ALWAYS write even when empty" case has no dedicated assertion: both fixtures have non-empty output. |
| §F | every emitted failure-mode event is registered in `event-schema.json` | tests/integration/router-sync-preserves-error-artifacts-test.sh:159-162; tests/unit/event-schema-emitted-coverage-test.sh | LOW | |
| §G | `kind=cycle` is forced to stdout only: "NEVER file, NEVER gh_comment" | tests/unit/stage-io-cycle-kind-test.sh:124-139 | MEDIUM | |
| §G | the orphan finalizer emits `output_never_emitted` for every kind but writes no `.partial.json` for `kind=cycle` | tests/unit/core-output-stage-io-split-test.sh:235-238; tests/unit/stage-io-cycle-kind-test.sh:284 | LOW | |
| §G | INPUT digest (first iteration says "no feedback"; required-but-missing → MISSING); OUTPUT restates the predicate as MATCHED / NOT MATCHED | tests/unit/stage-io-cycle-kind-test.sh:74-92,154-180 | LOW | |
| §H | "Any stage that runs an external command MUST wrap that command in `stage_io_begin --kind command`" | UNTESTED; contradicted | MEDIUM | Only build, intake, spec-acceptance and test call the chokepoint. pr-open (`gh pr list`/`git checkout`, plugins/tool/pr-open/plugin.sh:41,249), merge, deploy-release (`git tag`, plugins/tool/deploy-release/plugin.sh:76) and github-labels run uncaptured. The motivating `objective-gate` plugin was deleted. Per-plugin pin for test only: tests/integration/test-plugin-stage-io-banner-visible-test.sh. |
| Issue OUT | lens renderers never return non-zero; parallel members print one line, no raw JSON | tests/unit/artifact-render-lens-test.sh:75,101; tests/integration/review-lenses-output-test.sh:111-126 | LOW | |


## Conflicts

### Conflicts (ADR-001 … ADR-008)

- **C1. ADR-001 §Hook signature vs ADR-001 §Error semantics and ADR-054 §4.** §Hook signature says plugins "MUST … return rc=2 if `state_file` is empty, so config errors surface distinctly". §Error semantics and ADR-054 §4 say plugin rc is binary (0/1). **The code follows binary**: `dispatch_rc_narrow` maps 2→1 (core/pipeline/dispatch-rc.sh:54; tests/unit/dispatch-rc-test.sh:67), so the "distinct" rc=2 can never be seen. About 40 plugin.sh files still `return 2` (e.g. plugins/agent/pr-delivery/plugin.sh:38).
- **C2. ADR-001 §Cross-plugin dependencies vs ADR-001 §requires.core (line 310) and ADR-051:172.** The first says `requires.plugins` "is enforced at discovery time"; the latter two say it "remains unlanded under #1321". **The code follows "unlanded"**: no resolver exists.
- **C3. ADR-003 §Migration rule vs code.** The ADR says `weight: 0` drains a candidate. core/router/route.sh:4,681 always takes `candidates[0]` and never reads `weight`. The router contract `route(tier, complexity, budget_state) → {…, fallback_chain}` also does not exist (route.sh:135).
- **C4. ADR-004 §Stage-level enforcement (and ADR-013's tier table) vs code.** Both list `pr` as T0, "MUST never emit LLM-bound text". `pr` is now delivered by plugins/agent/pr-delivery (`kind: agent`, `tier_default: T2`, manifest.yaml:3,31; #756). It makes no route call today, but its declared tier says otherwise.
- **C5. ADR-005 §Consequences vs ADR-056 / ADR-001 (amended).** ADR-005 relies on each coordinator's `init` hook to self-test. ADR-056 deleted `init`. The ADR-005 Implementation Notes still claim "flock … self-test in `init`: Implemented".
- **C6. ADR-001 §Lifecycle and ADR-006 §Resume sequence vs code.** Both tell plugins to check `ZBUILD_RESUMING=1`. Nothing sets it. The runner exports `ZBUILD_RESUME` (resume *intent*, default 1, tests/unit/resume-default-test.sh:55-57), a different variable with different meaning, so a plugin following the ADR never sees a resume.
- **C7. ADR-006 §Persisted vs code.** The ADR's headline fix (`current_iteration` survives resume) has no production writer; `write_plugin_state`/`read_plugin_state` and the `state.persisted` validation do not exist; step 3.5 (mid-cycle resume) is unimplemented. Cycle iteration state actually lives in `cycle_iterations` and cycle history JSONL, which ADR-006 lists only as an amendment.
- **C8. ADR-004 §The chokepoint vs code.** The ADR's signature is `<text_var> <manifest> <allowlist> <cycle_id>` and its `redaction.applied` payload is `{prompt_size, redactions_count, scope_hash, cycle_id}`. The code (scope-redaction.sh:40, :272-279) takes files `<input> <output> <manifest> [allowlist] [cycle]` and emits `size_before/size_after/redactions/scope_hash/cycle`. The ADR's "one-shot" override token is never consumed.
- **C9. ADR-002 §Pruning protocol vs legacy/migrated/.** The ADR requires a one-line tombstone. All 12 files are 21-65-line documents in three different shapes. ADR-002's Implementation Notes call security-lens pruned; its tombstone says "NOT pruned".
- **C10. ADR-007 vs code/CI.** It says nightly E2E (e2e actually runs per PR, with no nightly job), `ZBUILD_UPDATE_GOLDEN` (the variable is `UPDATE_GOLDEN`), and a re-source guard in every test (0 files have one). ADR-008 says "CI runs Node LTS 22" (no workflow sets a Node version).

### Conflicts (ADR-009..014)

- **C1 — ADR-009 §Backward-compat case 2 vs ADR-042 §2 and the code.**
  - ADR-009 says: if a stage declares roles but no plugin provides them, the runner tries the direct id match.
  - ADR-042 §2 says: declared but unresolved roles **fail closed** (rc=1).
  - core/pipeline/dispatch.sh:68-73 (`resolve_stage_plugin`, cycle and parallel paths) follows ADR-042, pinned by tests/unit/stage-resolution-parity-test.sh:115.
  - The leaf path still follows ADR-009: strategy rc=4 → `_find_plugin_for_stage` at core/pipeline/runner.sh:3875-3890. The resolvability preflight (template-resolvability-preflight-test.sh:295) may refuse first.
  - So two dispatch paths apply opposite rules, and ADR-009 was never marked amended.
- **C2 — ADR-011 §Graceful degradation rule 2 vs ADR-014 §Decision and the code.**
  - ADR-011 says: `fallback_to_default_on_error: false` → hard-fail with a clear error; `true` → fall back and emit `backend.degraded`.
  - ADR-014 says: backend load failures are non-fatal (warn and use stubs).
  - The code follows ADR-014, and goes further:
    - Memory gates the fallback on env `ZBUILD_MEMORY_FALLBACK`, not on the declared key (core/memory/contract.sh:63-76).
    - Orch and cache always fall back silently with no `backend.degraded` event (core/orch/contract.sh:175-181; core/cache/contract.sh `_zbuild_cache_load_backend`).
- **C3 — ADR-010 §3 (`gh-pr-comment` = one comment per run, edited in place) vs code.**
  - core/output/destinations.sh:58 posts a fresh `gh issue comment` on every `emit_output` call.
  - Only scripts/lib/run-status-comment.sh follows the rule.
  - The check-run env var also differs: the ADR names `ZBUILD_EMIT_CHECK_RUN=true`, the code reads `ZBUILD_OUTPUT_GH_CHECK_RUN=1` (destinations.sh:66).
- **C4 — ADR-011 §Orchestrator (Phase 0.5 default = `orch-sequential`) vs code.**
  - core/config/config.sh:11 defaults to `bash-parallel`, pinned by tests/unit/core-config-load-test.sh:48.
  - The code follows `bash-parallel`.
- **C5 — ADR-011 §Retention ("the memory store is never reclaimed") vs code (suspected; verify).**
  - plugins/tool/memory-sqlite/plugin.sh:43-44 puts `memory.db` under `${ZBUILD_STATE_DIR}` when it is set, and the runner exports ZBUILD_STATE_DIR = the run's state dir (core/pipeline/runner.sh:2141).
  - If that dir is per-run, `cleanup --state-dirs` (scripts/lib/cleanup.sh `_cleanup_scan_state_dirs`) would delete the memory store.
  - The enforcing test, cleanup-new-reclaimers-test.sh:197, greps cleanup.sh for the name and cannot see this.
- **C6 — ADR-009 §4 (`sequential` halts only if `per_platform_halt_on_fail: true`) vs code.**
  - core/pipeline/strategies/sequential.sh always halts, and the flag is not implemented.
- **C7 — ADR-009 §Auto-detection ("warn + skip the folder") vs code.**
  - core/detect/platforms.sh:424-430 substitutes `generic`; tests/unit/core-detect-platforms-a-test.sh:59 pins `generic`.
- **C8 — ADR-012 internal conflict.**
  - The Mutation convention says `--tier mutation` "validates doc structure (not behavior)", but the #1184 amendment and scripts/run-mutation.sh execute mutants.
  - The Coverage policy says "kcov over unit + integration", but scripts/check-coverage.sh traces `--tier unit` only, and the ADR's own 29% floor note contradicts check-coverage.sh's default of 70.
- **C9 — ADR-010 §1 `zbuild teardown` vs ADR-054 §7 / ADR-001 lifecycle (naming).**
  - ADR-010's CI `teardown` command (snapshot and upload) is unimplemented.
  - "teardown" now names ADR-054 §7's stage, which releases plugin `cleanup` hooks and is run by `zbuild clean`.
  - The two would collide if ADR-010 Phase 1 lands as written.

### Conflicts (ADR-013/015)

1. **ADR-013 §Stage sequence / §Template integration vs ADR-047 §5 (and code).** ADR-013 says unknown ids are rejected "at template-load time" and that order must follow the canonical sequence. ADR-047 demotes the list, and the code follows ADR-047:
   - `_ZBUILD_CANONICAL_STAGES` is deleted (core/pipeline/template.sh:23-29).
   - `load_template` accepts unknown ids (tests/unit/core-pipeline-template-test.sh:207).
   - Membership is enforced by the runner resolvability preflight, and order by the input DAG.
   - ADR-013's body still says reordering needs "a new ADR-013 revision".
2. **ADR-013 lifecycle_hooks column (`init, run, finalize`) vs ADR-001/ADR-056 (run + cleanup only).** The code follows ADR-056: the init hooks must not exist (tests/integration/deployed-template-e2e-test.sh:177).
3. **ADR-013 fail-closed rule vs code.** ADR-013 specifies a synthetic `stage.fail` with `reason: "missing_artifact"`. The code emits `plugin.artifact.missing`/`plugin.artifact.empty`, then `plugin.<hook>.error reason=artifact-check-failed` and `plugin.contract.violated` (core/plugin-registry/lifecycle.sh:103,505-512). No `missing_artifact` string exists in the code.
4. **ADR-013 #361 rule 3 ("canonical artifact MUST be first in `outputs[]`", `_check_artifact_contract`) vs ADR-047 §4 / code.** The checker is retired (artifact-enforcement-survives-retirement-test.sh:136), `primary: true` decides instead, and pr-open's first output is `pr_open_errors` (plugins/tool/pr-open/manifest.yaml:74).
5. **ADR-013 "downstream MUST NOT wire inputs from secondary artifacts" vs code.** merge reads `pr-result.json` (plugins/tool/merge/plugin.sh:97), and pr-delivery reads pr-open's `pr-result.json` (#2250). These are cross-plugin reads of the "secondary" file, though via delegation rather than a manifest `inputs:` edge.
6. **ADR-013 §Stage skip conditions vs code.** `stage.skip`, `disabled_stages` and `ZBUILD_MONITOR_ENABLED` are not implemented. `stage.skip` is only registered (config/event-schema.json:15). A resumed complete stage emits nothing named `stage.skip`.
7. **ADR-013 Decision table (`deploy`/`validate`/`pr` = `kind: tool`) vs the #757 amendment and code.** All three resolve to `kind: agent` plugins (plugins/agent/{deploy,validate,pr-delivery}). The ADR keeps the table "unchanged", so the doc contradicts itself.
8. **ADR-013 #1208 amendment (`verdict=did_not_finish`) vs ADR-054 / code.** `did_not_finish` was removed (core/pipeline/verdict.sh:111). Build writes `disposition: timed_out` (tests/unit/convergence-timeouts-never-fatal-1208-test.sh:339).
9. **ADR-013 #1208 amendment ("returns rc=2" path) vs ADR-054 §4 (binary plugin rc).** Historical only; the code follows ADR-054.
10. **ADR-015 §2 vs ADR-015 §F (internal) and code.** §2 says "nothing else writes to `state/artifacts/stage-io/`". §F (and core/router/route.sh:1136,2118) has the router write `<stage>-sync-error.*` / `-iter<N>-error.*` there directly, bypassing `capture_stage_io`, and plugins/agent/plan/plugin.sh:734 reads them.
11. **ADR-015 §v6 vs §5 (internal).** §v6 says per-iteration stage-io artifacts go to `state/artifacts/<stage>/`. §5 and the code use `state/artifacts/stage-io/<stage>-<seq>.json`.
12. **ADR-015 §v4 fd validation vs code.** The ADR says a not-open fd "aborts the `source`". The code (#586) warns and falls back to fd 2 (core/output/stage-io.sh:73-86), and a test pins the fallback (core-output-stage-io-fd-fallback-test.sh:46-47). The code follows #586.
13. **ADR-015 §H vs code.** The mandatory command capture is violated by pr-open, merge, deploy-release and github-labels, which run `gh`/`git` uncaptured.
14. **ADR-015 §6 vs code.** The `redact: false` opt-out "recorded in the artifact metadata" is not written into the record.
15. **ADR-015 Implementation Notes vs its own status.** The notes still say "Proposed … No code has been written". §v3's "turn the feature on in `config/templates/standard.yaml`" refers to a template retired by #979.

