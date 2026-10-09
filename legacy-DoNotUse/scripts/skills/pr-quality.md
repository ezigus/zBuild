## PR Quality: Ship a Reviewable Pull Request

Write a PR that a reviewer can understand in 5 minutes.

### PR Description Structure
1. **What** — One sentence: what does this PR do?
2. **Why** — Link to issue. Why is this change needed?
3. **How** — Brief technical approach (2-3 sentences max)
4. **Testing** — What was tested? How to verify?
5. **Screenshots** — If UI changes, before/after screenshots

### Commit Hygiene
- Each commit should be a logical unit of work
- Commit messages: imperative mood, 50-char subject, blank line, body explains WHY
- No WIP/fixup/squash commits in final PR
- No merge commits — rebase onto base branch
- Separate refactoring commits from feature commits

### Diff Quality
- Remove all debugging artifacts (console.log, print statements, commented-out code)
- No unrelated formatting changes mixed with logic changes
- Generated files should be committed separately or excluded
- File renames should be separate commits (so git tracks them)

### Reviewer Empathy
- If the diff is >500 lines, add a "Review guide" section explaining the reading order
- Call out non-obvious decisions with inline comments
- Flag areas where you're least confident and want careful review
- If you changed a pattern used elsewhere, note whether existing code needs updating

### Self-Review Checklist
Before marking as ready:
- [ ] PR description explains what, why, and how
- [ ] All CI checks pass
- [ ] No secrets, credentials, or API keys in diff
- [ ] No TODO/FIXME comments without issue links
- [ ] Breaking changes documented in description
- [ ] Migration steps documented if applicable

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **PR Description**: What (one sentence), Why (issue link), How (2-3 sentence technical approach), Testing (what was tested)
2. **Commit Hygiene Check**: Verification that each commit is a logical unit, no WIP/fixup/squash, no merge commits
3. **Diff Review**: Confirmation that all debugging artifacts removed (console.log, commented code), no unrelated formatting changes
4. **Self-Review Checklist Completion**: All items from checklist checked (secrets scanned, CI green, breaking changes documented)

If any section is not applicable, explicitly state why it's skipped.
