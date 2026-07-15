# deploy

The deploy plugin is the pipeline's deployment agent — it guards the release side-effect behind a gate verdict check and refuses to trigger a deployment unless the gate-aggregator has explicitly passed. Once cleared, it delegates the actual git-tag and GitHub release creation to the `deploy-release` tool plugin. Use it as the `deploy` stage in any pipeline template that needs a controlled, fail-closed release step.

## How to use

Add `deploy` as a stage in your pipeline template's `flow:` block. It expects `pr` (which produces `pr-url.txt`) and `gate-aggregator` to run before it:

```yaml
flow:
  - stage: deploy
    plugin: deploy
```

To skip the release side-effect during testing, set `ZBUILD_DRY_RUN=1` before running the pipeline. The plugin writes a `deploy-result.json` with `"mode":"dry_run"` instead of executing the release:

```bash
ZBUILD_DRY_RUN=1 zbuild pipeline start --issue 42
```

## Reference

**Kind:** `agent`  
**Version:** `0.1.0`  
**Tier default:** T2  
**Role:** `deploy_agent`  
**Manifest:** `plugins/agent/deploy/manifest.yaml`

### Hooks

| Hook | Function |
|------|----------|
| `init` | `deploy_agent_init` |
| `run` | `deploy_agent_run` |
| `finalize` | `deploy_agent_finalize` |
| `cleanup` | `deploy_agent_cleanup` |

### Requires

| Dependency | Items |
|-----------|-------|
| `core` | `redaction`, `event-bus`, `state` |
| `plugins` | _(none)_ |

### Inputs

| ID | Type | Path | Source | Required |
|----|------|------|--------|----------|
| `pr_url` | file | `${artifact_dir}/pr-url.txt` | `stage:pr` | yes |
| `gate_aggregator_result` | file | `${artifact_dir}/gate-aggregator-result.json` | `stage:gate-aggregator` | yes |

### Outputs

| ID | Path | Type | Primary |
|----|------|------|---------|
| `deploy_result` | `${artifact_dir}/deploy-result.json` | `deploy-result.json` | yes |

The output artifact carries a `verdict` field: `deployed` on success, `skipped` when the gate did not pass, or `error` on failure.

## Advanced

_Newcomers can skip this section._

**Fail-closed gate allowlist (ADR-013, issue #757).** The gate-aggregator verdict is checked with an explicit allowlist: the deploy side-effect runs only when `verdict == "pass"`. Any other value — `fail`, a routing verdict such as `route_design`, an empty string, or a JSON parse error — causes the plugin to write `verdict:"skipped"` to the output artifact and return without releasing. A denylist (skip only on `fail`) was rejected because it would silently allow routing verdicts or a malformed gate result through.

**Dry-run mode.** When `ZBUILD_DRY_RUN=1`, the gate guard is bypassed entirely and the plugin writes a sentinel `deploy-result.json` with `"mode":"dry_run"`. This lets pipelines validate stage wiring without executing the release side-effect.

**Delegation pattern (ADR-018 Pattern 1, ADR-013).** Deploy is implemented as `kind:agent` for guard/orchestration parity with the `pr-delivery → pr-open` delegation pattern. The actual release work — `git tag` and `gh release create` — is performed by the `deploy-release` tool plugin at `plugins/tool/deploy-release/plugin.sh`. The deploy agent itself makes no LLM calls (`route_to_model` is absent by design); it exists solely to enforce the gate check and hand off to the tool.

**Input wiring (issue #1328).** The `gate_aggregator_result` input is declared `required: true` in the manifest, but upstream wiring is tracked under issue #1328. Until that wiring is complete, the plugin enforces gate-result presence at runtime inside `_deploy_agent_run_inner` rather than relying on the dispatcher to reject a missing input.

**Legacy reference.** This plugin migrates `stage_deploy` from `legacy/pipeline-stages-delivery.sh:950`.

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, [[Writing-Plugins]] for the plugin contract, and [[deploy-release]] for the tool delegate that executes the git-tag and GitHub release._
