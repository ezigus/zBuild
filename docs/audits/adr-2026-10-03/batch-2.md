# ADR audit — batch 2 (issue #2268)

Scope: ADR-016, ADR-017, ADR-018, ADR-019, ADR-020 (deferred tracker), ADR-020 (inter-stage data contract).
Method: normative statements extracted; each searched in `tests/` (unit/integration/e2e/golden), `core/*/tests`, `plugins/*/*/tests`, `scripts/lib/lint-*.sh`, `scripts/check-*.sh`; the assertion was read to confirm it checks the statement. Repo HEAD 158ee61c.

Totals: 6 ADRs (1 superseded, no statements listed); 121 normative statements; 43 UNTESTED or CONTRADICTED — HIGH 5, MEDIUM 16, LOW 20, stale/no-risk 2 (one more row is superseded and not counted). 17 conflicts.

Legend — "UNTESTED (weak)": a test touches the area but does not assert the statement. "NOT IMPLEMENTED": the code has no such behaviour at all (a stronger finding than untested). "CONTRADICTED": code (and sometimes a test) does the opposite.

---

## ADR-016 — Per-Repository Template Resolution (Proposed — never flipped to Accepted although #653 merged; amended 2026-06-05 by ADR-027/#705, 2026-07-07 by #1270)

