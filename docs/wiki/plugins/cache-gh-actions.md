# cache-gh-actions

The cache-gh-actions plugin provides a cache backend for GitHub Actions environments, using the runner's temporary directory for within-run artifact storage.

**Cache Backend — GitHub Actions (RUNNER_TEMP)**

- **Kind:** `tool`
- **Role:** `cache-backend`
- **Manifest:** `plugins/tool/cache-gh-actions/manifest.yaml`

## Manifest

```yaml
id: cache-gh-actions
name: Cache Backend — GitHub Actions (RUNNER_TEMP)
kind: tool
version: 0.1.0
description: |
  Cache backend for GitHub Actions environments. Uses $RUNNER_TEMP/zbuild-cache/
  as the within-run cache store. Cross-run persistence is handled by the surrounding
  workflow's actions/cache step saving/restoring $RUNNER_TEMP/zbuild-cache/.
  Gracefully degrades to CACHE_MISS when run outside GitHub Actions.
provides:
  role: cache-backend
  alias: gh-actions-cache
  capabilities: [github_actions, runner_temp, cross_job]
requires:
  env: [GITHUB_ACTIONS, RUNNER_TEMP]
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
