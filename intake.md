ZBUILD_PLATFORM is never changed by loading the shared libraries — it means the target platform only (ADR-009, part 2 of #1700)

## Goal

`ZBUILD_PLATFORM` means one thing only: the **target** platform a work unit builds for. Loading the shared libraries never changes it, and nothing reads the host OS from it. Part 2 of 2: depends on #1700, which moves the host checks off `ZBUILD_PLATFORM` first.

## What is wrong today

- `scripts/lib/compat.sh` sets `ZBUILD_PLATFORM` to the host OS (`macos`/`linux`) when sourced, while `_strategy_make_work_unit` (`core/pipeline/strategies/common.sh`) sets it to the build target.
- `_ZBUILD_COMPAT_LOADED` is not exported, so a child bash process that sources `helpers.sh` overwrites an inherited target with the host value. A child started with `ZBUILD_PLATFORM=ios` sees `macos`.
- Three code comments cite "ADR-009 §6" for the platform contract, a section ADR-009 does not have: in `core/pipeline/strategies/common.sh`, `core/pipeline/strategies/map.sh` and `core/event-bus/event-bus.sh`.

## ADR

- **Amend ADR-009** so it says:
  - `ZBUILD_PLATFORM` is the target platform a work unit builds for, and nothing else. Every strategy that runs a work unit per platform sets it to that platform.
  - Sourcing the shared libraries never changes `ZBUILD_PLATFORM`, and nothing reads the host OS from it.
- ADR-009 is in `config/adr-enforcement-baseline.txt`, so the amendment names its enforcing tests inline.

## Required behavior

Write each as a test first and watch it fail.

- **R1.** A process started with `ZBUILD_PLATFORM=ios` that sources `scripts/lib/helpers.sh` still has `ZBUILD_PLATFORM=ios`.
- **R2.** `compat.sh` does not write `ZBUILD_PLATFORM`. If a host value is needed, it uses `ZBUILD_OS`. Nothing reads `ZBUILD_OS` today, so if it is unneeded it may be dropped.
- **R3.** A guard test fails if any file under `core/`, `plugins/` or `scripts/` reads `ZBUILD_PLATFORM` to make a host decision.
- **R4.** The comments that cite "ADR-009 §6" (`common.sh`, `map.sh`, `event-bus.sh`) say what the contract is (`ZBUILD_PLATFORM` is the target platform) instead of citing a section number.

## Scope

- **Code:** `scripts/lib/compat.sh`; comments only in `core/pipeline/strategies/common.sh`, `core/pipeline/strategies/map.sh`, `core/event-bus/event-bus.sh`.
- **ADR:** `docs/adr/ADR-009-platform-aware-modularity.md`.
- **Tests:**
  - `tests/integration/strategy-platform-env-test.sh`
  - `tests/unit/map-strategy-test.sh` (SPEC-5)
  - `tests/unit/event-bus-emit-cost-test.sh`
  - `tests/integration/map-review-lenses-dispatch-test.sh`

  Run `grep -rlw 'ZBUILD_PLATFORM' tests/` and include every match. Use `-w`: without it the grep also matches `ZBUILD_PLATFORM_OVERRIDE`, a different variable.
- **Out of scope:** an event-schema rule for `ts`. It is already enforced by `event-bus-emit-cost-test.sh` E3.
