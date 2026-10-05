# finding-answers

In plain terms: every step that does work answers every problem the checks raised — "I fixed it, here's what I changed" or "nothing for me to do here, because…". The pipeline never decides whose problem it is; it just counts the answers.

Every stage answers every finding it receives, and loops count the answers. (ADR-068)

- **What it does:** each check lists its findings as numbered items (`acceptance-gate finding 2`). Every stage that calls a model answers each one with `done — what it changed` or `nothing to do — why`. Only the stage that opened a finding can close it, with `satisfied`.
- **Counting, not routing:** a loop with `unowned: yield` ends early when every member that answers findings said `nothing to do` to the same one, and the outer loop goes round from the top. A loop with `unowned: halt` stops the run when the next part disclaims it too, and writes `artifacts/unowned-findings.md`.
- **Canonical example:** in `simple.yaml`, `delivery_loop` holds `design_verify_cycle` and `build_test_cycle`. A WIRING choice only design can fix is disclaimed by test-author and build, so the build loop yields and design gets it with a fresh round count.
- **No backward jumps:** this replaces `route_back` and fault classes (ADR-045 and ADR-061, both superseded).

See [[mechanics/cycle]], [[mechanics/convergence]].
