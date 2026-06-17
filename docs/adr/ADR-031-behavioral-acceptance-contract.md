# ADR-031 — Behavioral acceptance contract

**Status:** Implemented (2026-06-17)
**Related:** ADR-007 (test strategy), ADR-022 (test-assessment stage), ADR-027 (recursive-flow template format), ADR-030 (scope governance)
**Issue:** #864

## Context

`design` currently produces a `design.md` artifact with a `\`\`\`scope` block and a prose narrative, but no machine-readable statement of *what behavioral change the implementation must produce*. The downstream `test_assessment` stage must infer the acceptance bar from prose context, making its verdict judgment imprecise. When `build` iterates, neither the cycle orchestrator nor `test_assessment` has a stable, tool-readable definition of "done."

Three problems compound each other:

1. **No test-first ordering.** Design phases can describe behavior without naming the tests that verify it. `test_assessment` then grades against tests that may not exist or may test the wrong thing.
2. **No don't-weaken charter.** Nothing prevents a later iteration from relaxing an assertion to make a red test go green, rather than fixing the implementation.
3. **Scattered acceptance signals.** `test_assessment`, `impact`, and `review` each read the prose artifact independently and reach independent conclusions about the acceptance bar — with no shared, canonical source.

The design stage is the right moment to specify the acceptance contract because it has full context (scope, plan, impact) and runs before any implementation code is written. Capturing the contract as a fenced block inside `design.md` keeps it adjacent to the prose rationale and co-versioned with the rest of the artifact, while making it parseable by a dedicated extractor lib.

## Decision

Add an `\`\`\`acceptance` fenced block to the `design.md` format. The block is written by `design` and consumed by `test_assessment`. The extractor library `scripts/lib/acceptance-block.sh` provides a single public function that parses the block.

### Block format

````
```acceptance
SPEC: <one-line description of the behavioral requirement>
SPEC: <additional requirement>
...
TESTFILES:
tests/unit/foo-test.sh
tests/integration/bar-test.sh
```
````

Rules:
- Each `SPEC:` line is a self-contained, falsifiable behavioral claim. It must be possible to determine whether the claim is satisfied without reading prose.
- The `TESTFILES:` sentinel is required and must appear after all `SPEC:` lines. Each subsequent non-blank line names one test file (repo-relative path) that verifies the claims above it.
- Test files named in `TESTFILES:` must be written (or amended) by `build` before the block is considered satisfied. They may not exist yet at design time — this is intentional: the block is a test-first directive.
- A `design.md` with no `\`\`\`acceptance` block is a **hard design failure** once the design stage emits the block (see Amendment 2026-06-15). `design` fails closed (`reason=missing_acceptance_block`, rc=1) rather than producing a design artifact that downstream stages cannot grade. (Superseded the original backwards-compatibility tolerance.)
- The block is not a scope declaration. File paths in `TESTFILES:` do not grant write-scope; that remains the responsibility of the `\`\`\`scope` block and ADR-030 scope governance.

### test_assessment consumption

`test_assessment` sources `scripts/lib/acceptance-block.sh` and calls `extract_acceptance_block` on the `design.md` path. When the block is present:

1. Every `SPEC:` claim is treated as a required acceptance criterion. If any claim cannot be grounded in passing test output, the verdict is `fail`.
2. Every file listed under `TESTFILES:` must be present and must have at least one passing test. A missing file is a hard fail.
3. `test_assessment` emits the extracted specs and their pass/fail status in its structured output, replacing ad-hoc prose extraction.

### Design writes failing tests

The acceptance block embeds a **test-first ordering** requirement: `design` must name tests before they pass. This is enforced by convention, not by tooling in this ADR. A future ADR may add a `build` guard that refuses to mark a cycle iteration "green" if an acceptance-block test file named in `TESTFILES:` was never executed.

### Don't-weaken charter

Once a `SPEC:` claim appears in a merged `design.md`, it may not be weakened or removed without an explicit design amendment. `review` is expected to flag any PR that removes or softens `SPEC:` lines without a corresponding design revision. This charter is enforced by process, not automation, in this ADR.

## Consequences

**Positive**
- `test_assessment` gains a machine-readable acceptance bar, reducing verdict imprecision.
- Test-file references surface missing tests early (at design time, not after a failed build loop).
- `SPEC:` lines give `review` a concrete checklist for behavioral completeness.
- The don't-weaken charter closes the loop where a red test is silenced by assertion removal.

