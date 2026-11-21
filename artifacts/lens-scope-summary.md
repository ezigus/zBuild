## review-lens-scope — fail

- found: medium: The unit probe of `_ccgl_read_holder` hand-writes the `run-status-comment.txt` fixture instead of calling `rsc_render_header` to generate it, violating CLAUDE.md's rule that data another part of the engine writes must be made with the writer's own code, never by hand. (plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh)

- medium: The unit probe of `_ccgl_read_holder` hand-writes the `run-status-comment.txt` fixture instead of calling `rsc_render_header` to generate it, violating CLAUDE.md's rule that data another part of the engine writes must be made with the writer's own code, never by hand. (plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh)
- score: 8
