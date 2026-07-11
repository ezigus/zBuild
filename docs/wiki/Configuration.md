# Configuration

zBuild's behavior is controlled through a combination of JSON config files, YAML templates, per-repo overrides, and environment variables. This page explains what each knob does and how to change it — no prior zBuild experience required.

**What you'll find here:**
- How zBuild picks an AI model (and why you never hard-code a model name)
- What a "template" is, and which one runs by default
- How to customize behavior for a specific repository
- Common environment variables

---

## Models and AI tiers

When zBuild calls an AI model, it never asks for a model by name (like "claude-sonnet-3-5" or "gpt-4o"). Instead, it uses a **tier** — a numbered level (T0 through T4) that represents roughly how capable the model should be for a given task. The actual model name for each tier lives in `config/models.json`.

**Why tiers instead of names?** Model names change frequently. By using stable tier ordinals, you can swap or reprice a model, or point at a different provider, by editing one config file — without touching any code.

Each entry in `config/models.json` declares: `id`, `provider`, `context_window`, input/output and cache pricing, `cache_eligible`, and a routing `weight`.

A template (explained below) can pin a specific tier and per-stage settings like `router.timeout_s`, `router.max_turns`, and `router.retries` for each stage.

See [[mechanics/router-models-as-data]] for the full routing logic.

---

## Templates

A **template** describes the sequence of stages (steps) a pipeline runs through. Think of it as a recipe — it defines what work happens, in what order, using which plugins. Templates are data files, not code, so changing the pipeline shape never requires editing the engine.

Stages are resolved by role first, then by id (see [[Pipeline-and-Stages]]).

**Shipped templates:**

- **`simple`** (default) — `intake → plan → design_verify_cycle → impact → build_test_cycle → review_lenses → review-aggregator → pr`
- **`deployed`** — extends `simple`, adding `deploy → validate → monitor`

You can write your own template by composing stages and [[Mechanics]] operators into a YAML file.

---

## Per-repo overrides (`.zbuild/`)

To customize zBuild for a specific repository, create a `.zbuild/` directory at the root of that repo. Overrides placed here affect only that repo and are never shared globally.

| Path | What it overrides |
|---|---|
| `.zbuild/templates/` | Repo-specific template files (replaces or extends shipped templates; see ADR-016) |
| `.zbuild/prompts/` | Repo-specific prompt overrides (see ADR-032) |
| `.zbuild/platforms.json` | Platform identity and role-based plugin selection (see ADR-009) |

---

## Environment variables

These are the most commonly needed environment variables. Set them in your shell or CI environment before running `zbuild`.

| Variable | Default | Purpose |
|---|---|---|
| `ZBUILD_HOME` | `~/.local/share/zbuild` | Runtime location where zBuild stores state |
| `ZBUILD_INSTALL_DIR` | `~/.local/bin` | Where CLI shims are installed |
| `ZBUILD_MCP_SERVERS` | — | MCP server URLs (newline-delimited); set by `--mcp-server` flags |
| `ZBUILD_MCP_TRANSPORT` | — | MCP transport (`stdio` or `sse`); set by `--mcp-transport` |
| `ZBUILD_MCP_TIMEOUT` | — | MCP timeout in seconds; set by `--mcp-timeout` |
| `ZBUILD_CLAIM_BACKEND` | — | Claim-coordinator backend (e.g. `local-fs` for test/CI) |
| `ZBUILD_CLAIM_STORE` | — | Claim store path (used with `ZBUILD_CLAIM_BACKEND`) |

The `--mcp-*` flags on `pipeline start` export these variables automatically; you only need to set them manually for advanced workflows. See [[CLI-Reference]] for the flags that set these.
