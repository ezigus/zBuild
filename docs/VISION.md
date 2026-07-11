# zBuild — Vision

> The North Star for zBuild. The README distills it; the wiki references it; every pipeline run is steered by it.
> This document is also the first instance conforming to the zBuild vision-document standard (short, Intent + Principles required).

## Intent
zBuild gives any individual or team a **flexible way to create consistent structure in how they build software**. You encode your process once as a template, then run every repository and every change through that same template the same way each time — and the implementation grows steadily more consistent. Flexibility exists to serve consistency: the engine is small and everything is plugin-delivered and template-composed, so you adapt zBuild to your workflow rather than bending your workflow to a tool.

## Principles
- **Consistency through repetition** — the same template, run the same way, every time. Consistency is the goal; every feature serves it.
- **Flexible by composition** — behavior is plugin-delivered and template-composed; run the full delivery pipeline or any subset you compose.
- **Safety is non-negotiable** — all model-bound text passes through one redaction chokepoint; state is atomic and resumable; scope is governed.
- **Models are data, not code** — routing is tiered and configured, never hardcoded to a model name.
- **Autonomy with guardrails** — bounded cycles, gates, and recovery drive work toward done without silent failure.
- **Intent leads** — every run is steered by this vision; stage prompts follow it as much as possible.

## Consistency anchors
- One template per workflow; changes flow through it unchanged run-to-run.
- Pipeline shape and gate semantics stay stable unless deliberately revised.
- Documentation, versioning, and release cadence follow published standards.