**Negative**
- `design` must write an acceptance block in addition to prose and scope. This is additional authoring burden.
- Mis-specified `SPEC:` lines (too broad, un-falsifiable) may cause false passes or false fails until teams calibrate.
- `TESTFILES:` paths in the block are not scope-governed; a confused agent could name out-of-scope test files.

## Implementation Notes (issue #864)

Delivered in two artifacts under #864:

- **`scripts/lib/acceptance-block.sh`** — pure parser; no side effects, no LLM calls. Exports `extract_acceptance_block <design_md>`. Mirrors `_extract_scope_from_design` guard-and-loop idiom from `plugins/agent/design/plugin.sh:351-374`.
- **`tests/unit/acceptance-block-test.sh`** — five test cases covering absent block, well-formed single-entry, multi-entry, malformed (no closing fence / missing TESTFILES), and co-presence with a `\`\`\`scope` block. Sources `scripts/lib/test-helpers.sh`.

Stage wiring (`test_assessment` consumption) is implemented in issue #867 (843-D) via `plugins/agent/test_assessment/plugin.sh` + manifest; see ADR-022 Amendment v5 for the full specification and downgrade event taxonomy.

## Amendment 2026-06-15 (#865)

843-B (#865) makes `design` **emit** the `\`\`\`acceptance` block (it parses `TESTFILES:` and writes red-first failing stubs for any named test file that does not yet exist, emitting `design.acceptance_tests.written`). With the design stage now responsible for producing the block, the original backwards-compatibility tolerance in the Decision's rules is **superseded**:

- A missing `\`\`\`acceptance` block in `design.md` is no longer "tolerated." `_design_stage_run_inner` (`plugins/agent/design/plugin.sh`) calls `extract_acceptance_block` on its output and, when no block is present, **fails closed**: it warns, emits `plugin.run.error` with `reason=missing_acceptance_block`, and returns `rc=1`. The design artifact is never handed downstream without a machine-readable acceptance bar.
- This is a HARD post-condition, not a SOFT warning. The reasoning: a `design.md` that omits the acceptance block leaves `test_assessment`, `impact`, and `review` back in the "infer the bar from prose" state this ADR exists to eliminate. Tolerating it would let the very failure mode the contract prevents re-enter silently. Failing closed surfaces the gap at the design stage, where it is cheap to fix, rather than after a build loop.
- The don't-weaken charter (above) applies to the block's presence as well as its `SPEC:` lines: a design revision may not drop the acceptance block to escape the post-condition.

## Amendment 2026-06-17 (#867, 843-D) — Stage wiring complete

843-D (#867) delivers the `test_assessment` consumption half of the contract. The ADR is now **fully implemented** across all three issues (#864, #865, #867).

Delivered in this PR:

- **`plugins/agent/test_assessment/plugin.sh`** — sources `acceptance-block.sh`, runs the TESTFILES existence gate (pre-LLM, hard fail-closed on any missing file), injects the `SPEC:` lines and `TESTFILES:` list into the LLM prompt, validates `acceptance_verified` boolean in the schema expression, and applies the downgrade taxonomy: `acceptance_llm_rejected` (pass→fail when `acceptance_verified=false`) and `acceptance_not_verified` (pre-LLM fail for missing TESTFILES). Returns `rc=1` fail-closed only on the TESTFILES gate; all other paths return `rc=0` with the verdict encoded in the artifact.
- **`plugins/agent/test_assessment/manifest.yaml`** — adds `id: design` input (`path: artifacts/design.md`, `required: false`); the optional flag preserves backwards-compatibility when no design artifact is present. The input carries the acceptance block consumed by arg `$9` in the plugin.
- **Unit tests T17–T20** (`tests/unit/test-assessment-plugin-test.sh`) — acceptance happy path, missing TESTFILE gate, LLM-rejected downgrade, and no-design-md no-op.
- **Integration tests IT-1–IT-4** (`tests/integration/test-assessment-acceptance-flow-test.sh`) — end-to-end flow covering the same four scenarios against the full plugin sourced in a git fixture.

The downgrade event taxonomy added to ADR-022 Amendment v5 covers these two downgrade reasons. No further amendments to this ADR are expected.
