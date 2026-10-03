# ADR audit — batch 4 (ADR-034 … ADR-050), issue #2268

Paths are repo-relative to /Volumes/zHardDrive/code/zbuild-pipeline. "UNTESTED (weak)" = a test exists but only greps source/ADR text, checks existence, or uses a fixture that cannot fail on the statement. "fixture-only" = asserted against a synthetic template, not config/templates/simple.yaml.

Totals: 17 ADRs (all Accepted, most amended), ~360 normative statement rows, ~112 UNTESTED or weak (HIGH 20, MEDIUM 53, LOW 39, per-part tallies), and 45 conflicts listed below, most of them ADR text gone stale after later amendments.

## ADR-034 — Targeted test re-run in build_test_cycle (Accepted 2026-06-15; amended #929, #1208, #2117 [superseded by #2144], #2121, #2144)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Amend #2121 | targeted set = red set ∪ tests naming the changed repo-relative PATH ∪ tests naming a UNIQUE basename ∪ the changed plugin's own `tests/` ∪ design TESTFILES | plugins/tool/test/tests/test-test.sh:521-531 (T14: path, unique basename, plugin-local, design TESTFILES included; non-unique `plugin.sh` word, other plugin, unrelated excluded) | MEDIUM | |
| Amend #2121 | an unresolvable red-set hint is dropped (advisory, not a target) | plugins/tool/test/tests/test-test.sh:538 (T14b) | LOW | |
| §1 | red set is built from `^(unit\|...): FAIL <path>` lines | plugins/tool/test/tests/test-test.sh:471-487 (T13/T13b) | MEDIUM | |
| §2 | targeted command is the `ZBUILD_TEST_CMD_TARGETED` `{files}` template, rendered with shell-quoted list; empty template/list → empty (caller runs full) | plugins/tool/test/tests/test-test.sh:545-551 (T15) | LOW | |
| §2 | with no template, defaults to `scripts/run-tests.sh --files {files}` when present; otherwise full command, `run_mode` stays `"full"` (never a broken targeted run) | UNTESTED | MEDIUM | every test sets `ZBUILD_TEST_CMD_TARGETED` explicitly (test-test.sh:591,633; integration:59); the auto-default branch plugins/tool/test/plugin.sh:361-363 and the no-run-tests.sh fallback are never exercised |
| §2 | targeted runner runs every file independently (no `&&` short-circuit) and emits the same `unit: N/M passed` grammar as a full run | tests/unit/run-tests-files-guard-test.sh:153 (#2123: rc/stdout identical serial vs parallel, failing file still fails) + :56-61 | MEDIUM | no-short-circuit is implied (all files counted) rather than asserted with a failing-first file |
| §3 / #2144 | a green targeted subset is confirmed by the full command IN THE SAME invocation; reports `run_mode: targeted+full`, full run's verdict/counts/red set/tree_sha, subset under `data.targeted` | plugins/tool/test/tests/test-test.sh:599-615 (T16) | HIGH | |
| §3 / #2144 | a red subset is reported as `run_mode: targeted`, full command does NOT run, no tree_sha | plugins/tool/test/tests/test-test.sh:640-648 (T17) | MEDIUM | |
| §3 / #2144 | the orchestrator knows nothing of run modes (`_cycle_read_test_run_mode`, `ZBUILD_TEST_FULL_SUITE_GATE`, `cycle.test.full_suite_gate` deleted) | tests/unit/core-pipeline-cycle-final-gate-test.sh:82-90 (T8) + :124 (T9: stale targeted artifact doesn't hold cycle) | MEDIUM | T8 is a source-absence grep but the deletion IS the rule; T9 is behavioral |
| §3 / #2144 | end-to-end: iter-2 targeted pass converges on iteration 2, no third iteration | tests/integration/build-test-cycle-targeted-rerun-test.sh:120-129 | HIGH | |
| Impl | `_cycle_apply_feedback` exports `ZBUILD_TEST_RED_SET` / `ZBUILD_TEST_CHANGED_FILES`; unset when absent | tests/unit/core-pipeline-cycle-final-gate-test.sh:46-76 (T4–T7) | MEDIUM | |
| #929 (1) | `--files` skips any input that is not `*-test.sh`, before the N/M count | tests/unit/run-tests-files-guard-test.sh:56-61 (G1) | MEDIUM | |
| #929 (2) | every test-file invocation runs with `</dev/null` | tests/unit/run-tests-files-guard-test.sh:67-70 (G2, behavioral) + tests/unit/scripts-run-tests-fd3-test.sh:55 (source grep) | HIGH | a stdin block wedged a stage 3.5h |
| #929 (3) | each file is wrapped in `gtimeout`/`timeout` (`ZBUILD_TEST_FILE_TIMEOUT`, "default 300s", 0 disables); hung file surfaces as a per-file result, not an unbounded wait | tests/unit/run-tests-files-guard-test.sh:83-92 (G3) | HIGH | default value is CONTRADICTED by code: scripts/run-tests.sh:22 uses 480 (see Conflicts). G3 now asserts TIMEOUT, not `FAIL` as the ADR says (#1613) |
| #929 (3) | `ZBUILD_TEST_FILE_TIMEOUT=0` disables the bound | UNTESTED | LOW | |
| #929 | the `3>/dev/null` fd-3 guard is preserved in `_rt_run` | tests/unit/scripts-run-tests-fd3-test.sh:51 (source grep) + :70-71 (behavioral probe) | MEDIUM | |
| ADR-036 #1660 (applies to run-tests.sh) | per-file bound escalates TERM→KILL with `-k` grace (`ZBUILD_TEST_KILL_GRACE`, 10s) | tests/unit/run-tests-timeout-report-test.sh:156 (RT-K behavioral) | HIGH | |
| #1208 | a mid-flight build (`did_not_finish`/interrupted) flips converged→not converged and emits `cycle.build_unfinished.suppressed_convergence` | tests/unit/convergence-timeouts-never-fatal-1208-test.sh:170-176 | HIGH | |
| #1208 | the mid-flight suppression has NO max_iterations fail-safe (suppresses even on the last iter) | tests/unit/convergence-timeouts-never-fatal-1208-test.sh:220 (SPEC-5b exhausted + mid-flight every iter → rc=2) | HIGH | |
| #1208 | a clean empty-diff stall is a resting point and NOT suppressed | tests/unit/convergence-timeouts-never-fatal-1208-test.sh:195-202 | MEDIUM | |

## ADR-035 — Orchestrator Run-State Isolation (Accepted 2026-06-15; amended 2026-07-01 run-hygiene, 2026-08-22 reclaimer reversal, 2026-08-23 #141 → ADR-059 §1)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §1 | default orch scratch is `runs/<run_id>/orch`, computed at USE time by `_strategy_orch_scratch_dir` | tests/unit/core-orch-run-id-isolation-test.sh:34 (S1) | MEDIUM | |
| §1 | distinct run_ids → distinct scratch dirs | tests/unit/core-orch-run-id-isolation-test.sh:39-44 (S2) | MEDIUM | |
| §1 | explicit `ZBUILD_ORCH_SCRATCH` overrides | tests/unit/core-orch-run-id-isolation-test.sh:48 (S3) | LOW | |
| §1 | `contract.sh` no longer bakes a source-time flat default | UNTESTED | LOW | |
| §2 / #141 | pool dirs live at `runs/<run_id>/pool/zbuild-pool-<id>` under the issue/goal area — never `${TMPDIR}` — for BOTH bash-parallel and sequential backends | tests/unit/adr059-no-tmpdir-defaults-test.sh:56-68 (SPEC-3/4: under `$STATE_DIR/pool`, not FAKE_TMP) + tests/unit/core-orch-run-id-isolation-test.sh:59,80 | HIGH | |
| §2 | same pool_id, different run → distinct pool dir | tests/unit/core-orch-run-id-isolation-test.sh:65 (P2) | MEDIUM | |
| §2 | explicit `ZBUILD_POOL_ROOT` overrides (both backends) | tests/unit/core-orch-run-id-isolation-test.sh:71,83; adr059-no-tmpdir-defaults-test.sh:74 | LOW | |
| §2 | pool dirs are reaped by `orch_shutdown` | tests/integration/core-orch-contract-test.sh:184; tests/integration/core-orch-parallel-test.sh:212 | MEDIUM | |
| Amend 08-22 | dedicated reclaimer `_cleanup_scan_orch_pools` (`zbuild cleanup --orch-pools`, default set) collects pools of killed runs | tests/unit/cleanup-new-reclaimers-test.sh:179 (SPEC-3) | HIGH | the test AND the scanner use the pre-#141 location `${TMPDIR}/zbuild-runs/` (scripts/lib/cleanup.sh:1315); post-#141 pools sit under `runs/<run_id>/pool` which this scanner never visits. The reclaimer is vestigial; tested against a layout nothing produces (see Conflicts) |
| Amend 08-22 | the pool scanner skips a pool whose run is still active and reports the guard | UNTESTED | MEDIUM | the active-run skip is asserted only for the scratch reclaimer (cleanup-new-reclaimers-test.sh:68), not pools |
| Run-hygiene | unpinned event-bus location is process-scoped under the DATA ROOT, never `${TMPDIR}`, never the shared global default | tests/unit/adr059-no-tmpdir-defaults-test.sh:36; tests/integration/per-run-state-isolation-test.sh:260-275 (T9) | MEDIUM | ADR text still says "implementation has not yet followed — see #2004"; #2004 is CLOSED and code (core/event-bus/event-bus.sh:45) follows it — doc stale |
| Run-hygiene | unpinned event dir is "reclaimable by path" (a reclaimer deletes `runs/<id>/` or `issues/<N>/`) | UNTESTED | MEDIUM | code puts it at `<data_root>/ephemeral-events/$$` (event-bus.sh:45), which is neither `runs/` nor `issues/`; no reclaimer names it. Contradicts the stated property |
| Run-hygiene | explicit `ZBUILD_EVENTS_DIR` pin wins | tests/unit/adr059-no-tmpdir-defaults-test.sh:47 | LOW | |
| Run-hygiene | when only `ZBUILD_EVENTS_JSONL` is pinned, the dir (SQLite mirror + lock) is derived from it | UNTESTED | MEDIUM | event-bus.sh:46-47 |
| Run-hygiene | `--no-resume` clears stale global-default `events.{jsonl,db}` + `.lock` at startup | tests/integration/per-run-state-isolation-test.sh:222-225 (T7) | MEDIUM | |
| Run-hygiene | an engine run writes events under its per-run dir and never recreates the shared global `events.jsonl` | tests/integration/per-run-state-isolation-test.sh:229-234 (T8) | MEDIUM | |
| Run-hygiene | best-effort trap teardown removes the run's own `.lock` siblings on exit | UNTESTED | LOW | |
| Run-hygiene | the ephemeral dir joins `ZBUILD_TMPDIR_PATTERNS` (`zbuild-ephemeral-events.*`) | n/a — superseded | LOW | removed by #2017 (scripts/lib/cleanup.sh:443); ADR text stale |
| — | `run_id` falls back to `default` when unset | UNTESTED | LOW | |

## ADR-036 — Acceptance-contract teeth (Accepted 2026-06-17; amended ~25 times through #2244/#2243 2026-09-30; Level 1 shifted to design-gate by ADR-046/#1218; #1219 superseded by #1583; self-hosting note superseded by ADR-057 §5/#1768; build authorship superseded by #2022)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Amend 07-01 | stage id `acceptance-gate` binds `roles: [acceptance_gate]`; plugin `spec-acceptance`; result `acceptance-gate-result.json` | UNTESTED (weak) | LOW | config/templates/simple.yaml:411-413 + manifest role; only incidentally exercised by integration tests that dispatch the stage |
| Amend 07-01 / §4 | unmet precondition → `verdict=pass reason=precondition_unmet precondition=<id>` + `acceptance.gate.skipped` (no block; placeholder block) | tests/integration/acceptance-gate-test.sh:141-145 (S4), :297-300 (S9); tests/integration/acceptance-gate-v2-reader-test.sh:115-117 | MEDIUM | `merge_base_resolvable` precondition not asserted |
| Amend 07-01 | a malformed block is a violation (fail closed), not a no-op | tests/integration/acceptance-gate-test.sh:156-157 (S5); acceptance-gate-v2-reader-test.sh:121-122 | HIGH | |
| Amend 07-01 | a declared-but-missing TESTFILE is a violation, not a no-op | tests/integration/acceptance-gate-test.sh:405-412 (S10b) | HIGH | now recoverable (#1959), not terminal as §Phase-2 table says |
| §1 | legacy bare `SPEC:` lines still parse; only `SPEC-n:` carry enforced ids | tests/unit/acceptance-block-test.sh:195-197 (TC-7, ids) | LOW | legacy-bare path not specifically asserted |
| §2 | every `SPEC-n` needs ≥1 tagged assertion across TESTFILES, else `untagged_spec` + event | tests/integration/acceptance-gate-test.sh:130-131 (S3), :324-326 (S10) | HIGH | ADR status says Level 1 moved to design-gate, yet the post-build gate still enforces it (both do) |
| §3 | a `[change]` SPEC's tagged test must fail at merge-base and pass at HEAD; passing at baseline → `tautology`; red at HEAD → `not_passing_at_head` | tests/unit/acceptance-negctl-test.sh:96-104 (NC-A..D); tests/integration/acceptance-gate-test.sh:113-115 (S2), :252-253 (S7) | HIGH | the core teeth |
| §3 / #1715 | merge-base==HEAD → one `NEGCTL SKIP <spec> no_impl_delta` per SPEC, rc=0; bare fallback line when roster unreadable | tests/unit/acceptance-negctl-test.sh:117-119 (NC-E), :645-647 (NC-K3); test-only diff → per-SPEC `no_prod_delta` :592-634 | MEDIUM | |
| §5 | gate runs inside `build_review_cycle` after `build_test_cycle`, before CQ stages | UNTESTED — and contradicted | LOW | no `build_review_cycle` exists in any template; gate is a member of `build_test_cycle` (config/templates/simple.yaml:221-240). Doc stale |
| Conseq. | gate events registered (`acceptance.gate.*`) | tests/unit/event-schema-emitted-coverage-test.sh (emitted-event coverage guard) | LOW | registration moved to manifest `provides.events` (plugins/agent/spec-acceptance/manifest.yaml:81-105), not `config/event-schema.json` as ADR says |
| Impl | negctl worktree is removed via a RETURN trap | UNTESTED | MEDIUM | leaked worktrees were a real class (mutation teardown) |
| Impl | default `ZBUILD_NEGCTL_TIMEOUT` = 60s | UNTESTED | LOW | |
| #951 / #2022 | gate findings reach the assertion author via `prior_acceptance_feedback` (`acceptance-gate.gate_result → … prior_acceptance_feedback`) | UNTESTED — and contradicted | MEDIUM | no feedback edge in simple.yaml (#1979 retired it: simple.yaml:266-268); findings now reach test-author via engine-injected summaries. build reader retirement asserted at tests/unit/build-acceptance-spec-feedback-test.sh:121-135 |
| #956 | `WIRING:` lists repo-relative targets; `WIRING: none` → pass + `acceptance.gate.wiring_exempt` | tests/unit/acceptance-block-test.sh:215-257 (TC-8..10); tests/integration/acceptance-gate-reachability-test.sh:168-170 (R3) | MEDIUM | |
| #956 | absolute / `..` WIRING paths rejected (fail closed) | tests/integration/acceptance-gate-reachability-test.sh:209-212 (R4, fixture `../../etc/passwd`, `/etc/hosts`) | MEDIUM | |
| #956 | wiring reverted at merge-base with all other changes from HEAD; ≥1 TESTFILE must flip pass→fail, else `inert_wiring` (verdict=fail + event) | tests/integration/acceptance-gate-reachability-test.sh:85-86 (R1), :127-131 (R2) | HIGH | |
| #956 | Level 3 runs only after Levels 1+2 pass | CONTRADICTED by code | LOW | plugins/agent/spec-acceptance/plugin.sh:471 — "#1220: runs REGARDLESS of Level 1/2 outcome". ADR not amended |
| #2109 | reachability: TESTFILE red at HEAD → `not_passing_at_head` (never inert_wiring); rc126/127 → harness ERROR; none on disk → `no_testfiles`; flip judged per tagged line | tests/unit/acceptance-gate-reachability-test.sh:175-218 (B1–B5); tests/integration/acceptance-gate-npah-from-reachability-test.sh:75-99 | HIGH | |
| #2110 | each TESTFILE executed at most once per side per gate pass; per-SPEC logs replayed | tests/unit/acceptance-gate-runs-per-file-test.sh:98-110, :147 | MEDIUM | |
| #2110 | per-run bound = max(negctl_timeout, 3× measured) clamped to 480; unmeasured keeps stage bound | tests/unit/acceptance-gate-runs-per-file-test.sh:154-162 | MEDIUM | `acceptance.gate.file_timeout` event not asserted |
| #1188 | a timeout on either run is INFRA (`negctl_error:timeout:<sid>` + `negctl_timeout` event), never control/violation/flip | tests/integration/acceptance-gate-test.sh:273-277 (S8); tests/unit/acceptance-negctl-test.sh:468-472 (NC-G) | HIGH | skips if no timeout binary |
| #1188 | precedence env `ZBUILD_NEGCTL_TIMEOUT` > template `negctl_timeout_s` > 60s | UNTESTED (weak) | LOW | only the template accessor is tested (tests/unit/core-pipeline-template-router-tier-test.sh:174-216); `_ag_resolve_negctl_timeout` precedence never asserted |
| #1188 | per-SPEC/WIRING output captured to size-bounded (64 KiB) logs | UNTESTED (weak) | LOW | capture asserted (acceptance-gate-quiet-test.sh:89,133; acceptance-negctl-test.sh:950); the 64 KiB bound is not |
| Phase 2 / #2161 | the plugin owns class→severity mapping; terminal outranks; table values (untagged/tautology/inert/guard_regressed/npah/wiring_not_on_path → recoverable; negctl/reachability_error → advisory; malformed → terminal) | tests/unit/acceptance-disposition-classify-test.sh:29-109 | HIGH | `no_testfile` is recoverable in code (:104) though the ADR table lists it terminal (see Conflicts) |
| #2161 | `disposition` is `complete` on every concluded path; `reason` always written; policy word lives in `severity` | tests/integration/acceptance-gate-v2-reader-test.sh:89-122 | HIGH | |
| #2161 | cycle halts only on `severity==terminal`; aggregator demotes `severity==advisory` (disposition as v1 fallback) | tests/integration/acceptance-gate-v2-reader-test.sh:155-162; tests/unit/core-pipeline-cycle-acceptance-terminal-test.sh:91-137; tests/integration/cycle-acceptance-terminal-failure-test.sh:370-427 | HIGH | |
| #1211 | sandbox runners unset `ZBUILD_STAGE_IO_FD` and close/redirect fd 3; nested output never reaches the terminal | tests/integration/acceptance-gate-quiet-test.sh:84-89, :128-133; tests/unit/acceptance-negctl-test.sh:758 (NC-N) | MEDIUM | |
| #1211 | operator summary = one line per SPEC and per WIRING target | tests/integration/acceptance-gate-quiet-test.sh:206-214, :256-258 | LOW | |
| #1265 | 0 commits ahead + build verdict ≠ empty_diff → `no_committed_changes`, rc=5, halts before review/pr | tests/integration/cycle-no-committed-changes-fail-fast-test.sh:100-113 | HIGH | |
| #1265 | clean `empty_diff` resting point is exempt | tests/integration/cycle-no-committed-changes-fail-fast-test.sh:168-174 | MEDIUM | |
| #1265 | pr-open refuses a 0-commit branch BEFORE push/`gh pr create` (ADR: `plugin.run.error`, rc=2) | tests/unit/pr-open-zero-commits-halts-test.sh:76-93 | HIGH | test pins rc=1 + `plugin.result verdict=error`; ADR's rc=2 is stale |
| #1583 | tautology at iter 1 declares no fault (test-author re-authors) | tests/integration/acceptance-gate-test.sh:350-352 (S12); tests/integration/acceptance-gate-tautology-escalation-test.sh:81 | HIGH | |
| #1585 | tautology and inert_wiring are recoverable, not terminal | tests/unit/acceptance-disposition-classify-test.sh:29-37; acceptance-gate-test.sh:323 | HIGH | |
| #1660 | negctl/reachability bound escalates to KILL (`-k`, `ZBUILD_NEGCTL_KILL_GRACE`) | tests/unit/acceptance-negctl-test.sh:788 (behavioral), :800 (argv) | HIGH | |
| #1660 | `-k` support is probed; without it, TERM-only bound (never condemn every run with rc125) | tests/unit/acceptance-negctl-test.sh:831 (NC-P3) | MEDIUM | |
| #1660 | `_acceptance_timeout_prefix` resolves `gtimeout` too | UNTESTED | MEDIUM | without it gates are unbounded on macOS w/o POSIX `timeout` |
| #1660 / 09-28 | rc 124 (and 137 when kill-after is in use) = timeout; rc 137 otherwise → `NEGCTL ERROR sigkill:` (infra) | tests/unit/acceptance-negctl-signal-test.sh:123,142,162; tests/unit/acceptance-negctl-test.sh:858-860; tests/unit/acceptance-gate-reachability-test.sh:25-65 | HIGH | |
| 09-28 | other signal exits (e.g. 143) with no own verdict → `killed_by_signal` (recoverable), not timeout; a verdict printed before death still counts | tests/unit/acceptance-negctl-signal-test.sh:102-111, :171-184 | HIGH | unit reachability test still asserts `_reachability_is_timeout_rc 143 → true` (acceptance-gate-reachability-test.sh:32) — reachability was not moved to the new rule (see Conflicts) |
| #1686 | WIRING target absent from the diff → `wiring_not_on_path` (not inert_wiring), recoverable, design-rooted | tests/unit/acceptance-gate-reachability-test.sh:94-137; tests/integration/acceptance-gate-test.sh:446-454 (S15) | HIGH | carrier is now `fault=specification`, not `route_target=design` |
| #1686 | empty `changed_files` with head≠base fails closed as `REACHABILITY ERROR diff_failed` | UNTESTED | HIGH | without it every target reads off-diff and rewinds every run to design |
| #2252 (code, not in ADR) | in-scope `wiring_not_on_path` at iter 1 is build's turn (no fault) | tests/integration/acceptance-gate-wiring-in-scope-test.sh:102-111 | MEDIUM | behaviour contradicts #1686's "routes immediately to design"; ADR not amended |
| #1684 | each per-SPEC line carries `design :` and `asserts:` sub-lines; verdict token still leads its line; `<no description>` / `<none found>` placeholders | tests/integration/acceptance-gate-test.sh:477-526, :550-554 | LOW | 100-char truncation not asserted |
| #1684 | label = first line that INVOKES an assertion helper (fixture text only as fallback) | UNTESTED (weak) | LOW | tests/unit/acceptance-coverage-test.sh:117 checks a label is found, not the fixture-text precedence |
| #1684 | summary persisted to `artifacts/acceptance-summary.txt` on every path | tests/integration/acceptance-gate-test.sh:487-489; tests/integration/acceptance-gate-quiet-test.sh:287-291 | MEDIUM | |
| #1670 | `[guard]` must PASS at baseline → `NEGCTL PASS <id> guard_spec`; fails with own ✗ → `guard_regressed` (fail); `guard_spec` SKIP no longer emitted | tests/unit/acceptance-negctl-test.sh:148-189, :438-440 (NC-F7); acceptance-gate-test.sh:195-204 | HIGH | |
| #1670 | baseline unparseable (`bash -n`) or rc126/127 → `NEGCTL ERROR harness:` (advisory) | tests/unit/acceptance-negctl-test.sh:303-338; acceptance-gate-test.sh:225-236 | MEDIUM | |
| #1670 | untagged guard → `NEGCTL SKIP guard_untested`, does not fail | tests/unit/acceptance-negctl-test.sh:368-371 | MEDIUM | |
| #1711 | inert_wiring at iter≥2 → specification fault + `inert_wiring_escalated`; iter 1 none; severity stays recoverable | tests/integration/acceptance-gate-reachability-test.sh:315-335; tests/integration/acceptance-gate-inert-wiring-iter1-test.sh:113-127 | HIGH | ADR says `route_target="design"`; code sets `fault=specification` (plugin.sh:660) |
| #1777 | `guard_regressed` is design-rooted (fault=specification), recoverable | tests/integration/acceptance-guard-regressed-routes-design-test.sh:100-134 | HIGH | |
| #1777 | design-gate C6 rejects a guard failing at baseline; fails OPEN (GUARD SKIP) on missing baseline/worktree/timeout/unparseable/untagged; records `guard_precheck`; key absent when no guards | tests/unit/design-gate-guard-baseline-test.sh:135-312 | MEDIUM | |
| #1777 | C6 and the acceptance gate share `_negctl_guard_resolve_tfs` / `_negctl_guard_verdict` so they cannot disagree | UNTESTED (weak) | LOW | |
| #2022 | test-author leads `build_test_cycle`; never sees the diff | UNTESTED (weak) | MEDIUM | order is in simple.yaml:229; no test asserts ordering or diff isolation |
| #2022 | build is denied Edit on declared TESTFILES (by role); test-author is not | tests/unit/lifecycle-testfile-deny-role-test.sh:97-113 | HIGH | |
| #2022 | `assertion-integrity` fails the cycle when a testfile differs from the author's recorded digest | tests/unit/assertion-integrity-test.sh:67-90 | HIGH | no digest → skip (SPEC-5, :88), a fail-open path |
| #2097 | `not_passing_at_head` recoverable; iter≥2 → fault=specification + `_escalated` event | tests/unit/acceptance-disposition-classify-test.sh:71-75; tests/integration/acceptance-gate-test.sh:379-380 (S14); tests/integration/acceptance-gate-npah-escalation-test.sh:76-93 | HIGH | |
| #2097 | still terminal: `no_testfile`, `malformed_acceptance_block` | tests/unit/acceptance-disposition-classify-test.sh:102 (malformed only) | MEDIUM | `no_testfile` is RECOVERABLE in code (:104) — contradicts this line |
| #2157 | tautology at iter≥2 → fault=specification + `tautology_escalated`; severity recoverable | tests/integration/acceptance-gate-tautology-escalation-test.sh:87-97 | HIGH | |
| 09-28 tag | under an issue the tag is `[#<issue>/SPEC-n]` (built only by `acceptance_spec_tag`); bare `[SPEC-n]` with no issue; the forms never match each other | tests/unit/issue-scoped-spec-tags-test.sh:64-81 (T1–T3) | HIGH | |
| 09-28 tag | test-author's stale-tag step touches only THIS issue's tags | tests/unit/issue-scoped-spec-tags-test.sh:99-105 (T4) | HIGH | stripping other issues' tags silently deletes coverage |
| 09-28 tag | every reader (coverage, negctl, reachability, label) and the prompts use `acceptance_spec_tag` | UNTESTED (weak) | MEDIUM | T5–T7 (:111-125) grep source for the call |
| #2234 | only an assertion's own printed verdict is evidence; unreached → `guard_unreached` / `unreached_at_base` / `unreached_at_head` (never design); 126/127 after other verdicts = unreached | tests/unit/acceptance-negctl-unreached-test.sh:160-237, :307-310 | HIGH | |
| #2234 | `guard_unverified` still fails; no fault round 1 (about=testfile); fault=specification round 2 | tests/unit/acceptance-negctl-unreached-test.sh:264-268 (U7); acceptance-negctl-test.sh:219-221 | HIGH | |
| #2234 | `about` names the testfile(s) when every finding is unmeasured | tests/unit/acceptance-negctl-unreached-test.sh:232,265,310 | MEDIUM | |
| #2234 | design-gate precheck fails open on unreached/unverified | tests/unit/acceptance-negctl-unreached-test.sh:184-188 (U5) | MEDIUM | |
| #2244 | guard ✗ at baseline AND HEAD → `guard_test_broken`, recoverable, about=testfile, no fault, design-gate fails open | tests/unit/acceptance-negctl-guard-broken-test.sh:51-88 | MEDIUM | |
| #2243 | design `supersedes` block lists checks the change makes wrong; test-author gets them (prompt + context paths); only listed tags editable; build stays read-only | tests/unit/test-author-supersedes-test.sh:68-117 | MEDIUM | "only listed tags editable" is asserted via prompt text (:114), not enforced on disk |

## ADR-037: Objective gates vs. semantic judgment (Accepted 2026-06-19)

Disposition: the §6 supersede/amend map was executed by EPIC #1129 / ADR-040, not by I13. The monolith was decomposed into gate stages plus `gate-aggregator`. §1 and §3 ("no objective gate is an LLM") are effectively amended by ADR-040's #2040 amendment, but ADR-037 carries no back-reference to it. ADR-046 extends §3.

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §1 | "full test suite green" is a blocking objective gate | tests/integration/simple-yaml-build-test-convergence-test.sh:54 (exit_when = gate-aggregator); tests/unit/gate-aggregator-test.sh:104 (suite error → fail) | HIGH | `test` is a `convergence: gate` member of build_test_cycle |
| §1 | lint / shellcheck is a blocking gate | UNTESTED | MEDIUM | lint-gate was dropped from simple.yaml (#1129 Change C, simple.yaml:210-218). It now blocks only if the `test` stage's suite runs lint |
| §1 | `negctl`: a changed-behaviour test must fail at the merge-base (blocks) | tests/integration/acceptance-gate-test.sh:113, :252 | HIGH | |
| §1 | reachability ablation: reverting the wiring must break a test (blocks) | tests/integration/acceptance-gate-reachability-test.sh:127-130 | HIGH | |
| §1 | reachability/negctl are "de-ceremonied … no `WIRING`/SPEC grammar" | UNTESTED, and contradicted | LOW | design-gate still requires `[change]/[guard]` + `WIRING` (simple.yaml:330-336). The Limitations section defers this to #971 |
| §1 | shape-change / golden-order floor blocks | tests/unit/shape-floor-content-stable-test.sh:70; tests/unit/gate-aggregator-test.sh:256 | HIGH | |
| §1 | coverage floor is a pipeline gate | UNTESTED | MEDIUM | CI `coverage` job only. coverage-gate is dormant (simple.yaml:214-217) |
| §1 | scope-adherence ("files the design/plan named were actually changed") hard-blocks | UNTESTED, not implemented | MEDIUM | no such gate exists. Contradicted by the ADR-038 2026-09-28 amendment #5 (see Conflicts) |
| §1 | coverage-delta is "a report signal, never a block" | UNTESTED, not implemented | LOW | no coverage-delta code anywhere |
| §1/§3 | "No objective gate is an LLM" (the gate stage contains no LLM/router call) | UNTESTED (weak) | MEDIUM | tests/unit/gate-v2-contract-test.sh:363 only checks that 7 tool manifests lack router budget knobs. Superseded in practice: spec-coverage and issue-acceptance are LLM gates (ADR-040 #2040) |
| §2/§3 | the review stage emits a report and never blocks | tests/unit/review-aggregator-test.sh:86; tests/integration/review-report-advisory-flow-test.sh:115 | HIGH | but see the Conflicts entry on pr-open refusing when the report is absent |
| §2 | review "never coerces a verdict" | tests/unit/review-aggregator-test.sh:105; tests/integration/review-report-advisory-flow-test.sh:119 | HIGH | review-aggregator-test.sh:115 is a source-token grep (weak). :105 is behavioural |
| §4 | `merge_policy` ∈ {auto_unless_flagged, auto, manual}; any other value is refused | tests/unit/template-merge-policy-test.sh:183, :188 | LOW | |
| §4 | a template that omits `merge_policy` gets `auto_unless_flagged` | tests/unit/template-merge-policy-test.sh:154 | MEDIUM | |
| §4 | `auto_unless_flagged`: auto-merge only when gates are green AND no top-severity finding, otherwise escalate to a PR | tests/integration/merge-policy-auto-unless-flagged-test.sh:125, :225, :250 | HIGH | |
| §4 | `auto_unless_flagged` also escalates on "lens disagreement" | UNTESTED, not implemented | MEDIUM | pr-delivery/plugin.sh:109-126 reads only severity and readiness |
| §4 | `auto`: merge whenever gates are green; "the report is informational only" | tests/integration/merge-policy-auto-test.sh:117, :147 | HIGH | the code is stricter: auto with no review → no merge (:245). See Conflicts |
| §4 | `manual`: always stop at a PR; a human merges | UNTESTED | HIGH | no test drives pr-delivery with `manual`. It works today only because there is no `manual` branch (pr-delivery/plugin.sh:86-150 falls through to pr-open) |
| §5 | no stage upgrades or self-certifies merge authorization; merge happens only via `merge_policy` | UNTESTED | MEDIUM | nothing asserts that `merge_run` / `gh pr merge` is reachable only from pr-delivery's policy branches |
| §5 | a non-green suite "halts before review" (the ADR-019 fail-closed rule) | UNTESTED, and contradicted | MEDIUM | simple.yaml:259 `on_max: continue`. tests/integration/build-test-cycle-fallthrough-to-review-test.sh:194 asserts that review DOES run (pipeline then ends `failed`) |

## ADR-038: Adversarial multi-lens review report (Accepted 2026-06-19)

Disposition: the single-stage packaging (§1, §4 orchestration) was superseded by ADR-040 §3/§4 (C3 #1142: `review_lenses` + `review-aggregator`). §2's change-bundle basis was amended by #1655. The ADR also has the Issue OUT amendment and the 2026-09-28 amendment. Lens content and the evidence-fed contract are kept.

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §1 | single pass with no remediation cycle; the lens group sits outside any cycle | tests/unit/template-simple-yaml-test.sh:214 (dispatch[6] = `map:review_lenses`, a top-level unit) | LOW | |
| §1 | one isolated call per lens, lenses fanned out concurrently | tests/integration/map-review-lenses-dispatch-test.sh:123, :129-133 (6 units, each element once) | LOW | concurrency itself is not asserted for review_lenses |
| §1 | review runs "after the objective gates pass" | tests/unit/template-simple-yaml-test.sh:214 (order only) | MEDIUM | the "pass" part is contradicted by on_max: continue (see ADR-037 §5) |
| §2 | each lens is fed DISTINCT mechanical evidence (reachability result, coverage map + negctl, design decisions, call graph) | UNTESTED for the production lens path | MEDIUM | `_review_lens_evidence_path` (review-lens/plugin.sh:178-191) maps only design-conformance, test-coverage, architecture and correctness. None of simple.yaml's other lenses (security, performance, red-team, scope, sre) has a mapping, and no simple.yaml stage writes call-graph.json, coverage-map.json or reachability-ablation.json, so every lens reads the diff bundle. tests/unit/call-graph-evidence-test.sh:94 exercises the retired review-report plugin |
| §2 | "A lens whose evidence is unavailable says so in the report rather than guessing" | UNTESTED, and contradicted | MEDIUM | the code falls back silently to the bundle (review-lens/plugin.sh:187-191). review-lens-test.sh:184 asserts that silent fallback |
| §2 | the change bundle is the full-branch merge-base diff via `zbuild_change_bundle`; review, review-lens and review-report share one basis | tests/unit/review-lens-report-merge-base-bundle-test.sh:63, :84, :91, :153 | MEDIUM | |
| §2 (#1655) | no `HEAD~1` guess; an unresolvable baseline returns empty | tests/unit/merge-base-default-branch-test.sh:80-83, :107 | HIGH | |
| §2 | fallback chain merge-base → `diff.patch` → "(no change bundle available)"; it never crashes | tests/unit/review-lens-report-merge-base-bundle-test.sh:134 (diff.patch step) | LOW | the sentinel step is UNTESTED. review-lens-test.sh:119 asserts only that empty evidence still routes |
| §3 | output is a report; it "never hard-blocks merge" | tests/unit/review-aggregator-test.sh:86, :268 | HIGH | pr-open refuses the PR when no review signal exists (pr-open/plugin.sh:185-193). See Conflicts |
| §3 | no `approve`/`request_changes`/`block` mutation | tests/unit/review-aggregator-test.sh:105; tests/integration/review-report-advisory-flow-test.sh:119 | HIGH | |
| §3 | aggregated and de-duped by file + category + proximity | tests/unit/review-aggregator-test.sh:92-98 | LOW | |
| §3 | escalation to a human PR is decided by `merge_policy` from top-severity findings | tests/integration/merge-policy-auto-unless-flagged-test.sh:250 | HIGH | |
| Lim. | "New lenses must declare their evidence input" | UNTESTED | LOW | review-lens declares one shared input set for all elements |
| Amend OUT | the aggregator prints the rendered `.md` to `fd ${ZBUILD_STAGE_IO_FD:-2}` only when its io dests include stdout | tests/unit/review-aggregator-test.sh:210, :220-222 | LOW | |
| Amend OUT | lens members are file-only; one human-readable line per lens, no raw JSON | tests/integration/review-lenses-output-test.sh:111, :116-126 | LOW | |
| 09-28 #1 | the lens prompt carries the issue, the SPECs and the planned scope | plugins/agent/review-lens/tests/review-lens-context-unit-test.sh:87-89 | MEDIUM | |
| 09-28 #2 | the lens is told to read around the change, not only the diff | review-lens-context-unit-test.sh:93-97 | LOW | |
| 09-28 #3 | each finding carries `introduced`; only introduced (or unsaid) findings count; the rest go under `pre_existing` | review-lens-context-unit-test.sh:116-119, :143-147 | MEDIUM | |
| 09-28 #4 | review-lens declares `prompt.repo_rules`, framed for a reviewer | review-lens-context-unit-test.sh:122, :127-131 | LOW | |
| 09-28 #5 | scope lens: planned-but-untouched files are not findings | review-lens-context-unit-test.sh:135-137 | LOW | conflicts with ADR-037 §1 scope-adherence |
| 09-28 #6 | a lens is never shown its own previous review | review-lens-context-unit-test.sh:102-104 | MEDIUM | |

## ADR-039: Parallel stage groups, `type: parallel` (Accepted 2026-06-27)

Disposition: amended by ADR-042 (member plugin resolution) and ADR-043 (the C6 refusal gate became a per-stage dedup). Phase 2 roster discovery was retired by #1842 (2026-09-30 note). simple.yaml's lens group was converted to `type: map` (ADR-047 §2, #1295). **No production template uses `type: parallel` today**, so every runtime rule below is latent: it is exercised only by fixtures.

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §1 | a `type: parallel` section with `flow:` of member ids; members are top-level leaf sections; the group folds into one dispatch unit | tests/unit/core-pipeline-template-parallel-test.sh:56-79 | LOW | |
| §1 | member `flow:` order is membership plus the stable order for aggregation and reporting, not execution order | tests/integration/parallel-orchestrator-test.sh:329 (declaration-order hook) | LOW | |
| §2 | bounded concurrent dispatch through a FIFO pool (wait on the oldest PID, no `wait -n`) | tests/integration/parallel-orchestrator-test.sh:187 (members overlap) | LOW | FIFO / oldest-PID behaviour is not asserted |
| §2 | cap = `max_parallel`, default `_zb_default_jobs`, override `ZBUILD_PARALLEL_JOBS` | UNTESTED for `_parallel_resolve_max` | LOW | only the parse is tested (template-parallel-test.sh:60). tests/unit/map-strategy-test.sh:737-741 tests map's mirror, not this one |
| §2 | `max_parallel: 1` degrades to sequential | UNTESTED | LOW | |
| §2 | "The pool is the **only** new concurrency in the engine"; the hand-rolled fan-out is rehomed | UNTESTED, and contradicted | LOW | core/pipeline/strategies/map.sh:194 has its own batch pool; plugins/agent/review-report/lib/lenses.sh:270 still has the hand-rolled fan-out |
| §3 | stage-io is per member and sequenced; no shared buffer | tests/integration/parallel-orchestrator-test.sh:116-121 | MEDIUM | |
| §3 | `ZBUILD_CURRENT_STAGE` is set per member inside its subshell and restored after the group | parallel-orchestrator-test.sh:124-125, :139 | HIGH | |
| §3 (ADR-043) | redaction dedup is scoped per (run_id, stage); a member never rides a sibling's `redaction.applied` | tests/integration/router-precondition-parallel-test.sh:85, :108, :126 | HIGH | |
| §3 | `events.jsonl` append is flock-serialized and stays valid JSONL under concurrency | tests/unit/event-bus-concurrency-test.sh:80, :85 | HIGH | |
| §3 | members never write orchestrator run-state; the parent writes all state serially in member order | UNTESTED (weak) | HIGH | only "parent wrote status/verdict" is checked (parallel-orchestrator-test.sh:128-134). The mock hook never tries to write state, so a member that did write would still pass |
| §4 | `aggregate: all_pass` (the default): group verdict is `pass` iff EVERY member passed | UNTESTED, and contradicted | HIGH | `_TPL_PARALLEL_AGGREGATE_*` is read only by the preflight. The group verdict comes from `on_member_error` (default `continue`, which always gives rc 0 and verdict "pass"): parallel-orchestrator.sh:320-325 and cycle-orchestrator.sh:1917-1922. Failures are counted by member rc, not member verdict (parallel-orchestrator.sh:291). cycle-parallel-member-test.sh only converges because the fixture sets `on_member_error: collect` |
| §4 | an `advisory` group "always" aggregates to non-blocking and is never `fail` | UNTESTED, and contradicted | MEDIUM | an advisory group with `on_member_error: collect` returns rc 1, giving verdict fail |
| §4 | a crashed or timed-out member contributes a `fail` slot, never a missing slot | UNTESTED | MEDIUM | code: missing `.rc` → 1 (parallel-orchestrator.sh:278) |
| §4 | `aggregate` ∈ {all_pass, advisory, quorum:&lt;n&gt;, any_pass}, enforced by the validator | UNTESTED, not implemented | MEDIUM | the template exports any string (template.sh:406). template-parallel-test.sh:305 asserts passthrough only |
| §5 | the validator flags a `feedback:` edge between two siblings of one parallel group | UNTESTED, not implemented | LOW | no such check in template.sh or lint-contract.sh |
| §5 | the aggregated group verdict feeds `exit_when` like a leaf verdict | tests/integration/cycle-parallel-member-test.sh:129-131, :158 | MEDIUM | |
| §5 | a parallel group may contain a cycle member | UNTESTED | LOW | |
| Amend OUT | one-line completion summary per member, from the parent, in declaration order | parallel-orchestrator-test.sh:328-329; tests/integration/review-lenses-output-test.sh:111 | LOW | |
| Amend OUT | the orchestrator is render-free; optional group trailer `▸ <group> complete — N members, M blocking` | UNTESTED | LOW | |
| Phase 1 | `aggregate:` is parsed and exported as `_TPL_PARALLEL_AGGREGATE_<id>` | tests/unit/core-pipeline-template-parallel-test.sh:305-306 | LOW | parsed, then never used at runtime (see §4) |
| Phase 2 (#1842) | the aggregator reads only the engine-resolved `lens_result` set; it never scans the directory | tests/unit/review-aggregator-closeout-test.sh:85, :91-95 | MEDIUM | |
| Phase 2 (#1842) | an empty lens set reports `needs_attention`, never `ready` | tests/unit/review-aggregator-test.sh:148 | HIGH | "refused at dispatch when absent" relies on the generic `required: true` input resolver and is not tested here |

## ADR-040: Composable gate / lens taxonomy (Accepted 2026-06-27)

Disposition: carries the #1219, #1986, #1988, #2040 and #1874 amendments. It supersedes ADR-038's packaging and evolves ADR-037. It is extended by ADR-046 and ADR-047. §1's `kind:`-based gate rule is superseded in-text by §7 (the `convergence:` marker) and #2040. §7's consolidated `gate-feedback.md` is superseded in-text by #1988. The #1219 route-verdict text is superseded in code by #1987/#1988 (see Conflicts).

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §1 | a gate is `kind: tool`, T0, with no router call | UNTESTED (weak) | MEDIUM | tests/unit/gate-v2-contract-test.sh:339, :363 grep 7 manifests for `tier_default: T0` / no router knobs. Superseded by §7/#2040 |
| §2 | gate-aggregator: `pass` iff every must-pass gate passed | tests/unit/gate-aggregator-test.sh:63, :80; missing → fail :88; malformed → fail :96 | HIGH | |
| §2 | the gate-aggregator is "the **only** convergence-bearing, merge-blocking construct" | UNTESTED, and contradicted | MEDIUM | test-author (`convergence: advisory`, router) has `blocking: true` (simple.yaml:157), so its failure halts the run with rc 8 (cycle-orchestrator.sh:2081). design_verify_cycle (`on_max: halt`, simple.yaml:113) also blocks |
| §2 | a failing gate halts "before the semantic layer runs" | UNTESTED, and contradicted | MEDIUM | `on_max: continue` (simple.yaml:259); see ADR-037 §5 |
| §3 | each lens is `kind: agent`, fed distinct mechanical evidence | UNTESTED for the production path | MEDIUM | same gap as ADR-038 §2 |
| §4 | the lens group verdict is always advisory and never appears in any `exit_when` | tests/integration/preflight-contract-templates-test.sh:111; tests/unit/lint-contract-convergence-test.sh:274 | HIGH | only for a single-condition exit_when (see the §5 row on multi-condition) |
| §4 (#1986) | every stage publishes a summary and every following stage ingests them, advisory stages included | tests/unit/summaries-all-stages-test.sh:95-96 | MEDIUM | |
| §4 (#1986) | an aggregator declaring `aggregates:` suppresses its members' summaries and must itself publish one | summaries-all-stages-test.sh:106-109, :174 | MEDIUM | |
| §4 (#1988) | gate-aggregator renders no gate-feedback.md/design-feedback.md and no longer declares `aggregates: gate` | tests/unit/gate-detail-outputs-test.sh:121-123, :141-145; tests/unit/gate-aggregator-test.sh:204 | MEDIUM | |
| §4 (#1988) | each gate publishes its own detail as a `summary: true` output, including on pass and skip | gate-detail-outputs-test.sh:58, :77-92 | MEDIUM | |
| §4 (#1988) | every failing gate is named in the aggregate | gate-aggregator-test.sh:256-257, :343-344 | MEDIUM | |
| §5 | no advisory or undeclared stage may sit in an `all_pass` group's must-pass set | tests/unit/lint-contract-convergence-test.sh:132, :222 (fixture-only) | HIGH | the guard runs only when the template has a blocking `type: parallel` group (scripts/lib/lint-contract.sh:626-632). simple.yaml has none, so Rules A/B are **inert on the production template** |
| §5 | `exit_when` / `abort_when` may not target a non-gate stage (single-condition form) | tests/integration/preflight-contract-templates-test.sh:111-112 (runtime CYCLE_AGG_TYPE); lint-contract-convergence-test.sh:168, :274 | HIGH | |
| §5 | the same rule for a **multi-condition** `exit_when: all:` | UNTESTED, and not enforced | HIGH | for `all:` the loader sets `_TPL_CYCLE_EXIT_N_STAGE_*` and leaves `_TPL_CYCLE_UNTIL_STAGE_*` empty (verified on design_verify_cycle). contract-validator.sh:605-608 then skips the cycle, and lint's awk (lint-contract.sh:524-561) never parses inline `- { stage: … }`. An advisory stage added to such a predicate passes both checks |
| §5 | "any stage with a router/LLM call (not a declared `convergence: gate`) reachable on a path that can block merge" fails the template | UNTESTED, and contradicted | HIGH | test-author is advisory, routes to a model and is `blocking: true` (simple.yaml:157). No check reads `blocking:` |
| §5 | an undeclared-marker stage on the must-pass path fails closed | lint-contract-convergence-test.sh:222 (fixture-only) | MEDIUM | the roster side also excludes it: gate-aggregator-roster-test.sh:89 |
| §5 Note | `disposition: advisory` failures are excluded; recoverable, terminal and absent dispositions stay blocking | tests/unit/gate-aggregator-test.sh:121-123, :132, :80 | HIGH | |
| §6 | adding or removing a gate from the cycle `flow:` changes the must-pass set with no aggregator edit | tests/unit/gate-aggregator-roster-test.sh:116-125 | MEDIUM | |
| §7 | the roster is discovered from `convergence: gate` cycle members, excluding itself and advisory/absent members | gate-aggregator-roster-test.sh:81-89 | HIGH | |
| §7 | no cycle in scope → legacy fixed set | gate-aggregator-roster-test.sh:136-138 | MEDIUM | |
| §7 | "a roster that resolves to zero gates also falls back rather than vacuously passing" | UNTESTED | HIGH | a vacuous pass would let every cycle converge |
| §7 | the aggregator is the single collector and writes consolidated `gate-feedback.md` | superseded by #1988 | n/a | the tests assert the opposite (gate-aggregator-test.sh:204). The stale text remains in the ADR |
| Ph1 (A) | a cycle's `exit_when` target must be a cycle member (CYCLE_AGG_NOT_MEMBER) | UNTESTED | MEDIUM | the type half is tested (preflight :111). The not-a-member branch (contract-validator.sh:619-621) has no test |
| Ph1 (B) | an `aggregate: advisory` parallel group needs an explicit non-member `convergence: advisory` aggregator | preflight-contract-templates-test.sh:121, :131; lint-contract-convergence-test.sh:244 | LOW | inert for simple.yaml: `type: map` groups go to `_TPL_MAP_GROUPS`, not `_TPL_PARALLEL_GROUPS` (template.sh:401 vs :728). Now covered by `lens_result required: true` |
| #1219 | on a failed gate's `route_target`, the aggregator emits `verdict = route_<target>` and writes `design-feedback.md` | superseded in code | n/a | gate-aggregator-test.sh:148-153 assert verdict stays `fail`, `fault` is mirrored, and no design-feedback.md is written. route_back keys on `field: fault` (simple.yaml:283-292) |
| #1219 | a route/specification outcome never auto-merges | tests/integration/merge-policy-auto-test.sh:200 | HIGH | |
| #2040 | a model-judged gate is admissible only with ≥1 reference input produced outside its cycle (GATE_REFERENCE_MUTABLE) | tests/integration/adr040-isolated-gate-test.sh:108-110, :118 | HIGH | |
| #2040 | a model-judged gate declaring no inputs fails closed (GATE_REFERENCE_UNPROVEN) | adr040-isolated-gate-test.sh:132-133 | HIGH | |
| #2040 | "model-judged" is DECLARED (router in `requires.core`), not inferred from `kind:` | adr040-isolated-gate-test.sh:125; tests/unit/plugin-route-source-guard-test.sh:451 (every route_to_model caller declares router) | HIGH | the two together close the "undeclared LLM gate" hole |
| #2040 | advisory model stages are unaffected | adr040-isolated-gate-test.sh:140 | LOW | |
| #1874 | scope list = plan ∪ design scope, plus the shape floor when a reported file matches `config/shape-change-paths.txt` | tests/unit/change-scope-floor-test.sh:46-51, :62 | HIGH | |
| #1874 | build, redaction and shape-floor all read that one list | change-scope-floor-test.sh:74 (build) | MEDIUM | redaction (route.sh:347, :621) and shape-floor (shape-floor/plugin.sh:126) consumption is UNTESTED here |
| #1874 | an unedited floor test file is accepted iff a full pass on the same `tree_sha` and the file is not among the failures; targeted run, different tree or no result → must edit | tests/unit/shape-floor-content-stable-test.sh:68-84 | HIGH | |
| #1874 | a golden is accepted unedited "only when nothing failed" | UNTESTED | MEDIUM | C6 deletes the golden before the "failure elsewhere → pass" case, so golden + an unrelated failure is never exercised |

## ADR-041 — flock as the serialization chokepoint (Accepted 2026-06-28)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Decision | Concurrent writes to a shared resource "MUST be serialized with `flock`", not `sleep`/unsynchronized writes/optional-tool locking | UNTESTED | MEDIUM | No lint/scanner for `sleep`-sync or unlocked appends; the "anti-patterns to reject in review" are review-only. |
| Decision | flock use is "guarded by `zbuild_has_flock` with a best-effort fallback" | tests/integration/state-corruption-failclosed-b-test.sh:175 (no-flock path of `locked_state_update`) | LOW | Only the state-write fallback is exercised; event-bus no-flock branch untested. |
| Corollary 1 | Independent resources use "distinct lock files" — mirror on `events.db.lock`, jsonl on `events.jsonl.lock` | tests/unit/event-bus-concurrency-test.sh:47 (db lock file created) | LOW | Line 48-49 "distinct" check compares two strings the test itself builds — tautological; :47 is the real check. |
| Corollary 2 | Best-effort writer acquires "NON-BLOCKING (`flock -n`) and SKIPS the write on contention" | UNTESTED (weak) | LOW | event-bus-concurrency-test.sh:101 allows mirror ≤ jsonl and :117 a 60s ceiling; neither holds the db lock to prove skip-not-wait. A blocking `flock` would pass both. |
| Corollary 2 | Authoritative writer "may use a bounded wait (`flock -w N`) and must fail soft on timeout (never abort the caller)" | UNTESTED | HIGH | **Code contradicts.** core/event-bus/event-bus.sh:219 `flock -w 5 9 \|\| exit 1` inside a subshell with no `\|\|` guard — under `set -e` a held jsonl lock kills the caller. Probed: holding `events.jsonl.lock` 8s then calling `eb_emit_event` under `set -euo pipefail` → script exits rc=1, no message, the event is lost. core/state/atomic.sh:132 likewise returns rc=1 on timeout. |
| Impl | jsonl append is flock-serialized (no loss, no interleave under concurrent emitters) | tests/unit/event-bus-concurrency-test.sh:80, :85, :90 | LOW | Weak as proof of flock: small O_APPEND writes are atomic without a lock, so removing the flock would likely still pass. |
| Impl | State read-modify-write (`locked_state_update`) is flock-serialized | UNTESTED | MEDIUM | state-corruption-failclosed-b-test.sh:228 "Scenario 9" *simulates* the race serially (comment line 231); no real concurrent-writer test. |
| Impl | Label leases (ADR-005) serialized with flock | tests/e2e/claim-race-test.sh:132 (≤1 winner of a 3-way race) | MEDIUM | Linux + flock only (skip_unless_capable :32); skipped on macOS. |

## ADR-042 — Stage portability: uniform stage→plugin resolution (Accepted 2026-06-29; amends ADR-001/021/039; completed by ADR-047, ADR-055 §1)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Decision | One shared resolver `resolve_stage_plugin` resolves "role first, then id" | tests/unit/stage-resolution-parity-test.sh:75, :89, :121 | MEDIUM | Calls the resolver directly against simple.yaml. |
| Decision | Cycle and parallel dispatch paths use `resolve_stage_plugin` (not id-only) | UNTESTED (weak) | HIGH | Every cycle/parallel test mocks `cycle_dispatch_stage`/`parallel_dispatch_stage` (e.g. parallel-orchestrator-test.sh:75, cycle-orchestrator-nested-cycle-test.sh:80), so runner.sh:2767/:2975 are never exercised with a divergent-id stage. Reverting either to `_find_plugin_for_stage` would pass every test that names these functions. Only the leaf verdict path has a grep check (leaf-dispatch-verdict-resolution-parity-test.sh:127, also weak). |
| Rule 1 | Roles resolve "platform-specific then generic", first match wins | UNTESTED | LOW | No test sets `_DETECTED_PLATFORMS` around `resolve_stage_plugin` (only map/strategy tests). |
| Rule 1 | Cycle/parallel members resolve a "single plugin (they do not fan out)" | UNTESTED | LOW | |
| Rule 2 | No roles declared → id-match fallback "preserved verbatim" | tests/unit/stage-resolution-parity-test.sh:86, :90, :91 | LOW | |
| Rule 2 | Roles declared but none resolves → "fails closed (rc=1 …) — no id-match fallback" | tests/unit/stage-resolution-parity-test.sh:115 | MEDIUM | |
| Consequences | Miss contract: empty stdout + rc=1 | tests/unit/stage-resolution-parity-test.sh:97, :102 | LOW | |
| Decision | "A stage's flow-name need not equal its plugin `id`" | tests/unit/stage-resolution-parity-test.sh:89 (acceptance-gate→spec-acceptance) | LOW | |
| Decision | Convergence/blocking is "declared per-stage, not inferred from position" | tests/unit/gate-aggregator-roster-test.sh:81, :88, :89 | MEDIUM | Owned by ADR-040; must-pass set comes from `convergence:` markers. |
| Consequences | Resolver is "side-effect-free" | UNTESTED | LOW | |
| Impl | "The leaf (serial) path keeps its existing inline role-then-id resolution" | n/a (stale) | LOW | Partly out of date: #1770 moved leaf *verdict* resolution onto `resolve_stage_plugin` (runner.sh:3902), while leaf *dispatch* still resolves inline (runner.sh:1892-1904). The ADR describes neither state exactly. |

## ADR-043 — Redaction by construction in the model-call path (Accepted 2026-07-02; inverts ADR-004 C6)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Decision | `route_to_model` "redacts its prompt internally"; the redacted text is what reaches claude | tests/unit/route-cli-redaction-test.sh:71, :73 (via `route_to_model_cli` → `route_to_model`) | HIGH | The only test that checks the *bytes* sent to the mock claude. Other tests only count `redaction.applied` events. |
| BC | Not yet redacted → router redacts, emits `redaction.applied`, and it precedes `model.route` | tests/integration/router-precondition-test.sh:53, :102, :105; core/router/tests/route-unit-test.sh:71 | MEDIUM | |
| BC | Already redacted for `(run_id, stage)` → "no re-redaction, no double emit" | tests/integration/router-precondition-parallel-test.sh:85 | MEDIUM | |
| BC | Router-emitted redaction is stamped with the calling stage (per-stage dedup) | tests/integration/router-precondition-parallel-test.sh:108, :126 | MEDIUM | |
| Decision | Single-shot and loop "share one redaction path (`_route_redact_prompt`)"; loop redacts every iteration | UNTESTED | HIGH | Loop tests set the operator override so a per-iteration *stub* satisfies C6 (build-loop-banner-test.sh:29, core-router-loop-banner-test.sh:37). No test checks that loop prompt text is redacted. |
| Scope | Runner exports `ZBUILD_SCOPE_MANIFEST=${STATE_DIR}/scope-manifest.md` "for every stage" | UNTESTED | MEDIUM | Set at runner.sh:2173; no test asserts it. Per ADR it only causes over-redaction (fail-safe) if it regresses. |
| Scope | `ZBUILD_SCOPE_ALLOWLIST` "derived per-stage from `plan.files[]`", empty before plan.json | n/a (stale) — current behaviour: tests/unit/engine-stage-reports-test.sh:70, tests/unit/change-scope-floor-test.sh:46 | MEDIUM | **Code contradicts the ADR text.** runner.sh:531-557 builds it from `artifacts/stage-reports.json .scope_files` plus the shape floor (#2189, #1874). engine-stage-reports-test.sh:70 asserts "plan.json not read". ADR-043 was never amended. |
| Fail-closed | Configured-but-missing/empty manifest → `redaction.refused`, router refuses rc=2, no `model.route` | tests/integration/router-precondition-test.sh:126, :128, :132 | HIGH | |
| Fail-closed | "Applied-even-if-empty" (blank prompt + present manifest) → applied → proceed | UNTESTED | LOW | |
| Fail-closed | `--skip-precondition` needs `ZBUILD_SCOPE_OVERRIDE` + token and is audited | tests/integration/router-precondition-test.sh:199, :204, :223, :226 | MEDIUM | |
| Fail-closed | Degenerate env (no run_id / no events log) stays fail-closed | tests/integration/router-precondition-test.sh:64, :76 | MEDIUM | |
| Fail-closed | No manifest configured → passthrough copy + `redaction.applied` stub `scope_hash=router-passthrough` | tests/integration/router-precondition-test.sh:53 (applied emitted, no manifest) | LOW | The `router-passthrough` value itself is only negatively asserted (:155). |
| Anti-bypass | `route_to_model[_loop]` "is the ONLY model-call path"; CI fails on `claude -p`/`curl anthropic` outside core/router, core/redaction | tests/unit/redaction-chokepoint-test.sh:111 (+ sentinel :162) | HIGH | Real scanner with a self-check. |
| Anti-bypass | `kind: agent` plugins still declare `requires.core: [redaction]` | tests/unit/requires-core-resolution-test.sh:345-348 | MEDIUM | |

## ADR-044 — Repo-declarable test-count contract (Accepted 2026-07-03, #1208)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Decision | `ZBUILD_TEST_RESULTS_JSON` file `{passed,failed,…}` → honest counts, `recognized=1` | tests/unit/test-declared-count-contract-1208-test.sh:53, :54, :55 | MEDIUM | |
| Decision | `ZBUILD_TEST_COUNT_CMD` stdout JSON → counts | tests/unit/test-declared-count-contract-1208-test.sh:69, :70, :71 | LOW | |
| Order | Declared contract is consulted "BEFORE the recognizer bank" | UNTESTED (weak) | MEDIUM | Every declared-contract case uses bank-unrecognizable output (FAUX_XCODE), so declared-after-bank would pass too. No case pairs jest output with a conflicting declared JSON. |
| Order | Results JSON is checked before COUNT_CMD | UNTESTED | LOW | |
| Decision | `verdict=fail` iff "`rc != 0` OR `failed > 0`" | tests/unit/test-declared-count-contract-1208-test.sh:52, :60 | MEDIUM | The `rc≠0 ∧ failed=0 → fail` arm is untested; dropping the rc check passes every case. |
| Consequences | Malformed / non-numeric declared JSON → falls back to the bank, then fail-safe, "never fabricated" | UNTESTED | MEDIUM | |
| Decision | Unrecognized runner + no contract → `summary_unavailable` (verdict=error, counts null) | tests/unit/test-declared-count-contract-1208-test.sh:43, :44 | HIGH | |
| Decision | Recognizer-bank behaviour is unchanged when no contract is set | tests/unit/test-declared-count-contract-1208-test.sh:79-82 | LOW | |
| Impl | Plugin re-exports `ZBUILD_TEST_RESULTS_JSON` into the fresh-shell test subshell (captured before the `ZBUILD_*` scrub) | UNTESTED | MEDIUM | plugin.sh:252/:649. If it regresses, a repo wrapper never sees the var and silently falls back to the bank. |

## ADR-045 — Bounded typed backward-route primitive (rc=11 route_back) (Accepted; amended #1225, #2119; extended ADR-055 §1.3; retirement tracked in #1339)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Grammar | `route_back {to, when, max}` parses into `_TPL_CYCLE_ROUTE_BACK_{TO,STAGE,FIELD,OP,VALUE,MAX}_<cid>` | tests/unit/template-route-back-parse-test.sh:64-69 | LOW | |
| Grammar | Absent block ⇒ empty vars ⇒ "inert" (forward-only) | tests/unit/template-route-back-parse-test.sh:102; tests/integration/cycle-orchestrator-route-back-test.sh:166 | MEDIUM | |
| Grammar | v2 `stages:` parser does NOT support `route_back` | UNTESTED | LOW | |
| Verdict | Predicate match on a correctable terminal → rc=11, reason `route_back`, target + fallback rc stashed | tests/integration/cycle-orchestrator-route-back-test.sh:97-100 | HIGH | |
| Verdict | ONLY `term_rc ∈ {2, 8}` reroute; 0/6/5/**7**/4/130/143 "never reroute" | Partial: rc=0 at cycle-orchestrator-route-back-test.sh:118 | HIGH | **Code contradicts.** cycle-orchestrator.sh:2858 admits `term_rc -eq 7` (#2178), and tests/unit/core-pipeline-cycle-reuse-and-route-back-test.sh:105-110 asserts that blocked_on_scope (7) *does* reroute. No test covers 6/5/4/130/143 not rerouting. |
| Verdict | Reclassify only "when the `route_back` predicate matches" | n/a — contradicted | HIGH | **Code contradicts.** cycle-orchestrator.sh:2880-2891 reroutes with no predicate match on blocked_on_scope and on max_iterations with `empty_diff` (#2172/#2178). Tested as *current* behaviour at core-pipeline-cycle-reuse-and-route-back-test.sh:59-63, :105. Not recorded in any ADR. |
| Verdict | rc=11 is NOT a halt; absent from the runner halt-case | tests/integration/route-back-rewind-replays-test.sh:86 (completes after rewind) | MEDIUM | Indirect: tested through behaviour, not the halt-case table (runner-cycle-rc-action-mapping-test has no rc=11 row). |
| Runner | rc=11 + strictly earlier target + budget left → emit `cycle.route_back`, rewind and replay | tests/integration/route-back-rewind-replays-test.sh:79, :83 | HIGH | |
| Runner | Global budget `${ZBUILD_ROUTE_BACK_BUDGET:-2}` counts total passes (default = one jump) and is the hard ceiling | tests/unit/route-back-budget-config-test.sh:75, :77, :79, :83 | HIGH | |
| Runner | Per-edge `max` is a subordinate cap | tests/unit/route-back-budget-config-test.sh:81; route-back-nested-propagates-test.sh:175 | MEDIUM | |
| Runner | Budget/cap exhausted → no rewind; stashed fallback rc restored; original cause reported | tests/integration/route-back-budget-exhausted-test.sh:73, :77, :80, :85, :88 | HIGH | |
| Consequences | `fallback_rc=2` → unconverged branch (`on_max=continue` honoured); `fallback_rc=8` → halt, status=failed | rc=8: route-back-budget-exhausted-test.sh:80; rc=2: UNTESTED | MEDIUM | |
| Nested (#1225) | Inner rc=11 propagates through every enclosing cycle to the runner and is never collapsed to rc=4 | tests/unit/core-pipeline-cycle-orchestrator-run-test.sh:251-252; tests/integration/route-back-nested-propagates-test.sh:152, :163 | HIGH | |
| Nested | Edge-owner identity: per-edge counter and `max` keyed on the owning (inner) cycle | tests/integration/route-back-nested-propagates-test.sh:175 (inner max=1 honoured under budget 5) | MEDIUM | |
| Nested | Depth not capped | UNTESTED | LOW | Only one nesting level is tested. |
| Acyclicity | `_tpl_validate_flow_acyclic` unchanged (membership cycles still rejected); the route_back edge does not trip it | tests/unit/template-route-back-validate-test.sh:47, :55 | MEDIUM | |
| Acyclicity | `to` must resolve strictly earlier: reject forward, self, own member, nested sibling | tests/unit/template-route-back-validate-test.sh:73, :79, :86, :141, :263 | HIGH | |
| Acyclicity | `max` must be a finite positive int: reject 0, non-numeric, empty | tests/unit/template-route-back-validate-test.sh:92, :97, :102 | HIGH | |
| Events | `cycle.route_back` registered in config/event-schema.json | tests/unit/event-schema-emitted-coverage-test.sh:83 | LOW | Generic emitted ⊆ known check. |
| Impl | Fallback rc/target globals "reset per run at `cycle_orchestrator_run` entry" so a prior hand-off can't leak | UNTESTED | MEDIUM | Reset at cycle-orchestrator.sh:2365, but tests pre-clear the globals themselves (cycle-orchestrator-route-back-test.sh:95; cycle-orchestrator-run-test.sh:248), which hides a missing reset. |
| Amend #2119 | Fires early at the iteration the fault appears when budget remains and it is not the last iteration; emits `cycle.route_back.early` | tests/unit/core-pipeline-cycle-stall-break-test.sh:168-171; route-back-nested-propagates-test.sh:154 | HIGH | The negatives (no early fire when budget is spent or on the last iteration) are UNTESTED. |
| Consequences | "Advisory stages never drive a route_back" (ADR-040) | UNTESTED | MEDIUM | |
| Amend #1219 | simple.yaml `build_test_cycle` route_back → `design_verify_cycle`, `when: gate-aggregator verdict eq route_design`, max 1 | tests/unit/template-simple-yaml-test.sh:282-296 (asserts the *current* `field: fault`, `op: in`, `value: "specification scope"`) | MEDIUM | **ADR text stale.** simple.yaml:285-293 and deployed.yaml:103-111 key on `fault` with `op: in` (#1987). The ADR's "blob-visibility" rationale (`when` reads only `{verdict,status}`) no longer matches. |
| Grammar (implied) | Supported predicate ops | tests/unit/template-route-back-validate-test.sh:233-234 | LOW | The test still says the bad-op error "mentions eq/ne"; `in` is now supported but neither the ADR nor that test documents it. |

## ADR-046 — Design-verify shift-left (Accepted 2026-07-03; amended 2026-08-12 by #1768 / ADR-055 §1; amended #1219)

Heavily drifted. Later issues removed or replaced several clauses: #1477 (C6 tag-presence and the stub writer), #1649 (C4 existence check), #2176 (`on_max: halt`), #1987 (route_back predicate), and ADR-055 §9 (feedback always written).

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| Decision | simple.yaml has a `design_verify_cycle` containing design → design-gate, `exit_when design-gate.verdict == pass`, `max_iterations: 3` | tests/unit/template-simple-yaml-test.sh:225-238 (members, max=3, exit cond 1) | MEDIUM | members are now `design,spec-coverage,design-gate` with a two-condition `all` exit (#1683) — the ADR text is stale |
| Decision | `on_max: continue` (ADR-019 fall-through) | CONTRADICTED — tests/unit/design-cycle-on-max-abort-test.sh:26 pins `halt` | HIGH | code and test follow #2176 (`halt`); ADR-046 was never amended |
| §1 | design-gate is `kind: tool`, `convergence: gate`, `role: design_gate`, T0 | UNTESTED (only manifest data; no test reads these keys for design-gate) | LOW | manifest matches today |
| §1 | "No LLM, no baseline" (ADR-037 §3 invariant) | UNTESTED | HIGH | CONTRADICTED: the current C6 GUARD-BASELINE runs assertions at the merge-base (plugins/tool/design-gate/plugin.sh:150-181; tests/unit/design-gate-guard-baseline-test.sh:135). No guard stops a tool plugin calling the router |
| §1 C1 | design.md has a non-empty ```scope block | tests/unit/design-gate-test.sh:149-150 | MEDIUM | |
| §1 C2 | the ```acceptance block is present and parseable | UNTESTED in design-gate-test (no ACCEPTANCE_MISSING assertion) | MEDIUM | design-router-timeout-reiter-test.sh only mentions it in a comment |
| §1 C3 | every SPEC-n carries `[change]`/`[guard]` | tests/unit/design-gate-test.sh:113-114 | MEDIUM | |
| §1 C4 | ≥1 `[change]` SPEC ⇒ TESTFILES non-empty AND each file exists on disk | partial: non-empty at design-gate-test.sh:323-325; existence is CONTRADICTED (design-gate-test.sh:172, 298 assert a missing file passes, #1649) | MEDIUM | ADR stale |
| §1 C5 | a WIRING section is present; each concrete path exists on disk | section: design-gate-test.sh:131-132; path existence UNTESTED | MEDIUM | the "path absent on disk" branch (plugin.sh:145) has no assertion |
| §1 C6 | every SPEC-n has a `[SPEC-n]` tag in a declared testfile | CONTRADICTED — design-gate-test.sh:95 asserts an untagged file passes (#1477) | LOW | C6 was reused for GUARD-BASELINE |
| §1 | reports ALL violations in ONE pass | tests/unit/design-gate-test.sh:202-206 | MEDIUM | |
| §1 | writes `{verdict, violations[]}` to design-gate-result.json and ALWAYS returns rc=0 | tests/unit/design-gate-test.sh:211,213 | HIGH | |
| §1 | writes design-gate-feedback.md ONLY on fail | CONTRADICTED — design-gate-test.sh:219 asserts it is written on pass (ADR-055 §9) | LOW | |
| §1 | design-gate is both a cycle member and `convergence: gate`; a single gate with no separate aggregator | UNTESTED for design-gate specifically (the CYCLE_AGG rules in contract-validator are generic) | LOW | |
| §2 | the design stub-writer embeds `[SPEC-n]` tags for change SPECs in new red-first stubs | CONTRADICTED — tests/unit/design-acceptance-block-test.sh:97-101 asserts design writes NO stub (#1477) | LOW | ADR stale |
| §3 | `impact` is a lone top-level stage after design_verify_cycle and before build_test_cycle | tests/unit/template-simple-yaml-test.sh:211-212 | MEDIUM | |
| §3 | the `impact` manifest stays marker-less (no `convergence:`) | UNTESTED | MEDIUM | a marker would silently change gate-aggregator's must-pass roster / break standard.yaml |
| Conseq. | `design_gate.pass`/`.fail` are registered events | UNTESTED (now declared via manifest `provides.events`, not event-schema.json) | LOW | ADR stale about the location |
| Amend #1219 | build_test_cycle `route_back` → `design_verify_cycle`, `max: 1` | tests/unit/template-simple-yaml-test.sh:282-295 | HIGH | predicate is now `fault in [specification scope]` (#1987), not `verdict eq route_design` — ADR stale |
| Amend #1219 | on route_back the runner rewinds to design_verify_cycle and replays forward | tests/integration/route-back-rewind-replays-test.sh (exists; not line-verified) | HIGH | assertion line not verified — treat as unconfirmed |
| Amend #1768 | design consumes `design_feedback` by name, `required: false`; splices it keyed on file presence | partial: tests/unit/design-prior-gate-feedback-test.sh:98-101 (absent ⇒ no section) | MEDIUM | mechanism moved again to engine-collected summaries (#1979); design no longer splices the detail itself (line 68) |

## ADR-047 — Stage-agnostic pipeline mechanics (Accepted 2026-07-08; amended 2026-08-12 by #1768 / ADR-055 §1)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §1 | the mechanics enumerate EXACTLY four operators: leaf/sequence/parallel/cycle | UNTESTED | LOW | CONTRADICTED: `map:` (tests/unit/template-simple-yaml-test.sh dispatch `map:review_lenses`) and `always_run:` (simple.yaml:65) are further operators |
| §1 | flow decisions (exit_when, route_back, join) reference no stage id | UNTESTED (weak) — the fictitious-stage harnesses only grep for the fixture name, e.g. tests/unit/verdict-stage-agnostic-test.sh:91-94 | HIGH | no guard greps core/pipeline for REAL stage names. Code: core/pipeline/runner.sh:236 and cycle-orchestrator.sh:2335 hardcode intake's `intake-baseline-ref.txt` |
| §3 | the verdict reader has no per-name branches | tests/unit/verdict-stage-agnostic-test.sh:72-97 (fictitious stage read; byte-identical) | MEDIUM | weak for real names (see above) |
| §3 | rc≠0 → fail, and rc always wins | tests/unit/core-pipeline-verdict-test.sh:109 | HIGH | |
| §3 | channel missing/malformed → warn | CONTRADICTED — core-pipeline-verdict-test.sh:208 (malformed → `error`); verdict-stage-agnostic-test.sh:79 (non-JSON primary with no sidecar → `pass`) | HIGH | missing artifact → warn is tested at core-pipeline-verdict-test.sh:192 |
| §3 | a non-JSON-primary stage writes a separate verdict JSON — the "normal contract" | tests/unit/verdict-stage-agnostic-test.sh:72-74 (sidecar is read) | MEDIUM | not required: a missing sidecar reads as pass (see Conflicts) |
| §4 | `provides_detailed_failure_count` ⇒ the cycle uses the structured count | tests/unit/cycle-orchestrator-capability-flags-test.sh:151,193,313 | MEDIUM | |
| §4 | `produces_commits` + `empty_diff_legitimate` drive the no-committed-changes policy | UNTESTED (weak) — capability-flags-test.sh:220-232 only asserts manifests declare the flag | HIGH | the policy outcome is not asserted from the flag |
| §4 (#1803) | `empty_diff_legitimate` exempts non-primary outputs only, never a `primary: true` output | tests/unit/lifecycle-required-output-test.sh:117,127,136 | HIGH | |
| §4 | `feedback_fields` formats the cycle digest | tests/unit/cycle-orchestrator-capability-flags-test.sh:254-255,290 | LOW | |
| §5 | every leaf resolves to a plugin; an unresolved leaf errors at load and names the id | tests/unit/template-resolvability-preflight-test.sh:130-132,295-296 | HIGH | runner call site runner.sh:1783; skipped under `ZBUILD_CONTRACT_VALIDATOR!=enforce` (runner.sh:622) and on `--resume` — an escape hatch the ADR doesn't mention |
| §5 (amended) | every declared input name resolves to exactly ONE producer | tests/unit/contract-validator-input-gating-test.sh:124 (required only) | HIGH | CONTRADICTED for optional inputs: input-gating-test.sh:136 asserts an optional input with zero producers is allowed |
| §5 (amended) | the producer must be ordered earlier OR reachable by a declared `route_back`; a late dependency errors at load | CONTRADICTED — tests/unit/core-pipeline-contract-validator-test.sh:233 asserts a later producer with no route_back is accepted | HIGH | contract-validator.sh:457-495 has no ordering check, only SELF_REF |
| §5 | these preflights error, they do not warn | partial: runner-startup-preflight-test.sh:57 (enforce rc=2) | HIGH | `_runner_validate_startup_preflight` defaults to `warn` (runner.sh:713) — contradicts "error, not warn" |
| §6 | a shipped base prompt is target-agnostic (names no repo) | partial: tests/unit/design-prompt-override-section-test.sh:70-80 (design only, specific tokens) | MEDIUM | no corpus-wide guard over all plugins |
| §6 | the per-repo prompt-override mechanism is preserved | tests/unit/design-prompt-override-section-test.sh:83-84 | LOW | |
| Conseq. | adding/retiring a stage needs zero edits under core/pipeline/ (fictitious-stage harness + `git diff --exit-code`) | partial: template-resolvability-preflight-test.sh:117-121, capability-flags-test.sh:300-320, verdict-stage-agnostic-test.sh:97 | MEDIUM | harness covers template.sh, verdict.sh, cycle-orchestrator.sh; not runner.sh |

## ADR-048 — Release versioning & signing (Accepted 2026-07-11)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §1 | the default version is 4-part A.B.C.D, assembled by `compute_version` | tests/unit/compute-version-test.sh:19-26 | MEDIUM | |
| §1 | A.B is anchored by the latest `vA.B.0.0` tag; C = count of release tags under A.B; D = issues closed since | UNTESTED (weak) — versioning-backend-test.sh:57-62 pins the inputs via env, so the tag derivation is never exercised | MEDIUM | |
| §1 | the VERSION shape guard accepts 3-or-4 parts (`^[0-9]+(\.[0-9]+){2,3}$`), no leading `v` | UNTESTED for 3-part and for rejection | LOW | 4-part: tests/integration/zbuild-version-subcommand-test.sh:53 |
| §2 | default backend `versioning=initiative-count`, listed in ALLOWED | tests/unit/versioning-backend-test.sh:33-34 | LOW | |
| §2 | precedence env > `.zbuild/config.yaml` > default | tests/unit/versioning-backend-test.sh:44,50 | LOW | |
| §2 | no scheme is hardcoded in the CLI/engine beyond the default strategy file | UNTESTED | LOW | |
| §3 | unknown backend ⇒ rc=1 plus `backend.missing` | tests/unit/versioning-backend-test.sh:71-72 | MEDIUM | event emission not asserted |
| §3 | `compute_version` is pure (no net/gh/git) and fails loud on malformed input | tests/unit/compute-version-test.sh:31-51,57 (empty PATH) | LOW | |
| §4 | `--version` prints the stamped VERSION file, probing config/VERSION before repo-root VERSION | tests/integration/zbuild-version-subcommand-test.sh:53,65 | LOW | test 4 passes from probe order alone; the shape-guard rejection of `sha=` is not isolated |
| §6 | `--major` needs a fully closed milestone "Initiative (A+1).0": missing ⇒ rc=1, open issues ⇒ rc=1, also under --dry-run | tests/integration/release-sh-major-guardrails-test.sh:97,104,128 | HIGH | |
| §6 | `--force` bypasses; `--minor`/`--patch` skip the check | release-sh-major-guardrails-test.sh:122 (force), :111-113 (minor) | MEDIUM | `--patch` skip not asserted |
| §6 | the gh call goes through the `ZBUILD_GH_CMD` seam | release-sh-major-guardrails-test.sh:149 | LOW | |
| §5 | scheduled workflow runs Monday 09:00 UTC with a fork guard | tests/integration/release-sh-scheduled-test.sh:161,168 | LOW | |
| §5 | the workflow calls `scripts/release.sh --patch --skip-if-no-issues`; D=0 ⇒ exit 0 with no release | skip semantics: release-sh-scheduled-test.sh:89-124 | MEDIUM | CONTRADICTED on mechanism: release-sh-scheduled-test.sh:177-196 asserts the workflow dispatches release.yml and does NOT call release.sh directly |
| §5 | `workflow_dispatch` has a `dry_run` input | UNTESTED (not verified) | LOW | |

## ADR-049 — Vision-document standard (Accepted 2026-07-12; VIS-C amendment; §5 Phase 1.1 #1360)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §1 | resolution order: `.zbuild/vision.md` > `docs/VISION.md` > `VISION.md`; first readable wins | tests/unit/vision-validator-test.sh:127-146 | MEDIUM | |
| §1 | none present ⇒ absent (`load_vision_doc` rc=1) | tests/unit/vision-validator-test.sh:153 | LOW | "Phase 1.0 non-fatal" superseded by §5 enforce |
| §2 | body word count (excluding frontmatter/headings/blank lines) MUST NOT exceed 300 | tests/unit/vision-validator-test.sh:101,117 | MEDIUM | |
| §2 | optional YAML frontmatter; unknown keys ignored | tests/unit/vision-validator-test.sh:176 | LOW | unterminated fence fails :194 |
| §3 (VIS-C) | `## Intent`/`## Principles` are NOT enforced | tests/unit/vision-validator-test.sh:81,94 | LOW | |
| §4 | vision is injected into prompts ONLY through `apply_scope_redaction` | UNTESTED (weak) — vision-prompt-inject-test.sh:78 shows the preamble in `_ROUTE_REDACTED_PROMPT`; :158 only checks `redaction.applied` fired (labelled guard; fires anyway) | HIGH | no test puts a secret in the vision doc and checks it is redacted |
| §4 | injected only when present AND valid | tests/unit/vision-prompt-inject-test.sh:130,213 | MEDIUM | |
| §5 | mode precedence env > config `vision.gate` > default `enforce`; unknown ⇒ enforce | tests/unit/vision-gate-config-test.sh:25-45 | MEDIUM | |
| §5 | `enforce`: missing/over-length ⇒ preflight_failed (rc=2) | tests/unit/vision-admission-gate-test.sh:185,210 | HIGH | |
| §5 | `off` skips the gate | tests/unit/vision-admission-gate-test.sh:233-236 | LOW | |
| §5 | `warn` advises but proceeds | UNTESTED (only mode resolution at vision-gate-config-test.sh:35; no runner-level warn case) | MEDIUM | |

## ADR-050 — Prior-work reuse contract (Accepted 2026-07-23; amended by #1878, #1921, #141/ADR-059 §7, #2111, #2225)

| § | statement | enforced by (file:line) or UNTESTED | risk | note |
|---|---|---|---|---|
| §1 | the engine persistence names no stage (snapshots a directory) | UNTESTED (weak) | MEDIUM | no grep/fictitious-stage harness over artifact-persist.sh |
| §1/§6 | a stage NEVER reads pipeline state, run history or resume logic | UNTESTED | MEDIUM | tension: #2225 design reads the prior run's gate/fault records to decide reuse |
| §2 | durable store is the separate branch `zbuild/state/issue-<N>`, never in work-branch history | tests/unit/artifact-persist-test.sh:61,79 | HIGH | |
| §2 | snapshots never touch the working tree or the real index | tests/unit/artifact-persist-test.sh:71-73 | HIGH | |
| §3/§6 | deterministic gates MUST re-evaluate and MUST NOT reuse a prior verdict | UNTESTED | HIGH | code complies today (only plugins/tool/hydrate reads restored artifacts), but no guard stops a gate reading `ZBUILD_RESTORED_ARTIFACTS_DIR`/`_read_prior_output` |
| §4 | snapshot at each stage boundary, leaf AND cycle member (#1878) | tests/integration/artifact-snapshot-runner-test.sh:126,135 | HIGH | parallel/map arms not asserted |
| §4 | identical snapshots are no-ops | tests/unit/artifact-persist-test.sh:101,154 | LOW | |
| §4 (#1878) | snapshot status saved/empty/unchanged/failed with a reason; emits `artifact.snapshot.failed` | artifact-persist-test.sh:146,186-189; artifact-snapshot-runner-test.sh:160-163 | MEDIUM | |
| §4 (#1878) | a snapshot failure never aborts the run | tests/integration/artifact-snapshot-runner-test.sh:174 | HIGH | |
| §4 (#1878) | one unstageable file is skipped and counted | tests/unit/artifact-persist-test.sh:172-176 | LOW | skipped when run as root |
| §4 (#1921) | a persist run adds exactly ONE commit containing persist-result.json; the branch copy has `pushed: null` | tests/unit/persist-stage-test.sh:260-281 | MEDIUM | amend-guard :304 |
| §4 (#1921) | the secret gate runs before the push and a credential refuses it | tests/unit/persist-stage-test.sh:134-135,182-185 | HIGH | |
| §4 (#1878) | state push runs BEFORE the work push in zbuild-pipeline.yml | UNTESTED | LOW | superseded by §7 (persist stage) |
| §5 | `_read_prior_output` order: cycle feedback > restored > local state > empty with rc 0 | tests/unit/prior-output-reader-test.sh:43-94 | MEDIUM | |
| §6 | every stage declares a `primary: true` output | UNTESTED here (may be covered by contract lint elsewhere) | LOW | |
| §6 | reuse is advisory; never skip the stage on the basis of prior output | CONTRADICTED by the #2225 amendment and tests/unit/resume-default-test.sh:134 (design reuses the prior design without a model call) | MEDIUM | internal ADR conflict |
| §7 | persist is an always-run stage after release that snapshots AND pushes; runs pass or fail | tests/unit/template-always-run-test.sh:39; tests/integration/always-run-exit-paths-test.sh:117; persist-stage-test.sh:88 | HIGH | the exit-path test uses a release marker, not persist itself |
| §7 | hydrate runs before intake and FETCHES the state branch (cold start) | tests/unit/template-simple-yaml-test.sh:83 (hydrate first); artifact-persist-test.sh:290-298 | HIGH | |
| §7 | restore never writes over live artifacts; input-resolve prefers the live path | tests/unit/stage-input-resolve-precedence-test.sh:127-149 | HIGH | |
| §7 | the local `refs/heads` copy beats `refs/remotes/origin` on read | UNTESTED (weak) — artifact-persist-test.sh:213 / :298 test each source alone, never both together | HIGH | a flip would silently lose unpushed work |
| §7 | adopting the saved history never moves an existing local ref | tests/unit/artifact-persist-test.sh:383-385 | HIGH | |
| Impl | intake adopts an existing remote work branch | tests/integration/intake-branch-ahead-count-test.sh:108 | MEDIUM | |
| Impl | pr-open reuses an existing PR instead of creating a duplicate | UNTESTED (weak) — pr-open-v2-result-test.sh:278-282 only checks verdict=pass; pr-open-existing-number-test.sh:31 only parses a number | MEDIUM | no assertion that `gh pr create` wasn't called |
| #2111 | a `llm_rate_limited` abort persists like any outcome | UNTESTED (not located) | MEDIUM | |
| #2225 | `ZBUILD_RESUME` defaults to 1; `--no-resume`/env=0 ⇒ 0; `0` restores nothing but still fetches and adopts | tests/unit/resume-default-test.sh:55,57,86 | MEDIUM | |
| #2225 | design reuses the prior design only when gate-passed hash + covered + no spec/scope fault + no current design + intake.md unchanged | tests/unit/resume-default-test.sh:134-156 | HIGH | |

## Conflicts

### From ADR-034–036

1. **ADR-034 #929 vs ADR-036 #2110 vs code — per-file timeout default.** ADR-034 says `ZBUILD_TEST_FILE_TIMEOUT` "default 300s"; ADR-036 #2110 calls the ceiling 480s; scripts/run-tests.sh:22 uses `${ZBUILD_TEST_FILE_TIMEOUT:-480}`. Code follows ADR-036; ADR-034 is stale.
2. **ADR-036 #1686 / #1711 / #1777 (and ADR-040 §route_target :311-322, ADR-045 :190) vs code — the routing carrier.** The ADRs say the gate sets `route_target: "design"` and the aggregator emits `verdict=route_design`, which `route_back` matches. Code sets `fault=specification` (plugins/agent/spec-acceptance/plugin.sh:568-699), and `route_back` matches `gate-aggregator.fault in {specification, scope}` (config/templates/simple.yaml:285-295, #1987). No `route_target` is written anywhere in the plugin. Code follows #1987; the ADR text is stale. Tests assert `fault`.
3. **ADR-036 #1686 vs code (#2252).** #1686 says `wiring_not_on_path` routes to design immediately. Code gives build iteration 1 when the target is in the design's scope list (plugin.sh:600-617), and escalates only at iter≥2 or when the target is out of scope. Tested (acceptance-gate-wiring-in-scope-test.sh). The ADR has no #2252 amendment.
4. **ADR-036 #956 vs code — Level 3 ordering.** ADR: "The gate runs Level 3 only after Levels 1+2 pass". Code: plugin.sh:471 runs Level 3 "REGARDLESS of Level 1/2 outcome" (#1220). Code follows #1220; ADR not amended.
5. **ADR-036 §Phase-2 table and #2097 "still terminal: no_testfile" vs code.** `_ag_failure_class_disposition no_testfile` → recoverable (tests/unit/acceptance-disposition-classify-test.sh:104, #1959); S10b asserts an unfulfilled testfile is recoverable. Code follows #1959; ADR-036 says terminal in two places.
6. **ADR-021 Phase-2 member-disposition contract vs ADR-036 #2161.** ADR-021 (:790-823) says a failing member declares `disposition: terminal|recoverable|advisory` and the cycle reads `disposition`. ADR-036 #2161 moves that word to `severity` and sets `disposition: complete` (ADR-054 vocabulary). Code follows ADR-036 #2161, with `disposition` as the v1 fallback (acceptance-gate-v2-reader-test.sh:155-162). ADR-021 is not amended.
7. **ADR-036 #951 / #2022 vs code — feedback edge.** ADR: untagged findings flow via the `acceptance-gate.gate_result → build.prior_acceptance_feedback` edge, and #2022 says "the same prior_acceptance_feedback.txt path now carries the finding to test-author". simple.yaml has no such edge (#1979 retired it, simple.yaml:266-268). Findings reach the author through engine-injected stage summaries, which #2097's text already assumes. ADR-036 contradicts itself; code follows #1979.
8. **ADR-036 §5 vs code — placement.** ADR: the gate runs in `build_review_cycle` after `build_test_cycle`. No `build_review_cycle` exists; the gate is a `build_test_cycle` member (simple.yaml:221-240).
9. **ADR-036 #1265 vs code — pr-open refusal rc.** ADR: `plugin.run.error reason=no_committed_changes`, rc=2. The test pins rc=1 and `plugin.result verdict=error` (tests/unit/pr-open-zero-commits-halts-test.sh:76-87).
10. **ADR-036 2026-09-28 "a signal is not a timeout" vs reachability code.** The amendment limits timeout to 124 (and 137 with kill-after). That rule is implemented and tested for negctl. tests/unit/acceptance-gate-reachability-test.sh:32 still asserts `_reachability_is_timeout_rc 143 → true`, so at Level 3 a SIGTERM from anyone is still classed as an infra timeout (advisory). The amendment text is negctl-only and silent on reachability, which leaves Level 3 on the superseded #1188 rule.
11. **ADR-035 08-22 amendment / ADR-059 §1 vs code — pool reclaimer location.** After #141, pools live under `runs/<run_id>/pool/`, but `_cleanup_scan_orch_pools` still scans `${TMPDIR}/zbuild-runs/` (scripts/lib/cleanup.sh:1315). Its only test seeds that obsolete path (cleanup-new-reclaimers-test.sh:174-180). The reclaimer the ADR names reaches nothing the engine now produces. Pools of killed runs are reclaimed only if something reclaims the whole `runs/<id>/` dir. The cleanup.sh:438 comment still describes the `${TMPDIR}/zbuild-runs` layout.
12. **ADR-035 run-hygiene vs code — ephemeral events dir.** The ADR requires the unpinned dir to sit where a reclaimer deleting `runs/<id>/` or `issues/<N>/` sweeps it. Code uses `<data_root>/ephemeral-events/$$` (core/event-bus/event-bus.sh:45), which is neither. The `zbuild-ephemeral-events.*` pattern was removed (#2017), and no reclaimer names the new path. The ADR's "implementation has not yet followed — see #2004" is also stale: #2004 is closed.

### From ADR-037–040

1. **ADR-037 §1/§3 vs ADR-040 #2040 amendment.**
   - ADR-037 says "No objective gate is an LLM" and that the blocking stages contain "no LLM/router call".
   - ADR-040 #2040 admits model-judged gates that have an outside-cycle reference input.
   - **Code follows ADR-040:** spec-coverage and issue-acceptance are LLM `convergence: gate` stages in simple.yaml:65-70, :92-98 and :245. ADR-037 has no amendment pointing to #2040.

2. **ADR-037 §5 + ADR-040 §2 vs code (simple.yaml:258-259, `on_max: continue`).**
   - Both ADRs say a non-green suite halts before the semantic layer.
   - **The code continues to review_lenses**, and tests/integration/build-test-cycle-fallthrough-to-review-test.sh:194 pins that behaviour (the pipeline then ends `failed`). Merge is still refused because the gate verdict is not `pass`.

3. **ADR-040 §2 ("gate-aggregator is the ONLY merge-blocking construct") and §5 rule 3 vs simple.yaml:157.**
   - test-author is `convergence: advisory`, routes to a model, and has `blocking: true`. A failure there halts the run with rc 8 (cycle-orchestrator.sh:2081).
   - **The code blocks**, and no lint or preflight check reads `blocking:`.
   - This also conflicts with ADR-037 §1 ("the only stages that may block the pipeline" are no-LLM gates).

4. **ADR-039 §4 (`aggregate: all_pass` default) + ADR-040 §2 vs core/pipeline/parallel-orchestrator.sh:320-325 and cycle-orchestrator.sh:1917-1922.**
   - **The code ignores `aggregate:` at runtime.** The group verdict is derived from `on_member_error`, whose default `continue` returns rc 0, which becomes "pass".
   - Member failure is counted by rc, not verdict.
   - So an `all_pass` gate group with a failing member converges. This is latent: no production template uses `type: parallel`.

5. **ADR-040 §5 (machine-enforced invariant) vs scripts/lib/lint-contract.sh:626-632 and contract-validator.sh:605-608.**
   - The invariant claims structural enforcement.
   - **The code enforces less.** Lint Rules A/B activate only when a blocking `type: parallel` group exists, which no production template has. The runtime check skips multi-condition `exit_when: all:`.

6. **ADR-038 §2 (distinct per-lens evidence; "says so" when unavailable) vs plugins/agent/review-lens/plugin.sh:178-191.**
   - **In the code, every lens reads the same diff bundle and falls back silently.** Only 4 lens ids have an evidence mapping, none of them is a simple.yaml element except `correctness`, and no simple.yaml stage produces the mapped artifacts.
   - This re-creates the "diverse questions over identical evidence" trap that ADR-038 §Context names.

7. **ADR-038 §3 / ADR-037 §5 ("report never blocks"; terminal state "PR opened with the report attached") vs plugins/tool/pr-open/plugin.sh:185-193.**
   - **The code refuses to open a PR when no review signal exists** (fail-closed per ADR-001), so the absence of the advisory layer blocks delivery.
   - A dead `review.json verdict=block` refusal also remains (pr-delivery/plugin.sh:55-66, pr-open/plugin.sh:168-180), although no plugin writes review.json any more.

8. **ADR-037 §4 (`auto`: "the report is informational only") vs plugins/tool/merge (tests/integration/merge-policy-auto-test.sh:238-245).**
   - **Under `auto`, the code refuses to merge when review.json/report is absent** (PR fallback), so the report is a precondition.

9. **ADR-037 §1 (scope-adherence hard gate: "files the design/plan named were actually changed") vs ADR-038 2026-09-28 amendment #5** ("planned-but-untouched files are not findings").
   - The two directly oppose each other.
   - **The code follows ADR-038:** no scope-adherence gate exists, and the scope lens is advisory.

10. **ADR-037 §1 + ADR-040 §1 (gate set includes lint, coverage floor, typecheck, scope) vs simple.yaml:207-218 (#1129 Change C / ADR-012).**
    - **lint, coverage and mutation gates were dropped from the template**: lint runs only inside the suite, coverage only in CI, and no typecheck gate exists.

11. **ADR-040 #1219 amendment vs ADR-040 #1988 amendment / #1987 and code.**
    - #1219 says the aggregator emits `verdict = route_design` and writes `design-feedback.md`.
    - **The code keeps the verdict `fail`, mirrors `fault`, and writes no payload** (gate-aggregator-test.sh:148-153). route_back matches `field: fault` (simple.yaml:283-292). The #1219 text was never marked superseded.
    - Likewise, §7's "single collector … one `gate-feedback.md`" contradicts the #1988 amendment within the same ADR.

12. **ADR-039 §2 ("the pool is the **only** new concurrency"; the hand-rolled fan-out is rehomed) vs ADR-047 §2 / core/pipeline/strategies/map.sh:194.**
    - **The code has a separate batch pool for map groups**, which do not wait on the oldest PID.
    - plugins/agent/review-report/lib/lenses.sh:270 still contains the hand-rolled fan-out (the plugin is unreferenced by simple.yaml but still resolvable).

13. **ADR-039 Phase 1 / ADR-040 Phase 1 (B) (advisory group must bind an aggregator) vs `type: map` (ADR-047 §2).**
    - **The preflight in code checks only `_TPL_PARALLEL_GROUPS`.** simple.yaml's `review_lenses` is a map group (template.sh:728), so check (B) never runs on production.
    - The intent is now carried by review-aggregator's `lens_result required: true` input instead.

14. **ADR-037 §1/§6 ("no `WIRING`/SPEC grammar") vs design-gate (simple.yaml:330-336).**
    - **The code still requires `[change]/[guard]` classification and `WIRING`.** ADR-037's own Limitations section defers this to #971, but the decision text reads as done.

### From ADR-041–045

1. **ADR-041 Corollary 2 vs code: core/event-bus/event-bus.sh:219 (and core/state/atomic.sh:132).**
   - The ADR says an authoritative writer's bounded wait "must fail soft on timeout (never abort the caller)".
   - The jsonl append does `flock -w 5 9 || exit 1` in an unguarded subshell, so under `set -e` a 5s lock contention ends the calling stage silently, rc=1 (reproduced with a scratch probe), and the event is lost.
   - The ADR's own Consequences paragraph also says emit "MUST never fail its caller" (the `return 0` at event-bus.sh:268 never runs).
   - The code follows neither: it aborts.
2. **ADR-045 §Verdict ("only `term_rc ∈ {2,8}` … `blocked_on_scope` (7) never reroute") vs cycle-orchestrator.sh:2858 (#2178).**
   - The code admits rc=7, and a test asserts it: tests/unit/core-pipeline-cycle-reuse-and-route-back-test.sh:105-110.
   - The code follows #2178; ADR-045 was never amended.
3. **ADR-045 §Verdict (reclassify only "when the route_back predicate matches") vs cycle-orchestrator.sh:2880-2891 (#2172/#2178).**
   - The code reroutes without a predicate match when the build "cannot complete": blocked_on_scope, or exhausted with an `empty_diff` build. It emits `cycle.route_back.blocked_on_scope` / `cycle.route_back.exhausted_unchanged`.
   - The code wins; no ADR records this.
4. **ADR-045 Amendment #1219 (`when: {field: verdict, op: eq, value: route_design}`; "route_back.when reads ONLY the verdicts blob") vs config/templates/simple.yaml:285-293 and deployed.yaml:103-111 (#1987).**
   - The templates use `field: fault`, `op: in`, `value: specification scope`.
   - Code and template-simple-yaml-test.sh:290-294 follow #1987; ADR-045 is stale. ADR-040 §route verdict (cited by ADR-045) may carry the same stale `route_design` wording.
5. **ADR-043 §Scope plumbing (`ZBUILD_SCOPE_ALLOWLIST` "derived per-stage from `plan.files[]`") vs core/pipeline/runner.sh:531-557.**
   - The code derives it from `artifacts/stage-reports.json .scope_files` plus the shape floor, and never reads plan.json (#2189, #1874). tests/unit/engine-stage-reports-test.sh:70 pins the new behaviour.
   - The code wins; ADR-043 is unamended.
6. **ADR-042 Decision / Impl ("the leaf path keeps its existing inline logic") vs runner.sh:3902 (#1770).**
   - Leaf verdict resolution now uses `resolve_stage_plugin`, while leaf dispatch (runner.sh:1892-1904) is still inline.
   - Minor drift: the ADR describes a state that is now only half true.

### From ADR-046–050

1. **ADR-046 (Decision) vs ADR-019 / #2176 / code.** ADR-046 says design_verify_cycle is `on_max: continue`. config/templates/simple.yaml:122 says `on_max: halt`, pinned by tests/unit/design-cycle-on-max-abort-test.sh:26. The code follows `halt`; ADR-046 was never amended.
2. **ADR-046 §1 ("No LLM, no baseline", ADR-037 §3) vs code.** design-gate's current C6 GUARD-BASELINE runs [guard] assertions at the merge-base (plugins/tool/design-gate/plugin.sh:150-181; tests/unit/design-gate-guard-baseline-test.sh:135). The code runs a baseline.
3. **ADR-046 §1 C4/C6 and §2 vs code.** The ADR requires declared testfiles to exist (C4), tag presence (C6), and a stub writer that embeds `[SPEC-n]` tags. Code: a missing testfile passes (#1649; design-gate-test.sh:172), tag presence was deleted (#1477; :95), and design writes no stubs (design-acceptance-block-test.sh:97-101). The code follows the later issues; the ADR text is stale. The design-gate manifest description still lists the old C4/C6.
4. **ADR-046 §1 ("feedback ONLY on fail") vs ADR-055 §9.** ADR-055 §9 says it is written on every terminal verdict; so do the design-gate manifest and design-gate-test.sh:219. The code follows ADR-055.
5. **ADR-046 Amendment #1219 (route_back `when: gate-aggregator.verdict eq route_design`) vs code.** The template uses `field: fault, op: in, value: specification scope` (#1987; template-simple-yaml-test.sh:290-295). The code follows #1987.
6. **ADR-047 §3 ("channel missing/malformed → warn") vs ADR-054 / code.** Malformed → `error` (core-pipeline-verdict-test.sh:208). A non-JSON primary with no sidecar → `pass` (verdict-stage-agnostic-test.sh:79; verdict.sh:280-286 "presence==pass"). This is also the batch's known ADR-054 §5 vs ADR-047 §3 sidecar conflict, seen from the ADR-047 side: §3 calls the sidecar "the normal contract", yet its absence silently passes.
7. **ADR-047 §5 (amended: "every declared input … ordered earlier OR reachable by route_back; strictly stronger, covers optional inputs") vs ADR-055 §1.5 as amended by #1825 / code.** Two parts:
   - ADR-055 limits the zero-producer refusal to REQUIRED inputs (contract-validator.sh:465-478; input-gating-test.sh:136).
   - The validator has NO ordering/route_back check: a later producer with no route_back is accepted (core-pipeline-contract-validator-test.sh:233). Only self-edges are checked (SELF_REF).

   The code follows ADR-055/#1825. ADR-047 overstates the guarantee.
8. **ADR-047 §5 ("these error, not warn") vs code.** `_runner_validate_startup_preflight` defaults to `ZBUILD_CONTRACT_VALIDATOR=warn` (runner.sh:713, 1808, 1829), while the resolvability check defaults to enforce but is skipped when the mode is not enforce (runner.sh:622). The code is mixed.
9. **ADR-047 §1 ("exactly four operators") vs ADR-047 Impl H / ADR-059 / code.** `map:` groups and `always_run:` (simple.yaml:65) are additional composition operators that the mechanics enumerate.
10. **ADR-047 Consequences ("nothing under core/pipeline/ names a zBuild stage") vs code.** core/pipeline/runner.sh:236 and core/pipeline/cycle-orchestrator.sh:2335 hardcode intake's artifact `intake-baseline-ref.txt`. No guard catches real stage names.
11. **ADR-048 §5 (workflow calls `release.sh --patch --skip-if-no-issues`) vs code.** tests/integration/release-sh-scheduled-test.sh:177-196 asserts the scheduled workflow dispatches release.yml with `skip_if_no_issues=true` and no longer calls release.sh directly. The code follows the test.
12. **ADR-048 §1 vs §6 (internal).** §1 says an initiative completing rolls A.B from 1.0 to 1.1, i.e. a minor change. §6 says the `--major` cut (A→A+1) is what "declares an initiative complete", and it guards only `--major` with the "Initiative (A+1).0" milestone. `--minor`, which per §1 is the initiative rollover, skips the guard (release-sh-major-guardrails-test.sh:111-113).
13. **ADR-050 §6 ("Never skip the stage on the basis of prior output") vs ADR-050 #2225 amendment / code.** Design keeps the prior design with no model call (resume-default-test.sh:134). It also gates that reuse on the prior run's design-gate pass, which comes close to §3's "never reuse a deterministic-gate verdict" — although design-gate still re-runs this run. The code follows #2225.
14. **ADR-049 §1 ("Phase 1.0 treats absence as non-fatal") vs ADR-049 §5 (default `enforce`).** The code follows §5 (vision-admission-gate-test.sh:185). The §1 text is stale.

