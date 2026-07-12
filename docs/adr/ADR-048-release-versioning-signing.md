# ADR-048 — Release versioning & signing (pluggable 4-part A.B.C.D)

**Status:** Accepted (2026-07-11)
**Related:** ADR-011 (backend selection framework — versioning is a new backend capability),
ADR-003 (models-as-data / stable tier ordinals — the same "schemes are data, names are not"
discipline), ADR-023 (single install path — the `VERSION` file + `$ZBUILD_HOME/version`
metadata seam). EPIC #872 (release), initiative #1362. Obsoletes #88 (npm-publish — do
**not** revive; distribution is the signed-tarball track REL-C #875, not npm).

## Context

zBuild needs a release version that is meaningful, derivable, and not a hand-maintained
string. #1362/#1363 already shipped the plumbing: a tracked `VERSION` file (currently
`1.0.0`), `install.sh` copying it to `$ZBUILD_HOME/config/VERSION`, and `zbuild --version`
surfacing it alongside the `$ZBUILD_HOME/version` install-metadata (sha/branch/date).

What was missing: (1) a defined *scheme* for what the version numbers mean, and (2) the
recognition that the scheme itself is a **policy** a repo owner may want to change. The
epic's original scheme (`z = cumulative issues closed all-time`, e.g. `v0.1.341`) and an
interim 3-part weekly-SemVer model were both superseded during design (2026-07-11).

## Decision

### 1. The default scheme is 4-part `A.B.C.D`

- **`A.B`** = the last **completed initiative**, anchored by the latest `vA.B.0.0`
  release tag. The initiative release itself is `A.B.0.0` (e.g. `1.0.0.0`). Today the
  anchor is `1.0` (tag `v1.0.0` exists; no initiative has completed past it yet). When
  the next initiative (1.1) completes, `A.B` rolls to `1.1` and `C`,`D` reset.
- **`C`** = **release count** — the Nth release cut since the `A.B.0.0` initiative
  release (count of prior release tags under this `A.B`; cadence-independent).
- **`D`** = number of **issues closed since** the `A.B.0.0` initiative release — a
  monotonic progress counter toward the next initiative.
- Example: `1.0.0.0` → `1.0.1.12` → `1.0.2.13` → … → `1.1.0.0`.

This is **NOT strict 3-part SemVer**. The `VERSION` file carries no leading `v`
(`v` is tag-only); the `VERSION` file + `zbuild --version` shape guard accept
**3-or-4-part** (`^[0-9]+(\.[0-9]+){2,3}$`) so a legacy 3-part value still validates.

### 2. Versioning is a PLUGGABLE ADR-011 backend

The scheme above is the **default**, not the law. Versioning is a new ADR-011 backend
**capability** — repo-owner-selectable exactly like `memory`, `orchestrator`, and `cache`:

- Default: `_ZBUILD_BACKEND_DEFAULTS[versioning]="initiative-count"`; the sole allowed
  built-in is listed in `_ZBUILD_BACKEND_ALLOWED[versioning]`.
- Selection precedence (unchanged ADR-011 rule): env `ZBUILD_VERSIONING_BACKEND` >
  `.zbuild/config.yaml` `backends.versioning` > compiled-in default.
- A repo owner overrides with a `versioning-backend` plugin (plain SemVer, date-based,
  calendar, etc.). The engine calls the **selected** strategy — **no scheme is hardcoded
  in the CLI/engine** beyond the default strategy's own file.

The engine is **mechanism**; the versioning scheme is **data/strategy**. This mirrors
ADR-003 (models are data, not names) and completes ADR-011's backend set.

### 3. The engine seam and the pure/gathering split

- `resolve_repo_version` (`scripts/lib/version.sh`) reads
  `zbuild_config_get_backend versioning`, sources the selected strategy, and calls its
  `<backend>_version` entrypoint. An unknown/absent configured backend **fails loud**
  (rc=1, `backend.missing` message + event), mirroring ADR-011.
- The default strategy (`scripts/lib/versioning/initiative-count.sh`) separates a
  **pure** `compute_version <anchor_xy> <release_count> <issues_since>` — no net/gh/git,
  fail-loud on malformed input, self-validates the assembled 4-part shape, unit-testable —
  from a **gathering** wrapper (`initiative-count_version`) that derives `A.B`/`C`/`D`
  from git tags (and, in REL-B, `gh` for the issues-closed count) and delegates to the
  pure function.

