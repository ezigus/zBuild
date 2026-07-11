# router — models as data

In plain terms: zBuild **never hardcodes which AI model to use** in its source code or templates. Instead, you pick a capability tier (like "cheap and fast" or "most capable"), and a config file maps that tier to the actual model. Swapping models — or updating to a new release — is a one-line config change, not a code change.

Model selection is **data, not code**: the router reads `config/models.json`; source never names a model. (ADR-003)

- **Tiers T0–T4:** stable ordinals decouple "which capability level" from "which model this month." Code and templates reference tiers; the config maps tiers to concrete models (with context window, pricing, cache flags, routing weight).
- **Per-stage tier:** a template can pin a stage's tier (and per-stage `timeout_s` / `max_turns` / `retries`).
- **Why:** you can swap or reprice models, or point at a different provider, without touching pipeline logic — and a stray hardcoded model name is caught in review.
- **Outcomes:** routing decisions and results emit `model.route` / `model.outcome` on the [[mechanics/event-bus]].

See [[Configuration]], [[Architecture]].
