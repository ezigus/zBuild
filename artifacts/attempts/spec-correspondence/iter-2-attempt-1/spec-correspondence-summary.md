## spec-correspondence — partial

- judged 10 SPEC(s): 8 correspond, 2 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-6 partial: the assertion verifies the dated-#1752 line, the lint-failure statement, and both entries under `## Enforced by`, but the clause "every timeout bound in `core/`, `scripts/`, and `plugins/` resolves through `_acceptance_timeout_prefix`" is only tested by bare string presence of `_acceptance_timeout_prefix`, not by the full scoped statement.
- SPEC-9 partial: all five sub-tests call `_acceptance_timeout_prefix` directly with a numeric argument; they test the shared helper works on a gtimeout-only PATH but do not exercise each call site's own wrapping code, so behavior attributable to site-specific logic is not established.

