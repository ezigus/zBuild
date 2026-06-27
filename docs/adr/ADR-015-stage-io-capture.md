# ADR-015: Stage I/O Capture Chokepoint

**Status:** Accepted (2026-05-29)
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

### v2 — `run_captured_command` wrapper (issue #439)

The v2 slice introduces the `run_captured_command <stage> <argv...>` wrapper in
`scripts/lib/helpers.sh`. The wrapper executes the wrapped command with merged
stdout+stderr captured to a temp file, records wall-clock duration in
millisecond resolution via `$EPOCHREALTIME` (zBuild requires Bash 5+ per
`scripts/lib/compat.sh`), forwards the record to `capture_stage_io --kind command`,
and re-emits the captured output on its own stdout so it is a drop-in
replacement for `$(cmd)` callers. The caller's `errexit` state is preserved.

**Adoption recipe:** any plugin invoking an external command whose argv,
exit code, or output is worth auditing should replace the bare command with
`run_captured_command <stage> <argv...>`. The plugin must already source
`core/output/stage-io.sh` (a defensive guard returns rc=2 if not). When the
template's stage declares no `io.destinations`, the wrapper still runs the
command transparently and the capture is a no-op (hot path).

**Adopted in v2:**

- `plugins/agent/intake/plugin.sh` — the `gh issue view` call in `intake_run`:
  ```sh
  fetched="$(run_captured_command intake gh issue view "$issue" \
      --json title,body --jq '...' 2>/dev/null)"
  ```
  Stdout passthrough returns the assembled `title\n\nbody` string.
- `plugins/agent/build/plugin.sh` — the `git apply --check` validation:
  ```sh
  if ! run_captured_command build git -C "$repo_root" apply --check \
      "$output_diff_patch" >/dev/null 2>&1; then
      warn "..."
  fi
  ```
  The wrapper's stdout is redirected to `/dev/null` because only the rc
  matters for `--check`; the captured output still lands in the artifact.

**v2 limitations (carried into v3):**

- Capture is read-back through `head -c $RUN_CAPTURED_CMD_MAX_BYTES` (default
  1 MiB). Output exceeding the cap is truncated and the artifact's `.output`
  ends with `[truncated: <N> bytes total, captured <max>]`.
- Embedded NUL bytes are stripped (`tr -d '\0'`) before the record is
  assembled — binary command output is lossy by design.
- `duration_ms` resolution is true milliseconds via `$EPOCHREALTIME`.
- Outbound `gh_comment` redaction is still deferred to #440; v2 stages that
  enable `gh_comment` will receive the v3 stub renderer.

### v3 — stdout + gh_comment renderers (issue #440)

The v3 slice replaces the `_stage_io_to_stdout` and `_stage_io_to_gh_comment`
stubs in `core/output/stage-io.sh` with functional renderers, wires outbound
redaction for `gh_comment` destinations through
`core/redaction/scope-redaction.sh::apply_scope_redaction`, and turns the
feature on by default in `config/templates/standard.yaml` for the four
agent-bearing stages (intake/plan/build/review). The ADR status flips from
Proposed to Accepted with this slice.

**Renderer formats**

`_stage_io_to_stdout <record_json>` renders to its own stdout (not stderr —
the rendered text is *content*). Layout:

```
── stage-io: <stage> [<kind>] seq=<N> <OK|FAIL> <duration> ──
<per-kind body>
── end stage-io: <stage> ──
```

Per-kind body:

- `llm` — `── input ──\n<head tail_lines of input>\n── output ──\n<tail tail_lines of output>`
- `command` — `── input ──\n$ <input>\n── output ──\n<tail tail_lines of output>\n── exit: <exit_code> ──`
- `computed` — `in: <input>\nout: <output>`

Status indicator: `command` reports `OK` when `exit_code==0` and `FAIL`
otherwise. `llm` reports `OK` when `metadata.error` is absent and `FAIL`
when present. `computed` always reports `OK`. Duration is rendered as
`%.1fs` from `duration_ms`, or `-` when unset.

`_stage_io_to_gh_comment <record_json>` wraps the same stdout rendering
inside a `<details>...</details>` block with a one-line `<summary>`:

```
<details><summary>OK stage: plan (llm, 2.4s)</summary>

```
<stdout rendering, redacted>
```
</details>
```

**Redact-before-truncate ordering**

Redaction is applied to `output` and then `input` BEFORE the body-cap check.
Truncating first could slice through a path-token in mid-string and produce
an `<out-of-scope-context>` wrapper with an unmatched closing tag, defeating
the purpose. The full body is assembled, then trimmed if it exceeds the cap.

**60_000-byte body cap**

GitHub allows up to 65_536 bytes per issue comment body; the cap is set
conservatively at 60_000 to leave headroom for the wrapping `<details>`,
fence markers, summary, and the truncation marker itself. When a rendered
body exceeds the cap, the rendered output portion is trimmed and a marker is
appended:

```
[truncated — see <state_dir>/artifacts/stage-io/<stage>-<seq>.json for full <N>-byte capture]
```

The artifact path always points to the full capture written by the
`file` destination — `gh_comment` is for human review; the `file`
destination is the source of truth.

**gh_comment skip semantics**

The destination is a silent no-op when:

- `ZBUILD_ISSUE` is unset, empty, or `0` (mirrors `_dest_gh_comment` at
  `core/output/destinations.sh:50-52` — when there's no issue, there's
  nothing to comment on).
- `ZBUILD_OUTPUT_GH_COMMENT=0` (global kill switch, also mirrors
  `core/output/destinations.sh:13-15` — operators can disable all
  `gh_comment` capture without touching templates).

On `gh issue comment` failure (network, permissions, rate limit), the
destination emits `stage.io.error reason=gh_comment_post_failed` via the
event bus and returns 0 — capture is best-effort observability; a flaky
comment must not break the stage that produced it. On redaction failure
(`apply_scope_redaction` returns non-zero), the comment is dropped, an
event `stage.io.error reason=redaction_failed` is emitted, and the
function returns 0; the file capture is unaffected and still contains the
unredacted record (file is private state; gh_comment is the public
emission path).

