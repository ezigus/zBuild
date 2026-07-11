# zBuild

**A flexible, plugin-based engine for composing AI delivery pipelines.** You encode your process once as a template, then run every repository and every change through that same template the same way each time — and the implementation grows steadily more consistent. Flexibility serves consistency. (See [`docs/VISION.md`](https://github.com/ezigus/zBuild/blob/main/docs/VISION.md).)

## Start here
- **[[Installation]]** — prerequisites and `./install.sh`.
- **[[Getting-Started]]** — your first dry run, then a real run.
- **[[Configuration]]** — models, templates, per-repo overrides.

## Understand it
- **[[Pipeline-and-Stages]]** — how a template runs: operators, cycles, gates, state.
- **[[CLI-Reference]]** — every command, flag, exit code, and environment variable.
- **[[Architecture]]** — system view and the plugin contract.

## Reference
- **[[Plugins]]** — a page for every leaf node (plugin), generated from its manifest.
- **[[Mechanics]]** — a page for every operator and cross-cutting mechanic.

## Extend & operate
- **[[Writing-Plugins]]** — the manifest contract and hook lifecycle.
- **[[Troubleshooting]]** — exit codes, event logs, resuming runs.
- **[[Release-Model]]** — versioning and the release cadence.
