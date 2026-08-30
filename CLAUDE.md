# Claude Code Instructions for zBuild

## Source of truth

zBuild's architecture and migration plan live in:
- [docs/KEEPERS.md](docs/KEEPERS.md) — what we preserve from legacy and why
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — system view, plugin contract, data flow
- [docs/adr/](docs/adr/) — formal architecture decisions

**If implementation drifts from spec, the spec wins.** PRs cite the relevant ADR or KEEPERS section in the description.

## Behavioral rules

- Do what has been asked; nothing more, nothing less.
- ALWAYS read a file before editing it.
- NEVER create files unless necessary for the task.
- NEVER proactively create documentation files (`*.md`) or READMEs unless explicitly requested.
- NEVER save working files, tests, or scratch markdown to the root folder.
- NEVER commit secrets, credentials, or `.env` files.
- Keep files under 500 lines unless there is a strong reason.

## File organization

- `/core` — engine: safety primitives, plugin registry, event bus, dispatch
- `/plugins` — plugin implementations, one directory per plugin
- `/config` — config files (models.json, event-schema.json)
- `/scripts` — CLI entry + shared libs
- `/tests` — all tests; `/tests/golden` for snapshot diffs
- `/docs` — KEEPERS, ARCHITECTURE, ADRs, plans
- `/legacy` — frozen upstream import; FROZEN, do not run
- `/.github` — workflows, issue templates, `keepers-manifest.yaml`

## Working with `legacy/`

- `legacy/` is a frozen reference copy of shipwright. **DO NOT EDIT files in `legacy/`** except `legacy/.shipwright-disabled` (the sentinel) and `legacy/scripts/sw` (one-line patch documented in ADR-002).
- The only legitimate way to remove `legacy/` content is the pruning protocol: when a keeper passes its 5-test trial, `git rm` the legacy source and write `legacy/migrated/<keeper-id>.md` with date + issue link.
- Never run scripts under `legacy/` directly; the sentinel will refuse to run anyway, but assume daemon-level state pollution risk if you bypass it.

## Migration discipline

- Each keeper from KEEPERS.md gets one issue (template in `.github/issues/keepers-manifest.yaml`).
- Issue PRs include the 5-test trial checklist in the description, marked complete before merge.
- After a keeper merges, the legacy source is removed in the same PR (tombstone added to `legacy/migrated/`).
- Phase milestones gate progression: Phase 1 issues are blocked until Phase 0 ships.
- **Test scope discovery**: before listing test files in scope for any issue that changes pipeline stage counts, template shape, or dispatch units, run `grep -rl <hardcoded-value> tests/` to find every test that pins that value. All matches must be in the issue's scope — a missed file causes build-loop failures that can't be fixed within the plan's scope enforcement.

## Build & Test

```bash
# Install
./install.sh

# Test
npm test           # full bash test suite
npm run test:unit  # unit tests only
npm run lint       # shellcheck + lint
```

- **Write the test first.** Before editing any file under `core/`, `plugins/`, or `scripts/`,
  write (or amend) the test that expresses the required behavior, run it, and confirm it FAILS —
  and fails for the reason you intend, not on a typo or a missing fixture. Only then write the
  implementation. Then re-run and watch it go green.
- **A test written after the implementation asserts what the code does, not what was required.**
  This is not a style preference — it is the defect class that shipped #1919: its test asserted
  the grant was "exactly the repo root + stage scratch", a faithful description of the code, which
  therefore stayed green while every design stage died on a refused write (#1961). Order the work
  so the test cannot be shaped by the implementation.
- **Reverting the implementation afterwards to check the test goes red is NOT test-first.** It
  produces the same two files and a weaker test, because the assertion was still authored while
  looking at the code. Use it to verify an inherited test, never as a substitute for the ordering.
- **State the red step in the PR body**: the assertion, and how it failed before the fix.
- ALWAYS run tests after making code changes.
- CI enforces a **29% statement coverage floor** on `core/` + `scripts/lib/` (issue #372, raised in Wave 4). Target is 70% — will be raised incrementally as test depth improves. If Coverage CI fails, run `bash scripts/check-coverage.sh` locally to see per-file coverage. The denominator counts every in-scope `.sh` file on disk, including ones no test ever sources (#1761) — a new untested file lowers the number rather than being invisible to it.
- ALWAYS verify the relevant test passes before opening a PR.

## Security rules

- NEVER hardcode API keys, secrets, or credentials in source files.
- NEVER commit `.env` files.
- Validate user input at system boundaries (the CLI, GitHub label parsers, plugin manifests).
- Sanitize file paths to prevent directory traversal.
- All LLM-bound text passes through `core/redaction/apply_scope_redaction` — no exceptions. A plugin that invokes a model directly is a bug.

## Code style

- **Function headers**: one-line comment above a function only when the WHY is non-obvious (hidden constraint, workaround, invariant). Never multi-line docstrings. Apply this on touch — no mass backfill.
- **Shellcheck**: `.shellcheckrc` at repo root sets `shell=bash` and disables SC1090/SC1091 (dynamic source paths). Per-file `# shellcheck disable=SCXXXX` is still fine for local suppressions.
- **Editor conventions**: `.editorconfig` at repo root: 4-space indent for `.sh`, 2-space for YAML/JSON, LF line endings, final newline, no trailing whitespace.
- **No SIGPIPE-prone pipes**: never `printf`/`echo "$var" | grep -q`, and no bare `| head`, in `scripts/`, `core/`, or `plugins/`. The reader exits early, the writer takes SIGPIPE, and under `set -euo pipefail` the surrounding function dies for a reason nothing logs. Use a here-string (`grep -q ... <<< "$var"`), or capture in full and trim in bash. `tests/unit/sigpipe-antipattern-guard-test.sh` enforces this; a genuinely safe pipe is annotated `# sigpipe-ok: <reason>`.

## Models as data, not strings

- Code never references `haiku`, `sonnet`, `opus`, etc. by name.
- All model selection goes through `core/router` reading `config/models.json`.
- Tier ordinals (T0–T4) are stable; model names change. (See ADR-003.)
