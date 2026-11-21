## intake — pass

- 9 requirement(s): RQTST-1, RQTST-2, RQTST-3, RQTST-4, RQADR-1, RQADR-2, RQADR-3, RQADR-4, RQADR-5

- RQTST-1: A process started with `ZBUILD_PLATFORM=ios` that sources `scripts/lib/helpers.sh` still has `ZBUILD_PLATFORM=ios`.
- RQTST-2: `compat.sh` does not write `ZBUILD_PLATFORM`. If a host value is needed, it uses `ZBUILD_OS`. Nothing reads `ZBUILD_OS` today, so if it is unneeded it may be dropped.
- RQTST-3: A guard test fails if any file under `core/`, `plugins/` or `scripts/` reads `ZBUILD_PLATFORM` to make a host decision.
- RQTST-4: The comments that cite "ADR-009 §6" in `common.sh`, `map.sh`, and `event-bus.sh` say what the contract is (`ZBUILD_PLATFORM` is the target platform) instead of citing a section number.
- RQADR-1: Amend ADR-009 to state `ZBUILD_PLATFORM` is the target platform a work unit builds for, and nothing else.
- RQADR-2: Amend ADR-009 to state every strategy that runs a work unit per platform sets it to that platform.
- RQADR-3: Amend ADR-009 to state sourcing the shared libraries never changes `ZBUILD_PLATFORM`.
- RQADR-4: Amend ADR-009 to state nothing reads the host OS from `ZBUILD_PLATFORM`.
- RQADR-5: ADR-009 amendment must name its enforcing tests inline.
