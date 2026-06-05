# Orphan PRs — merged without linking to an issue

Auto-maintained by `scripts/manifest-sync.sh`. Each entry below is a PR that
merged without referencing an issue via `Closes #N` / `Fixes #N` / `Resolves #N`.

The point of this log is institutional memory: changes that didn't have a
tracking issue should still show up somewhere when reviewing repo history.

_Last updated: 2026-06-05T03:23:11Z_

| PR | Title | First seen |
|---|---|---|
| #2 | chore(ci): bump actions/setup-node from 5 to 6 | 2026-05-24 |
| #1 | chore(ci): bump actions/checkout from 5 to 6 | 2026-05-24 |
| #229 | [manifest-sync] Drift reconciliation | 2026-05-25 |
| #232 | [manifest-sync] Drift reconciliation | 2026-05-25 |
| #236 | fix(#87): address code review P1+P2 — malformed artifact isolation + markdown escaping | 2026-05-25 |
| #233 | [manifest-sync] Drift reconciliation | 2026-05-25 |
| #240 | fix: align security-lens hook with (stage, state_file) contract | 2026-05-25 |
| #234 | [manifest-sync] Drift reconciliation | 2026-05-25 |
| #237 | [manifest-sync] Drift reconciliation | 2026-05-25 |
| #242 | manifest: Phase 0.5 wave ordering + cleanup .claude/scheduled_tasks.lock | 2026-05-25 |
| #241 | [manifest-sync] Drift reconciliation | 2026-05-25 |
| #250 | [manifest-sync] Drift reconciliation | 2026-05-25 |
| #259 | test(parity): CI/CLI engine parity test for ADR-010 (#214) | 2026-05-25 |
| #256 | chore(ci): bump peter-evans/create-pull-request from 7 to 8 | 2026-05-25 |
| #255 | chore(ci): bump actions/checkout from 4 to 6 | 2026-05-25 |
| #254 | chore(ci): bump actions/upload-artifact from 4 to 7 | 2026-05-25 |
| #253 | [manifest-sync] Drift reconciliation | 2026-05-25 |
| #257 | [manifest-sync] Drift reconciliation | 2026-05-25 |
| #269 | fix(pipeline): address PR #268 review comments (strategy + orch contract) | 2026-05-25 |
| #265 | [manifest-sync] Drift reconciliation | 2026-05-25 |
| #295 | manifest(delta-deferred): file 8 tracking issues from review delta plan | 2026-05-26 |
| #324 | docs(#310): reconcile cache contract signature — ADR-011 matches the code | 2026-05-26 |
| #323 | fix(#299/#300): 24h boundary tests + UTC parsing fix + abort-trap coverage | 2026-05-26 |
| #322 | fix(#309): mutation harness verifies expected-failing-test belongs to mutated module | 2026-05-26 |
| #321 | fix(#311): composite strategy fail-loud with structured event | 2026-05-26 |
| #320 | feat(#308): default claim-coordinator plugin (github-labels) + race test | 2026-05-26 |
| #319 | fix(#307): dispatcher exports ZBUILD_PLATFORM per per-platform invocation | 2026-05-26 |
| #318 | fix(#287/#288/#294): manifest schema validation + fail-closed artifact scanner | 2026-05-26 |
| #317 | fix(#289 rescope): router C6 fail-closed when ZBUILD_RUN_ID/events log unset | 2026-05-26 |
| #316 | fix(#290): plugin lockfile hashes plugin.sh + manifest; reverify before source | 2026-05-26 |
| #315 | fix(#303): memory-sqlite busy_timeout — no more lost writes under concurrency | 2026-05-26 |
| #314 | docs(adr): Implementation Notes appendices + ADR-006/008 clarifications | 2026-05-26 |
| #270 | [manifest-sync] Drift reconciliation | 2026-05-26 |
| #326 | [manifest-sync] Drift reconciliation | 2026-05-26 |
| #328 | manifest: pull #292 (ADR-013) from phase-1 → phase-0.5 | 2026-05-27 |
| #327 | [manifest-sync] Drift reconciliation | 2026-05-27 |
| #346 | manifest: add Wave B plugin issues (#340-#345) for Phase 0.5 dogfooding | 2026-05-27 |
| #339 | fix: resolve Copilot review comments from PRs #335, #336, #337 | 2026-05-27 |
| #334 | [manifest-sync] Drift reconciliation | 2026-05-27 |
| #347 | [manifest-sync] Drift reconciliation | 2026-05-27 |
| #350 | feat(manifest-sync): richer PR body + 3× daily schedule | 2026-05-27 |
| #348 | [manifest-sync] Drift reconciliation | 2026-05-27 |
| #409 | fix: harden abort-trap test against kcov timing | 2026-05-28 |
| #395 | ci(#389): add lint step to reject hardcoded model names (ADR-003) | 2026-05-28 |
| #414 | [manifest-sync] Drift reconciliation | 2026-05-28 |
| #423 | fix(ci): drop invalid secrets.GITHUB_TOKEN from zbuild-pipeline workflow | 2026-05-28 |
| #420 | [manifest-sync] Drift reconciliation | 2026-05-28 |
| #434 | [manifest-sync] Drift reconciliation | 2026-05-29 |
| #453 | fix: strip ANSI/CSI escape sequences from captured input/output | 2026-05-29 |
| #452 | feat: pretty-print JSON outputs in stage-io banner via jq | 2026-05-29 |
| #451 | feat: human-readable command-kind input rendering in stage-io banner | 2026-05-29 |
| #450 | fix: stage-io banner uses dedicated fd 3, survives plugin 2>/dev/null | 2026-05-29 |
| #449 | fix: stage-io stdout banner goes to stderr (route_to_model contention) | 2026-05-29 |
| #448 | fix: export _TPL_STAGE_IO_* vars so plugin subshells see stage-io config | 2026-05-29 |
| #446 | chore: verbose stage-io defaults in standard.yaml (file+stdout, tail 200) | 2026-05-29 |
| #443 | chore(manifest-sync): backfill 55 orphan issues into keepers-manifest.yaml | 2026-05-29 |
| #441 | docs(ADR-015): propose stage-I/O capture chokepoint | 2026-05-29 |
| #475 | feat(#467): build agent-loop with pipeline-derived diff (ADR-018 Pattern 2) | 2026-05-30 |
| #472 | feat(#470): artifact renderer registry for inter-stage markdown (ADR-018) | 2026-05-30 |
| #471 | feat(#466): router adopts shipwright's claude flag set (ADR-018) | 2026-05-30 |
| #465 | docs(adr): ADR-018 — stage invocation modes (one-shot with tools vs agent-loop) | 2026-05-30 |
| #459 | fix(#456): intake refuse --issue <N> when CLOSED; report state back to operator | 2026-05-30 |
| #458 | feat(#455): ADR-017 v1 — per-stage router.timeout_s in pipeline template | 2026-05-30 |
| #457 | docs(ADR-017): propose per-stage router configuration | 2026-05-30 |
| #454 | [manifest-sync] Drift reconciliation | 2026-05-30 |
| #493 | fix(#491): stage-io ordering contract (ADR-015 amendment + #481 fix) | 2026-05-30 |
| #487 | feat(#484): intake creates feature branch from issue (fail-closed) | 2026-05-30 |
| #480 | [manifest-sync] Drift reconciliation | 2026-05-30 |
| #543 | feat(banner): drop stage-io: prefix + blank-line spacing between stages (#523) | 2026-05-31 |
| #536 | fix(build): classify git apply --check rc=128 as corrupt_format / tool_state (#529) | 2026-05-31 |
| #532 | docs(ADR-020): propose deferred-work tracker workflow | 2026-05-31 |
| #522 | docs(adr): cross-reference cleanup + missed-amendment audit fixups | 2026-05-31 |
| #516 | feat(runner): stage-start + stage-end timestamps with duration (#508) | 2026-05-31 |
| #500 | feat(#496): inter-stage data contract + pre-flight validator (ADR-020) | 2026-05-31 |
| #644 | chore: drop unit step continue-on-error (#635 fixed) | 2026-06-02 |
| #638 | chore: drop integration step continue-on-error (96/96 passing) | 2026-06-02 |
| #620 | fix(runner): export ZBUILD_STATE_DIR so #617 branch-state injection fires (#618) | 2026-06-02 |
| #611 | feat(build): pipeline commits per cycle iter using COMMIT_SUMMARY marker (#608) | 2026-06-02 |
| #603 | fix(portability): replace grep -P with portable equivalents in 3 tests (#601) | 2026-06-02 |
| #599 | feat(cleanup): handle zb-applycheck-* stashes + tmpdirs + --restore-stash flag (#594) | 2026-06-02 |
| #597 | feat(install): copy code to $ZBUILD_HOME instead of symlinking (#595) | 2026-06-02 |
| #588 | fix(test-harness): open fd 3 in run-tests.sh + relax stage-io guard with warn+event fallback (#586) | 2026-06-02 |
| #657 | docs(adr-013): taxonomy-only scope clarification (ADR-016 prerequisite) | 2026-06-02 |
| #648 | [manifest-sync] Drift reconciliation | 2026-06-02 |
| #659 | [manifest-sync] Drift reconciliation | 2026-06-04 |
| #680 | chore(tests): add total rollup + quiet mutation table on full pass | 2026-06-05 |
| #678 | [manifest-sync] Drift reconciliation | 2026-06-05 |