Most of this ADR was never built. `core/pipeline/template-resolver.sh` has only the search order, the `extends:` presence/existence check and the overlay. It has no events, no snapshot, no CLI-path mode and no resume checks.

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| L1 | Resolver tries `.zbuild/templates/<id>.yaml` "first", then falls back to `config/templates/<id>.yaml` | tests/unit/template-resolver-search-path-test.sh:57 (no override → shipped); tests/unit/template-resolver-new-shape-overlay-test.sh:55 (override wins) | HIGH | |
| L1 | "Full replace: there is no field-level merge" (old shape: override `stages:`/`stage_definitions:` replace base's) | tests/unit/template-resolver-search-path-test.sh:96; tests/integration/template-resolver-extends-test.sh:91,93 | MEDIUM | |
| L2 | "`extends:` is REQUIRED in every per-repo override" | tests/unit/template-resolver-search-path-test.sh:111; tests/unit/template-resolver-new-shape-overlay-test.sh:79 | MEDIUM | `extends: null` is also refused (template-resolver.sh:42 skips `null`), but no test covers that. |
| L2 | An unresolvable `extends:` "hard-fails at template-load time with a structured error" | tests/unit/template-resolver-search-path-test.sh:129-130; template-resolver-new-shape-overlay-test.sh:97; tests/integration/template-resolver-extends-test.sh:123-124 | MEDIUM | |
| L2 | `extends:` resolves "only to shipped template ids — never to a file path, never to another override, never to a URL" | UNTESTED | MEDIUM | CONTRADICTED: template-resolver.sh:50 splices the raw value into `config/templates/${extends_id}.yaml`, so `extends: ../../x` loads an arbitrary file. Nothing sanitizes it. |
| L2 | Depth "exactly 1": multi-hop chains "refused at load time" | UNTESTED | LOW | NOT IMPLEMENTED: the base's own `extends:` is never read. The shipped config/templates/deployed.yaml:3 has `extends: simple`, so `extends: deployed` is accepted silently. |
| L3 | The diff is computed against the resolved base, post-cycle-expansion flat list | UNTESTED | LOW | NOT IMPLEMENTED (no diff computed anywhere) |
| L4 | `pipeline.template.resolved` is "emitted exactly once per pipeline run … unconditionally", including shipped-only runs | UNTESTED | MEDIUM | NOT IMPLEMENTED: no emitter in core/; not in config/event-schema.json |
| L4/C2 | The event's `path` is repo-relative (basename for cli); the absolute path "NEVER appears" | UNTESTED | LOW | NOT IMPLEMENTED (no event exists) |
| L5 | `pipeline.template.diff_from_base` is emitted "ONLY when source∈{local,cli} AND" it differs; informational, non-blocking | UNTESTED | LOW | NOT IMPLEMENTED |
| L6 | A `--template` argument containing `/` or ending in `.yaml` is treated as a file path (`source=cli`) | UNTESTED | MEDIUM | NOT IMPLEMENTED: runner.sh:1655 passes the raw value to the id resolver, which builds `config/templates/<value>.yaml`. There is no id sanitization, so `--template ../x` traverses (CLAUDE.md security rule). |
| L6/Q3 | "There is NO env-var surface for templates" | tests/integration/suite-under-teststage-env-test.sh:71 (ZBUILD_TEMPLATES_DIR ignored) | LOW | |
| Steps 7-12 | Validation results are "CAPTURED … do NOT abort" until events 10/11 have fired | UNTESTED | LOW | NOT IMPLEMENTED (events absent; load_template aborts directly, runner.sh:1755) |
| B1 | The fully resolved template is "snapshotted at run start to `state/artifacts/template.resolved.yaml`" via atomic_write; "Resume reads the snapshot, not the override file" | UNTESTED | HIGH | NOT IMPLEMENTED: nothing references `template.resolved.yaml`. On resume the runner re-resolves from disk/`$PWD` (runner.sh:1711), so editing an override mid-run changes the resumed run, which is the exact failure B1 calls BLOCKING. |
| C3 | Resume with a different `template_id` → refuse `pipeline.resume.template_mismatch`; same id but different content → warn `template_drift` and use the snapshot | UNTESTED | MEDIUM | NOT IMPLEMENTED |
| F2 | No override: the first stat-miss is "silent in operator chatter" | UNTESTED (weak) — template-resolver-search-path-test.sh:56-57 checks rc and path, not stderr | LOW | |
| C4 | "no engine-side hardcoded safety-critical list"; diff event never gates dispatch | UNTESTED | LOW | |
| Amd 06-05 | Override reserved keys REPLACE the base's; stage sections REPLACE the matching base section; override-only sections are ADDED; "a stage section present only in the base is KEPT" | UNTESTED | HIGH | CONTRADICTED: template-resolver.sh:84-87 copies a new-shape override VERBATIM, so base-only sections are DROPPED. An override that restates `flow:` but not every stage section loses those sections' router/io knobs without any warning. new-shape-overlay-test.sh:55 checks only that the flow is replaced. |
| Amd 06-05 | A cycle stage section is replaced wholesale, with no merge inside it | UNTESTED (weak) — implied by the verbatim copy; no test overrides a cycle section | LOW | |
| Amd 06-05 | After the shim window, pre-ADR-027 shape overrides are a load-time error; `template.format.deprecated` fires per old-shape file | UNTESTED | LOW | `template.format.deprecated` is not emitted anywhere. The old shape is still accepted and is asserted as supported (new-shape-overlay-test.sh:120). |
| #1270 | The shipped read root is hardcoded `$_TEMPLATE_RESOLVER_ROOT/config/templates/` with no env override | tests/integration/suite-under-teststage-env-test.sh:71 | LOW | |
| #1270 | No test writes a fixture into the real repo's `config/templates/` or `.zbuild/templates/` | tests/unit/templates-dir-hermeticity-test.sh:105 (lint-style scan, with a non-vacuity guard at :40) | MEDIUM | |

---

## ADR-017 — Per-Stage Router Configuration (Accepted; amended #762/#763, #1230, §11 #1816 / ADR-054)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §1/§4 | Per-stage `router.timeout_s` is parsed; absent block → no override | tests/unit/core-pipeline-template-test.sh:520-525 | MEDIUM | |
| §4 | `_TPL_STAGE_ROUTER_TIMEOUT_<id>` is "exported" for plugin subshells | tests/unit/core-pipeline-template-test.sh:624; tests/integration/router-timeout-precedence-e2e-test.sh:91 | HIGH | |
| §2 | Precedence: per-stage > `ZBUILD_ROUTER_TIMEOUT` > 300 | tests/integration/core-router-route-test.sh:470,476,483,491,504 | HIGH | |
| §3 | Resolution goes through "one chokepoint" `_route_resolve_*` helper | UNTESTED | HIGH | CONTRADICTED: core/pipeline/cycle-orchestrator.sh:2117-2127 re-implements max_turns precedence by hand (template > env > 25) and skips the §11 manifest layer. A plugin declaring `config.router.max_turns: 60` that times out has its escalation base taken as 25. The escalated override (37) then beats the manifest's 60 in `_route_resolve_max_turns`, so "escalation" lowers the budget. No test or lint guards the chokepoint. |
| §5 | Validator rejects non-integer / outside `1..3600` with the actionable error | tests/unit/core-pipeline-template-test.sh:546-548, 569, 590 (0 rejected), 616 (1 and 3600 accepted) | MEDIUM | |
| §6 | `standard.yaml` ships plan=300, build=900, review=300 | UNTESTED | LOW | STALE: config/templates/standard.yaml no longer exists; simple.yaml carries its own values. Should be marked superseded. |
| §7 | `model.route` (and `model.outcome`) carry the resolved `timeout_s` | tests/integration/core-router-route-test.sh:516,519 | LOW | |
| impl | Per-stage and env both set and different → `router.timeout.override_ignored` | tests/integration/core-router-route-test.sh:494 | LOW | |
| §8 | `router.tier` must match `^T[0-4]$`; a bad value or model name "fails loud" | tests/unit/core-pipeline-template-router-tier-test.sh:88,105 | MEDIUM | |
| §8 | Tier precedence: env `ZBUILD_<ID>_TIER` > template `router.tier` > manifest `config.tier_default` > fail-loud | tests/unit/tier-resolve-test.sh:96,100,104,51 | MEDIUM | §8's order (env beats template) is the reverse of §2's rule that "per-stage MUST win the env var". The ADR does not reconcile this (see Conflicts). |
| Amd #762 | `router.max_turns` accepts `0..200`; 0 is a sentinel (omit flag) at template, env and default | tests/unit/router-claude-flags-test.sh:184-195, 222-230, 328 (201 rejected) | MEDIUM | |
| Amd #1230 | `router.retries` is in `0..10`, `0` valid, default 0, per-stage > env > 0 | tests/unit/core-pipeline-template-router-retries-test.sh:93 (11 rejected), 139-141 (0 accepted); tests/integration/router-retries-test.sh:142-143 (default 0) | MEDIUM | |
| Amd #1230 | `router.retries.override_ignored` fires when env differs | tests/integration/router-retries-test.sh:161-164 | LOW | |
| Amd #1230 | retries is honored by "both leaf model-call paths" | tests/integration/router-retries-test.sh:128 (single-shot); tests/integration/router-loop-retries-test.sh:117-121 (loop, intra-iteration) | HIGH | |
| §11 | Chain is "template accessor → environment variable → manifest config.router.* → constant" | tests/unit/router-manifest-budget-test.sh:172-176, 206-210, 222-226; tests/integration/router-manifest-budget-dispatch-test.sh:103 (engine-supplied ZBUILD_PLUGIN_DIR) | HIGH | |
| §11 | "A manifest that declares nothing behaves exactly as before" | tests/unit/router-manifest-budget-test.sh:149-166 | HIGH | |
| §11 | `validate_manifest` rejects non-numeric, out-of-range, and unknown keys inside `config.router` | tests/unit/router-manifest-budget-test.sh:340-353; every shipped manifest still validates :363 | MEDIUM | |
| §11 | A top-level `router:` block is not the plugin's declaration (read by path) | tests/unit/router-manifest-budget-test.sh:186, 299 | LOW | |
| §11 | `max_iterations` is "not in the set" of manifest knobs | UNTESTED (weak) — route.sh:833 passes no manifest knob, but no assertion exists | LOW | |
| §11 | A manifest default losing to env or template emits no `override_ignored` | tests/unit/router-manifest-budget-test.sh:247 | LOW | |
| §11 | A manifest-declared `max_turns: 0` classifies as `manifest`, not `default` | tests/unit/router-manifest-budget-test.sh:282-286 | LOW | |

---

## ADR-018 — Stage Invocation Modes (Proposed — still not flipped although Issues A-D shipped; amended #1919/#1961, ADR-043 redaction, ADR-028 v3, v4 #816, #908, #1329, #762)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| #1919 | Spawn uses `--permission-mode acceptEdits …`; "`bypassPermissions` MUST NOT be used" | CONTRADICTED — tests assert the opposite: tests/unit/router-permissions-test.sh:193-196,218 and tests/unit/router-claude-flags-test.sh:101 require `bypassPermissions` | HIGH | core/router/permissions.sh:160 emits `bypassPermissions` (#2180). The ADR was never amended (no ADR mentions #2180 for this). Spec and code disagree on the security posture. |
| #1919 | `--dangerously-skip-permissions` is replaced at both spawn sites | tests/unit/router-permissions-test.sh:174 (no non-comment occurrence in core/router/) | HIGH | |
| #1919/#1961 | The grant is `--add-dir` for `ZBUILD_REPO_ROOT`, `ZBUILD_STAGE_SCRATCH`, `ZBUILD_ARTIFACT_DIR` | tests/unit/router-permissions-test.sh:72,77,84; tests/unit/router-permissions-grant-coverage-test.sh:72,138 (every declared checkpoint path is covered) | HIGH | |
| #1919 | "The run STATE dir is deliberately NOT granted" (pipeline-state.json, events.jsonl) | tests/unit/router-permissions-grant-coverage-test.sh:150,157 | HIGH | |
| #1919 | Roots are derived from env vars, "never from a path literal" | tests/unit/router-permissions-grant-coverage-test.sh:187 | MEDIUM | |
| #1961 | The grant "must never be made conditional on the directory existing" | UNTESTED | MEDIUM | |
| #1919 P2b | Do not use `allowedDirectories` in the settings file | tests/unit/router-permissions-test.sh:92 | LOW | |
| #1919 P5 | Deny rules "must be written as `Edit(...)`" | tests/unit/router-permissions-deny-test.sh:66-68; tests/unit/router-permissions-test.sh:230 | HIGH | |
| P1/DP1 | Pattern 1 argv has `--disallowed-tools "EnterPlanMode,ExitPlanMode"` (one token) and `--max-turns 25` by default | tests/unit/router-claude-flags-test.sh:79,83-88; tests/integration/router-claude-flags-test.sh:123-127 | MEDIUM | |
| Decision | Pattern selection is plugin-internal; the template does NOT declare Pattern 1/2 | UNTESTED | LOW | |
| P1/DP8 | Pattern 1 plugins "MUST set `ZBUILD_ROUTER_JSON_OUTPUT=1`" around `route_to_model` and consume `.result` | UNTESTED (weak) — tests/unit/llm-agent-framework-test.sh:181 tests the framework wrapper only; tests/unit/agent-stages-artifact-metadata-symmetry-test.sh greps ARTIFACT_ID (not JSON_OUTPUT) for 3 plugins | MEDIUM | CONTRADICTED: plugins/agent/spec-coverage/plugin.sh:185, spec-correspondence/plugin.sh:121 and issue-acceptance/plugin.sh:167 call `route_to_model` without envelope mode. They parse line protocols, so the impact is reasoning leaking into the parsed text. |
| P1 | The router enforces `--output-format json` when opted in | tests/unit/router-claude-flags-test.sh:124-125 (argv only) | LOW | `.result` auto-extraction was not traced to a dedicated assertion. |
| P1/#478 | `.result` goes through `extract_first_json_object`; LAST balanced object wins | tests/unit/extract-first-json-object-test.sh:65,113 | MEDIUM | Tests the helper only; no guard that every Pattern 1 plugin calls it. |
| v3 | "All Pattern 1 stages MUST migrate to the [ADR-028] framework" | UNTESTED | MEDIUM | spec-coverage, spec-correspondence and issue-acceptance bypass the framework (see above). |
| P2 | Loop ends on an anchored `LOOP_COMPLETE` line (no mid-line, lowercase or suffix match) | core/router/tests/route-loop-unit-test.sh:190-197 | HIGH | |
| P2 | `max-iterations` cap → rc=1, `terminated_reason=max_iterations`, `loop.max_iterations` | core/router/tests/route-loop-unit-test.sh:136-139 | MEDIUM | |
| P2 | "The LLM never emits a diff"; the pipeline derives `diff.patch` from git | tests/unit/build-diff-cumulative-test.sh:152 (byte-equals `git diff $baseline..HEAD`) | HIGH | The basis follows ADR-020 #660 (baseline..HEAD), not this ADR's "`git diff HEAD`" (see Conflicts). |
| P2 | Out-of-scope path → `*.scope.violation` event, `scope_violation=true`; "The stage continues" | tests/integration/build-created-oos-still-violation-test.sh:136,145,147,157 | HIGH | DP5 says "fail-closed" while §P2 and the impl notes say fail-soft rc=0 (see Conflicts). |
| P2 single-file | An untracked stray → `mv` + `<plugin>.stray.recovered`; a tracked stray → refuse + `.stray.conflict reason=tracked` | tests/unit/design-stray-file-recovery-test.sh:112-122, 141-153 | MEDIUM | |
| P2 single-file | Plugins "MUST inject the absolute destination path into the LLM prompt" | UNTESTED | MEDIUM | No prompt assertion found for design's absolute dest path. |
| #602 | No stash or apply-check dance; the test stage runs on the synced tree with "no `git apply` step" | tests/unit/test-plugin-empty-diff-test.sh:67 (weak: empty-diff case only) | MEDIUM | |
| #530 | `diff.patch` ends with `\n` (restored + `build.diff.trailing_newline_restored`); NUL scan emits `binary_truncation_observed` | UNTESTED | MEDIUM | Code is at plugins/agent/build/lib/diff.sh:99,107. No test references either event. |
| #530 | `git add -N` intent-to-add entries are cleared after capture | UNTESTED | LOW | plugin.sh:461 |
| Det. | Deterministic operations (diff, apply-check, tests, lint, schema, scope) "must NOT be delegated to the LLM"; the orchestrator re-runs them | UNTESTED (principle; no guard) | MEDIUM | |
| Renderers | Plugins register renderers via `register_artifact_renderer` without editing `artifact-render.sh` | tests/unit/artifact-render-extensibility-test.sh:26-36 | LOW | |
| ADR-004 amd | "A plugin that invokes a model without passing through `route_to_model` or `route_to_model_loop` is still a bug" | tests/unit/redaction-chokepoint-test.sh:111 (static scan for raw `claude -p/--print`) | HIGH | |
| #505 | Iteration ≥2 banner dedupes the static prompt and diff; `claude -p` always gets the full prompt; artifact `.input` keeps the full prompt | tests/unit/core-router-loop-banner-test.sh:171,196,203,211 | LOW | |
| #512 | The inner loop has a "hardcoded ceiling … 50" | UNTESTED | MEDIUM | CONTRADICTED in part: only the template validator checks 1..50 (core/pipeline/template.sh:1621, itself untested). `route_to_model_loop` checks only `>=1` (core/router/route.sh:1621), so `ZBUILD_ROUTER_MAX_ITERATIONS=500` is accepted. |
| #512 | Loop and cycle "install INT/TERM traps but NEVER own EXIT" | UNTESTED | MEDIUM | |
| #608 | COMMIT_SUMMARY regex, LAST match, trimmed to 72 chars, fallback `plan.title` → `zbuild: build iter <N>` | tests/unit/build-plugin-commit-msg-parser-test.sh:37,42,50,57,64,74,81 | LOW | |
| #608 | "The LLM does NOT run `git commit` — the pipeline owns commit semantics" | UNTESTED | MEDIUM | No guard detects or refuses an LLM-made commit. |
| #1329 | Multi-iteration: subject = `plan.title` with one bullet per distinct summary; control chars stripped; an injected trailer becomes a bullet | tests/unit/build-plugin-commit-msg-parser-test.sh:92-154 | LOW | |
| #762 | `max_turns: 0` omits `--max-turns`; emits `router.max_turns.flag_omitted` with source | tests/unit/router-claude-flags-test.sh:184-195, 222-230, 244-252 | MEDIUM | |
| #762 | Explicit `--max-turns-per-call 0` (or >200) is rejected | core/router/tests/route-loop-unit-test.sh:400,405,410 | LOW | |
| #466 | Invalid max_turns → rc=2, `reason=invalid_max_turns` | tests/unit/router-claude-flags-test.sh:168-171 | LOW | |
| v4 | design is Pattern 2 (`route_to_model_loop`) | UNTESTED | LOW | |
| #908 | On schema-gate failure only, impact re-scans and takes the FIRST schema-valid object, emits `impact.envelope.recovered`; the shared parser stays LAST-wins | tests/integration/impact-envelope-recovery-test.sh:103-117; tests/unit/extract-first-json-object-test.sh:65 | MEDIUM | |
| #467 (superseded) | "3 consecutive timeouts → fatal" | Superseded — tests/integration/router-loop-retries-test.sh:137-141 asserts a non-fatal yield (#1208) | — | Not counted. The ADR text was not updated. |

---

## ADR-019 — Review Fail-Closed on Unknown or Failed Tests (Accepted; amended by ADR-047 (#1277), #1261, #2176, #2241)

The `review` agent plugin was retired (#979). `_review_derive_test_status`, the coercion and the prompt rule no longer exist anywhere. The test fail-closed invariant now lives in gate-aggregator (the test suite is a must-pass gate of `build_test_cycle`). §1-§5 and §7 are stale and the ADR does not say so.

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §1 | The `test` stage is in `standard.yaml` between build and review, `roles: [tester]` | UNTESTED | LOW | STALE: standard.yaml is gone. In simple.yaml, test is a `build_test_cycle` member. |
| §2 | Review derives `test_status` from `.verdict` (pass→passed, fail/error→failed, missing→unknown) | UNTESTED | — | STALE: no code (#979). |
| §3 | `approve` with test_status unknown/failed is coerced to `request_changes`; `block` is the floor | UNTESTED as written. The equivalent invariant (no green run without a passing suite) is enforced by tests/unit/gate-aggregator-test.sh:88 (missing gate → fail), :104 (suite error → fail) | HIGH | STALE as written. Code follows the gate-aggregator model (ADR-040). Note that gate-aggregator lets `disposition=advisory` demote a suite fail to non-blocking (plugins/tool/gate-aggregator/plugin.sh:147-154). ADR-019 has no such exception. |
| §4 | Every coercion emits `review.test_status.coerced` | UNTESTED | LOW | Declared in plugins/agent/review-aggregator/manifest.yaml:65 but never emitted by any code. It is a phantom event. |
| §5 | The review prompt carries the approve-requires-tests rule | UNTESTED | LOW | STALE |
| §6 | Test plugin: passed==0 AND failed==0 AND exit 0 → `verdict=error` | plugins/tool/test/tests/test-test.sh:174 | HIGH | |
| §7 | `test_assessment.verdict` beats `test.verdict`; `inconclusive` → unknown | UNTESTED | — | STALE: there is no test_assessment plugin in plugins/. |
| #507 | Exactly one `outputs[].primary: true` per stage-bound manifest | scripts/lib/lint-contract.sh:184-188 (lint over the shipped tree) | MEDIUM | The lint has no negative-fixture test (0 or 2 primaries); only monitor's manifest is pinned (tests/unit/monitor-manifest-test.sh:126). |
| #507 | The verdict → class table (pass/warn/fail rows) | Partial: tests/unit/core-pipeline-verdict-test.sh:62 covers pass, approve, request_changes, incomplete, fail, error, block, scope_violation; tests/unit/lint-verdict-classify-test.sh:297 covers blocked | MEDIUM | UNTESTED (weak) for degraded, unjudged, unreadable, partial, uncheckable, mismatch, covered, uncovered, healthy, deployed, skipped, corresponds. SPEC-13 (:284) only checks that an arm EXISTS, not the class, so `degraded` → fail would pass every gate. |
| #507 | `rc != 0` → fail; "rc always wins" | tests/unit/core-pipeline-verdict-test.sh:109, 390 | HIGH | |
| #507 | A missing primary artifact → warn + `stage.verdict.missing` | tests/unit/core-pipeline-verdict-test.sh:192-196 | MEDIUM | |
| #507 | A MALFORMED primary artifact → warn | CONTRADICTED — tests/unit/core-pipeline-verdict-test.sh:208 asserts `error` | MEDIUM | core/pipeline/verdict.sh:449-456 returns raw `error` (#1821). The table is stale (see Conflicts). |
| #1708 | Every primary manifest declares `config.valid_verdicts`; an absent key fails lint; every declared verdict is in the table and has an arm | tests/unit/lint-verdict-classify-test.sh:100, 230, 284 | MEDIUM | |
| #507 | `security-lens` output "is always treated as `pass`" | UNTESTED | LOW | |
| #527 | An unconverged `continue` cycle marks its until-stage failed and the run ends `failed` | tests/integration/cycle-on-max-pipeline-continues-test.sh:320 (weak) | HIGH | The test's own comment says `failed` comes via "no review.json rescue", not via `_RUNNER_CYCLE_UNCONVERGED`. It is not isolated. |
| #1261 | A terminating `did_not_finish` with no test signal halts as `design_timeout_exhausted` (rc=8) | tests/unit/design-timeout-exhaustion-halt-1261-test.sh:198-200 | LOW | Mostly moot now that design_verify_cycle is `on_max: halt`. |
| #2176 | `design_verify_cycle` is `on_max: halt`; ends `failed` with reason `design_not_converged` | tests/unit/design-cycle-on-max-abort-test.sh:26 (template value) | MEDIUM | The reason string `design_not_converged` is not asserted anywhere. |
| #2241 | A `halt` cycle that runs out of rounds stops the run: `failed`, `pipeline.end` names the cycle and reason, no later unit; `continue` falls through; `abort` ≡ `halt` | tests/integration/runner-cycle-on-max-halt-test.sh:85-89, 93, 97, 101 | HIGH | |

---

## ADR-020 — Deferred-Work Tracker (Proposed; Amendment v2 2026-05-31)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Decision | A separate workflow with 3× daily cron offset 30 min (02:30/10:30/18:30) and a `concurrency:` group | tests/integration/deferred-tracker-integration-test.sh:258 (concurrency) | LOW | The cron offset (.github/workflows/deferred-tracker.yml:14-16) is not asserted. |
| Decision | Auth uses `GITHUB_TOKEN`, "no PAT", minimal scopes | UNTESTED | LOW | The workflow uses GITHUB_TOKEN (yml:46,56); no assertion. |
| Hardening | Fork guard `if: github.repository == …` | tests/integration/deferred-tracker-integration-test.sh:259 | LOW | |
| Dup handling | 0 open issues → create | tests/integration/deferred-tracker-integration-test.sh:162-164 | LOW | |
| Dup v2 | 1 open with no engagement → update in place (`gh issue edit`), no close or create | tests/integration/deferred-tracker-integration-test.sh:293-301 | MEDIUM | |
| Dup | 1 open with human comments or checked boxes → append via comment, no close | tests/integration/deferred-tracker-integration-test.sh:336-338 | MEDIUM | |
| Dup | >1 open → `exit 2` + `.deferred-drift` sentinel | tests/integration/deferred-tracker-integration-test.sh:363-379 | LOW | |
| Idempotency | Log records PR numbers; a scanned PR is never re-scanned | tests/unit/deferred-tracker-idempotency-test.sh:52-69; tests/integration/deferred-tracker-integration-test.sh:225-227 | LOW | |
| Idempotency | "Since last run" anchored to `max(mergedAt)` in the log, not wall-clock | tests/unit/deferred-tracker-idempotency-test.sh:90 | LOW | |
| Idempotency | Log written only after a successful create; failure → not updated, exit 2 | tests/integration/deferred-tracker-integration-test.sh:172, 197-201 | MEDIUM | |
| Paging | >25 candidates → `Part N/M` issues | tests/integration/deferred-tracker-integration-test.sh:408 | LOW | |
| Bot skip | Bots are skipped via `author.type`, never by name substring | tests/unit/deferred-tracker-bot-filter-test.sh:23-66 | LOW | |
| Injection | Excerpts are fenced, with `#` and `@` escaped and truncated to 200 chars | tests/unit/deferred-tracker-sanitize-test.sh:26,30,39,57 | MEDIUM | |
| Shell | Body passed via `--body-file`, never `--body "$var"` | tests/integration/deferred-tracker-integration-test.sh:168 | MEDIUM | "forbids eval / bash -c" is not linted (UNTESTED part). |
| Signals | The v1 locked phrase list, case-insensitive; past-tense filtered; `phase N` excluded | tests/unit/deferred-tracker-signal-match-test.sh:23-67 | LOW | Only 9 of 16 phrases are asserted (no `not in scope`, `file separately`, `future issue`, `separate PR`, `tracked separately`, `won't fix here`, `stretch goal`). |
| Modes | `--report` is read-only; exit 0 / 10 / 2 | tests/integration/deferred-tracker-integration-test.sh:126, 162, 251-254 | LOW | |
| v2 Jaccard | Lowercase, split on non-alnum, tokens ≥4 chars, stopwords dropped, empty → 0.00 | tests/unit/gh-automation-similarity-test.sh:23-69 | LOW | |
| v2 | Float thresholds via awk / `gha_score_meets_threshold`; bash integer compare "forbidden" | tests/unit/gh-automation-similarity-test.sh:73-83 (helper) | LOW | The ban on `-ge` against `%.2f` is not linted. |
| v2 LLM | Fail-open: returns the Jaccard score plus a marker; "NEVER silently fall through" | tests/unit/gh-automation-similarity-llm-test.sh:32-161 | LOW | |
| v2 | Thresholds 0.35 (deferred) / 0.6 (manifest-sync), configurable by env | UNTESTED | LOW | |
| v2 | SHA256 race check before edit: abort if the body changed | UNTESTED (weak) — tests/integration/deferred-tracker-integration-test.sh:505 only checks that a helper exists | MEDIUM | |
| v2 | Body capped at the most recent 10 `## Update —` sections | tests/unit/deferred-tracker-rotate-sections-test.sh:97-162 | LOW | |
| v2 | manifest-sync fuzzy matches are PR-staged, never auto-flipped | UNTESTED (weak) — tests/integration/manifest-sync-similarity-test.sh:132-136 checks report mode only | MEDIUM | |

---

## ADR-020 — Inter-Stage Data Contract + Pre-flight Validator (Superseded by ADR-055 (#1820))

Superseded and kept for history. The #1750 amendment is marked Accepted but says itself that "the live contract is governed by ADR-055". Statements are audited under ADR-055 and none are listed here.

Two observations for whoever audits ADR-055:
- The runner's error messages still say the default is `warn` (core/pipeline/runner.sh:1808, 1829, and `_runner_validate_startup_preflight` defaults `warn` at runner.sh:713). `_contract_validate_pipeline` defaults to `enforce` (core/pipeline/contract-validator.sh:191). An operator reading the error on a default run is told the wrong mode.
- §"Pre-flight error format" still names `config/templates/standard.yaml`, which no longer exists.

---

## Conflicts

1. **ADR-018 #1919 amendment vs code (core/router/permissions.sh:160) and tests.** The ADR says the spawn uses `--permission-mode acceptEdits` and "`bypassPermissions` MUST NOT be used — the blanket bypass under a new name." The code (#2180) emits `--permission-mode bypassPermissions`, and tests/unit/router-permissions-test.sh:218 plus router-claude-flags-test.sh:101 require it. No ADR records this. **The code follows #2180, not the ADR.** Security posture is undocumented.
2. **ADR-016 lock 1 vs ADR-016 Amendment 2026-06-05 vs code.** Lock 1 says "full replace, no field-level merge". The amendment defines a key-level merge in which base-only stage sections are KEPT. core/pipeline/template-resolver.sh:84-87 uses a new-shape override verbatim, so base-only sections are dropped. **The code follows lock 1 as its comment reads it, contradicting the amendment.**
3. **ADR-016 B1/C3 (resume snapshot, BLOCKING) vs code.** No `template.resolved.yaml` exists; resume re-resolves from disk (runner.sh:1711). The ADR also says the ADR-006 amendment adds the snapshot to persisted state. **The code follows neither.**
4. **ADR-016 lock 2 ("never a file path") vs code.** template-resolver.sh:50 concatenates `extends:` into a path, and runner.sh:1655 does the same for `--template`, without sanitization. Multi-hop refusal is absent, and shipped deployed.yaml:3 itself declares `extends: simple`.
5. **ADR-017 §3 (one chokepoint) + §11 (manifest layer) vs core/pipeline/cycle-orchestrator.sh:2117-2127.** The orchestrator recomputes the max_turns base without the manifest layer. For a plugin with a manifest `max_turns` above 25, the ADR-029 "escalation" lowers its budget. **The code diverges from the ADR.**
6. **ADR-017 §2 vs ADR-017 §8.** §2 says "Per-stage MUST win the env var". §8's tier precedence puts env `ZBUILD_<ID>_TIER` above template `router.tier`. The code follows each section for its own knob (route.sh `_route_resolve_knob` vs scripts/lib/tier-resolve.sh). The ADR does not explain the inversion.
7. **ADR-017 header amendment line vs ADR-017 §11.** The header says router config is "resolved through the manifest-declared data path before falling through to the template/global config tiers" (manifest first). §11 and the code put the manifest BELOW template and env (route.sh:744-778). **The code follows §11; the header is wrong.**
8. **ADR-018 Decision point 5 ("Out-of-scope → … fail-closed") vs ADR-018 §Pattern 2 and #467 notes ("stage continues", "fail-soft … rc=0").** The code is fail-soft: verdict `scope_violation`, HEAD unchanged (tests/integration/build-created-oos-still-violation-test.sh:145,157).
9. **ADR-018 #530/#602 vs ADR-020 #660 §A.** ADR-018 says the pipeline captures "`git diff HEAD` … the captured diff IS the canonical `diff.patch`". ADR-020 #660 redefines it as cumulative `git diff <intake-baseline>..HEAD`. **The code follows ADR-020** (tests/unit/build-diff-cumulative-test.sh:152).
10. **ADR-018 #512 ("hardcoded ceiling … 50 inner") vs core/router/route.sh:1621.** Only `>=1` is checked at the loop. The 1..50 bound exists only in the template validator (template.sh:1621), so an env value bypasses it.
11. **ADR-018 #467 ("3 consecutive timeouts → fatal") vs #1208/ADR-029.** Code and tests (router-loop-retries-test.sh:137-141) yield non-fatally. ADR-018 was not annotated.
12. **ADR-018 DP8 / v3 (Pattern 1 MUST use the JSON envelope and the ADR-028 framework) vs plugins/agent/spec-coverage/plugin.sh:185, spec-correspondence/plugin.sh:121, issue-acceptance/plugin.sh:167.** These call `route_to_model` raw, in text mode.
13. **ADR-019 §2-§5/§7 (review-plugin coercion) vs #979 / ADR-040 gate-aggregator model.** The coercion code is gone. `review.test_status.coerced` is still declared in plugins/agent/review-aggregator/manifest.yaml:65 but never emitted. **The code follows the gate-aggregator model**, and ADR-019 is not marked superseded on those sections. gate-aggregator also lets `disposition=advisory` demote a suite failure, which ADR-019 never allows.
14. **ADR-019 #507 table ("missing/malformed primary artifact → warn") vs ADR-020 #550 + #1821 / core/pipeline/verdict.sh:449-456.** A malformed primary returns raw `error` (structural fail; tests/unit/core-pipeline-verdict-test.sh:208). **The code follows #1821.**
15. **ADR-019 #509 note (corrupt_diff gate; build returns rc=1) vs ADR-018 #602.** #602 removed `_build_apply_check`, and plugins/agent/build/plugin.sh:467 confirms the forced rc=1 was removed. `corrupt_diff` is still listed as a build verdict in ADR-019's table and in ADR-020's per-stage table, but nothing produces it. **The code follows ADR-018 #602.**
16. **ADR-016 / ADR-017 §6 / ADR-019 §1 / ADR-020 data-flow table all name `config/templates/standard.yaml` as the default or carrier.** It no longer exists; the default is `simple` (runner.sh:1639).
17. **ADR-020 (inter-stage, historical) "warn default" vs ADR-055 / contract-validator.sh:191 (enforce default) vs runner.sh:713/1808/1829.** The runner messages and the startup-preflight still default to `warn`. Three places disagree on the default mode.
