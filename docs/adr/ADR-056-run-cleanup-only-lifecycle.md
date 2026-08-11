# ADR-056: run+cleanup-only plugin lifecycle

**Status:** Accepted
**Issue:** #1828
**Date:** 2026-08-09

## Context

ADR-001 defined four lifecycle hooks for plugins: `init`, `run`, `finalize`, and `cleanup`.
In practice the engine never dispatches `init` or `finalize` — every call site in
`runner.sh` and `strategies/common.sh` passes `"run"` to `plugin_hook_call`. The hooks
existed in ~30 manifests and ~30 `plugin.sh` files as dead weight: they inflated the
contract surface, misled plugin authors, and produced events (`plugin.init.*`,
`plugin.finalize.*`) only through test-only direct calls that the live path never emits.

A second defect: `plugin_hook_call` returned `0` for an absent optional hook, making an
undeclared `cleanup` indistinguishable from one that ran and succeeded — callers could
not know whether to escalate or skip.

## Decision

### 1. Delete `init` and `finalize`

Strip `init:` and `finalize:` from every plugin manifest, remove the corresponding
functions from every `plugin.sh`, delete the six `plugin.init.*` and `plugin.finalize.*`
event types from `config/event-schema.json`, and drop them from
`_ZBUILD_YAML_PREWARM_KEYS`. All docs and tests that reference them are updated.

### 2. Enforce `run` at registration time with a named failure

`validate_manifest` already rejected a missing `run` hook for agent/tool/orchestrator
kinds, but the error message was generic. The message now names the specific plugin and
hook so failures are immediately actionable:

```
validate_manifest: plugin 'my-plugin' (kind: agent) requires hook 'run'
(declare under hooks: in the manifest)
```

### 3. Record an absent optional hook on the event stream

> **Amended 2026-08-11 (#1823, ADR-054 §4).** As accepted, this section returned exit
> code `3` (`ZBUILD_HOOK_ABSENT=3`) for an absent `cleanup`, justified on the grounds
> that "the sentinel does not collide with plugin exit-code semantics (0=ok,
> 1=recoverable, 2=fatal)" — the ADR-001 rc table that **ADR-054 §4 supersedes**. rc is
> binary everywhere, so the sentinel is removed. The requirement it served is unchanged
> and still met; only the channel changes.

When `plugin_hook_call` is called with `cleanup` and `hooks.cleanup` is absent from the
manifest, emit `plugin.cleanup.absent` and return `0`. The absence is visible in the
event stream, which is where a consumer that needs to tell "skipped" from "ran cleanly"
reads it.

Two channels carrying one fact is the defect ADR-054 exists to end, and between the
two, the rc is the one nothing can enforce — no engine code ever compared against the
`3`. The event was always the load-bearing half: #1828's acceptance asked that an absent
hook be "distinguishable in the engine's **records** from a hook that ran and returned
0", and the event satisfies that on its own.

Consumers: #1829 (teardown dispatch) and #1830 (the teardown stage) read
`plugin.cleanup.absent`. Neither issue asks for an exit code — both state the
requirement as recording the absence.

## Lifecycle after this ADR

| Hook | Required? | Absent behavior |
|------|-----------|-----------------|
| `run` | Yes (agent, tool, orchestrator) | `plugin.run.refused` emitted; rc=1 |
| `cleanup` | No (all kinds) | `plugin.cleanup.absent` emitted; rc=0 (amended #1823) |

`init` and `finalize` no longer exist in the contract.

## Resume contract

The `init` hook previously reconstructed state on resume. That responsibility moves into
the `run` hook's preamble: plugins that need to recover state on resume check
`ZBUILD_RESUMING=1` at the top of their `run` function and read from `state_file`.
See `docs/RESUME-CONTRACT.md` for the updated pattern.

## Consequences

- Plugin authors implement fewer hooks (run + optional cleanup).
- Orchestrators distinguish "cleanup skipped" from "cleanup ran cleanly" by reading
  `plugin.cleanup.absent`. (As accepted this said the rc=3 sentinel let them do it
  "without parsing events"; #1823 removed the sentinel — see the amendment in §3.)
- All six `plugin.{init,finalize}.{start,complete,error}` event types are removed from
  the schema; any downstream consumer that filtered on them receives nothing.
- Tests that called `_init` / `_finalize` functions directly are removed.

## Implementation Notes (Phase 0/D1 — issue #1828)

- `core/plugin-registry/lifecycle.sh` — `plugin_hook_call` branches on the hook name
  when `hooks.<name>` is undeclared: `cleanup` emits `plugin.cleanup.absent` and returns
  0, anything else emits `plugin.<hook>.refused` and returns 1. (As accepted this
  returned `ZBUILD_HOOK_ABSENT=3`; the constant was deleted by #1823 — see §3.)
- `core/plugin-registry/manifest-validation.sh` — the missing-required-hook error names
  the plugin id; `_ZBUILD_YAML_PREWARM_KEYS` drops `hooks.init` / `hooks.finalize`.
- `config/event-schema.json` — the six `plugin.{init,finalize}.*` types are gone;
  `plugin.cleanup.absent` and `plugin.run.refused` are added.
- Guard: `tests/unit/plugin-hook-contract-test.sh` greps every `plugins/**/manifest.yaml`
  for `init:` / `finalize:` and fails on any hit, so the pair cannot come back.
- The ~20 orphaned `cleanup` implementations are **not** touched here — #E1 gives them a
  caller, and deleting them now would delete the thing that issue is about to wire up.
