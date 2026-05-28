# ADR-010: CI / CLI Parity

**Status:** Accepted
**Date:** 2026-05-24

> **Memory split:** This ADR covers the **transport** for pipeline-resume memory
> across CI runs. The state itself (which stage failed, which iteration was
> active, etc.) is defined in [ADR-006](ADR-006-resume-contract.md). The cache
> backend here is how that state moves between an ephemeral CI runner and the
> next run.
>
> Learning memory (patterns, embeddings) is a **different memory model** —
> see [ADR-011](ADR-011-pluggable-backends.md). Learning memory may ride
> through the same cache backend or use its own (e.g., ruflo's remote MCP);
> it's a backend choice, not a CI/CLI lifecycle choice.

## Context

zBuild must run identically from a developer laptop and from GitHub Actions, regardless of the target repo's platform (Node, iOS, TypeScript, Python, etc.). Same command, same flags, same output. The only differences should be in **setup** (CI starts cold every run; the laptop has persistent state) and **teardown** (CI uploads artifacts to durable storage; laptop just persists locally).

Shipwright's legacy CI workflow (`legacy/.github/workflows/shipwright-pipeline.yml`) did this well — extensive setup to rehydrate state, run, then teardown to preserve learnings. We adopt the pattern explicitly so it's not improvised per workflow.

The user requirement: "same command behaves the same in both contexts" with platform-awareness driven by detection (ADR-009), not by hardcoded CI logic.

## Decision

Three mechanisms:

### 1. `zbuild bootstrap` and `zbuild teardown` commands

The pipeline lifecycle in CI is always:

```bash
zbuild bootstrap   # rehydrate state, verify auth, validate plugin lockfile
zbuild pipeline start --issue $ISSUE
zbuild teardown    # persist state, upload artifacts, summarize to PR
```

Locally, `bootstrap` is a no-op (state is already persistent in `~/.zbuild/`); `teardown` is a no-op too (state persists in place). In CI, both do real work.

**Bootstrap responsibilities:**
- Validate prereqs (bash 5, gh, jq, claude CLI).
- Restore state from cache (AgentDB, ruflo namespaces, plugin lockfile) into `~/.zbuild/`.
- Validate plugin lockfile against discovered plugins; warn on mismatch.
- Verify auth (gh token works, ANTHROPIC_API_KEY set).

**Teardown responsibilities:**
- Snapshot state from `~/.zbuild/` to cache.
- Upload artifacts (`state/artifacts/*`, `state/events.jsonl`) as GH Actions artifacts.
- Render summary to `$GITHUB_STEP_SUMMARY` (markdown) when running in Actions.
- Post or update the PR comment marker (uses live-comment marker from KEEPERS §E).

### 2. State-cache subsystem (durable across runs)

Pluggable cache backends (similar to ADR-011 backend pattern):

| Backend | Where state lives | Use |
|---|---|---|
| `local` (default) | `~/.zbuild/state/` | laptop |
| `gh-actions-cache` | `actions/cache@v4` keyed on repo+branch | GH Actions |
| `s3` | configurable bucket | self-hosted runners |
| `gist` | private gist (read-only fallback) | minimal setup |

`zbuild bootstrap` reads `.zbuild/cache.yaml` (or env var) to pick a backend; falls back to `local` if none configured. Cache content: `~/.zbuild/state/{agentdb.sqlite, ruflo-namespaces/, plugins.lock, events.jsonl-archive}`.

### 3. Output destination abstraction

Output goes through a `kind: tool` plugin (`output-destinations/`) that adapts to context:

| Destination | When | Adapter |
|---|---|---|
| `stdout` | always (terminal + CI logs both see it) | none — direct echo |
| `state/report-<run_id>.md` | always | local file write |
| `gh-pr-comment` | when `ZBUILD_ISSUE` is a PR number AND running in CI | uses `pipeline-github.sh:97-135` marker |
| `gh-check-run` | when in Actions and `ZBUILD_EMIT_CHECK_RUN=true` | `gh api` checks endpoint |
| `step-summary` | when `$GITHUB_STEP_SUMMARY` set | appends markdown |

The output stage (MVP-5 / #87) dispatches to whichever destinations are configured. Same plugin code; destinations are config.

### Workflow conventions

The reusable workflow (CI-1 / #91) embeds the bootstrap/teardown pattern:

```yaml
jobs:
  zbuild:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: ezigus/zBuild/.github/actions/bootstrap@v1
        with:
          cache-backend: gh-actions-cache
      - run: zbuild pipeline start --issue ${{ inputs.issue }}
      - uses: ezigus/zBuild/.github/actions/teardown@v1
        if: always()
```

Two reusable composite actions (`bootstrap` and `teardown`) ship with zBuild so consumer workflows don't reimplement them.

### Platform agnosticism

The CI workflow does NOT inspect the target repo for platform; that's the detection subsystem's job (ADR-009 / plat-4). Same workflow YAML works for a Node repo, an iOS repo, a Python repo. Bootstrap installs the same dependencies; detection determines which plugins run.

This is the property the user asked for: "consistent regardless of underlying repository."

## Consequences

**Good:**
- One workflow YAML works across all platforms.
- State survives CI runs (no relearning every time).
- Local and CI behavior are explicitly identical, not coincidentally similar.
- Output destinations are configurable; same plugin code, different sinks.
- The bootstrap/teardown contract makes failure modes visible (auth errors loud at bootstrap, not at first LLM call).

**Bad:**
- Two new commands to document (`bootstrap`, `teardown`).
- Cache backend is a new pluggable surface — more contracts to maintain.
- GH Actions cache has size limits (10GB total per repo, 5GB per item); some users may hit them with large AgentDB stores.

## Implementation Notes (Phase 0.5 — issue #291)

| Item | Status | PR / Notes |
|------|--------|------------|
| Parity test (`tests/e2e/parity-local-vs-ci-test.sh`) diffing state, artifacts, event sequence | Implemented | #306 (ADR-010 parity depth); golden + sha256 + event-type sequence |
| `bootstrap` / `teardown` commands in CLI | Deferred → Phase 1 | not yet needed for single-machine Phase 0.5; includes plugin `init`/`cleanup` hook coordination at CI boundary (see ADR-001 §Open questions and [PHASE-DEFERRALS.md](PHASE-DEFERRALS.md)) |
| Pluggable cache backend contract | Deferred → Phase 1 | ADR-011 backends (#211, #215, #217, #219, #221) define the pattern |

## References

- [ADR-009 — Platform-Aware Modularity](ADR-009-platform-aware-modularity.md) — detection drives platform, not the workflow
- [ADR-011 — Pluggable Backends](ADR-011-pluggable-backends.md) — cache + memory + orchestrator all follow same pattern
- `legacy/.github/workflows/shipwright-pipeline.yml` — reference for the setup/teardown shape
