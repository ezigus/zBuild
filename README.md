# zBuild

Plugin-based framework for autonomous AI agent delivery pipelines. Built as a clean rearchitecture of an upstream system (frozen for reference in `legacy/`), redesigned around interchangeable plugins (`kind: agent | tool | recovery | orchestrator | claim-coordinator | daemon`) over a stable stage contract.

**Status:** pre-Phase 1. The architecture is locked; implementation is starting. See:

- [Keepers Spec](docs/KEEPERS.md) — which legacy behaviors we're preserving and why
- [Architecture](docs/ARCHITECTURE.md) — system view, plugin contract, data flow
- [ADRs](docs/adr/) — formal architecture decisions
- [Open issues](https://github.com/ezigus/zBuild/issues) — the work, organized by phase

Implementation is happening in phases (0 → 5) tracked as GitHub milestones. Phase 0 establishes the core engine; subsequent phases migrate behaviors from `legacy/` into plugins.

## License

MIT — see [LICENSE](LICENSE).