### 4. `--version` reads the stamped VERSION file (not a live recompute)

`zbuild --version` prints the **released, stamped** value from the `VERSION` file, so an
installed tree reports the version it was cut at — not a value recomputed against the
user's local tags. `resolve_repo_version` is the seam a *release cutter* (REL-B #874)
uses to compute the next version to stamp. `--version` probes `config/VERSION` **before**
repo-root `VERSION` and rejects any non-semver content (see Implementation Notes).

### 5. Single install path; signing deferred; cadence implemented (REL-F #1357)

Distribution stays on the single install path (ADR-023); #88 (npm-publish) is obsolete
and not revived. **Signing** (signed release tarball) is deferred to **REL-C (#875)**.

**Release cadence — done (REL-F #1357):** `.github/workflows/zbuild-release-scheduled.yml`
fires every Monday at 09:00 UTC (cron `0 9 * * 1`). Day-of-week is configurable by editing
the 5th cron field. The workflow calls `scripts/release.sh --patch --skip-if-no-issues`:
when no issues have closed since the last release (D=0), the script exits 0 with a skip
notice — no empty release is cut. A `workflow_dispatch` with a `dry_run` boolean input
enables on-demand dry runs without mutating state. A fork guard
(`if: github.repository == 'ezigus/zBuild'`) prevents accidental runs in forks.

## Consequences

- Adding a new versioning policy is a **plugin + config change**, zero edits to the CLI
  or engine — the same portability property ADR-011 gives memory/cache/orchestrator.
- 4-part versions are self-describing: `A.B` names the initiative, `C` the release count,
  `D` the delivery progress — derivable from tags + closed issues, never hand-set.
- The `VERSION` shape guard accepting 3-or-4-part keeps `1.0.0` (the current stamped
  value) valid through the transition; the first cut version under REL-B will be 4-part.

## Implementation Notes (REL-A #873)

- `core/config/config.sh` — `[versioning]="initiative-count"` added to
  `_ZBUILD_BACKEND_DEFAULTS` and `_ZBUILD_BACKEND_ALLOWED` (exact style of the existing
  memory/orchestrator/cache entries).
- `scripts/lib/versioning/initiative-count.sh` — the default strategy: pure
  `compute_version` (validates `A.B` anchor + non-negative `C`/`D`, assembles + re-validates
  `A.B.C.D`, fail-loud) plus the git-gathering `initiative-count_version` wrapper.
- `scripts/lib/version.sh` — `resolve_repo_version` engine seam (backend select →
  source strategy → call `<backend>_version`; fail-loud `backend.missing` on unknown).
- `scripts/zbuild` — the `VERSION`-resolution loop now probes `config/VERSION` **before**
  repo-root `VERSION` and **shape-guards** each candidate (`^[0-9]+(\.[0-9]+){2,3}$`). This
  fixes a real bug: post-install, `$SCRIPT_DIR/../VERSION` == `$ZBUILD_HOME/VERSION`, which
  on a case-insensitive filesystem (macOS default) is the **same inode** as the lowercase
  `version` metadata file — reading it printed `sha=...` as the semver. Reordering plus the
  guard rejects that collision. The guard also admits the 4-part value.
- Tests: `tests/unit/compute-version-test.sh` (pure assembly + fail-loud);
  `tests/unit/versioning-backend-test.sh` (ADR-011 default/override/unknown resolution);
  the `zbuild version` integration test extended to assert a 4-part `VERSION` surfaces.
- Docs: `docs/wiki/Release-Model.md` + the README release section updated from the
  3-part weekly-SemVer description to this 4-part pluggable model.
- The ~65 `0.1.0` occurrences under `tests/`/`config/`/`plugins/` are plugin-**manifest**
  versions, not the CLI version — left untouched.

## References

- [ADR-011](ADR-011-pluggable-backends.md) — backend selection framework.
- [ADR-003](ADR-003-models-as-data.md) — models/schemes are data, not names.
- [ADR-023](ADR-023-install-isolation.md) — single install path; `VERSION` + metadata seam.
- EPIC #872, initiative #1362 — the release track (REL-A..F). #88 — obsolete npm-publish.
