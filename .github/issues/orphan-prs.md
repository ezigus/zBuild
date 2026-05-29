# Orphan PRs — merged without linking to an issue

Auto-maintained by `scripts/manifest-sync.sh`. Each entry below is a PR that
merged without referencing an issue via `Closes #N` / `Fixes #N` / `Resolves #N`.

The point of this log is institutional memory: changes that didn't have a
tracking issue should still show up somewhere when reviewing repo history.

_Last updated: 2026-05-29T18:49:40Z (rolling 30-PR window)_

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
