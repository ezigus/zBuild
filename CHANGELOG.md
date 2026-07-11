# Changelog

All notable changes to zBuild are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows
[Semantic Versioning](https://semver.org/) with a cadence policy: **major** = manual
milestone release, **minor** = weekly automated release, **patch** = hotfix.

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
