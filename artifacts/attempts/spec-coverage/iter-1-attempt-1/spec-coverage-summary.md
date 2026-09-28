## spec-coverage — uncovered

- two acceptance items are directly contradicted by SPECs that preserve exactly what the issue requires removed/normalized, and several requirements have no SPEC at all.

- NOT COVERED: no-path-construction-in-code (SPEC-18 explicitly keeps the hardcoded artifact path literals in plugin.sh, "not deleted")
- NOT COVERED: rc ∈ {0,1} (SPEC-6 lets SIGTERM/SIGINT rc=130 propagate instead of expressing it as a disposition)
- NOT COVERED: mandatory `reason` field in the v2 result (no SPEC requires writing `reason`)
- NOT COVERED: namespaced `data` block folding rendered output (the "Folds in" requirement has no SPEC)
- NOT COVERED: `cleanup`/`release` hook or its recorded absence (#1829, uncovered)
