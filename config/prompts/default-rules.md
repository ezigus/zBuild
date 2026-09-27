<!-- zBuild's default repository rules: given to every stage that declares
     `prompt.repo_rules: true` when the target repository has no
     .zbuild/prompts/rules.md of its own. Keep it target-agnostic — it is used
     for repositories in any language. See docs/wiki/repo-rules.md. -->
- Write in the language, style and idiom the repository already uses. Match the surrounding code's naming, formatting, indentation and comment density.
- Before writing, read the repository's own contributor guidance if it has any (for example CLAUDE.md, AGENTS.md, CONTRIBUTING.md, .editorconfig, and lint configuration) and follow it.
- Every file you write must pass the repository's own linters and guard tests, test files included.
- Never write secrets, credentials or tokens into any file.
- Do not add a dependency, tool or framework the repository does not already use.
