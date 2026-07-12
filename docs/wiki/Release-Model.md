# Release Model

This page explains how zBuild versions its releases — what the version numbers mean, how they're generated automatically, and how you can plug in a different versioning scheme if the default doesn't fit your workflow.

---

## What the version number means

zBuild versions look like `1.0.2.13` — four numbers separated by dots. Here's what each part means in plain terms:

| Part | Plain meaning | Technical detail |
|---|---|---|
| **`A.B`** (first two) | Which major milestone ("initiative") the release belongs to. Increments when a new initiative ships; resets C and D. | Anchored by the latest `vA.B.0.0` tag. Currently **`1.0`**. |
| **`C`** (third) | How many releases have been cut since the current milestone started. | Count of release tags under this `A.B`. |
| **`D`** (fourth) | How many GitHub issues have been closed since the current milestone started — a progress indicator. | Issues closed since the anchor tag. |

**Worked example:** `1.0.0.0` → `1.0.1.12` → `1.0.2.13` → … → `1.1.0.0` (when the next initiative, 1.1, ships).

The version is **never set by hand**. It's computed automatically from git tags and closed issues each time. The `VERSION` file holds no leading `v` — that prefix appears only on tags.

---

## The current stable release: 1.0.0

The `1.0.0` release covers phases 0, 0.5, and 1 — the core engine, safety primitives, the plugin system, stage-agnostic pipeline mechanics, models-as-data routing, the single install path, and the review/gate model.

See [`CHANGELOG.md`](https://github.com/ezigus/zBuild/blob/main/CHANGELOG.md) and [Releases](https://github.com/ezigus/zBuild/releases) for the full history.

---

## What's coming in Initiative 1.1

Release automation is tracked under [#1362](https://github.com/ezigus/zBuild/issues/1362):

- **Versioning foundation / `compute_version`** (#873) — the model described on this page
- **`zbuild release` command** (#1355) and the release generator (#874 REL-B)
- **Signed tarball** (#875 REL-C), CI release workflow (#877 REL-D), docs-as-release (#876 REL-E)
- **Release cadence** (#1357 REL-F) — **implemented**. Default: **every Monday at 09:00 UTC** via `.github/workflows/zbuild-release-scheduled.yml`. Day-of-week is configurable by editing the cron expression's 5th field (e.g. `1` = Monday, `5` = Friday). The release is **skipped automatically** when no issues have closed since the last release (`--skip-if-no-issues`). A `workflow_dispatch` input enables on-demand dry runs.
- **Docs automation** (#1356), **vision-document standard** (#1358)

---

## Advanced: pluggable versioning (newcomers can skip)

The `A.B.C.D` scheme above is the **default**, not the only option. zBuild's versioning is fully pluggable — you can replace it with any scheme (plain SemVer, calendar versioning, build numbers, `git describe`, etc.) without touching engine code.

Versioning is an [ADR-011](https://github.com/ezigus/zBuild/blob/main/docs/adr/ADR-011-pluggable-backends.md) backend capability, selectable the same way as the `memory`, `orchestrator`, and `cache` backends:

- **Default backend:** `initiative-count` (the `A.B.C.D` scheme above)
- **Custom backend:** ship a `versioning-backend` plugin and select it via:
  - `ZBUILD_VERSIONING_BACKEND` environment variable, or
  - `backends.versioning` in `.zbuild/config.yaml`
  - Precedence: env > config file > compiled-in default

The engine calls `resolve_repo_version`, which dispatches to whichever strategy is selected. No scheme is hardcoded in core. See [ADR-048](https://github.com/ezigus/zBuild/blob/main/docs/adr/ADR-048-release-versioning-signing.md) for the full specification.

## Advanced: version file details (newcomers can skip)

- The version lives in `VERSION` at the repo root, copied to `$ZBUILD_HOME/config/VERSION` on install.
- `zbuild --version` reads `config/VERSION` first (before the repo-root `VERSION`) and validates the shape.
- A separate `$ZBUILD_HOME/version` file records per-install metadata (sha, branch, timestamp) — this is not the version.
- On case-insensitive filesystems (macOS), `VERSION` and `version` collide; the shape-guard rejects the metadata file and reads the true version correctly.
- Both 3-part (`1.0.0`) and 4-part (`1.0.0.0`) values are accepted during the transition period (`^[0-9]+(\.[0-9]+){2,3}$`).
- Model tiers T0–T4 are stable ordinals independent of the release version (see [[mechanics/router-models-as-data]]).
