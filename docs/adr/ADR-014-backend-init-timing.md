# ADR-014: Backend Contract Init Timing — Eager Auto-Load

**Status:** Accepted
**Date:** 2026-05-28

## Context

ADR-011 introduced three pluggable backend contract layers: `core/cache/contract.sh`, `core/orch/contract.sh`, and `core/memory/contract.sh`. Each provides an interface that is satisfied by a backend plugin sourced at runtime.

After shipping ADR-011, an asymmetry emerged:

- `cache/contract.sh` and `orch/contract.sh` **auto-load** their backend at source time: they define a private `_load_backend` helper and call it at the bottom of the file.
- `memory/contract.sh` uses a **lazy pattern**: the backend is not loaded until an explicit `memory_init` call.

This asymmetry was not a deliberate design choice. It arose because the memory backend was implemented after the cache and orch backends, and the author independently chose the lazy pattern.

## Decision Factors

**Lazy init pros:**
- Deferred init; expensive operations happen at point of use.
- Errors have richer call-stack context (you know what triggered init).
- Callers can configure env vars between source and init.

**Eager init pros:**
- Uniform boot-time failure; all backend problems surface at startup.
- Callers don't track init state; just source and use.
- Symmetric with `cache` and `orch`; lower cognitive load for contributors.

**Mitigating factors specific to this project:**
- `memory_backend_init` in the SQLite backend is cheap (schema creation, idempotent).
- Tests set `ZBUILD_MEMORY_BACKEND` before sourcing the contract file — both patterns work.
- The existing explicit `memory_init()` call in `runner.sh:20` is a one-liner; removing it has minimal benefit.
- Lazy init's "point-of-use error context" advantage is marginal: the backend source is `memory/contract.sh`, which is already known.

## Decision

**Eager auto-load**, matching `cache` and `orch`.

`memory/contract.sh` will call `_memory_load_backend` at file end, mirroring the cache and orch patterns. The public `memory_init` function is retained as an idempotent no-op wrapper so existing callers are not broken. Backend load failures are non-fatal (warn + degrade to uninitialized stubs) so sourcing the contract file never kills a caller.

## Consequences

- All three contract files follow the same pattern: source the file, the backend is ready.
- `runner.sh` `memory_init` call becomes a no-op (idempotent guard). It is kept as documentation of intent.
- Contributors adding a fourth backend contract must use the eager pattern.
- If a backend is slow or fallible, the failure surfaces at startup rather than at first memory use.

## Implementation Notes

`core/memory/contract.sh` was updated to add `_memory_load_backend` as an internal helper (mirroring `_zbuild_cache_load_backend` in cache and `_orch_load_backend` in orch) and to call it at file end. The public `memory_init` function is retained as a thin idempotent wrapper. Failure is non-fatal: the function warns and returns without aborting the caller, consistent with how cache and orch handle missing plugins. The `_ZBUILD_MEMORY_INITIALIZED` flag prevents double-init.
