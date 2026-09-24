## spec-coverage — covered

- SPEC-2, SPEC-5, and SPEC-9 each explicitly enumerate "interrupted with signal-death rc" in their exit-path lists, and SPEC-23, SPEC-24, and SPEC-25 mandate `disposition=unavailable` for each plugin's unknown-outcome signal-death case — the spec-coverage finding misread the SPEC text and the interruption/unavailable requirement is fully covered.

- every requirement the issue states maps to a declared SPEC
