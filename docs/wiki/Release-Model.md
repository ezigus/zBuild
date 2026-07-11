# Release Model

zBuild follows **SemVer with a cadence policy** (`MAJOR.MINOR.PATCH`):

| Part | Meaning | How it's cut |
|---|---|---|
| **major** | A milestone release marking a phase / major-capability completion. | **Manual.** `1.0.0` is the first (phases 0, 0.5, 1). |
| **minor** | A regular, incremental release. | **Weekly, automated** — a scheduled workflow bumps the minor and creates a GitHub Release. |
| **patch** | A hotfix. | As needed. |

## 1.0.0
The first stable release: phases 0, 0.5, and 1 — the core engine, safety primitives, the plugin system, the stage-agnostic pipeline mechanics, models-as-data routing, the single install path, and the review/gate model. See [`CHANGELOG.md`](https://github.com/ezigus/zBuild/blob/main/CHANGELOG.md) and [Releases](https://github.com/ezigus/zBuild/releases).

## What's coming (Phase 1.1)
Release automation is tracked under initiative [#1362](https://github.com/ezigus/zBuild/issues/1362):
- **`zbuild release`** — cut a release from the CLI (#1355).
- **Weekly cadence** — the scheduled minor-release workflow (#1357).
- **Versioning foundation / `compute_version`** (#873), signed tarball (#875), CI release workflow (#877), docs-as-release (#876).
- **Docs automation** (#1356) — regenerate the per-leaf/per-mechanic pages and publish README + wiki on release.
- **Vision-document standard** (#1358) — a required, prompt-injected repo vision.

## Versioning notes
The version is surfaced by `zbuild --version` (and recorded per-install at `$ZBUILD_HOME/version`). Model tiers T0–T4 are stable ordinals independent of the release version (see [[mechanics/router-models-as-data]]).
