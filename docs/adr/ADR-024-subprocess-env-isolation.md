# ADR-024: Subprocess Environment Isolation Contracts

**Status:** Accepted (2026-06-03, flipped from Proposed in Wave 13-B #671)
**Date:** 2026-06-03
**Depends on:** ADR-015 (stage-io capture, fd 3 contract)
**Implemented by:** #671 (helper `_zbuild_make_fresh_shell` in `scripts/lib/env-scrub.sh` + applied at test plugin + 4 router spawn sites). Umbrella: #670.

## Context

Three consecutive discoveries of the same env-divergence bug class — each at
a different `ZBUILD_*` env-var family — have shipped tactical, per-variable
fixes that did not generalize:

1. **#645 (Wave 11A)** — `ZBUILD_STAGE_IO_FD` plus an open fd 3 inherited from
   the runner into the test-plugin's `npm test` subprocess caused nine
   phantom failures (the T11/T51 stage-io banner case plus the
   router-claude-flags T1–T3 trio). The tactical fix lives at
   `plugins/tool/test/plugin.sh:181-186` — `unset ZBUILD_STAGE_IO_FD` and
   `exec 3>&-` in the inner subshell, immediately before `eval "$test_cmd"`.
2. **#647 (Wave 11C)** — same bug class, defense-in-depth in the router's
   four claude-spawn subshells. Tactical fix at
   `core/router/route.sh:364`, `:370`, `:809`, `:816` — the same
   `unset ZBUILD_STAGE_IO_FD && exec 3>&-` ritual before each
   `claude "${_claude_args[@]}"` invocation.
3. **Wave 13 dogfood (this ADR's motivating discovery)** — `ZBUILD_RUN_ID`
   and `ZBUILD_EVENTS_JSONL` leak into the test subprocess. When the
   `npm test` subprocess re-enters the router (via a recursive zbuild
   invocation in a fixture), `route_to_model`'s C6 precondition at
   `core/router/route.sh:158-182` finds a non-empty `ZBUILD_RUN_ID` plus a
   readable `ZBUILD_EVENTS_JSONL`, then walks the events log looking for
   the most recent `redaction.applied` event for that run id — which does
   not exist (the subprocess belongs to a different logical run) — and
   refuses to spawn `claude` with `router.precondition.refused`. Nine
   phantom failures, different env vars, identical root cause.

The pattern is now clear: the inner subprocess inherits the entire
`ZBUILD_*` namespace from the runner. Every new pipeline-state variable
recreates the bug. Per-variable `unset` is a treadmill — it patches the
symptom of the run that surfaced it, not the class.

What's missing is a single semantic contract that tells future plugin
authors which subprocesses MUST look like a fresh user terminal and which
are allowed to inherit pipeline state.

## Decision

zBuild codifies **two plugin-subprocess classes**. Every subprocess a
plugin spawns belongs to exactly one of these classes, and the choice is
declared at the spawn site.

### Fresh-user-shell class

The subprocess MUST look like a fresh user terminal — exactly as if the
user invoked the command from their own login shell, with no zBuild runner
in the process tree.

**Contract:**

- Scrub the entire `ZBUILD_*` environment variable namespace before exec.
- Close fd 3 (the ADR-015 stage-io channel) before exec.
- The plugin calls a single framework-owned helper,
  `_zbuild_make_fresh_shell`, in the inner subshell at the spawn point.
  The helper's implementation lives in `scripts/lib/env-scrub.sh` and is
  shipped by Wave 13-B (#671). This ADR does not write that code.

**Members today:**

- Test plugin: `plugins/tool/test/plugin.sh` — the `eval "$test_cmd"`
  subshell at `:181-186` that runs `npm test` (or the project's
  configured test command).
- Router: `core/router/route.sh` — all four `claude "${_claude_args[@]}"`
  spawns at `:364`, `:370`, `:809`, `:816`.

**Future candidates:**

- Sandboxed mutation harnesses (mutation-testing fixtures that exec the
  project's actual test command).
- e2e fixture spawners that boot a real binary under test.
- Any plugin whose subprocess is supposed to simulate user-shell
  semantics — i.e., the subprocess MUST NOT see pipeline state because
  doing so would change its behavior away from what the end user would
  observe.

### Pipeline-internal class

The subprocess inherits the full pipeline state by design and is expected
to call back into the events bus, write artifacts, or otherwise behave as
a participant in the running pipeline.

**Contract:** no scrub. The subprocess sees the runner's full `ZBUILD_*`
environment.

**Members today:**

- Agent plugins: plan, build, review, security-lens. These dispatch model
  calls *through* the router (which itself owns the fresh-user-shell
  contract for the claude spawn); the agent plugin process is internal.
- Cycle orchestrators (ADR-021): the cycle loop is part of the pipeline,
  not a user-shell simulation.
- Anything that reads `ZBUILD_STATE_DIR`, writes `ZBUILD_ARTIFACT_DIR`,
  or emits to `ZBUILD_EVENTS_JSONL` from within the subprocess body.

## Boundary

The scrub happens at the **inner subshell** where the plugin's own code
constructs the spawn — NOT at plugin entry, and NOT at runner dispatch.

This boundary is load-bearing. The plugin itself needs the full
`ZBUILD_*` environment to do its own work (locate artifacts, write
outputs, emit events). It is only the spawned child that simulates
user-shell semantics. Two walkthroughs make the boundary concrete:

**Test plugin** (`plugins/tool/test/plugin.sh`):

1. Plugin entry: reads `ZBUILD_STATE_DIR` to find `diff.patch`,
   `ZBUILD_ARTIFACT_DIR` to know where to write `test-results.json`,
   `ZBUILD_RUN_ID` + `ZBUILD_EVENTS_JSONL` to emit progress events.
2. Plugin does its setup, writes events, decides on the test command.
3. Plugin reaches the inner subshell at `:181-186`.
4. **The fresh-user-shell helper runs here.** Scrub `ZBUILD_*`, close
   fd 3, then `eval "$test_cmd"`.
5. After the subprocess returns, the plugin reads `raw_output`, parses
   verdict, emits more events — using the full `ZBUILD_*` environment
   it never lost.

**Router** (`core/router/route.sh`):

1. Router entry: reads `ZBUILD_RUN_ID` + `ZBUILD_EVENTS_JSONL` for the
   C6 precondition (`:158-182`), `ZBUILD_STAGE_IO_FD` for its own
   stage-io banner (ADR-015), routing config from `config/models.json`.
2. Router does precondition checks, computes the model tier, builds
   `_claude_args`.
3. Router reaches one of the four `claude` spawn sites
   (`:364`, `:370`, `:809`, `:816`).
4. **The fresh-user-shell helper runs here.** Scrub `ZBUILD_*`, close
   fd 3, then `exec claude "${_claude_args[@]}"`.
5. After the spawn returns, router parses the response, emits
   completion events.

In both cases, the plugin/router process retains full pipeline state for
its own work. Only the leaf subprocess — the `npm test` or `claude` exec
— sees a scrubbed environment.

## Member taxonomy

| Class                | Component                              | Spawn site(s)                                           |
| -------------------- | -------------------------------------- | ------------------------------------------------------- |
| Fresh-user-shell     | Test plugin                            | `plugins/tool/test/plugin.sh:181-186`                   |
| Fresh-user-shell     | Router (claude spawn)                  | `core/router/route.sh:364`, `:370`, `:809`, `:816`      |
| Pipeline-internal    | Agent plugins (plan/build/review/sec)  | All internal subprocesses                                |
| Pipeline-internal    | Cycle orchestrators (ADR-021)          | Cycle iteration body                                     |
| Future fresh-user-shell | Sandboxed mutation harness          | TBD                                                      |
| Future fresh-user-shell | e2e fixture spawners                | TBD                                                      |

When Wave 13-B (#671) lands, both fresh-user-shell sites today are
converted to call `_zbuild_make_fresh_shell` and the per-variable
`unset ZBUILD_STAGE_IO_FD` / `exec 3>&-` lines collapse into one call.

## Alternatives considered

- **(a) Per-variable `unset` ritual at every spawn site** — current state
  from Wave 11A (#645) and Wave 11C (#647). Rejected: does not generalize.
  Three discoveries already, each at a new env-var family. Every future
  `ZBUILD_*` addition is one missed unset away from a regression. The
  fix scales with the variable namespace, not with the number of spawn
  sites — and the variable namespace grows monotonically.

- **(b) `env -i` allowlist mode** at the spawn site — more aggressive
  isolation that strips the entire environment and re-injects only an
  allowlist (PATH, HOME, USER, etc.). Rejected for now: high risk of
  breaking unrelated test setup that depends on a shell-side env-var
  (`NODE_ENV`, language locales, CI-specific markers). Defer until a
  **non-`ZBUILD_*`** env-divergence bug surfaces. When it does, the
  fresh-user-shell helper is the natural place to add the stricter
  allowlist mode.

- **(c) Declarative subprocess dispatch in stage manifest** — a future
  manifest schema like:

  ```yaml
  subprocess:
    mode: fresh_shell
    command: "npm test"
    output_artifact: "test-results.json"
  ```

  where the runner owns the exec and the plugin is a thin wrapper.
  Rejected for now, kept as a forward-looking note. The current plugin
  shape is *not* a thin wrapper — the test plugin does pattern-bank
  parsing, verdict computation, summary emission, and event bookkeeping
  *around* the spawn. The helper-call-at-inner-subshell boundary is the
  natural fit for that shape. This alternative becomes the right
  direction IF zBuild grows ≥3 thin-wrapper plugins where the manifest
  could fully describe the spawn. Until then it is speculative.

## Consequences

**Good:**

- The next `ZBUILD_*` variable added to the pipeline namespace does NOT
  recreate the Wave 11A/11C/13 bug. The helper scrubs the family, not
  the specific variable.
- Plugin authors writing a new test-shaped or claude-shaped plugin have
  a clear one-line contract: call `_zbuild_make_fresh_shell` in the
  inner subshell.
- The per-variable `unset` ritual at six sites collapses into a single
  function call, with the policy expressed once in one file.
- The taxonomy is explicit in this ADR: a reviewer of a future plugin
  can ask "is this fresh-user-shell or pipeline-internal?" and have
  a documented answer.

**Bad:**

- One more piece of framework vocabulary (`_zbuild_make_fresh_shell`)
  that new plugin authors must learn. Mitigated by the helper living
  in `scripts/lib/env-scrub.sh` where the contract is colocated with
  the implementation.
- The fresh-user-shell contract makes it harder to debug the spawned
  subprocess — `printenv | grep ZBUILD_` returns nothing inside, so an
  author who expected pipeline state and didn't read this ADR will be
  surprised. Mitigated by the helper being explicit at the call site
  rather than implicit at runner entry.

**Open follow-ups:**

- **Wave 13-B (#671)** — ship `_zbuild_make_fresh_shell` in
  `scripts/lib/env-scrub.sh`, convert both fresh-user-shell sites
  (test plugin + router's four spawns) to call it, retire the per-
  variable `unset` lines. ADR-024 flips from Proposed to Accepted on
  that merge.
- **Future env-divergence non-`ZBUILD_*` discovery** — if a non-zBuild
  env-var (`NODE_ENV`, etc.) ever causes the same class of bug, revisit
  alternative (b) `env -i` allowlist mode.
- **Declarative subprocess dispatch (alternative c)** — revisit IF
  zBuild grows ≥3 thin-wrapper plugins.

## Status flip

ADR-024 ships in **Proposed** status. The status flips from Proposed to
**Accepted** when Wave 13-B (#671) merges — the same pattern used by
ADR-015, which flipped on #438 (and is itself cited as that precedent in
ADR-016's Implementation Notes). No code, no test, no event-schema
changes in this PR. Only the ADR text.

## References

- [ADR-015](ADR-015-stage-io-capture.md) — stage-io capture; the fd 3
  contract (`exec 3>&2` plus `ZBUILD_STAGE_IO_FD=3` at runner entry) is
  the predecessor env channel whose leak motivated Wave 11A/11C. The
  fresh-user-shell helper's `exec 3>&-` step closes ADR-015's channel
  before exec.
- [ADR-016](ADR-016-per-repository-template-resolution.md) — recent ADR
  with the same Proposed-then-Accepted flip pattern; structure modeled
  on it.
- [ADR-020](ADR-020-inter-stage-data-contract.md) — adjacent contract
  owner (inter-stage data); not directly coupled, but the fresh-user-
  shell scrub runs at the same conceptual boundary (where the pipeline's
  internal contract ends and the spawned subprocess's begins).
- Issue #645 (Wave 11A) — first discovery; tactical fix at
  `plugins/tool/test/plugin.sh:181-186`.
- Issue #647 (Wave 11C) — second discovery; tactical fix at
  `core/router/route.sh:364`, `:370`, `:809`, `:816`.
- Issue #670 (this ADR) — Wave 13-A umbrella.
- Issue #671 (Wave 13-B) — helper impl + apply at both call sites; the
  PR that flips ADR-024 to Accepted.
- Wave 13 dogfood — third discovery: `ZBUILD_RUN_ID` +
  `ZBUILD_EVENTS_JSONL` leak triggers C6 precondition refusal at
  `core/router/route.sh:158-182`.
- `core/router/route.sh:158-182` — C6 precondition that motivated the
  Wave 13 discovery.
- `scripts/lib/env-scrub.sh` — forthcoming home of
  `_zbuild_make_fresh_shell` (lands in Wave 13-B).

## Implementation Notes (Proposed — 2026-06-03)

This ADR ships in **Proposed** status. No code, no test, no event-schema
changes in this PR. The status flips to **Accepted** when Wave 13-B
(#671) lands the helper and converts both call sites.

The impl sequence (Wave 13-B):

- Ship `_zbuild_make_fresh_shell` in `scripts/lib/env-scrub.sh`. The
  helper scrubs the `ZBUILD_*` namespace via a loop over the current
  process's exported env-var names matching the prefix, then runs
  `exec 3>&-` to close the ADR-015 fd 3 channel.
- Convert `plugins/tool/test/plugin.sh:181-186`: replace the
  `unset ZBUILD_STAGE_IO_FD && exec 3>&-` pair with one
  `_zbuild_make_fresh_shell` call.
- Convert `core/router/route.sh` at `:364`, `:370`, `:809`, `:816`:
  same replacement.
- Add subprocess-boundary integration test that asserts `printenv` from
  inside the test plugin's spawned subprocess returns NO `ZBUILD_*`
  lines and that fd 3 is closed.
- ADR-024 status flips from Proposed to Accepted in the Wave 13-B PR.

This PR (closing #670) lands only the ADR text.

## Amendment 2026-06-03 (#674 / Wave 14) — Two-layer contract: process boundary + test-mode env

Wave 13-B (#673) shipped `_zbuild_make_fresh_shell` and converted the test plugin + four router claude-spawn sites. That fixed the env-divergence bug class at the process boundary. Three test failures remained — verified to pass when run directly on `main`, but fail under the pipeline `test` stage:

1. `tests/integration/core-router-route-test.sh` Tr-5 — assumes `ZBUILD_ROUTER_TIMEOUT=450` survives into the subshell.
2. `plugins/tool/test/tests/test-test.sh` section 6 — assumes the runner's fd 3 redirection survives through `_test_run_inner`'s helper-protected subshell.
3. `plugins/tool/test/tests/test-test.sh` section 7 — same banner-on-fd-3 contract.

These are not source-code regressions and not bugs in `_zbuild_make_fresh_shell`. They are pre-ADR-024 tests written when the runner's full environment was assumed to flow through subshell boundaries. The wider scrub legitimately strips that assumption. Per-test patching is the same treadmill the original ADR rejected at the variable level: it scales with the test corpus, not with the contract.

The fix lives one layer up. The runner scrubs at the process boundary (Layer 1, correct). Inside the resulting fresh shell, the test harness constructs deterministic test-mode env state before any test file runs (Layer 2, new). Tests source the harness instead of relying on inheritance.

### The two-layer contract

**Layer 1 — Process boundary** (existing, unchanged):

- Owned by `scripts/lib/env-scrub.sh::_zbuild_make_fresh_shell`.
- Applied at every fresh-user-shell subshell-spawn site (test plugin's `eval "$test_cmd"`, router's four `claude` spawns).
- Strips every `ZBUILD_*`-prefixed env var, closes fd 3, neutralizes shell options (`set +e +u +o pipefail`).
- Preserves user-shell vars (PATH, HOME, USER, SHELL, TERM, TMPDIR, etc.).
- Scope: the *boundary* between runner and spawned child. The helper does not know what env state the spawned child needs to do its own work — it only knows what state must not leak through.

**Layer 2 — Test-mode env** (new, owned by Wave 14-B #675):

- Owned by `tests/lib/test-harness.sh`.
- Applied *inside* the fresh shell (and inside individual test entry points or a harness-aware runner like `tests/run-all.sh`), before any test file's first assertion.
- Constructs canonical test-mode env state:
  - `ZBUILD_RUN_ID` — deterministic per-invocation id (e.g., `test-$$`).
  - `ZBUILD_STATE_DIR` — isolated per-run tmpdir (auto-created).
  - `ZBUILD_EVENTS_JSONL` — fresh empty events file under the tmpdir.
  - `ZBUILD_EVENT_SCHEMA` — canonical schema path.
  - `ZBUILD_ARTIFACT_DIR` — isolated per-run artifact dir under the tmpdir.
- Auto-cleanup via additive EXIT trap composition (the harness composes its cleanup onto any pre-existing trap rather than overwriting it).
- Scoped helpers for individual test conditions:
  - `zb_test_with_router_timeout` — pin `ZBUILD_ROUTER_TIMEOUT` for a single test case.
  - `zb_test_with_stage` — pin stage-context vars for a single test case.
  - `zb_test_capture_fd3` — re-establish a fd-3 sink for a single test case that asserts on the ADR-015 stage-io banner.
- Helpers use `( ... )` subshell isolation so mutations do not leak into adjacent test cases.

### Why two layers

The runner does not know what env state tests need. The test harness does. Splitting ownership at the process boundary keeps both contracts small:

- Future runner additions to the `ZBUILD_*` namespace do not ripple into tests, because tests are not in the inheritance chain by design. The Layer 1 scrub strictly widens; the Layer 2 harness names exactly what test mode requires.
- Future tests do not write env-setup boilerplate. They source the harness and call helpers for case-specific conditions.
- The bug class — "test assumes inherited env that the scrub strips" — is killed at the architectural boundary, not test-by-test. Wave 14-B migrates the three discovered sites; future tests start with the harness in place and never enter the failure mode.

### Boundary contract

- Tests MUST source the harness (or be run through a harness-aware entry point like `tests/run-all.sh`) rather than rely on inheritance from the runner.
- Tests MAY use the scoped helpers (`zb_test_with_router_timeout`, `zb_test_with_stage`, `zb_test_capture_fd3`) for cases that need additional env conditions beyond the canonical baseline. Mutations stay scoped to the helper's subshell.
- Production code — runner, plugins, agents, cycle orchestrators — does NOT know about Layer 2. The harness is invisible from outside the test scope. Nothing in `core/`, `plugins/`, or `scripts/` imports `tests/lib/test-harness.sh`.

### Motivating discoveries

Three failures surfaced under the pipeline `test` stage on the Wave 13 dogfood run, each passing when invoked directly on `main`:

1. `tests/integration/core-router-route-test.sh` Tr-5 — depends on `ZBUILD_ROUTER_TIMEOUT=450` propagation into the inner subshell, scrubbed by Layer 1.
2. `plugins/tool/test/tests/test-test.sh` section 6 — depends on fd 3 surviving through `_test_run_inner`'s helper-protected subshell; fd 3 is closed by Layer 1.
3. `plugins/tool/test/tests/test-test.sh` section 7 — same fd-3 banner contract.

Wave 14-B (#675) migrates these three sites to the harness. Future `ZBUILD_*` additions will not reopen the class because tests source canonical env rather than inherit it.

### Reference dogfood

Wave 13 dogfood `20260603193616-48336` exposed all three failures simultaneously. Cited for traceability.

### References

- ADR-024 main body (Layer 1).
- ADR-015 — stage-io capture; the fd 3 channel whose Layer 1 closure motivated discovery (2)/(3).
- ADR-020 — inter-stage data contract; sibling contract at the same conceptual boundary.
- #672 (Wave 13-A) — ADR-024 Proposed.
- #673 (Wave 13-B) — `_zbuild_make_fresh_shell` helper + first call sites; flipped ADR-024 to Accepted.
- #674 (this amendment).
- #675 (Wave 14-B) — `tests/lib/test-harness.sh` implementation + migration of the three discovered sites.
