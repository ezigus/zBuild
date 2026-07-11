# Release Model

zBuild uses a **4-part `A.B.C.D`** version. It is **NOT** strict 3-part SemVer, and the
scheme is a **pluggable, repo-owner-configurable strategy** (see [[#Pluggable versioning]]).

| Part | Meaning | How it's derived |
|---|---|---|
| **`A.B`** | The last **completed initiative**, anchored by the latest `vA.B.0.0` tag. Rolls when the next initiative completes; `C`,`D` reset. | The `A.B` of the latest `vA.B.0.0` release tag. Currently **`1.0`** (`v1.0.0` exists). |
| **`C`** | **Release count** — the Nth release cut since the `A.B.0.0` initiative release (cadence-independent). | Count of prior release tags under this `A.B`. |
| **`D`** | Number of **issues closed since** the `A.B.0.0` initiative release — a progress counter toward the next initiative. | Issues closed since the anchor tag. |

Worked example: `1.0.0.0` → `1.0.1.12` → `1.0.2.13` → … → `1.1.0.0` (when Initiative 1.1
completes). The `VERSION` file carries **no** leading `v` (`v` is tag-only).

The selected versioning backend derives this dynamically — the version is never hand-set
(the pure `compute_version` helper only assembles + validates the 4 parts; the git/issue
gathering lives in the backend strategy, reached via `resolve_repo_version`). The `VERSION`
file and `zbuild --version` guard accept **3-or-4-part** (`^[0-9]+(\.[0-9]+){2,3}$`), so a
legacy 3-part value (the current `1.0.0`) still validates through the transition.

## Pluggable versioning

The scheme above is the **default**, not the law. Versioning is an [ADR-011](https://github.com/ezigus/zBuild/blob/main/docs/adr/ADR-011-pluggable-backends.md)
backend capability — selectable exactly like `memory` / `orchestrator` / `cache`:

- **Default:** `initiative-count` (the `A.B.C.D` scheme above).
- **Override:** set `ZBUILD_VERSIONING_BACKEND`, or `backends.versioning` in
  `.zbuild/config.yaml`, or ship a `versioning-backend` plugin (plain SemVer, date-based,
  calendar, …). Precedence: env > config file > compiled-in default.

The engine (`resolve_repo_version`) calls the **selected** strategy — no scheme is
hardcoded in the CLI/engine beyond the default strategy's own file. See
[ADR-048](https://github.com/ezigus/zBuild/blob/main/docs/adr/ADR-048-release-versioning-signing.md).

## 1.0.0 (baseline)
The first stable release: phases 0, 0.5, and 1 — the core engine, safety primitives, the
plugin system, the stage-agnostic pipeline mechanics, models-as-data routing, the single
install path, and the review/gate model. See [`CHANGELOG.md`](https://github.com/ezigus/zBuild/blob/main/CHANGELOG.md)
and [Releases](https://github.com/ezigus/zBuild/releases).

## What's coming (Initiative 1.1)
Release automation is tracked under initiative [#1362](https://github.com/ezigus/zBuild/issues/1362):
- **Versioning foundation / `compute_version`** (#873) — *this model*.
- **`zbuild release`** (#1355) and the release generator (#874 REL-B).
- **Signed tarball** (#875 REL-C), CI release workflow (#877 REL-D), docs-as-release (#876 REL-E).
- **Cadence** (#1357 REL-F) — default **daily @ 03:00** (configurable), **skip if no issues
  closed** since the last release.
- **Docs automation** (#1356), **vision-document standard** (#1358).

## Versioning notes
The version lives in the `VERSION` file (copied to `$ZBUILD_HOME/config/VERSION` on install)
and is surfaced by `zbuild --version`; the separate `$ZBUILD_HOME/version` file records
per-install metadata (sha/branch/timestamp), not the version. `zbuild --version` probes
`config/VERSION` **before** the repo-root `VERSION` and shape-guards the value — on a
case-insensitive filesystem the uppercase `VERSION` and lowercase `version` metadata file
collide, so the guard rejects the metadata and reads the true version. Model tiers T0–T4
are stable ordinals independent of the release version (see [[mechanics/router-models-as-data]]).
