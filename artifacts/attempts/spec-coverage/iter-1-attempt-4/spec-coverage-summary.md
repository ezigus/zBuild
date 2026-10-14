## spec-coverage — fail

- Three requirements have portions that no SPEC fully covers: R-1 omits the parallel-group-member route and per-backend verification; R-8 omits the fixture-migration check; R-9 omits the installed-tree test constraint.

- NOT COVERED: R-1: "parallel-group member" is absent from SPEC-1's enumerated route list (map, fanout, sequential strategy, cycle member, roleless leaf, always_run), and no SPEC requires that the timeout behaviour is verified under each of the three named backends (bash-parallel, ruflo-hive, mock) — SPEC-1 establishes only that plugin_hook_call is above the backend layer, not that tests exercise each backend
- NOT COVERED: R-8: no SPEC requires that every test which previously used orch-sequential as a fixture now passes on orch-mock or bash-parallel — SPEC-8 covers deletion, the guard, and the misconfigured-config case but is silent on fixture migration
- NOT COVERED: R-9: no SPEC requires the misconfigured-backend test to be run from the installed tree (install.sh layout) — SPEC-9 describes only the runtime behaviour, not the test-execution environment the requirement mandates
