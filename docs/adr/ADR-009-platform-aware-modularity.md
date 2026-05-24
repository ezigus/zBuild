# ADR-009: Platform-Aware Modularity

**Status:** Accepted
**Date:** 2026-05-24

## Context

zBuild's pipelines must adapt to multiple project types — iOS, Node, React, Python, generic — without templates fragmenting per platform and without forcing every plugin to know every platform. The original plan (ADR-001 plugin contract) handled "one plugin = one capability"; that worked for a single-platform world but breaks down for monorepos with both `ios/` and `api/` folders, or when a generic `coder` plugin should defer to a `coder-ios` if one exists.

Three things must work together:

1. **Modularity** — adding a new platform should require zero core code changes. Drop in a manifest, get detection + routing.
2. **Auto-detection** — repo content (Package.swift, package.json, etc.) drives platform selection; manual config overrides where needed.
3. **Fallback chains** — a platform-specialized plugin wins over a generic one; if no specialized version exists, the generic runs (or a clear failure if neither).

A v4 shipwright design (referenced in `~/.claude/plans/i-am-about-to-rustling-book.md`) explored a `role` abstraction parallel to plugins, sectioned prompts per stage, and three orchestration strategies (fanout/composite/sequential). We borrow concepts but adapt the implementation to zBuild's existing plugin contract instead of introducing a parallel "role" layer.

## Decision

Four mechanisms, layered atop the existing plugin contract:

### 1. Manifest fields for platform identity + role

Extend ADR-001's plugin manifest with three optional fields:

```yaml
# plugins/agent/security-lens-ios/manifest.yaml
id: security-lens-ios
name: iOS Security Audit Lens
kind: agent
version: 0.1.0
platform: ios                     # NEW: omit or null = generic fallback

provides:
  artifact_type: findings.json
  role: security-auditor           # NEW: semantic capability templates reference

platform_overrides:                # NEW: per-platform config without forking
  ios:
    max_findings: 25
    tier_default: T2

detect:                            # NEW: declarative detection signals
  signals:
    files:
      - pattern: "Package.swift"
        strength: high
      - pattern: "Podfile"
        strength: medium
    directories:
      - pattern: "ios/"
        strength: high
```

All three are **optional**:
- Plugins without `platform` default to `null` (generic / always-applicable).
- Plugins without `provides.role` are addressed by `id` only (templates can still name them directly).
- Plugins without `detect.signals` aren't part of platform detection (e.g., the generic redaction chokepoint).

### 2. Templates declare roles, not plugin IDs

Templates list semantic roles per stage; the runner resolves to a concrete plugin at dispatch time.

```yaml
# config/templates/standard.yaml
id: standard
name: Standard Pipeline
extends: null                      # Set to another template to inherit + override
defaults:
  strategy: fanout                 # Multi-platform stage behavior

stages:
  - id: intake
    gate: auto
    roles: [intake]
  - id: build
    gate: auto
    roles: [coder]
    strategy: fanout               # Override default per-stage
  - id: test
    gate: auto
    roles: [tester]
  - id: review
    gate: approve
    roles: [reviewer]
  - id: pr
    gate: approve
    roles: [vcs-coordinator]
```

The runner reads `state/platforms.json` (written by the detection subsystem), and for each `role` in a stage, resolves the matching plugin via the fallback chain.

### 3. Resolver: `(role, platform) → plugin` with fallback chain

```bash
resolve_plugin_for_role role platform
  → search plugins where provides.role == role AND platform == <platform>
  → if found: return it
  → else: search plugins where provides.role == role AND platform == null
  → if found: return it (generic fallback)
  → else: emit registry.role-unresolved event; pipeline decides (skip / fail)
```

Tie-breaking when multiple plugins claim the same `(role, platform)`: highest `version` wins; ties resolved alphabetically by `id` with a warning.

### 4. Three multi-platform strategies per stage

