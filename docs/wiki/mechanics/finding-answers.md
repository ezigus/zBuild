# finding-answers

In plain terms: every check lists the problems it found, and every step after it sees them and says, in its own output, what it did about each one. The pipeline never decides whose problem it is, and it keeps nothing but each step's output.

Every check lists numbered findings, and every later stage sees them. (ADR-068)

- **What it does:** each check lists its findings as numbered items (`acceptance-gate finding 2`) in its result. Later stages see each one on its own line and say in their own result what they did about it, or why there was nothing for them to change.
- **No record beside the outputs:** the engine passes each stage's output forward and keeps nothing else. A check that runs again lists its findings afresh; a finding it does not list again is closed. A loop goes round until its exit condition passes or its rounds run out (ADR-068 §8, amended 2026-10-11).
- **What is still open** when a run ends is read from the checks' latest results ([[mechanics/convergence]]).
- **No backward jumps:** nested loops replace `route_back` and fault classes (ADR-045 and ADR-061, both superseded).

See [[mechanics/cycle]], [[mechanics/convergence]].
