<!-- zBuild's own rules for its pipeline stages (scripts/lib/repo-rules.sh).
     Every stage that declares `prompt.repo_rules: true` is given this file.
     Each rule here is enforced by a test; keep them in step with CLAUDE.md. -->
- Bash only, and match the file you are in: 4-space indent, LF line endings, a final newline, no trailing whitespace (.editorconfig). Everything must pass `shellcheck` with the repo's .shellcheckrc.
- Never pipe anything into `grep -q`, and never pipe into a bare `head`, in any `.sh` file, test files included. The reader exits early, the writer takes SIGPIPE, and under `set -o pipefail` the line fails for a reason nothing logs. Use a here-string instead: `grep -q PATTERN <<< "$var"`, or run grep on the file directly: `grep -q PATTERN "$file"`. `tests/unit/sigpipe-antipattern-guard-test.sh` fails the suite on any violation; a genuinely safe pipe is annotated `# sigpipe-ok: <reason>`.
- Never name a model (haiku, sonnet, opus, …) in code; model selection goes through core/router and config/models.json.
- A test must be able to fail: assert what is required, never what the code happens to do.
- Never edit anything under `legacy/`.

## Facts reviewers need
- `ZBUILD_*` environment variables are set by the engine at dispatch (the artifact dir, the stage's input index `ZBUILD_STAGE_INPUTS`, the issue, the run). They are trusted engine inputs, not user or attacker input.
- A stage never builds a path to another stage's output: the engine resolves every input and hands the stage an index (ADR-055 §1). A plugin that derives a path from its state file is a defect.
- Every stage writes a v2 result (`result_contract`, `verdict`, `disposition`, `reason`, detail under `data`) on every exit path, and exits 0 or 1 (ADR-054).
- `[SPEC-n]` / `[#<issue>/SPEC-n]` tags in a test tie an assertion to one issue's acceptance contract. A tag that belongs to another issue must never be changed or removed.
