# Design checkpoint — issue #1752 — iteration 2 (current)

## Status: Writing revised design.md

## Changes from prior design
- SPEC-8: reframe from "greps files and asserts patterns" (file-content description rejected by design-gate) to behavioral: "conversion-integrity test exits 0 when all five call-site files use helper; exits 1 when any retains inline probe"
- SPEC-6: explicit 6-fact enumeration, no "every timeout bound" over-claim
- SPEC-9: say "inline simulation of each site's bridging pattern" — does not source actual site files
- Scope: added run-mutation-empty-dir-clean-gate-test.sh and run-mutation-stale-anchor-test.sh (build stage needed them)

## SC2034 already fixed in HEAD
run-tests.sh:37 has `export ZBUILD_NEGCTL_KILL_GRACE="$_RT_KILL_GRACE"` — export present.
run-mutation.sh:155 has `export ZBUILD_NEGCTL_KILL_GRACE="${ZBUILD_MUTATION_KILL_GRACE:-10}"` — export present.
Issue-acceptance finding 2 was from before commit 8bd73572; already fixed.

## Legacy failures
security-lens-test.sh and scope-manifest-b1-regression-test.sh fail due to legacy/ exclusion per ADR-059 §2. Pre-existing; cannot be fixed in this PR.
