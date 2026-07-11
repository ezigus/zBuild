# scope governance

Controls **which files a run may read and write**, so autonomous work can't wander outside its lane. (ADR-030)

- **Read/write split:** scope is declared (e.g. `--scope <path>`, repeatable); writes are constrained more tightly than reads.
- **Security floor:** certain paths/patterns are always protected regardless of the requested scope.
- **Governed expansion (ADR-030):** when work legitimately needs more scope, expansion is explicit and recorded — build-created collateral is auto-granted under controlled rules rather than silently.
- **Input validation:** scope paths are validated at the CLI boundary (no absolute paths, no `..` traversal).

See [[mechanics/admission-gate]], [[mechanics/redaction-chokepoint]], [[CLI-Reference]].