**Per-stage template knobs: `tail_lines`, `redact`**

The pipeline-template `io:` block grows two optional sibling keys:

```yaml
stages:
  - id: plan
    io:
      destinations: [file, gh_comment]
      tail_lines: 60     # int, 1..10000, default 40
      redact: true       # bool, default true; LLM ignores false
```

`tail_lines` (integer, range `1..10000`, default `40` when unset) controls
how many trailing lines of `output` (and leading lines of `input` for the
`llm` body) appear in renderings. The validator rejects non-integers,
zero/negative, and values above 10_000 to catch unit-confusion typos
(e.g. someone writing `tail_lines: 60000` thinking bytes).

`redact` (`true|false`, default `true` when unset) lets `command` and
`computed` stages opt out of outbound redaction for trusted internal
commands (e.g. `git apply --check` on a path already inside scope). The
`llm` kind ALWAYS redacts — the response could be model-emitted content
referencing paths the prompt never mentioned. The opt-out is for commands
whose argv and output the operator has audited as safe to publish.

**Deferred items**

- Per-stage `max_output_bytes` knob — for now the 60_000-byte body cap is
  global. A future iteration could let high-signal stages (review) keep more.
- `gh_check_run` and `step_summary` destinations — sibling tokens to add
  after experience with `gh_comment` reveals what shape works.
- Resume idempotency — when a pipeline resumes mid-stage, `seq` is recomputed
  from the artifact-dir listing; on disk this works, but a stage that
  re-runs after partial completion may double-post `gh_comment` entries.
  A future "did this seq already comment?" check is deferred.

### v4 — Emission ordering contract (issue #491)

Every stage that performs work MUST emit its input banner BEFORE the action is
invoked and its output banner AFTER the action returns. Concretely:
`stage_io_begin` (or `_stage_io_stdout_begin`) writes to fd
`${ZBUILD_STAGE_IO_FD:-2}` and is sequenced before the LLM/command/computed
action runs in the parent shell; `stage_io_end` is sequenced after. Capturing
the action via `$(...)` is forbidden when that subshell would intercept the
banner fd — callers must either (a) write banners to a fd the subshell
inherits and does not redirect (the default fd 2), or (b) invoke the action
without a stdout-capturing subshell. The chokepoint itself MUST redirect its
own banner writes (`>&"${ZBUILD_STAGE_IO_FD:-2}"`) so a caller that wraps it
in `$()` cannot capture the banner into a string. Stages adopting
`route_to_model`, `route_to_model_loop`, or `run_captured_command`
automatically inherit this contract; stages with bespoke action invocation
must satisfy it manually and are linted (see CI invariant test reference).

