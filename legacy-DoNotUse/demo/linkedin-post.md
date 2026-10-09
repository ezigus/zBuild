<!-- LinkedIn Post — copy-paste ready -->

**I built an autonomous dev team out of AI agents. It watches GitHub, picks up issues, and ships PRs — while I sleep.**

Picture this: you label a GitHub issue "ready-to-build." A daemon picks it up, triages it, selects the right pipeline, and spins up Claude Code agents in isolated git worktrees. They plan, build, test, review, and open a PR. If it fails, it retries with a smarter model. If it keeps failing, it remembers why for next time.

That's Shipwright v1.7.0. I open-sourced the full stack.

Here's what it does now:

**Delivery pipeline** — `shipwright pipeline start --issue 42` chains intake, plan, design, build, test, review, and PR into a single command. Self-healing builds: when tests fail, it captures the error and re-enters the build loop automatically.

**Autonomous daemon** — `shipwright daemon start` watches your repo for labeled issues and processes them through the pipeline. Priority lanes let hotfixes jump the queue. Adaptive template selection picks the right pipeline based on issue complexity.

**Fleet operations** — `shipwright fleet start` orchestrates daemons across multiple repos from a single config. One command, entire org.

**Bulk fix** — `shipwright fix "Update lodash" --repos ~/api,~/web,~/mobile` applies the same fix across repos in parallel.

**Persistent memory** — Every pipeline run teaches the system. Failure patterns, root cause analysis, codebase conventions — all injected into future builds so agents don't repeat mistakes.

**Cost intelligence** — Token tracking, daily budgets, model routing. The cost-aware pipeline template uses haiku for simple stages, sonnet for builds, opus only when needed.

**DORA metrics** — Lead time, deploy frequency, change failure rate, MTTR. The daemon can self-optimize its own parameters based on these metrics.

**Deploy adapters** — Vercel, Fly.io, Railway, Docker. `shipwright init --deploy` detects your platform and wires up staging, production, rollback, and health checks.

Plus: 12 team templates, quality gate hooks, continuous loop, layout presets, and a premium dark tmux theme.

My favorite workflow: label issues, go to sleep, wake up to PRs.

Pure bash + jq. No heavy dependencies.

Check it out: https://github.com/sethdford/shipwright
Docs: https://sethdford.github.io/shipwright

What does your autonomous development setup look like?

#ClaudeCode #AIEngineering #DeveloperTools #OpenSource #Anthropic #DevOps #DORA
