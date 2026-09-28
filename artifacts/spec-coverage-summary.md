## spec-coverage — uncovered

- Three acceptance checkboxes — interruption exit path, router budgets from manifest, and `primary: true` in manifest — have no covering SPEC; SPEC-3 also contradicts the `rc ∈ {0,1}` requirement by explicitly preserving `rc=10` for the `scope_too_large` path.

- NOT COVERED: interruption exit path (timeout → disposition:interrupted) — no SPEC
- NOT COVERED: router budgets resolve from manifest and template override wins — no SPEC
- NOT COVERED: manifest declares `primary: true` output — no SPEC
- NOT COVERED: `rc ∈ {0,1}` — SPEC-3 keeps `rc=10` for scope_too_large, directly contradicting the requirement
