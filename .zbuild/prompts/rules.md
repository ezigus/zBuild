<!-- zBuild's own rules for its pipeline stages (scripts/lib/repo-rules.sh).
     Every stage that declares `prompt.repo_rules: true` is given this file.
     Each rule here is enforced by a test; keep them in step with CLAUDE.md. -->
- Bash only, and match the file you are in: 4-space indent, LF line endings, a final newline, no trailing whitespace (.editorconfig). Everything must pass `shellcheck` with the repo's .shellcheckrc.
- Never pipe anything into `grep -q`, and never pipe into a bare `head`, in any `.sh` file, test files included. The reader exits early, the writer takes SIGPIPE, and under `set -o pipefail` the line fails for a reason nothing logs. Use a here-string instead: `grep -q PATTERN <<< "$var"`, or run grep on the file directly: `grep -q PATTERN "$file"`. `tests/unit/sigpipe-antipattern-guard-test.sh` fails the suite on any violation; a genuinely safe pipe is annotated `# sigpipe-ok: <reason>`.
- Never name a model (haiku, sonnet, opus, …) in code; model selection goes through core/router and config/models.json.
- A test must be able to fail: assert what is required, never what the code happens to do.
- Never edit anything under `legacy/`.
