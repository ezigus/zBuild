# Configuration

## Models (`config/models.json`) — models as data
Model selection goes through the router; **code never names a model** (ADR-003). Models are organized into stable tiers **T0–T4** (by ordinal). Each entry declares `id`, `provider`, `context_window`, input/output and cache pricing, `cache_eligible`, and a routing `weight`.

- Reference tiers (T0–T4), not model names, everywhere.
- Swap or reprice a model, or point at a different provider, by editing config only — no logic changes.
- A template may pin a stage's tier and per-stage `router.timeout_s` / `router.max_turns` / `router.retries`.

See [[mechanics/router-models-as-data]].

## Templates
A template composes stages over the operators in [[Mechanics]]. Shipped templates:
- **`simple`** (default) — `intake → plan → design_verify_cycle → impact → build_test_cycle → review_lenses → review-aggregator → pr`.
- **`deployed`** — `extends: simple`, adding `deploy → validate → monitor`.

Compose your own by writing a template that arranges leaves and operators. Templates are data — a stage is resolved by role-then-id (ADR-042/047), so you don't edit engine code to change the flow. See [[Pipeline-and-Stages]].

## Per-repo overrides (`.zbuild/`)
Drop repo-local overrides in a `.zbuild/` directory in the target repo:
- **`.zbuild/templates/`** — repo-specific template overrides (ADR-016).
- **`.zbuild/prompts/`** — repo-specific prompt overrides (ADR-032).
- **`platforms.json`** — platform identity / role-based selection (ADR-009).

## Environment variables (common)
- `ZBUILD_HOME` — runtime location (default `~/.local/share/zbuild`).
- `ZBUILD_INSTALL_DIR` — where shims are installed (default `~/.local/bin`).
- `ZBUILD_MCP_SERVERS` / `ZBUILD_MCP_TRANSPORT` / `ZBUILD_MCP_TIMEOUT` — set via the `--mcp-*` flags on `pipeline start`.
- `ZBUILD_CLAIM_BACKEND` (+ `ZBUILD_CLAIM_STORE`) — claim-coordinator backend selection (e.g. `local-fs` for test/CI).

See [[CLI-Reference]] for the flags that set these.
