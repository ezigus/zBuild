# ADR: Unix Socket Bridge as the Bash-to-Ruflo Transport

- **Status:** Accepted
- **Date:** 2026-05-03
- **Deciders:** Shipwright maintainers
- **Issue:** #501 (this ADR) — under parent #449 ([Ruflo MCP 1.0])
- **Implementation:** #500 ([Ruflo MCP 1.1] bridge + wrapper, merged in 3ed61d1)
- **Consumers:** #502 (lifecycle wiring), #503 (caller migration), #504 (additional tools)

## Decision

Use a persistent unix-socket bridge — `scripts/lib/ruflo-bridge.mjs` — as the
sole transport between Shipwright bash code and the `ruflo` MCP runtime.

The bridge is a long-lived Node ESM process that listens on
`$HOME/.shipwright/ruflo-bridge.sock` for newline-delimited JSON requests and
dispatches them to ruflo via in-process `import('ruflo')` (preferred, ~2 ms)
or via `execFileSync(ruflo, ['mcp','exec',...])` as a warm fallback (~50 ms).
Bash callers reach it through `ruflo_mcp_call` in
`scripts/lib/ruflo-mcp-call.sh`, which uses `nc -U` for framing.

The full interface contract — socket path, env vars, wire format, supported
tools, error codes, latency profile, lifecycle, versioning — is defined in
[`docs/ruflo-mcp-transport.md`](../ruflo-mcp-transport.md) (produced by
#500). This ADR records *why* that contract exists; it does not duplicate it.

## Context

Each pipeline stage that touches ruflo (memory store, search, ping) was
shelling out to the `ruflo` binary directly. Cold-starting Node + loading the
ruflo module costs 200–500 ms per invocation. Across the 12-stage pipeline
this manifested as multi-second synchronous latency and as
`⚠ Ruflo command failed (attempt N/5)` lines in `context-bundle.md` when
back-to-back calls collided with a slow startup.

The transport boundary needed to be:

1. Local-only (single-tenant per pipeline, no network exposure).
2. Bidirectional and framed (request → response, no interleaving).
3. Reachable from bash 3.2 without compiling a new binary.
4. Sub-10 ms warm-path latency.
5. Crash-recoverable (stale endpoint must not block the next run).

## Alternatives Evaluated

| Option | Verdict | Reason |
|--------|---------|--------|
| `ruflo mcp exec` per call (status quo) | Ruled out | Spawns a new Node process per call (~200–500 ms cold, ~30 ms warm cache); doesn't eliminate subprocess overhead and was the source of the original timeout pattern. |
| HTTP transport (`ruflo mcp serve -t http`) | Ruled out | The flag is documented in `--help` but is a no-op upstream — the server always starts in stdio mode. Confirmed in #449 investigation. |
| Named pipes / FIFOs | Ruled out | Single shared FIFO can't isolate concurrent callers — responses interleave. Per-caller FIFO pairs reintroduce the same lifecycle problem this ADR solves. |
| gRPC server | Ruled out | Wrong scale for three tools (`memory_store`, `memory_search`, `ping`); adds protobuf toolchain to a bash + Node repo. |
| Compiled Rust/Go shim | Ruled out | Introduces a binary build artifact and per-platform distribution into a bash + Node repo; complicates `homebrew/`, `install.sh`, and `shipwright doctor`. |
| Standalone MCP daemon (separate process tree) | Superseded | A bridge co-hosted with the pipeline is simpler — no separate daemon registry, no orphan-process detection, no cross-pipeline contention. |
| `sw-daemon` co-host | Superseded | The pipeline already runs `ruflo_init` at startup; the bridge starts there naturally without coupling to the optional `sw-daemon` lifecycle. |

## Rationale

A unix domain socket is the only option that satisfies all five constraints:

- **Bidirectional + framed**: native socket I/O, one connection per request,
  no interleaving risk.
- **Local-only ACL**: filesystem permission bits on the socket file are the
  authentication model — no tokens, no TLS, no port choice.
- **Trivial bash client**: `nc -U "$SOCK"` is universally available on macOS
  and Linux; no new dependency beyond `nc` and `jq` (already required).
- **Sub-millisecond kernel latency**: warm in-process dispatch is ~2 ms
  end-to-end, ~100× better than the prior cold-start path.
- **Crash recovery is one `unlink()`**: the bridge unlinks any stale socket
  before `listen()`, so a hard kill on a prior pipeline never blocks the next.

The transport boundary is also intentionally narrow. The bridge owns only
request dispatch — it does not cache results, schedule retries, batch calls,
or persist state. Those concerns stay with the caller, which keeps the wire
format stable and the upgrade path open (see below).

## Consequences

**Positive**

- Warm-path ruflo calls drop from 200–500 ms to ~2 ms.
- The `⚠ Ruflo command failed (attempt N/5)` pattern is eliminated for any
  caller migrated to `ruflo_mcp_call` (migration tracked in #503).
- The transport contract is a single document and a single bash function;
  future MCP tools added in #504 only need to register a tool name.
- Fail-open semantics on `ruflo_bridge_available` mean call sites can adopt
  the bridge incrementally — a missing socket falls through to the legacy
  `ruflo` subprocess path defined in `scripts/lib/ruflo-adapter.sh`.

**Negative / accepted trade-offs**

- One additional long-lived process per pipeline run (Node, ~30 MB RSS).
  Acceptable: the daemon already runs Node-based tooling.
- Adds `nc` to the hard dependency list for the wrapper (already present on
  every supported platform; checked by `shipwright doctor`).
- Wire format is now a versioned contract — breaking changes require a
  major bump and a one-minor-cycle dual-support window
  (see [transport doc §9](../ruflo-mcp-transport.md#9-lifecycle--versioning)).

**Out of scope for this decision**

- Lifecycle wiring (`_ruflo_bridge_start` from `ruflo_init`,
  `_ruflo_bridge_stop` from `ruflo_cleanup`) — tracked in #502.
- Migration of existing callers off the legacy `ruflo` subprocess path —
  tracked in #503.
- Authentication beyond filesystem permissions — defer until ruflo grows a
  multi-tenant model.
- Rate limiting — concurrency is bounded by the calling pipeline's
  `max_parallel`.

## Upgrade Path

The `ruflo_mcp_call` bash function is the only public surface. If
benchmarks from #504 show that `nc -U` framing or in-process dispatch is the
bottleneck, the transport can be swapped without touching call sites:

1. **Drop-in HTTP**: replace the unix socket with a localhost HTTP listener
   if upstream ruflo ever ships a real HTTP transport. The wrapper can
   dispatch via `curl --unix-socket` or `curl http://127.0.0.1:port` behind
   the same function signature.
2. **Warm `execFileSync` only**: if the in-process import becomes
   unmaintainable upstream, the bridge can run subprocess-only. The
   `RUFLO_BIN` env var already exposes this path; the latency degradation
   (~2 ms → ~50 ms) is still well below the 200–500 ms cold-start baseline.
3. **Per-tool sharding**: high-traffic tools could move to a dedicated
   bridge socket without breaking the wire format — `RUFLO_BRIDGE_SOCK` is
   already overridable per call site.

In all three cases the wire format (`{"tool":"...","args":{...}}` →
`{"success":bool,"result":..,"error":..,"code":..}`) remains the contract.

## References

- [`docs/ruflo-mcp-transport.md`](../ruflo-mcp-transport.md) — interface contract (socket path, wire format, tools, env vars, error codes, latency profile, lifecycle, versioning)
- [`scripts/lib/ruflo-bridge.mjs`](../../scripts/lib/ruflo-bridge.mjs) — bridge server
- [`scripts/lib/ruflo-mcp-call.sh`](../../scripts/lib/ruflo-mcp-call.sh) — bash wrapper
- [`scripts/lib/ruflo-adapter.sh`](../../scripts/lib/ruflo-adapter.sh) — legacy subprocess fallback (lifecycle wiring lands in #502)
- Issue #449 — Ruflo MCP 1.0 (parent epic)
- Issue #500 / commit 3ed61d1 — bridge implementation
- Issue #502 — lifecycle wiring (`ruflo_init` / `ruflo_cleanup`)
- Issue #503 — caller migration to `ruflo_mcp_call`
- Issue #504 — additional tools and benchmark suite