**Why #481 regressed before #491.** #481 split the v1 single banner into
begin/end phases with the intent that input emits before the action runs and
output emits after. But five plugins (plan/review/security-lens/build/intake)
wrap their action invocation in `$(...)` with `2>/dev/null` to suppress stderr
noise; because the banner writes to fd 2 by default, the `2>/dev/null` swallowed
the begin half of the banner. The output half still emitted from the parent
shell (after `$()` returned), so an operator saw a single output banner — the
exact pre-#481 shape, plus orphan-trap noise. #491 codifies the contract
above, hardens the chokepoint with a layer-2 fd redirect inside
`_stage_io_stdout_begin` / `_stage_io_stdout_end` (defense-in-depth), removes
the `2>/dev/null` from all five callsites, validates `ZBUILD_STAGE_IO_FD` at
module load (refuses 0 or 1 — collision with stdin or the action's stdout), and
ships a same-line lint guard and a cross-stage integration test.

**Two-layer fd contract (defense-in-depth).** The caller-level redirect
(`stage_io_begin` / `stage_io_end` wrap their internal helper invocations with
`>&"${ZBUILD_STAGE_IO_FD:-2}"`) is the belt. The helper-level redirect
(`_stage_io_stdout_begin` / `_stage_io_stdout_end` wrap their bodies in
`{ … } >&"${ZBUILD_STAGE_IO_FD:-2}"`) is the suspenders — even if a future
caller forgets the outer redirect, every banner-printing `printf` lands on the
banner fd directly. A test that calls these helpers directly with no caller
redirect must still see the banner on fd 2.

**`ZBUILD_STAGE_IO_FD` validation.** `_stage_io_validate_fd` runs once at
module load (gated by `_ZBUILD_STAGE_IO_LOADED`) and refuses `0` (stdin
collision) and `1` (stdout collision — would interleave the banner with `$()`
captures and corrupt downstream parsing) with `error` + `return 2`. The
validation also verifies the fd is actually open for write in the sourcing
shell. Failure aborts the `source` so the operator sees the error immediately
rather than at the first banner-emit attempt.

**gh_comment fd asymmetry (documented carve-out).** The stdout-destination
banner writes to fd `${ZBUILD_STAGE_IO_FD:-2}`. The gh_comment renderer's body
is built via `$(_stage_io_to_stdout …)` capture (fd 1). This is intentional:
the gh_comment body is *content* assembled as a string for the GitHub API
call, whereas the stdout-banner is *operator-visible logging* that must
survive callers wrapping the action in `$()`. Do not collapse this asymmetry
without a follow-up issue; moving the gh_comment renderer to fd 2 would make
the body unavailable for the gh CLI invocation. Cross-reference:
`core/output/stage-io.sh::_stage_io_to_gh_comment` carries the same note.

**Pre-begin error frames are intentionally unframed.** Errors that fire
before `stage_io_begin` (budget overflow, precondition failure, router
config errors) appear without banner framing; this is by design — the
orphan-trap from #481 captures the state for forensics
(`stage.io.error reason=output_never_emitted`) and an unbanner-framed error
keeps the operator's attention on the actionable text. Adopters who want
pre-begin errors framed must call `stage_io_begin` before the precondition
gate; this is out of scope for #491 and tracked as a follow-up.

**CI invariant test.** The keystone enforcement lives in
`tests/integration/stage-io-ordering-invariant-test.sh`. It is table-driven
(one row per stage that performs work — currently intake/plan/build/review/
security-lens) and asserts, with a slow mock claude (sleep 1.5s per call),
that the input banner emits at least 1 second before the output banner. New
contributor adds a stage = adds a row. A meta-test
(`tests/unit/docs-adr-015-references-invariant-test.sh`) fails if this ADR
ever stops referencing the invariant test path — preventing silent deletion
of the test.

**Lint guard.** `scripts/lib/lint-stage-io.sh` rejects any production code
(`plugins/**/plugin.sh` + `core/router/route.sh`) that has `2>/dev/null` on
the SAME LINE as `route_to_model`, `route_to_model_loop`, or
`run_captured_command`. The guard is narrow on purpose: it does not flag the
~100 unrelated `2>/dev/null` uses (gh/git probes, optional helpers) which
have nothing to do with banner emission. Test files are out of scope (they
legitimately exercise error returns with stderr suppression). Wired into
`npm run lint`.

### v5 — Visual hierarchy + timestamps (issue #492)

The v4 contract delivered correct *ordering*. v5 polishes the operator-facing
banner shape so a long pipeline run is scannable in scrollback. Concrete
changes, all confined to the fd-2 (default) banner path:

**Per-stage color registry.** `core/output/stage-colors.sh` declares a
Bash 5+ associative array `_STAGE_COLORS` keyed by canonical stage id
(intake/plan/build/test/review/security-lens) with the value drawn from the
existing helpers palette (`$BLUE/$CYAN/$YELLOW/$PURPLE/$GREEN/$RED`). A small
helper `_stage_color <stage>` returns the ANSI escape for a stage and falls
back to `$CYAN` for unknown stages. A source-once guard (`_ZBUILD_STAGE_COLORS_LOADED`)
keeps re-source cheap. The registry is sourced by `core/output/stage-io.sh`
(banner emitter) and `core/pipeline/runner.sh` (`▸ Running stage` line +
stage-transition divider) — NOT by `plugin-bootstrap.sh`, since plugins
already get the palette indirectly via `info()`/`success()` etc.

**Banner format.** The heading is composed as
`── stage-io: <stage> [<kind>] seq=<N> <input|output> [STATUS DUR] ──── HH:MM:SS UTC ──`.
Token order matches v4 so existing substring assertions
(`tests/unit/core-output-stage-io-split-test.sh`) keep working: prefix text
first, then padding dashes, then the right-aligned timestamp. Width comes
from `scripts/lib/helpers.sh::_term_width` (memoized `tput cols` →
`$COLUMNS` → 80). When the computed padding falls to ≤2 (terminal < ~70
cols), the heading degrades to the v4 format (no timestamp, no
right-alignment) so a narrow terminal still gets readable output.

**Timestamp.** `_stage_io_now_short` renders `HH:MM:SS UTC`. It honors
`ZBUILD_STAGE_IO_NOW_MS_OVERRIDE` for golden determinism and falls back
through BSD `date -r <sec>` (macOS) → GNU `date -d @<sec>` so the same
helper works on both platforms.

**Status icons.** The end-trailer carries `✓` on OK and `✗` on FAIL, colored
green/red respectively. The icon is on the END trailer, not the output
heading — keeping `seq=N output OK <dur>` as a literal substring for v4
assertions. The output heading itself colors only the `OK`/`FAIL` token
(via `$GREEN`/`$RED`), not the surrounding text.

**Heavy stage divider.** `core/pipeline/runner.sh::_render_stage_divider`
emits a blank line + a full-width `━` (U+2501) rule with the stage name
centered in stage-color, then another blank line — fired between
`eb_emit_event "stage.start"` and `info "Running stage:"`. The `▸ Running
stage` and `✓ Stage <id> complete` lines now color the stage name with
its registry color (icon stays `info`/`success` palette).

**Truncation hint.** When `_stage_io_head_with_hint`/`_stage_io_tail_with_hint`
detect that the content exceeds `tail_lines`, they append a single
`↪ [<remaining> more lines · full at <artifact-path>]` line. The artifact
path is the deterministic `${ZBUILD_STATE_DIR}/artifacts/stage-io/<stage>-<seq>.json`
so the operator can `cat` the full record without scrolling backward to
find the path.

**Color asymmetry (by construction).** Colors are emitted ONLY by
`_stage_io_stdout_begin`/`_stage_io_stdout_end` (the fd-2 banner path).
`_stage_io_to_stdout` — which is captured via `$(...)` by
`_stage_io_to_gh_comment` to assemble the GitHub comment body — remains
plain-text by construction. This means the gh_comment body never carries
ANSI escapes even when the operator-visible banner is fully colored.
Cross-references the v4 fd-asymmetry note above; the v5 change extends the
asymmetry from `fd` to `bytes`. Regression test:
`tests/integration/stage-io-gh-comment-ansi-strip-test.sh` forces colors on
and asserts zero ESC bytes in the captured `gh issue comment --body`.

**Producer-side artifact-id contract (issue #483).** Pattern 1 plugins
that want their captured `route_to_model` output rendered via the
artifact-renderer registry (rather than fence-fallback) set
`ZBUILD_ROUTER_ARTIFACT_ID=<id>` around the route call. The router
attaches `metadata.artifact=<id>` to the `stage_io_begin` call; the
output banner then dispatches to `render_artifact "<id>" "$output"`.
Currently used by plan / review / security-lens. See ADR-018
§"Implementation Notes (#483)" for the env-knob save/restore idiom.

**NO_COLOR / non-tty graceful degradation.** `_stage_io_banner_use_color`
inspects `NO_COLOR`, `ZBUILD_STAGE_IO_FORCE_COLOR` (the banner-specific
test/golden pin), and `[[ -t $ZBUILD_STAGE_IO_FD ]]` to decide whether to
emit ANSI escapes for this specific banner write. When the banner fd is a
file or pipe (common in tests, in CI logs, and when an operator pipes the
pipeline through `tee`), colors are dropped so substring assertions and
log archives stay clean. Tests that need colored goldens set
`ZBUILD_STAGE_IO_FORCE_COLOR=1` per case.

**Per-iteration build loop colors.** Iterations within `build` inherit the
stage's color from the registry — there is no per-iteration override.
Theme support is out of scope; `NO_COLOR` is the escape hatch.

**Palette collapse + `LIGHT_BLUE` ═ dividers (issue #499 — amendment).**
The original v5 per-stage color palette
(intake=BLUE, plan=CYAN, build=YELLOW, test=PURPLE, review=GREEN,
security-lens=RED) shipped under #492 but was found in scrollback review to
be visual noise rather than a scan aid: the colored stage name token already
carries identity, and rotating the surrounding hue per stage made the divider
runs themselves compete for attention without helping the operator find
anything. Under #499 the built-in registry collapses so every canonical stage
maps to a single uniform `$BLUE` — stage identity is now carried only by the
BOLD weight + the stage name token in the banner heading. The
`register_stage_color` extension hook and the per-stage `_stage_color`
lookup remain in place so plugins / future stages can register a bespoke
color when there is a real reason. The unknown-stage `$CYAN` fallback
becomes a meaningful diagnostic signal: built-ins are BLUE, anything CYAN
is an unrecognized stage id.

To preserve a sense of visual weight, #499 also introduces a new global
color in `scripts/lib/helpers.sh` — `LIGHT_BLUE` (`\033[38;2;100;200;255m`)
— and swaps the I/O banner header dividers from the light `─` (U+2500) to
the medium-weight `═` (U+2550), wrapped in `LIGHT_BLUE`. The end-trailer
`── end stage-io: <stage> <icon> ──` keeps the lighter `─` glyph and
the `_end_color` rc-color from v4 (green on OK, red on FAIL). The result
is a three-tier visual hierarchy on every captured pair:

  - `═══ … ═══` LIGHT_BLUE — structural top of the banner
  - stage name — BLUE + BOLD identity token
  - `── end stage-io … ──` rc-color — lighter close

Substring invariant: the asserted v4 prefix
(`stage-io: <stage> [<kind>] seq=N <input|output>`) remains byte-identical
because color escapes are placed BETWEEN tokens (around the stage-name
sub-span), never inside it. Existing assertions in
`tests/unit/core-output-stage-io-split-test.sh` stay green.

`gh_comment` safety is unchanged: `_stage_io_strip_ansi` strips by pattern
(`\x1b\[…`), so `LIGHT_BLUE` escapes are removed transparently — no
code change was needed in `_stage_io_to_gh_comment`. Regression-guarded
by `tests/integration/stage-io-gh-comment-ansi-strip-test.sh`, which now
additionally asserts that the `─` glyph survives the strip (to catch a
future over-aggressive stripper that nukes all non-ASCII bytes).

**Implementation Note — banner-vs-payload divergence in loops (issue #505).**
For loop callers (`route_to_model_loop`, ADR-018 Pattern 2), the `stage_io_begin --input` string MAY diverge from the actual LLM payload starting at iter 2. The banner's `--input` carries an operator-facing deduped pointer
(`[static prompt: same as iter 1, N lines, sha=…]` + `[diff: see ── changed-files ── summary below …]`), while the artifact `.input` field — and the `claude -p` argv — continue to carry the full prompt. This divergence is enabled by a new optional `stage_io_begin --persist-input <path>` flag (`core/output/stage-io.sh`): when set, the artifact record reads its `.input` from that file rather than the `--input` string. Default behavior — for callers that don't pass `--persist-input` — is byte-identical to v5; plan / review / security-lens callers are untouched. The ordering contract (begin emits before LLM call, end after) is preserved unchanged; only the banner's CONTENT shape changes. See ADR-018 §Pattern 2.5 for the loop-side dedupe rules.

### v5 addendum — Operator-banner input override + review numstat (issue #506)

The review stage's input to the LLM is the full diff (the LLM needs it to
judge correctness). The operator-visible banner does not — every diff hunk
on every PR is noise. #506 introduces a producer-side override knob that
lets a stage swap the banner body without disturbing the persisted artifact
or the prompt that actually reaches the model.

**Knob:** `ZBUILD_ROUTER_BANNER_INPUT_OVERRIDE` (string, env). When set,
`_stage_io_stdout_begin` substitutes its value for `.input` before any
renderer dispatch — and also clears the local `artifact_id` so the registry
renderer does not re-process the already-formatted text. The persisted
JSON record (`state/artifacts/stage-io/<stage>-<seq>.json`) keeps the
full original input verbatim — only the on-screen banner body is swapped.

**Review numstat shape.** The review plugin sources `scripts/lib/numstat-format.sh`
(extracted from `plugins/agent/build/plugin.sh` in the same PR), computes
`git diff <merge-base> HEAD --numstat` against the closest of
`origin/main` → `main` → `HEAD~1`, formats via the shared
`format_numstat` helper with `--event-prefix review` and `--full-at
<diff.patch path>`, then wraps the body in a `── changed files ──`
heading. The override is exported around the `route_to_model` call and
restored immediately after (mirror of the `ZBUILD_ROUTER_JSON_OUTPUT` /
`ZBUILD_ROUTER_ARTIFACT_ID` save/restore pattern already in the plugin).

**Why a producer-side env knob and not a `--banner-input` route_to_model
flag?** route_to_model is the chokepoint that calls `stage_io_begin`, but
its signature is intentionally minimal (tier + prompt). Adding a banner
override flag would push presentation concerns into the router. The env
knob keeps the router signature stable, and the consumer (`_stage_io_stdout_begin`)
already centralizes all banner presentation logic — making it the right
place for the substitution.

**Scope-redaction interaction.** The banner body is NOT piped through
`apply_scope_redaction` a second time. The shared formatter masks
out-of-scope paths to `<out-of-scope-context>` via its allowlist
parameter, and the allowlist is reconstructed from the same `+` lines in
`scope-manifest.md` that `_review_audit_tool_use` already parses. This
keeps the redaction chokepoint (`core/redaction/`) the single source of
truth for the LLM-bound prompt while the banner uses a lighter,
path-only masker on a body the LLM never sees.

**Stable event names.** Truncation events keep their historical
`<stage>.numstat.truncated` shape (`build.numstat.truncated`,
`review.numstat.truncated`) — the formatter accepts `--event-prefix
<stage>` and inserts the literal `numstat` segment so existing build
assertions stay byte-identical.

**Stage boundary timestamps (issue #508 — amendment).** The runner's three
stage-boundary lines (`core/pipeline/runner.sh::_render_stage_divider`,
the `▸ Running stage: X` line, and the `✓/✗ Stage X complete/failed`
lines) now carry wall-clock timestamps so operators can see *when* each
stage began and ended, plus elapsed duration:

  - **Heavy divider** — gains a right-aligned `HH:MM:SS UTC` stamp,
    mirroring the `_stage_io_compose_banner` right-alignment idiom. Width
    math (no bookend glyphs in this layout): `left_bar = (width - len(label)
    - len(ts) - 1) / 2`; `mid_bar = width - left_bar - len(label) - len(ts)
    - 1`. When `mid_bar <= 2` (very narrow terminals) the divider degrades
    to the legacy symmetric format (no timestamp) so layout stays readable.
  - **Running line** — appended `  (started HH:MM:SS UTC)` in `${DIM}`.
    Two-space separator before the paren matches the metadata-trailer
    convention used by stage-io banner footers.
  - **Complete line** — appended `  (finished HH:MM:SS UTC · <N.Ns>)`
    in `${DIM}`. The `·` (U+00B7) separator matches the stage-io banner
    footer. Sub-minute durations format as `<N.N>s` (mirrors
    `_stage_io_render_duration`); `>= 60 s` formats as `<m>m<ss>s` so a
    slow stage doesn't surface as e.g. `127.4s`.
  - **Fail line** — `Stage X failed (rc=N, finished HH:MM:SS UTC · <dur>)`.
    The timestamp stays `${DIM}`, not red — the clock isn't the failure;
    the prefix `✗`/red carried by `error()` already signals rc.

The duration source is a new runner-local associative array
`_RUNNER_STAGE_START_MS` populated immediately before each
`_render_stage_divider` call and read at the complete/fail sites. The
clock primitive is `_runner_now_ms` / `_runner_now_short`, both of which
honor the *same* `ZBUILD_STAGE_IO_NOW_MS_OVERRIDE` env var used by
`_stage_io_now_ms` / `_stage_io_now_short` — single test contract; the
runner does NOT introduce a new override name. Defensive fallbacks:
empty / non-numeric clock → `??:??:?? UTC`; missing start-time cache →
`?s`. Color handling: the timestamp is plain text outside color escapes,
so `NO_COLOR=1` naturally preserves it. Tests:
`tests/unit/core-pipeline-runner-stage-timestamps-test.sh` (30 unit
cases), `tests/unit/core-pipeline-runner-stage-banner-goldens-test.sh`
(8 byte-exact goldens under `tests/golden/runner-stage-banners/`),
plus integration coverage in
`tests/integration/core-pipeline-runner-test.sh` (I1/I1b/I2).

**Heading prefix removal (issue #523 — amendment).** The literal `stage-io:`
label in the banner heading (begin/end input+output header lines) is removed.
New shape: `══ <stage> [<kind>] seq=N <input|output> [STATUS DUR] ══`.
The bracketed `[kind]` is retained as load-bearing — it selects the renderer
branch in `_stage_io_to_stdout` (llm | command | computed) and is asserted by
integration tests under `tests/integration/build-*-banner-test.sh`. The
closing trailer `── end stage-io: <stage> <icon> ──` is unchanged: the
trailer's prefix bounds the captured section and aids scrollback search.
Goldens regenerated; v4 substring invariant updated. The gh_comment renderer
(`_stage_io_to_stdout`) applies the same prefix removal to preserve banner/
comment schema symmetry.

**Stage-divider blank-line spacing (issue #523 — amendment).** A single blank
line is emitted at the END of every stage divider (combined with the existing
leading `\n` produces two stacked blanks between consecutive stages). Cycle
sub-dividers (ADR-015 §v6 / ADR-021) do NOT add blank lines to preserve
vertical density across high-iter cycles.

### v5.1 — Verdict-driven stage indicator glyphs (#507)

The `▸ Running stage:` / `✓ Stage <name> complete` lines emitted by the
runner (see `core/pipeline/runner.sh:490-527`) now derive the trailing
glyph + color from the plugin's manifest-declared primary output verdict
instead of unconditionally painting green on rc=0.

| Class   | Glyph | Color  |
| ------- | ----- | ------ |
| pass    | `✓`   | GREEN  |
| warn    | `⚠`   | YELLOW |
| fail    | `✗`   | RED    |

The stage name keeps its registry color (assigned in §v5); only the
leading glyph + indicator color change. See ADR-019 / ADR-020 amendments
for the verdict table and primary-output declaration rules.

### v5 Implementation Note — Renderer-side prose/JSON split (#510)

`_stage_io_stdout_end` (`core/output/stage-io.sh:1030`) dispatches to
`render_artifact "$_artifact_id" "$output"` when the capture metadata
carries an `artifact` tag. As of #510, the registered renderers for
`plan` and `review` may split the captured payload into two visual
sections inside the OUTPUT banner: the rendered artifact FIRST (eye-target
priority) followed by a `── llm comment ──` block carrying any free-text
the model emitted alongside the JSON in the same assistant turn (envelope
mode separates turns but not in-turn prose).

This split is purely a banner-render concern. The on-disk capture
record's `.output` field is the raw payload (unchanged); plugins that
write structured artifacts to disk (e.g. `plan.json`) continue to do so
via their own parser (`extract_first_json_object` — see ADR-018 Pattern 1).
The new `extract_json_and_surrounding_prose` helper in
`scripts/lib/helpers.sh` powers the split; `extract_first_json_object`
itself is unchanged for back-compat with the plan plugin's schema check.

### v5.2 — Pipeline terminal banner (issue #525)

`core/pipeline/runner.sh` emits an operator-visible pipeline.end banner at
every `pipeline.end` / `pipeline.abort` emit site (9 in-runner sites + the
pre-flight `return 2` path + the EXIT trap). The banner is framed with `═`
(U+2550) to distinguish the pipeline boundary from stage boundaries (`━`,
v5) and stage-io banners (`─`, v4).

Format:

```
════ pipeline.end ════ HH:MM:SS UTC
<glyph> Pipeline <word>: status=<X> run_id=<Y> issue=<N> (took <dur>)
```

Glyph + color derive from `core/pipeline/verdict.sh` via a thin runner-local
shim (`_pipeline_status_glyph` / `_pipeline_status_color`) mapping the
ADR-006 pipeline status enum to verdict classes — this is a render-only
mapping and does NOT extend the verdict-table enum:

| status              | glyph | color  | verdict class |
| ------------------- | ----- | ------ | ------------- |
| `complete`          | `✓`   | GREEN  | pass          |
| `failed`            | `✗`   | RED    | fail          |
| `interrupted`       | `✗`   | RED    | fail          |
| `aborted`           | `✗`   | RED    | fail          |
| `preflight_failed`  | `⚠`   | YELLOW | warn          |

Duration is sourced from `_RUNNER_PIPELINE_START_MS`, cached immediately
after `_runner_run_id` is sanitized (before the EXIT trap installs) so
even very-early failures — including the pre-flight contract-validator
path — report a real elapsed time; cache miss degrades to `?s`.

Event payload contract is unchanged: the legacy `status=success` token
remains the persisted JSONL value (consumers depend on it). The banner
performs `success → complete` mapping for display only, tracking the
ADR-006 state-enum word so the operator sees the same vocabulary in the
banner that they see in `pipeline-state.json`.

Banner is emitted AFTER `eb_emit_event "pipeline.end"` (or
`eb_emit_event "pipeline.abort"` in the EXIT trap) so the durable event
record is fail-closed against banner-write failures. Width-degrade rule
mirrors `_render_stage_divider`: when `mid_bar <= 2` (very narrow
terminals) the timestamp is dropped and a symmetric divider is rendered
on line 1 — line 2 still emits the full status detail.

Goldens under `tests/golden/pipeline-end/` cover all five statuses in
both layout (`NO_COLOR=1`) and colored (`FORCE_COLOR=1`) modes.

### v6 — Per-iter stage-io within outer cycles (#512, ADR-021)

When a stage runs inside an outer cycle, the orchestrator exports
`ZBUILD_CYCLE_ITER=<N>` and `ZBUILD_CYCLE_ID=<id>` around each dispatch.
Stage banner headers gain an `iter=N/max` prefix so operators can attribute
artifacts to the correct iteration. Per-iter stage-io artifacts are written
to the existing per-stage location (`state/artifacts/<stage>/`) — the cycle
overlay does NOT introduce a new artifact layout; downstream consumers
continue to read the canonical path. Iteration history (verdicts,
failure_count) lives in the per-cycle JSONL (`cycle-<id>-history.jsonl`)
plus `cycle_iterations[X].iter[]` in pipeline-state.json.

#### v6 — Cycle-scope visual hierarchy (#524)

The v5 stage-transition divider (`━━━` U+2501, BOLD BLUE) is the heaviest
visual rule. Outer cycles nest one layer above this with a heavier-feeling
LIGHT_BLUE `═══` (U+2550) for cycle entry/exit, and one layer below stage
transitions with a CYAN `─` (U+2500) for per-iter sub-dividers. Four new
helpers in `core/pipeline/runner.sh` render this hierarchy:

- `_render_cycle_entry <cycle_id> <max> <stages_csv>` — heavy `═` divider
  with `cycle: <id>` label, `▸ Entering cycle` line, DIM trailer with
  `max_iterations` + stages.
- `_render_cycle_iter_divider <cycle_id> <iter> <max>` — light `─` CYAN
  sub-divider `─── iter N/M ───`.
- `_render_cycle_iter_complete <iter> <verdict> <velocity> <fc> <elapsed_s>` —
  DIM `↳ iter N complete: …` trailer (event emitted FIRST, banner SECOND
  per ordering contract below).
- `_render_cycle_exit <cycle_id> <reason> <iter> <max>` — heavy `═` divider
  with verdict glyph + reason text. Map:

  | reason            | glyph | color        |
  | ----------------- | ----- | ------------ |
  | converged         | ✓     | GREEN+BOLD   |
  | max_iterations    | ✗     | RED+BOLD     |
  | plateau           | ✗     | RED+BOLD     |
  | divergence        | ✗     | RED+BOLD     |
  | aborted           | ⚠     | YELLOW+BOLD  |
  | verdict_missing   | ⚠     | YELLOW+BOLD  |
  | blocked           | ✗     | RED+BOLD     |
  | error / config_invalid / unknown | ✗ | RED+BOLD |

**Routing contract** (mirrors v5's stage-divider rules):
- Helpers are operator-fd-2 chrome: hardcoded `>&2`, never wrapped in `$()`.
- Each helper's writes are grouped under `{ …; } >&2 2>/dev/null || true`
  so a broken stderr never aborts the cycle.
- NEVER routed through `gh_comment` — operator-only.
- NO_COLOR strips ANSI but preserves glyphs + text.
- `_term_width` is the single source of width truth (honors
  `ZBUILD_TERM_WIDTH_OVERRIDE` for goldens). Narrow terminals degrade to
  the legacy symmetric divider.

**Orchestrator coupling**: the orchestrator stays event-emit + control-flow
only. It calls three optional hook functions when declared:
`cycle_iter_begin_hook`, `cycle_iter_complete_hook`, `cycle_exit_hook`. The
runner registers these to invoke the helpers above; tests can register
alternative hooks (or none) without changing orchestrator code.

**Emission ordering** (silent-failure mitigation): for each terminal event,
the durable event (`cycle.iteration.complete`, `cycle.complete`) is emitted
FIRST and the operator banner SECOND, mirroring v4's stage-start contract.
All terminal-rc paths fan in through `_cycle_handle_terminal_rc`, which
emits `cycle.complete` then invokes `cycle_exit_hook` once per cycle run
(idempotent via `_CYCLE_EXIT_BANNER_EMITTED`).

Goldens live under `tests/golden/cycle-banners/` paired
(`.layout.txt`/`.colored.txt`) per termination reason. Determinism is
pinned via the same env vars used by the v5 stage banner goldens
(`ZBUILD_TERM_WIDTH_OVERRIDE`, `ZBUILD_STAGE_IO_NOW_MS_OVERRIDE`).

## Amendment §F: Forensic Failure-Mode Preservation (Wave 19-I + 19-K, 2026-06-08)

The success-path capture above (`stage_io_begin` / `stage_io_end`) handles
the **happy path** — agent stage prompt + LLM response, command stage
argv + stdout/stderr/rc. But when the LLM call itself fails (claude rc≠0)
the router historically `rm -f`'d the only forensic data — the raw JSON
envelope and stderr — immediately after emitting a coarse
`router.error` event. Postmortems were left guessing whether the failure
was rate-limit, token-limit, max-turns, or network.

Wave 19-I (#743/PR #745) shipped this contract for the **LOOP** path
(`route_to_model_loop`); Wave 19-K (#748) shipped parity for the **SYNC**
path (`route_to_model`, used by design, plan, review, test_assessment,
security-lens, compound-quality-cycle).

**Contract (both paths):**

When the claude CLI exits rc≠0:
1. Before any cleanup, persist the JSON envelope and stderr to
   predictable paths:
   - sync: `${ZBUILD_ARTIFACT_DIR}/stage-io/<stage>-sync-error.{raw-claude-output.json,raw-claude-stderr.txt}`
   - loop: `${ZBUILD_ARTIFACT_DIR}/stage-io/<stage>-iter<N>-error.{raw-claude-output.json,raw-claude-stderr.txt}`
   Last failure per stage wins on sync (forensics want most recent;
   collisions are intentional). Loop disambiguates via iteration index.
2. ALWAYS write the artifact files — even when `$response` is empty or
   the stderr file is absent. Empty/missing IS the forensic signal
   (Copilot reviews #745 and #750 both caught variants of "skipped the
   write on empty input, losing the very case the contract exists for").
   Use `[[ -f ]]` (existence) not `[[ -s ]]` (non-empty) when reading
   back; the absence of a file means the preservation step itself
   failed, which is a higher-priority signal.
3. Emit `router.error.diagnostic` (sync) or
   `router.loop.iter.error.diagnostic` (loop) with parsed
   `.is_error`, `.error` (first 200 chars), `.num_turns`, and the
   preserved-file paths so operators grep events.jsonl without
   opening files.
4. The original `router.error` / `loop.iteration.error` event
   continues to fire — diagnostics augment, never replace.

**Why both events, not one:** the original event has been an integration
point since early waves. Removing it would silently break alert rules
keyed on `type=router.error`. The diagnostic event is additive — new
consumers subscribe to `*.diagnostic`, old consumers keep working.

**Schema-as-warn invariant:** any failure-mode event registered must
also appear in `config/event-schema.json` `known_types`. Wave 19-K also
fixed schema drift for `router.error` itself (emitted since early waves,
never registered — hence `[event-bus] WARN: unknown event type 'router.error'`).

## Amendment — `impact` renderer added (#768, 2026-06-09)

The artifact renderer registry (`scripts/lib/artifact-render.sh`) at this
ADR's v1 cutoff enumerated `plan`, `diff`, `review`, `test_assessment`.
The `impact` stage shipped in Wave 19-J (#744) without an entry, so the
terminal display dumped the full JSON envelope rather than rendering the
structured `impact_feedback_md` field. PR #768 adds:

- `render_impact_md` in `scripts/lib/artifact-render.sh`. Renders a
  one-line summary header (`Impact: verdict=<v>, missing=<n>`) followed
  by `impact_feedback_md` as raw markdown. Empty feedback (verdict=complete
  with no gaps) renders header-only. Prose preamble preserved as LLM
  comment for forensics (see #767 contract-violation capture).
- Producer-side tagging in `plugins/agent/impact/plugin.sh`: sets
  `ZBUILD_ROUTER_ARTIFACT_ID=impact` before `route_to_model`, mirrors
  the plan/review/test_assessment pattern. Restore on both branches
  (unset on `__UNSET__`, otherwise re-export prior).
- Registry entry: `register_artifact_renderer "impact" "render_impact_md"`.

Registered artifact ids: `plan`, `diff`, `review`, `test_assessment`,
`impact`. `intake` and `build` deliberately have no renderer — intake has
no LLM-structured terminal output; build's terminal artifact is the
`diff.patch`, already covered by the `diff` renderer at downstream
consumers. `security-lens` is an outstanding renderer gap tracked in
ADR-018 §v4 (separate follow-up).

## Amendment §G — `cycle` kind: per-iter cycle boundary banners (issue #833)

The §v6 amendment gave operators per-iter *leaf* stage banners
(`══ <stage> [<kind>] seq=N input/output ══`) inside outer cycles, plus
cycle entry/iter/exit chrome dividers. But the cycles themselves
(`design_impact_cycle`, `build_review_cycle`, `build_test_cycle`) emitted
only events at their boundaries — there was no operator-visible banner
showing what each iteration *consumed* (the feedback edges) or *concluded*
(the termination-predicate eval). Issue #833 adds a fourth stage-io kind,
`cycle`, to fill that gap.

**`cycle` joins `llm`/`command`/`computed` as a kind.** No new event type:
the cycle OUTPUT banner pairs through the existing `stage_io_begin` /
`stage_io_end` chokepoint and emits the already-registered
`stage.io.captured` event with `stage=<cycle_id>` and `kind=cycle`. The
change is purely additive — a kind enum value plus body branches; the
record envelope, the event contract, and the fd contract are all unchanged.

**INPUT banner — feedback-edge digest.** Emitted right after
`cycle_iter_begin_hook` (before the first inner leaf's input banner). Body is
derived *per cycle* from `_CYCLE_FEEDBACK[]` cross-referenced against the
present `iter-<N>/feedback/<to_field>.txt` artifacts:

- present → `<to_field>(<digest>)` where digest is the JSON `.verdict` when
  the artifact parses as JSON, else its first ~40 chars;
  `test_assessment`-bearing fields also append `, N changes` from
  `required_changes` length.
- required + missing → `<to_field>(MISSING)`.
- optional + missing → omitted.
- iteration 1 (or no edges) → `(no feedback — first iteration)`.

Edges are comma-joined. The digest helper
(`_cycle_render_feedback_digest`) is pure / read-only / `2>/dev/null`-guarded
— it never trips errexit and never mutates state.

**OUTPUT banner — termination-predicate eval + velocity.** Emitted *after*
the `cycle.iteration.complete` event and around `cycle_iter_complete_hook`,
before the `↳ iter complete` trailer — preserving the §v6 event-FIRST /
banner-SECOND ordering contract. Body is two lines:

```
<exit_when|abort_when> stage=<s> field=<f> op=<op> value=<v> → MATCHED|NOT MATCHED (got=<actual>)
velocity=<0-failure_count> failure_count=<failure_count>
```

`_cycle_check_until` and `_cycle_check_abort_when` already compute the
kind/stage/field/op/expected/actual/match tuple; they now stash it into
`_CYCLE_LAST_PREDICATE_*` so `_cycle_render_predicate_result` can restate it
without recomputation. `abort_when` is the kind when the abort predicate
fired. `velocity = 0 - failure_count`, mirroring `cycle.iteration.complete`.

**Routing contract.** Cycles have NO template `io:` block, so
`template_stage_io_dests "<cycle_id>"` returns empty and the normal
dest-gated path would suppress the banner. When `kind == cycle`,
`stage_io_begin` forces `dests = stdout` only — fd-2 routing (via
`ZBUILD_STAGE_IO_FD`, default 2; the runner opens fd 3 → stderr), NEVER
`file`, NEVER `gh_comment`. This mirrors the §v6 cycle-divider chrome:
operator-visible logging, never a persisted artifact and never a GitHub
comment. (The runner's main process does not otherwise source
`core/output/stage-io.sh` — only plugin subshells do via `route.sh` — so
`cycle-orchestrator.sh` sources it directly; the module's load guard makes
the re-source a no-op.)

**Nesting.** INPUT precedes the first inner-leaf input banner of the
iteration; OUTPUT follows the last inner-leaf end banner and the
`cycle.iteration.complete` event. The cycle banner uses the cycle stage-id
namespace for its seq counter (`_CYCLE_IO_SEQ[<iter>]`), distinct from the
leaf stage-id namespaces — so inner-leaf hierarchical seq labels (`N.k`,
`N.k.i.j`) are unchanged.

**Predicate stash precedence.** `_cycle_check_until` always stashes its
exit_when evaluation into `_CYCLE_LAST_PREDICATE_*`. `_cycle_check_abort_when`
overwrites the stash *only when its abort predicate actually matched* — on a
normal / converged iter (abort_when configured but NOT matching) the stash
retains the exit_when evaluation, so the OUTPUT banner shows the predicate
that actually drove the iteration rather than a misleading
`abort_when ... NOT MATCHED`.

**Orphan finalizer (main-process arming).** Sourcing
`core/output/stage-io.sh` from `cycle-orchestrator.sh` arms
`_stage_io_orphan_finalizer` (the EXIT trap that records unpaired
`stage_io_begin`s) in the runner's MAIN process for the first time —
previously only plugin subshells sourced stage-io. The finalizer still emits
the `stage.io.error reason=output_never_emitted` diagnostic event for every
kind, but it is **kind-aware for the file write**: `kind=cycle` is skipped, so
an orphaned cycle INPUT begin (e.g. the cycle aborted between the INPUT begin
and the OUTPUT end via a blocking-member `rc=8` or SIGINT `rc=130`) never
produces a `<cycle_id>-<seq>.partial.json` artifact. This preserves the
kind=cycle "fd-2 only, NEVER file" invariant on abnormal exit, not just the
happy path.

**Known limitation — full-suite-gate iter.** When the ADR-034 full-suite
gate suppresses an otherwise-converged iteration (`converged` flipped back to
1 so a targeted-mode pass is re-confirmed with a full suite next iter), the
exit_when evaluation stashed for that iter is `MATCHED`. The OUTPUT banner for
the gate-suppressed iter therefore renders `exit_when ... → MATCHED` even
though the cycle deliberately continued. This is cosmetic — the durable
`cycle.test.full_suite_gate` event records the real reason — and is left
unfixed to keep the predicate-stash logic simple; operators reading the
banner should consult the gate event for gate-suppressed iters.

## Amendment §H — `command`-kind capture is MANDATORY for external-command stages (issue #1115)

The opt-in default in §"Opt-in vs. opt-out" governs *destinations* (an absent
`io:` block means no output is persisted/published — the fail-closed privacy
posture). It does NOT license a stage to bypass the chokepoint and run an
external command with its output discarded. **Any stage that runs an external
command MUST wrap that command in `stage_io_begin --kind command` /
`stage_io_end` (or the `run_captured_command` wrapper, which does so for it).**
Capture remains a hot-path no-op when the stage declares no destinations — the
begin returns an empty seq and the end is a no-op — so the obligation costs
nothing when observability is off, but it guarantees the banner appears the
moment an operator turns destinations on.

**Motivating case — `objective-gate`.** `plugins/tool/objective-gate/plugin.sh`
ran the test suite and lint as `bash -c "$cmd" >/dev/null 2>&1`, discarding the
output entirely. Because the discard happened *inside* the plugin — not gated by
the template `io:` block — the operator saw NO banner for the single most
expensive command in the pipeline (the full suite, ~13 min), even though the
`objective-gate` stage declares `io: { destinations: [file, stdout] }`. The fix
captures stdout+stderr (no `>/dev/null`), keeps the full raw output in a
`objective-gate-{suite,lint}-output.log` artifact, and feeds a truncated
verdict+summary to `stage_io_end --output` — mirroring the `test` plugin's
`_test_emit_io_end`. When the ADR-034 full-suite result is reused (no command
runs), the pair still emits, with the INPUT banner carrying a
`[reused] cached full-suite result tree=<sha>` note. The gate logic is
unchanged; the banner is additive observability only.

This generalizes the §v4 ordering contract's "every stage that performs work
MUST emit its input banner before the action and its output banner after" from
an ordering rule into a presence rule: *discarding* a command's output is the
same defect as emitting the banners out of order — both deny the operator the
record the chokepoint exists to provide.
