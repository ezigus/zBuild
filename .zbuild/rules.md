<!-- zBuild's own rules, beside its vision.md (#2630, ADR-067 §8). Every stage
     is given this file whole, under "From the repo" (load_repo_rules,
     scripts/lib/prompt-overrides.sh), and CLAUDE.md includes it, so the rules
     have one source. It holds only what is true for every stage working on this
     repo; a rule for one kind of work goes in that stage's own text. -->
## Rules
- If the code drifts from the spec, the spec wins: docs/KEEPERS.md, docs/ARCHITECTURE.md and docs/adr/. Every issue cites the ADR and section it implements; when no ADR covers a change, an ADR is written or amended first, and a later decision amends the earlier ADR in the same change.
- Every ADR statement has a test, named in the ADR's Enforced by section; a new or changed statement ships with its test (`scripts/lib/lint-adr-enforced-by.sh`).
- Write the test first: run it and see it fail, for the reason you intend, before the code that makes it pass. A test written after the code asserts what the code does, not what was asked.
- Tests are deterministic. A remote service is faked at the project's own wrapper around it, never the project's own code. Never wait on a clock in a test: no sleep before a check or a signal — wait for a marker the code writes, with a timeout (`scripts/lib/lint-test-determinism.sh`).
- Keep files under 500 lines.
- Process and exec budgets only go down: a change to work zBuild already does never raises what it costs (ADR-065).
- Bash only, and match the file you are in: 4-space indent, LF line endings, a final newline, no trailing whitespace (.editorconfig). Everything must pass `shellcheck` with the repo's .shellcheckrc.
- Never pipe anything into `grep -q`, and never pipe into a bare `head`, in any `.sh` file, test files included. The reader exits early, the writer takes SIGPIPE, and under `set -o pipefail` the line fails for a reason nothing logs. Use a here-string instead: `grep -q PATTERN <<< "$var"`, or run grep on the file directly: `grep -q PATTERN "$file"`. `tests/unit/sigpipe-antipattern-guard-test.sh` fails the suite on any violation; a genuinely safe pipe is annotated `# sigpipe-ok: <reason>`.
- Never name a model (haiku, sonnet, opus, …) in code; model selection goes through core/router and config/models.json.
- A test must be able to fail: assert what is required, never what the code happens to do.
- Never edit anything under `legacy-DoNotUse/`.

## Facts about this repo
- `ZBUILD_*` environment variables are set by the engine at dispatch (the artifact dir, the stage's input index `ZBUILD_STAGE_INPUTS`, the issue, the run). They are trusted engine inputs, not user or attacker input.
- A stage never names another stage's output — not its output name, not its file. The engine hands every stage every earlier stage's latest output, and a stage finds what it needs by what it contains (scripts/lib/earlier-output.sh; ADR-055 §1). A plugin that names another stage's output is a defect.
- Every stage writes a v2 result (`result_contract`, `verdict`, `disposition`, `reason`, detail under `data`) on every exit path, and exits 0 or 1 (ADR-054).
- `[SPEC-n]` / `[#<issue>/SPEC-n]` tags in a test tie an assertion to one issue's acceptance contract. A tag that belongs to another issue must never be changed or removed.
