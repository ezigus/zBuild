# scope governance

In plain terms: scope governance is a **fence around the filesystem**. You tell zBuild which files and folders a run is allowed to touch, and it enforces that boundary — so an autonomous pipeline can't accidentally (or maliciously) modify files outside its lane.

Controls **which files a run may read and write**, so autonomous work can't wander outside its lane. (ADR-030)

- **Read/write split:** scope is declared (e.g. `--scope <path>`, repeatable); writes are constrained more tightly than reads.
- **Security floor:** certain paths/patterns are always protected regardless of the requested scope.
- **The test folders (ADR-030 §8, #2508):** the repository's test folders (`config/test-paths.txt`, or a repo's `.zbuild/test-paths.txt`) belong to test-author, which commits every file it changes there. Build may change any file outside them and none inside them: a change it makes there is put back. There is no other write list to widen.
- **Input validation:** scope paths are validated at the CLI boundary (no absolute paths, no `..` traversal).

See [[mechanics/admission-gate]], [[mechanics/redaction-chokepoint]], [[CLI-Reference]].
