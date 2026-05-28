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

## Build & Test

```bash
# Install
./install.sh

# Test
npm test           # full bash test suite
npm run test:unit  # unit tests only
npm run lint       # shellcheck + lint
```

- ALWAYS run tests after making code changes.
- CI enforces a **29% statement coverage floor** on `core/` + `scripts/lib/` (issue #372, raised in Wave 4). Target is 70% — will be raised incrementally as test depth improves. If Coverage CI fails, run `bash scripts/check-coverage.sh` locally to see per-file coverage.
- ALWAYS verify the relevant test passes before opening a PR.

## Security rules

- NEVER hardcode API keys, secrets, or credentials in source files.
- NEVER commit `.env` files.
- Validate user input at system boundaries (the CLI, GitHub label parsers, plugin manifests).
- Sanitize file paths to prevent directory traversal.
- All LLM-bound text passes through `core/redaction/apply_scope_redaction` — no exceptions. A plugin that invokes a model directly is a bug.

## Models as data, not strings

- Code never references `haiku`, `sonnet`, `opus`, etc. by name.
- All model selection goes through `core/router` reading `config/models.json`.
- Tier ordinals (T0–T4) are stable; model names change. (See ADR-003.)
