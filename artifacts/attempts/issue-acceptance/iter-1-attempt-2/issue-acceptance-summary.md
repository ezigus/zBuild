## issue-acceptance — fail

- SPEC-2 assigns `disposition=misconfigured` to `invalid_plan_response` instead of the required `unusable`; SPEC-15's manifest is missing `summary: true` on the `plan-summary.md` output entry; SPEC-18's template-over-manifest precedence regresses after the manifest gains explicit budget defaults (guard that passed at merge-base now fails at HEAD).

- NOT MET: all three parse/schema error paths (schema_violation, empty_result_envelope, invalid_plan_response) must produce `disposition=unusable` — invalid_plan_response enters the `router_rc != 0` branch and gets `misconfigured` instead (SPEC-2)
- NOT MET: manifest `plan-summary.md` output entry must declare `summary: true` — the diff adds no such property (SPEC-15)
- NOT MET: template-set `max_turns`/`timeout_s` must beat manifest-declared defaults — adding explicit manifest values broke the resolver's precedence check (SPEC-18)
