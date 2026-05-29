# ADR-015: Stage I/O Capture Chokepoint

**Status:** Proposed
**Date:** 2026-05-29

## Context

zBuild pipeline stages perform observable *work*: agent stages send a prompt
to an LLM and receive a response (plan, build, review, security-lens);
deterministic stages run external commands and inspect their output
(intake's `gh issue view`, build's `git apply`, a future test-runner's
`pytest`, deploy's API calls). Today none of that work is preserved in a
form an operator can review after the fact.

What exists today:

- `core/output/destinations.sh` (issues #213, #238) defines an end-of-pipeline
  destination abstraction with toggles `ZBUILD_OUTPUT_STDOUT`,
  `ZBUILD_OUTPUT_LOCAL_REPORT`, `ZBUILD_OUTPUT_GH_COMMENT`,
  `ZBUILD_OUTPUT_GH_CHECK_RUN`, `ZBUILD_OUTPUT_STEP_SUMMARY`. It is **only**
  used by the final summary; stages do not feed it.
- The router (`core/router/route.sh`) holds `raw_response` in a local
  variable and discards it after parsing. The plan plugin
  (`plugins/agent/plan/plugin.sh`) persists `plan-prompt.redacted.txt` (the
  post-redaction prompt) and `plan.json` (the parsed JSON) — but no plain
  text of the raw response, and no equivalent artifact for any other stage.
- The event bus emits `model.route` and `model.outcome` events carrying
  metadata (tier, model_id, token counts) but not prompt or response content.

What's missing — and what this ADR addresses — is a uniform, per-stage,
operator-visible record of *what the stage did* and *what came back*.
Concretely:

- An agent stage's prompt and the LLM's raw response.
- A command stage's argv, stdout, stderr, and exit code.
- A computed stage's source artifact path and produced artifact path.

…written to the operator's choice of destinations (file, stdout, GitHub
issue comment), configured per-stage in the pipeline template, with no
output by default so private repo content and PII don't leak from a
forgotten flag.

This ADR mirrors the shape of ADR-004 (redaction chokepoint): the prior
work had nine ad-hoc redaction call sites, and ADR-004 imposed one
chokepoint helper to make the safety property checkable. The same problem
will recur for capture if every stage rolls its own write — divergent
record shapes, inconsistent redaction posture, no single place to gate
behavior. We adopt the same chokepoint pattern up front.

## Decision Factors

**One chokepoint vs. per-plugin capture:**

- Per-plugin capture: each plugin writes its own record format and decides
  its own destinations. Lower coupling per plugin but contract drift across
  stages and no single place to enforce redaction-outbound. Rejected.
- One chokepoint helper: a single `capture_stage_io` function in
  `core/output/stage-io.sh` that every capture site calls. Parallels ADR-004.
  Accepted.

**Config in env vars vs. config in templates:**

- Env vars (the existing `ZBUILD_OUTPUT_*` pattern): familiar but operator
  must remember to set them, and the same set applies to every stage. No
  per-stage control. Rejected for v1.
- Per-stage block in the pipeline template: lives next to `gate`, `roles`,
  and the rest of stage metadata; observability is part of stage
  orchestration; per-stage tuning becomes one-line. Accepted.

**Opt-in vs. opt-out:**

- Opt-out (everything captured by default): risks leaking private content
  to a `gh comment` destination the operator didn't realize was on.
  Rejected.
- Opt-in (absent `io:` block produces no output): fail-closed default.
  Accepted.

**Three kinds vs. one kind:**

- One generic "stage output" record: pushes type discrimination into
  renderers and makes per-kind redaction harder. Rejected.
- Three named kinds (`llm`, `command`, `computed`) with a shared envelope
  schema: each kind has different fields (`exit_code` only for `command`;
  `metadata.tier`/`metadata.model_id` only for `llm`). Renderers branch on
  kind for human-readable output but share serialization. Accepted.

## Decision

1. **Stage I/O is a first-class observable** with three named kinds:
   - `llm` — prompt → raw response (router success branch).
   - `command` — argv → stdout/stderr/exit code (test runners, `gh issue view`,
     `git apply`, etc.).
   - `computed` — source artifact path → produced artifact path (plugins
     that derive a file without external work; sparing use).

2. **One chokepoint helper** in a new module `core/output/stage-io.sh`:

   ```
   capture_stage_io \
       --stage <id> \
       --kind llm|command|computed \
       --input <file-or-string> \
       --output <file-or-string> \
       [--exit-code N] \
       [--duration-ms N] \
       [--metadata key=val ...]
   ```

   Parallels `apply_scope_redaction` (ADR-004). All capture in zBuild flows
   through here; nothing else writes to `state/artifacts/stage-io/`.

3. **Config lives in the pipeline template** per stage as an optional
   `io:` block. Schema:

   ```yaml
   stages:
     - id: plan
       gate: auto
       roles: [planner]
       io:
         destinations: [file, stdout, gh_comment]
         # optional knobs (v1 may defer):
         # tail_lines: 40
         # max_output_bytes: 60000
         # redact: true        # default true; only command/computed may opt out
     - id: review
       # no io block → no output captured for review stage
   ```

   Stage without an `io:` block produces nothing — the fail-closed default.
   No global master switch; visibility is always declared.

4. **Destination tokens (v1):** `file`, `stdout`, `gh_comment`. Future:
   `gh_check_run`, `step_summary` mirroring `core/output/destinations.sh`.
   Unknown tokens fail-closed at template load time with an actionable error.

5. **Capture record envelope (locked, schema_version=1):**

   ```json
   {
     "schema_version": 1,
     "run_id": "20260529...",
     "stage": "plan",
     "kind": "llm",
     "seq": 1,
     "input": "...post-redaction prompt or argv or source-path...",
     "output": "...raw response or stdout/stderr or produced-path...",
     "exit_code": 0,
     "duration_ms": 1234,
     "metadata": { "model_id": "...", "tier": "T2", "tokens": "..." },
     "ts": "2026-05-29T..."
   }
   ```

   Stored at `state/artifacts/stage-io/<stage>-<seq>.json` via `atomic_write`.

6. **Redaction obligations** (non-negotiable):
   - `llm` kind: prompt MUST already be post-redaction (ADR-004 governs the
     inbound path — unchanged by this ADR). Response gets an outbound
     redaction pass when `gh_comment` is in the destinations list.
   - `command` kind: argv and output get outbound redaction when
     `gh_comment` is selected, unless the stage sets `redact: false` in its
     template entry. Stages MAY opt out for trusted internal commands; the
     opt-out is recorded in the artifact metadata.
   - `computed` kind: same as `command`.
   - The redaction chokepoint is reused as-is (`core/redaction/scope-redaction.sh`).
     This ADR adds a caller, not a new redactor.

7. **New event type** `stage.io.captured` with fields
   `{stage, kind, seq, dest_list, artifact_path}`. Schema entry added to
   `config/event-schema.json`.

8. **Implementation path** — three sequential issues, each independently
   mergeable:
   - **#438** (v1, smallest end-to-end slice): template `io.destinations`
     field + awk parser extension + `capture_stage_io` helper + `_stage_io_to_file`
     renderer + LLM-kind capture point in `core/router/route.sh`. Status of
     this ADR flips from **Proposed** to **Accepted** when #438 lands.
   - **#439** (v2, blocked by #438): `run_captured_command` wrapper in
     `scripts/lib/helpers.sh` + command-kind adoption in build/intake.
   - **#440** (v3, blocked by #438): `_stage_io_to_stdout` + `_stage_io_to_gh_comment`
     renderers + update `config/templates/standard.yaml` defaults.

## Consequences

**Positive:**

- Operators can audit what every stage actually sent the LLM (or ran on
  the shell) and what came back — currently impossible without recompiling
  with debug prints.
- Failure debugging gets dramatically easier: a `plan` stage that produces
  malformed JSON (the issue-#435 class of failure) can be diagnosed by
  reading the captured response.
- Per-stage visibility lets operators surface `plan`-stage prompts as
  comments on the GitHub issue while keeping `build`-stage diffs file-only.
- One chokepoint, one record schema, one redaction policy. CI can lint for
  "every stage that does work calls `capture_stage_io`" the same way it
  could lint for ADR-004 redaction call sites (open follow-up: linter).

**Negative / costs:**

- Adds storage. Each captured stage writes a JSON artifact;
  `state/artifacts/stage-io/` grows with run count. Mitigation: `gitignore`
  the path (it lives under `~/.zbuild/state/` which is already runtime
  state); a future `zbuild teardown` (#210, #224) can prune.
- Adds a plugin-author obligation: command-kind stages should adopt the
  `run_captured_command` wrapper rather than calling shell directly. Stages
  that don't adopt simply produce no command-kind capture — degrades
  gracefully.
- Each `gh_comment` destination call costs one GitHub API request per stage
  per run. For a 4-stage capture run that's 4 API calls; well under rate
  limits but worth documenting.
- The template schema grows. The awk parser at `core/pipeline/template.sh:87-137`
  needs careful extension to keep bash-3.2 compat. Existing template tests
  must still pass.

**Open follow-ups (will file after this ADR is accepted):**

- CI linter: "every stage that performs work calls `capture_stage_io`."
- Per-template `defaults.io.destinations` cascade.
- Encryption-at-rest for capture artifacts (Phase 1+; filesystem perms suffice
  for now).
- Per-token streaming (separate concern; Anthropic streaming API).

## References

- [ADR-001](ADR-001-plugin-contract.md) — plugin contract, manifest schema.
- [ADR-004](ADR-004-redaction-chokepoint.md) — the chokepoint pattern this
  ADR mirrors. Stage I/O capture is to observability what
  `apply_scope_redaction` is to inbound safety.
- [ADR-013](ADR-013-canonical-stage-list.md) — canonical stage list; this
  ADR adds a per-stage `io:` field to every template that drives those stages.
- `core/output/destinations.sh` — existing end-of-pipeline destination
  abstraction. The new `core/output/stage-io.sh` mirrors its renderer pattern.
- `core/pipeline/template.sh:87-137` — awk-based template parser whose
  per-stage handling will be extended.
- `core/router/route.sh` — LLM-kind capture point.
- `config/event-schema.json` — `stage.io.captured` event addition.
- Issue #213 (closed) — end-of-pipeline destinations.
- Issue #421 (closed), Issue #435 (closed) — recent failures that would
  have been visibly diagnosable from captured LLM I/O.

## Implementation Notes (Proposed — 2026-05-29)

This ADR ships in **Proposed** status. No code has been written yet.
Implementation is split across three sequential issues, each independently
mergeable, with ADR-015 flipping to **Accepted** when the first one lands.

- **#438** (v1, the minimum end-to-end slice) — template `io.destinations`
  field + awk parser extension at `core/pipeline/template.sh:87-137` +
  `capture_stage_io` chokepoint in new module `core/output/stage-io.sh` +
  `_stage_io_to_file` renderer + LLM-kind capture point in
  `core/router/route.sh`. ADR-015 **Status** changes from Proposed to
  Accepted on merge of #438.
- **#439** (v2, blocked by #438) — `run_captured_command` wrapper in
  `scripts/lib/helpers.sh` + command-kind adoption in
  `plugins/agent/intake/plugin.sh` (the `gh issue view` call landed in #421)
  and `plugins/agent/build/plugin.sh`.
- **#440** (v3, blocked by #438) — `_stage_io_to_stdout` and
  `_stage_io_to_gh_comment` renderers + outbound redaction for `gh_comment`
  (reuses `core/redaction/scope-redaction.sh`) + `config/templates/standard.yaml`
  defaults turning the feature on for plan/build/review/intake.

This ADR PR (#441) lands the design document only; it does not modify the
template parser, router, helpers, plugins, or event schema.
