## spec-coverage — covered

- Every checkbox and behavioral requirement in the issue — v2 result on all exit paths, valid_verdicts, no path construction in code, fail-closed preservation, rc ∈ {0,1}, router budget state, primary output, provides.role, provides.events, cleanup hook, and passing-run correctness — maps to at least one SPEC; the "template override still wins" sub-clause of the router budget checkbox is trivially established by SPEC-20's assertion that the manifest carries no config.router block, leaving the template as the only source.

- every requirement the issue states maps to a declared SPEC
