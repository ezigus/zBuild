# Changelog

All notable changes to zBuild are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows
[Semantic Versioning](https://semver.org/) with a cadence policy: **major** = manual
milestone release, **minor** = weekly automated release, **patch** = hotfix.

## [1.0.0.61] — 2026-07-15

> **Versioning is plug-and-play.** The `A.B.C.D` (`initiative-count`) scheme
> shown here is just one example — the versioning backend is a swappable plugin
> (ADR-011 / ADR-048). Drop in a different `versioning-backend` to version this
> repo any way you like, with zero engine changes.

### Features

- [SHIP-5] CI auto-merge → publish reliability: publish in the same job (bypass GITHUB_TOKEN recursion) ([#1502](https://github.com/ezigus/zBuild/issues/1502))
- [SHIP-3] --ship idempotent re-run/resume of an interrupted ship ([#1500](https://github.com/ezigus/zBuild/issues/1500))
- [SHIP-2] --ship CLI/UX: --dry-run full plan, confirm prompt + --yes, per-phase progress, help ([#1499](https://github.com/ezigus/zBuild/issues/1499))
- [SHIP-1] --ship orchestration engine: _release_ship (prepare→push→PR→wait→merge→publish, pinned + gated) ([#1498](https://github.com/ezigus/zBuild/issues/1498))
- [release] zbuild release wrapper + --dry-run preview (folds DOC-F plan; read-only) ([#1466](https://github.com/ezigus/zBuild/issues/1466))
- [release] Major-release guardrails + initiative↔GitHub binding ([#1464](https://github.com/ezigus/zBuild/issues/1464))
- [release] Initiative-aware versioning scheme (w.x.0.0 major / w.x.y.z minor) ([#1462](https://github.com/ezigus/zBuild/issues/1462))
- [DOC-A] Plugin manifest: optional summary + usage doc fields ([#1419](https://github.com/ezigus/zBuild/issues/1419))
- [DOC-E] Doc freshness + coverage + DOC-STYLE gate ([#1418](https://github.com/ezigus/zBuild/issues/1418))
- [DOC-D] Unified LLM doc-generator (gather → template+code+page → route_to_model) ([#1417](https://github.com/ezigus/zBuild/issues/1417))
- [DOC-C] config/mechanics.yaml registry (+ A→B code fallback) ([#1416](https://github.com/ezigus/zBuild/issues/1416))
- [DOC-B] Standardized doc-page template (shared LLM output contract) ([#1415](https://github.com/ezigus/zBuild/issues/1415))
- [DOC-A] Plugin manifest: optional summary + usage doc fields ([#1414](https://github.com/ezigus/zBuild/issues/1414))
- [REL-D1] Complete release.sh apply path — build/sign tarball, tag, publish Release ([#1412](https://github.com/ezigus/zBuild/issues/1412))
- [1.2] Hardwire tier-2 personas into plan / impact / test (static) ([#1390](https://github.com/ezigus/zBuild/issues/1390))
- [1.2] Hardwire specialist personas into the 5 review lenses (static) ([#1389](https://github.com/ezigus/zBuild/issues/1389))
- [INITIATIVE] 0.5 — MVP Pipeline & Distribution ([#1386](https://github.com/ezigus/zBuild/issues/1386))
- [INITIATIVE] 0 — Core Engine Foundation ([#1385](https://github.com/ezigus/zBuild/issues/1385))
- [EPIC] Shipped: Initiative 1.0 (part 4) ([#1384](https://github.com/ezigus/zBuild/issues/1384))
- [EPIC] Shipped: Initiative 1.0 (part 3) ([#1383](https://github.com/ezigus/zBuild/issues/1383))
- [EPIC] Shipped: Initiative 1.0 (part 2) ([#1382](https://github.com/ezigus/zBuild/issues/1382))
- [EPIC] Shipped: Initiative 1.0 (part 1) ([#1381](https://github.com/ezigus/zBuild/issues/1381))
- [EPIC] Shipped: Initiative 0.5 (part 2) ([#1380](https://github.com/ezigus/zBuild/issues/1380))
- [EPIC] Shipped: Initiative 0.5 (part 1) ([#1379](https://github.com/ezigus/zBuild/issues/1379))
- [EPIC] Shipped: Initiative 0 (part 1) ([#1378](https://github.com/ezigus/zBuild/issues/1378))
- [INITIATIVE] 1.0 — Pipeline & Intelligence ([#1377](https://github.com/ezigus/zBuild/issues/1377))
- [VIS-C] Inject vision into all stage prompts ([#1361](https://github.com/ezigus/zBuild/issues/1361))
- [VIS-B] Admission-gate enforcement + `zbuild vision init` ([#1360](https://github.com/ezigus/zBuild/issues/1360))
- [EPIC] Vision-document standard: required, validated, prompt-injected repo intent ([#1358](https://github.com/ezigus/zBuild/issues/1358))
- [REL-F] Weekly release cadence — scheduled workflow (configurable day-of-week) ([#1357](https://github.com/ezigus/zBuild/issues/1357))
- [REL-B1] `zbuild release` command — cut a release from the CLI ([#1355](https://github.com/ezigus/zBuild/issues/1355))
- [REL-C] Signed, checksummed release tarball + verified upgrade ([#875](https://github.com/ezigus/zBuild/issues/875))
- [REL-B] release.sh + zbuild release: per-issue changelog/release-notes generator ([#874](https://github.com/ezigus/zBuild/issues/874))
- Add claude GitHub actions 1783806370631 ([#1408](https://github.com/ezigus/zBuild/pull/1408))

### Fixes

- [release] Doc regen must not leave .bak/.hash cruft in the working tree ([#1492](https://github.com/ezigus/zBuild/issues/1492))
- [release] Converge the weekly scheduled workflow onto the branch→PR→publish flow ([#1491](https://github.com/ezigus/zBuild/issues/1491))
- [release] Prepare release on a branch + PR; publish commits, tags the commit, pushes tag before gh release ([#1490](https://github.com/ezigus/zBuild/issues/1490))
- [EPIC] Release-flow correctness: one branch→PR→publish path (fix direct-cut) ([#1489](https://github.com/ezigus/zBuild/issues/1489))
- [release] zbuild release must target the CWD repo, not its install dir (repo-agnostic, run from installed) ([#1487](https://github.com/ezigus/zBuild/issues/1487))
- [release] release.yml: commit the bumped VERSION in the Release PR (git add VERSION) ([#1483](https://github.com/ezigus/zBuild/issues/1483))
- [release] release-sh-apply-test: isolate VERSION via ZBUILD_RELEASE_VERSION_FILE (stop leaking real VERSION) ([#1482](https://github.com/ezigus/zBuild/issues/1482))
- [EPIC] Release VERSION-file handling bugs (test leak + uncommitted bump) ([#1481](https://github.com/ezigus/zBuild/issues/1481))
- [release] CI dispatch for a major/initiative release (cadence input) ([#1465](https://github.com/ezigus/zBuild/issues/1465))
- [EPIC] Initiative-aware release command + versioning (zbuild release, major/minor, CI dispatch) ([#1461](https://github.com/ezigus/zBuild/issues/1461))
- [REL-D2] release.yml CI workflow (workflow_dispatch) — Option-B PR → auto-merge → publish ([#1413](https://github.com/ezigus/zBuild/issues/1413))
- [REL-D] CI release-PR workflow (workflow_dispatch) + per-phase gate ([#877](https://github.com/ezigus/zBuild/issues/877))
- Fix --ship checks-wait: scope to REQUIRED checks only (--required) ([#1511](https://github.com/ezigus/zBuild/pull/1511))
- Fix --ship checks-wait race: tolerate GH not having registered checks yet ([#1509](https://github.com/ezigus/zBuild/pull/1509))
- Fix release-repo-agnostic-test.sh SPEC-3 hardcoded VERSION assumption ([#1508](https://github.com/ezigus/zBuild/pull/1508))
- Restore inline-comment MCP tool grant — fix silent 0-comment Claude reviews ([#1470](https://github.com/ezigus/zBuild/pull/1470))
- [#1420 follow-up] doc publish: default repo_root to CWD (installed-shim fix) ([#1458](https://github.com/ezigus/zBuild/pull/1458))
- Fix silent Claude-review runs + always post a commit-stamped outcome comment ([#1451](https://github.com/ezigus/zBuild/pull/1451))
- fix(test): de-flake manifest-sync MS5 — compare content, not mtime ([#1388](https://github.com/ezigus/zBuild/pull/1388))

### Docs

- [release] zbuild release orchestrates doc regen + wiki publish across the lifecycle (ops stay separate) ([#1467](https://github.com/ezigus/zBuild/issues/1467))
- [release] zbuild release command — local dry-run + create-PR (minor default, --major), folds docs ([#1463](https://github.com/ezigus/zBuild/issues/1463))
- [DOC-F] Publish generated docs to the wiki + README (release step) ([#1420](https://github.com/ezigus/zBuild/issues/1420))
- [1.1] Documentation style standard (newcomer-first) — enforce in doc regeneration ([#1406](https://github.com/ezigus/zBuild/issues/1406))
- [EPIC] Automate documentation: per-leaf & per-mechanic docs generated + published on release ([#1356](https://github.com/ezigus/zBuild/issues/1356))
- [REL-E] Docs-as-release-deliverable: per-x.y doc regen + notes-cover-every-issue gate ([#876](https://github.com/ezigus/zBuild/issues/876))
- [EPIC] Release process: per-phase gated, signed-tarball releases + versioned docs ([#872](https://github.com/ezigus/zBuild/issues/872))
- [#1467] release.sh orchestrates doc regen + wiki publish (ops stay separate) ([#1474](https://github.com/ezigus/zBuild/pull/1474))
- [#1420] DOC-F: regen + publish generated docs to wiki + README ([#1453](https://github.com/ezigus/zBuild/pull/1453))
- docs: release cadence is weekly + configurable (not daily) ([#1411](https://github.com/ezigus/zBuild/pull/1411))
- docs: newcomer-first README + DOC-STYLE standard ([#1405](https://github.com/ezigus/zBuild/pull/1405))
- [#1362] docs: README + wiki point to milestones, Roadmap board, wiki ([#1364](https://github.com/ezigus/zBuild/pull/1364))
- [#1362] zBuild 1.0.0: VISION, user README, full wiki, VERSION + CHANGELOG ([#1363](https://github.com/ezigus/zBuild/pull/1363))

### Architecture

- [VIS-A] Vision-document standard + ADR ([#1359](https://github.com/ezigus/zBuild/issues/1359))
- [REL-A] Release versioning foundation: x.y.z scheme + VERSION file + ADR ([#873](https://github.com/ezigus/zBuild/issues/873))
- [#873] REL-A: pluggable 4-part versioning (A.B.C.D) + ADR-048 ([#1387](https://github.com/ezigus/zBuild/pull/1387))

### Safety

- [1.2] Tier-2 personas: planner / impact-analyst / security-auditor / test-analyst / implementer ([#1326](https://github.com/ezigus/zBuild/issues/1326))

### Other

- [pipeline] Plan stage: budget-aware prompt guardrail (inject turn budget + bias to converge) ([#1442](https://github.com/ezigus/zBuild/issues/1442))
- [DOC-D3] --all batch over every plugin + mechanic ([#1441](https://github.com/ezigus/zBuild/issues/1441))
- [DOC-D2] Single-source LLM page generation + NO_CHANGE + write + reconciled hash ([#1440](https://github.com/ezigus/zBuild/issues/1440))
- [DOC-D1] Deterministic gather(source) collector (+ A→B code fallback) ([#1439](https://github.com/ezigus/zBuild/issues/1439))
- Pipeline PRs get no Claude review — drafts suppress it; open non-draft ([#1436](https://github.com/ezigus/zBuild/issues/1436))
- [data-provision E] Application areas as data: design→architect; lenses→map over agents ([#1309](https://github.com/ezigus/zBuild/issues/1309))
- zbuild: automated PR for issue #1500 ([#1506](https://github.com/ezigus/zBuild/pull/1506))
- [SHIP-5] CI auto-merge → publish reliability: publish in the same job (bypass GITHUB_TOKEN recursion) ([#1505](https://github.com/ezigus/zBuild/pull/1505))
- zbuild: automated PR for issue #1499 ([#1504](https://github.com/ezigus/zBuild/pull/1504))
- zbuild: automated PR for issue #1498 ([#1503](https://github.com/ezigus/zBuild/pull/1503))
- [#1491] Converge weekly cron onto the shared branch→PR→publish flow ([#1495](https://github.com/ezigus/zBuild/pull/1495))
- [#1490] Release: split release.sh into prepare (branch→commit→PR) + publish (tag→push→gh release) ([#1494](https://github.com/ezigus/zBuild/pull/1494))
- [#1492] doc regen leaves no .bak/.hash cruft in the working tree ([#1493](https://github.com/ezigus/zBuild/pull/1493))
- [#1487] Make the release path repo-agnostic (target the CWD repo, not the install dir) ([#1488](https://github.com/ezigus/zBuild/pull/1488))
- [#1482] release-sh-apply-test: isolate VERSION via ZBUILD_RELEASE_VERSION_FILE ([#1486](https://github.com/ezigus/zBuild/pull/1486))
- zbuild: automated PR for issue #1483 ([#1484](https://github.com/ezigus/zBuild/pull/1484))
- zbuild: automated PR for issue #1465 ([#1475](https://github.com/ezigus/zBuild/pull/1475))
- zbuild: automated PR for issue #1464 ([#1473](https://github.com/ezigus/zBuild/pull/1473))
- zbuild: automated PR for issue #1466 ([#1469](https://github.com/ezigus/zBuild/pull/1469))
- zbuild: automated PR for issue #1462 ([#1468](https://github.com/ezigus/zBuild/pull/1468))
- zbuild: automated PR for issue #1418 ([#1450](https://github.com/ezigus/zBuild/pull/1450))
- zbuild: automated PR for issue #1441 ([#1449](https://github.com/ezigus/zBuild/pull/1449))
- zbuild: automated PR for issue #1436 ([#1448](https://github.com/ezigus/zBuild/pull/1448))
- zbuild: automated PR for issue #1440 ([#1446](https://github.com/ezigus/zBuild/pull/1446))
- chore(ci): Bump actions/checkout from 4 to 7 ([#1445](https://github.com/ezigus/zBuild/pull/1445))
- [#1439] DOC-D1: deterministic gather(source) collector ([#1444](https://github.com/ezigus/zBuild/pull/1444))
- [#1442] Plan stage: budget-aware prompt guardrail (+ bump plan max_turns 25→45) ([#1443](https://github.com/ezigus/zBuild/pull/1443))
- [#1416] DOC-C: config/mechanics.yaml registry + validator (A→B fallback) ([#1438](https://github.com/ezigus/zBuild/pull/1438))
- zbuild: automated PR for issue #1415 ([#1437](https://github.com/ezigus/zBuild/pull/1437))
- zbuild: automated PR for issue #1414 ([#1433](https://github.com/ezigus/zBuild/pull/1433))
- [#1360] VIS-B: vision admission gate + `zbuild vision init` (+ config bypass) ([#1432](https://github.com/ezigus/zBuild/pull/1432))
- chore: make Claude PR reviewer actually post comments (--comment + allowedTools) ([#1430](https://github.com/ezigus/zBuild/pull/1430))
- zbuild: automated PR for issue #1361 ([#1429](https://github.com/ezigus/zBuild/pull/1429))
- chore: Claude PR code-review — comment-only, auto on PR + on-demand ([#1428](https://github.com/ezigus/zBuild/pull/1428))
- zbuild: automated PR for issue #1359 ([#1427](https://github.com/ezigus/zBuild/pull/1427))
- zbuild: automated PR for issue #1357 ([#1426](https://github.com/ezigus/zBuild/pull/1426))
- zbuild: automated PR for issue #1413 ([#1423](https://github.com/ezigus/zBuild/pull/1423))
- [#1355] zbuild release cadence flags + VERSION stamp (reconciled onto #1412 direct-apply) ([#1422](https://github.com/ezigus/zBuild/pull/1422))
- [#1412] REL-D1: complete release.sh apply path — build/sign tarball, tag, publish ([#1421](https://github.com/ezigus/zBuild/pull/1421))
- [#876] REL-E: notes-cover-every-issue coverage gate + doc-style gate wired into release flow ([#1410](https://github.com/ezigus/zBuild/pull/1410))
- [#1406] Enforce the doc-style standard: lint-doc-style check + CI wiring ([#1409](https://github.com/ezigus/zBuild/pull/1409))
- [#875] REL-C: release tarball + SHA256SUMS + pluggable signing + verified upgrade ([#1407](https://github.com/ezigus/zBuild/pull/1407))
- [#874] REL-B: release.sh + zbuild release + per-issue notes/CHANGELOG generator ([#1404](https://github.com/ezigus/zBuild/pull/1404))

[1.0.0.61]: https://github.com/ezigus/zBuild/releases/tag/v1.0.0.61

## [1.0.0] — 2026-07-11

First stable release. zBuild is a flexible, plugin-based engine for composing AI
delivery pipelines — encode your process as a template and run every change through
it the same way, for consistent structure over time. This release covers phases 0,
0.5, and 1.

### Added
- **Engine & safety** — plugin registry with manifest discovery (ADR-001); an event
  bus persisting schema-validated events to SQLite + JSONL; a single redaction
  chokepoint that all model-bound text passes through (ADR-004); atomic, crash-safe
  state with resume (ADR-006); and a fail-closed admission gate.
- **Pipeline & operators** — stage-agnostic mechanics over a closed operator set
  (`leaf`, `sequence`, `parallel`, `cycle`, and data-driven `map`) (ADR-047); bounded
  convergence cycles with `exit_when` / all-any conditions / `on_max`, and `route_back`
  to earlier stages (ADR-045); and scope governance with a security floor and governed
  expansion (ADR-030). Ships the `simple` template (intake → plan → design_verify_cycle
  → impact → build_test_cycle → review_lenses → review-aggregator → pr) and `deployed`
  (adds deploy → validate → monitor).
- **Plugins** — six kinds (`agent`, `tool`, `recovery`, `orchestrator`,
  `claim-coordinator`, `daemon`) resolved by role-then-id (ADR-042). 36 plugins ship,
  including the review lenses, mechanical gates, aggregators, caches, and the
  GitHub-labels claim coordinator (ADR-005).
- **Router / models-as-data** — tiered routing (T0–T4) read from `config/models.json`;
  no model names in code; per-stage tier, timeout, and turn limits (ADR-003).
- **Distribution & CLI** — a single install path (`install.sh` copies the runtime into
  `~/.local/share/zbuild` and installs `zbuild` + `zb` shims, ADR-023); `zbuild --version`
  now reports semver from a `VERSION` file; commands for `pipeline start`/`resume`,
  `--attach`, `status`, `doctor`, `cleanup`, `plugin list`, `deferred`, `manifest`, and
  `upgrade`.
- **Review & gates** — mechanical gates aggregated by a single merge-blocking
  gate-aggregator; advisory review lenses (security, performance, red-team, correctness,
  scope) merged by a review-aggregator (ADR-040).
- **Documentation** — user-facing README, a `docs/VISION.md` North Star, and a full
  wiki (installation, getting started, configuration, CLI reference, pipeline & stages,
  a page per plugin and per mechanic, plugin authoring, architecture, troubleshooting).

[1.0.0]: https://github.com/ezigus/zBuild/releases/tag/v1.0.0
