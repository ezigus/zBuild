# memory-sqlite

**SQLite Memory Backend**

- **Kind:** `tool`
- **Role:** `memory-backend`
- **Manifest:** `plugins/tool/memory-sqlite/manifest.yaml`

## Manifest

```yaml
id: memory-sqlite
name: SQLite Memory Backend
kind: tool
version: 0.0.1
provides:
  role: memory-backend
  alias: sqlite
  capabilities: [text_search, namespacing, persistence]
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
