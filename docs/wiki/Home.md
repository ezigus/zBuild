# zBuild

**zBuild is a command-line tool that runs a software task — like fixing a bug or building a feature — through the same repeatable series of steps every time, using AI to do the work at each step.**

You describe what you want (or point zBuild at a GitHub issue), and it plans, writes code, runs tests, reviews the result, and opens a pull request — following a consistent process called a *pipeline*. Because every task goes through the same pipeline, your results stay predictable even as your codebase grows.

## Start here

- **[[Installation]]** — get zBuild onto your machine in a few minutes.
- **[[Getting-Started]]** — run your first pipeline, step by step.
- **[[Configuration]]** — choose AI models, pick a template, set per-repo options.

## Learn how it works

- **[[Pipeline-and-Stages]]** — what happens at each step: planning, building, testing, reviewing.
- **[[CLI-Reference]]** — every command, flag, exit code, and environment variable.
- **[[Architecture]]** — how the engine, plugins, and events fit together.

## Reference

- **[[Plugins]]** — one page per plugin (a plugin handles one step of the pipeline).
- **[[Mechanics]]** — one page per operator and cross-cutting behaviour.

## Extend and operate

- **[[Writing-Plugins]]** — how to add your own step to the pipeline.
- **[[Troubleshooting]]** — exit codes, event logs, resuming interrupted runs.
- **[[Release-Model]]** — versioning and the release cadence.

## Roadmap

Work is organized into **initiatives** (GitHub [milestones](https://github.com/ezigus/zBuild/milestones)) and tracked on the **[zBuild Roadmap project](https://github.com/users/ezigus/projects/2)**. See [[Release-Model]] for the versioning and release cadence.
