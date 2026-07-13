# cache-local

The cache-local plugin is the default cache backend, storing run state archives in a local directory without requiring any external services.

**Cache Backend — Local Filesystem**

- **Kind:** `tool`
- **Role:** `cache-backend`
- **Manifest:** `plugins/tool/cache-local/manifest.yaml`

## Manifest

```yaml
id: cache-local
name: Cache Backend — Local Filesystem
kind: tool
version: 0.1.0
description: |
  Default cache backend. Stores state archives under ZBUILD_CACHE_DIR.
  No external dependencies required.
provides:
  role: cache-backend
  alias: local
  capabilities: [local_filesystem, persistent]
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
