---
version: '1.1'
updated: '2026-07-12'
---

# zBuild — Vision

> The North Star for zBuild — it steers how zBuild is built. The README distills it; the wiki references it; every pipeline run is steered by it.

## Intent
zBuild turns a delivery process into data — templates and plugins — so software is built the same disciplined way every time. We build zBuild the way zBuild builds: a minimal core, with all behavior plugin-delivered and template-composed. A good change is small, aligned to the spec, proven by a test, and wired into the live path — never scaffolding that looks finished but does nothing.

## Principles
- **Spec wins over drift** — KEEPERS, ARCHITECTURE, and the ADRs are the source of truth; when code disagrees, the code changes, not the spec.
- **Small engine, behavior at the edges** — keep the core tiny; add capability as plugins composed in templates, never by growing the engine.
- **Safety is structural** — all model-bound text passes one redaction chokepoint; state is atomic and resumable; scope is governed at every boundary.
- **Models are data, not code** — selection flows through the router and config tiers; never hardcode a model name.
- **Prove behavior, then wire it** — every change ships a test that fails without it and connects to the live path; green-but-inert is a defect.
- **Fail closed, never silent** — gates block on real problems and say why; bounded cycles and recovery drive work to done.
- **Dogfood every change** — build zBuild with zBuild; if the pipeline can't ship it, fix the pipeline.
