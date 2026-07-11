# admission gate

In plain terms: the admission gate is a **checklist that runs before the pipeline starts**. If anything required is missing or misconfigured, zBuild refuses to begin rather than failing partway through with a confusing error.

**Fail-closed preconditions checked before a run starts.** If the environment or inputs aren't valid, zBuild refuses to run rather than proceeding into a bad state.

- **What it checks:** required tooling/config and run inputs are present and well-formed.
- **Fail-closed:** a failed precondition stops the run with a clear message — never a silent degrade.
- **Coming in Phase 1.1 (#1358/#1360):** the admission gate will also require a conforming **vision document** (fail-closed if missing, malformed, or over the ~300-word cap), with `zbuild vision init` to scaffold one.

See [[mechanics/scope-governance]], [[Troubleshooting]].
