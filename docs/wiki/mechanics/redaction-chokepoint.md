# redaction chokepoint

**The single path all model-bound text passes through before leaving the machine.** (ADR-004)

- **Invariant:** every prompt sent to a model goes through `core/redaction/apply_scope_redaction`. A plugin that calls a model directly, bypassing this, is a bug.
- **Why:** one auditable place to strip/replace sensitive content and enforce scope, rather than trusting every plugin to remember.
- **Events:** emits `redaction.applied` / `redaction.refused` (and `redaction.refused.overridden`) so redaction is observable in the [[mechanics/event-bus]].
- **Relevance to the vision standard:** the required repo vision (Phase 1.1, #1358) is injected into every stage prompt **through this chokepoint** — no exceptions.

See [[mechanics/scope-governance]], [[Architecture]].
