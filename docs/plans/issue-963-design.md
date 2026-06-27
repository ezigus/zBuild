# Issue #963 — self-host contract-reader version split

## Context

zBuild runs from the INSTALLED engine (`$ZBUILD_HOME`, ADR-023). When dogfooding a
change to its OWN engine, the test stage exercises the working tree (new code) but
the contract-READER stages (acceptance-gate, test_assessment, design) source the
acceptance-grammar libs from the installed (OLD) engine. A grammar-extending change
(e.g. #956 `WIRING:`) makes the old reader mis-parse the dogfood's own `design.md`,
deadlocking the run.

## Decision

Add an explicit self-host mode that redirects ONLY the read-only acceptance-grammar
libs to the working tree, via a snapshot so ADR-023 install-tree immutability is
preserved.

- `scripts/lib/plugin-bootstrap.sh` publishes `_ZBUILD_CONTRACT_LIB_DIR`
  (default `<repo_root>/scripts/lib`, override `ZBUILD_CONTRACT_LIB_DIR`).
- The three contract-reader plugins source the grammar libs from that variable.
- `core/pipeline/runner.sh` gains `--self-host` (and `ZBUILD_SELF_HOST=1`): once
  the run's `state_dir` is known, it snapshots the grammar libs ONCE into
  `$state_dir/contract-lib-snapshot/` and exports `ZBUILD_CONTRACT_LIB_DIR` at it.
  Non-self-host runs leave the variable unset (readers source from `$ZBUILD_HOME`).

The snapshot includes `merge-base.sh` because the negctl/reachability libs source it
from their own directory, so the snapshot must be a self-contained source root.

## Acceptance

```acceptance
SPEC-1[change]: bootstrap publishes _ZBUILD_CONTRACT_LIB_DIR defaulting to <root>/scripts/lib (normal case unchanged).
SPEC-2[change]: ZBUILD_CONTRACT_LIB_DIR redirect is honored by contract-reader plugins.
SPEC-3[change]: a working-tree-only acceptance-grammar extension is honored by the gate in the same run.
SPEC-4[change]: contract libs are snapshotted once at run entry; mid-run edits don't mutate the reader.
TESTFILES:
tests/unit/plugin-bootstrap-contract-lib-dir-test.sh
tests/integration/self-host-contract-lib-redirect-test.sh
tests/integration/self-host-snapshot-immutable-test.sh
WIRING:
scripts/lib/plugin-bootstrap.sh
core/pipeline/runner.sh
```
