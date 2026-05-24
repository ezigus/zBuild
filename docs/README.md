# zBuild Documentation Index

## Start here

- **[KEEPERS.md](KEEPERS.md)** — what we preserve from shipwright, with audit-verified citations and a 5-test trial per keeper. The spec.
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

## Conventions

- ADRs are numbered sequentially; never renumbered.
- Each ADR has: Status, Context, Decision, Consequences, References.
- New ADRs require Status = "Proposed" initially; promoted to "Accepted" by merge.
- Superseding an ADR: open a new one with Status = "Supersedes ADR-N" and mark ADR-N's Status = "Superseded by ADR-M".