When `state/platforms.json` has more than one platform, the stage's `strategy` field decides:

- **`fanout` (default)** — run the role once per detected platform in parallel. Each invocation gets `ZBUILD_PLATFORM=<p>`. Artifacts aggregated by stage end.
- **`composite`** — run the role ONCE with all platforms' context bundled (e.g., a design doc spanning multiple platforms must be coherent).
- **`sequential`** — fanout serialized; halt on first failure if `per_platform_halt_on_fail: true`.

Strategy is template-overridable per stage; default is `fanout`.

### Auto-detection lives in core/, signals in manifests

`core/detect/platforms.sh` is an engine subsystem (not a plugin), invoked before any stage runs. It:

1. Reads `.zbuild/platforms.json` for manual overrides + disabled folders.
2. Globs `plugins/*/*/manifest.yaml`, extracts `detect.signals` from each.
3. Walks the repo, applies signals folder-by-folder.
4. Writes `state/platforms.json` for the runner + downstream plugins to consume.

Conflict resolution: rank by `strength` (high > medium > low); ties → emit `detection.conflict` event + use config override if present, else warn.

Fallback for unknown platforms: warn + skip the folder unless `.zbuild/platforms.json` sets `fallback_platform: <p>`.

### CLI surface

```
zbuild detect platforms [--explain] [--repo <root>]
zbuild pipeline start --platform-override <p>   # force whole-repo single platform
zbuild pipeline start --scope <path>            # restrict run to subset of folders
zbuild pipeline start --strategy <fanout|composite|sequential>   # deferred to wishlist
```

`detect platforms --explain` prints the per-folder resolution decision with the matching signals + source (config / detected / fallback). Critical for debugging "why did this folder get classified as ios?"

### Per-platform cost ceilings (extends ADR-003)

Cost ledger (#28, db-2) tracks per-(stage, platform) spend. `.zbuild/platforms.json` may set per-platform overrides:

```json
{
  "cost_overrides": {
    "ios":  { "max_tokens_per_stage": 200000 },
    "node": { "max_tokens_per_stage": 100000 }
  }
}
```

Ceiling enforcement is per-platform; one platform hitting cap doesn't downgrade others.

## Consequences

**Good:**
- Adding a new platform = drop a manifest with `detect.signals` + optionally specialized plugins. Zero core code changes.
- One `standard.yaml` template works for every platform; monorepos handled by `fanout` strategy.
- Generic plugins keep working as-is (the new fields are all optional).
- Detection is debuggable (`--explain`) and overridable (config + CLI flag).
- Cost ceilings per platform prevent one platform's budget blowout from affecting others.
- Fallback chain (`platform` → `null`) means a partial platform pack still works.

**Bad:**
- ADR-001 manifest schema grows (three optional fields). Manageable; backward-compatible.
- Resolver adds runtime indirection (role → plugin). Logged in events for observability.
- Template schema becomes YAML (legacy is JSON); migration is mechanical.
- Composite strategy is harder to reason about than fanout; default fanout is safer.
- Multi-platform detection requires walking the repo (small cost per pipeline start).

**Open questions deferred:**
- Glob patterns in `.zbuild/platforms.json` paths (literal-prefix only in v1).
- Per-pipeline-run strategy override via CLI (`--strategy` flag wishlist).
- Content-pattern detection signals (file content parsing) deferred to Phase 1+.

## References

- [ADR-001 — Plugin Contract](ADR-001-plugin-contract.md) — manifest schema (extended here)
- [ADR-003 — Models as Data](ADR-003-models-as-data.md) — cost tier model (extended for per-platform ceilings)
- [ADR-006 — Resume Contract](ADR-006-resume-contract.md) — `state/platforms.json` is persisted state
- v4 shipwright design at `~/.claude/plans/i-am-about-to-rustling-book.md` — input but not adopted; v4 had a parallel `role` concept which zBuild absorbed into `provides.role` field instead.
