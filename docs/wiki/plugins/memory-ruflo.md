# memory-ruflo

The memory-ruflo plugin provides a vector memory backend using ruflo's HNSW index, enabling semantic search over stored pipeline context across runs.

**ruflo HNSW Vector Memory Backend**

- **Kind:** `tool`
- **Role:** `memory-backend`
- **Manifest:** `plugins/tool/memory-ruflo/manifest.yaml`

## Manifest

```yaml
id: memory-ruflo
name: ruflo HNSW Vector Memory Backend
kind: tool
version: 0.0.1
provides:
  role: memory-backend
  alias: ruflo
  capabilities: [vector_search, hnsw, namespacing, persistence]
requires:
  bin: [ruflo, jq]
config:
  tier_default: T2
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
