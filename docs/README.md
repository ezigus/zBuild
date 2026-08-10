# zBuild Documentation Index

## Start here

- **[KEEPERS.md](KEEPERS.md)** — what we preserve from legacy, with audit-verified citations and a 5-test trial per keeper. The spec.
- **[ARCHITECTURE.md](ARCHITECTURE.md)** — system view, plugin contract, data flow, state model, glossary. The system.

## Architecture Decision Records

- **[ADR-001 — Plugin Contract](adr/ADR-001-plugin-contract.md)** — manifest schema, required interfaces per kind, lifecycle ordering, error semantics, lockfile format.
- **[ADR-002 — Legacy Import Strategy](adr/ADR-002-legacy-import-strategy.md)** — plain copy, no history, sentinel-guarded, tombstone-pruned. PROJECT_ROOT collision risk and mitigation.
- **[ADR-003 — Models as Data](adr/ADR-003-models-as-data.md)** — T0–T4 ordinal, models in `config/models.json`, never named in code.
- **[ADR-004 — Redaction Chokepoint](adr/ADR-004-redaction-chokepoint.md)** — single helper, all LLM-bound text passes through it, refuse-to-emit when scope manifest absent.
- **[ADR-005 — Claim Coordinator](adr/ADR-005-claim-coordinator.md)** — modular plugin contract; default `github-labels`, swap to `ttl-leases` later.
- **[ADR-006 — Resume Contract](adr/ADR-006-resume-contract.md)** — explicit persisted vs. reconstructed state lists; plugin responsibilities.
- **[ADR-007 — Test Strategy](adr/ADR-007-test-strategy.md)** — call-and-assert + golden-file diffing; the 5-test trial; the migration matrix.
- **[ADR-008 — Dependency Policy](adr/ADR-008-dependency-policy.md)** — GitHub Actions, Node.js, and npm: Dependabot weekly, quarterly audit, pre-release checklist.
- **[ADR-009 — Platform-Aware Modularity](adr/ADR-009-platform-aware-modularity.md)** — Platform identity in manifest, role-based templates with fallback chain, declarative detection signals, three orchestration strategies (fanout/composite/sequential).
- **[ADR-010 — CI / CLI Parity](adr/ADR-010-ci-cli-parity.md)** — `zbuild bootstrap`/`teardown` lifecycle, state cache backends, output destination abstraction. Same command behaves identically on laptop and in CI regardless of target repo platform.
- **[ADR-011 — Pluggable Backends](adr/ADR-011-pluggable-backends.md)** — Memory, orchestrator, cache backends as plugins. Defaults work with zero external deps; ruflo (HNSW, hive-mind) drops in via config.
- **[ADR-054 — Stage Contract](adr/ADR-054-stage-contract.md)** — active hooks (run, cleanup), hook signature, env-var context, binary rc, disposition vocabulary, fail-closed scanner, per-stage router surface. Amends ADR-001.
- **[ADR-055 — Inter-Stage Data Contract v2](adr/ADR-055-inter-stage-data-contract-v2.md)** — clean v2 of the producer–consumer declaration model, closed templating-var set, external-sources allowlist, cycle_feedback discriminator, output-uniqueness rule, resume-mode artifact-existence check. Supersedes ADR-020.

## Conventions

- ADRs are numbered sequentially; never renumbered.
- Each ADR has: Status, Context, Decision, Consequences, References.
- New ADRs require Status = "Proposed" initially; promoted to "Accepted" by merge.
- Superseding an ADR: open a new one with Status = "Supersedes ADR-N" and mark ADR-N's Status = "Superseded by ADR-M".
