# ADR-060: Stages return structure; the engine renders prose

**Status:** Accepted (2026-08-28)
**Date:** 2026-08-28
**Amends:** ADR-028 (§ output contract — the `--markdown-fields` escaping block and its retired ADR-022 citation)
**Related:** ADR-001 (plugin contract — event namespacing, `provides.events`), ADR-015 (stage-io capture), ADR-018 (envelope parse, LAST-wins), ADR-020/ADR-055 (inter-stage data contract), ADR-054 (stage contract), ADR-021 (cycle semantics — the re-iterate path this reuses)

## Context

Run 32886190954 (issue #1833) aborted 24 minutes in with:

```
✗ _impact_run_inner: impact.json schema violation (requires schema_version=1,
  verdict ∈ {complete,incomplete,error}, missing[], impact_feedback_md string)
```

Every condition that message names was satisfied. The model had written `done\_sentinel` — twice — inside `impact_feedback_md`, backslash-escaping an underscore the way markdown requires. `\_` is not a legal JSON escape, so `jq` refused to parse the object at all, and the gate reported the only failure it knew how to describe.

The run's own stage-io artifact settles what happened. An escape census of the reply: `\"` ×16 valid, `\n` ×10 valid, `\_` ×2 invalid. A round-trip or encoding fault would have corrupted the quotes and newlines too; it did not. The engine's storage wrote `\\_` — correctly escaped — and the wrapper parses cleanly. The malformation was the model's own, and removing exactly those two characters (leaving `schema_version: 1` untouched) makes the gate pass.

Three things made this an architecture problem rather than a typo:

**The prose was redundant.** The reply carried one finding twice — `missing[]` (758 bytes, structured) and `impact_feedback_md` (1545 bytes, the same finding as prose). The larger, redundant half is the half that broke.

**Nothing consumed it.** No plugin declared `impact_feedback_md` as an input. `design_verify_cycle` wires `design-gate.design_gate_feedback → design.design_gate_feedback`; impact is not even a stage in that cycle. The field cost tokens and a run to produce a file nothing read.

**It was not the first time.** #767 (prose preamble), #774 (prompt incompleteness), #783 (postamble), #908 (LAST-wins misselection) are four prior fixes to the same seam, each treating a symptom. The common root is asking a text generator to hand-serialize a markdown document into a JSON string — a task where every backtick, quote, newline, and underscore is a chance to break the envelope.

The stage that never had this problem shows the alternative: `design` tells the model to write `design.md` to a path. It hand-writes no JSON, and it has never hit this class.

## Decision

### 1. Stage → engine: JSON, always

A parsed response envelope carries structured data only. A stage MUST NOT declare a field whose value is a markdown *document*.

### 2. Stage → stage: JSON

Cycle feedback is structured. A downstream LLM consumer reads `missing[]` as well as it reads prose — prose was never required for the machine or the model, only for the human reading a log.

### 3. Engine → human: rendered

Human-readable output is produced by `scripts/lib/artifact-render.sh` from the JSON. `render_impact_md` builds its narrative from `missing[]`; `render_plan_md` and `render_review_report_md` already worked this way. The model authors data; the engine authors presentation.

### 4. Carve-out: a markdown artifact that IS the deliverable

A stage may produce a markdown document when the document is the product — `design.md`. It is written to a **file**, never embedded in an envelope field.

### 5. The line: short plain text is data, documents are not

This distinction is load-bearing and must not be read more broadly than it is written:

| Keep | Ban |
|---|---|
| `reason`, `message`, `summary`, `description`, `evidence` — short plain-text fields inside structured objects | A multi-paragraph markdown *document* as a string field |

`missing[].reason` and `missing[].evidence` are data and stay. `impact_feedback_md` was a document and goes. A field with no home is the pressure that recreates blobs — when a fact does not fit, add a slot for it (this ADR adds `missing[].evidence`), never a free-text dumping ground.

### 6. A malformed reply is re-asked, never repaired

The engine MUST NOT rewrite what a model returned. Stripping an illegal escape guesses at intent and fabricates data that no model produced.

A malformed envelope is a transient failure of the same class as a router timeout, and takes the same treatment (#892/#937, ADR-021): write `verdict=incomplete` with a `reason`, emit the diagnostic event, return rc=0, and let the cycle re-run the stage. `design_verify_cycle` is `max_iterations: 3, on_max: continue`, so the retry is bounded and an unconverged verdict still falls through to the operator.

### 7. A rejection says which check failed

`_llm_envelope_classify <json> [<gate>]` returns exactly one of `unparseable` | `schema` | `ok`, and `_llm_envelope_parse_error` surfaces jq's real complaint instead of discarding it through `2>/dev/null`.

The pre-existing message printed a fixed list of five requirements and identified none of them. During a week of migrating a *different* version number (`result_contract: 1 → 2`, #1819), "requires schema_version=1" read as a contract-version mismatch. The two numbering systems are unrelated — `schema_version` is the impact envelope's own format and has been 1 since June — but nothing in the error said so. A diagnostic that cannot distinguish "this is not JSON" from "this JSON is wrong" costs more than the bug it reports.

## Consequences

- `impact_feedback_md` is removed from the impact schema, manifest, gate, and fallbacks. The `impact_feedback.md` output is deleted. Legacy envelopes that still carry the field (artifacts restored from a prior run's state branch) parse and are ignored, never rendered.
- `--markdown-fields` has no remaining caller. The ADR-028 escaping block it gates is now unreachable; it cited ADR-022, which has been **Retired** since #979 — a live prompt quoting a retired ADR as its authority.
- Stages still carrying free text stay in scope for follow-up: `plan.notes` is declared "optional caveats; empty string if none" and returned 1246 bytes of numbered prose in this same run — wrong by drift rather than design. `monitor.summary` is declared one-line and is unverified against real runs.
- Nothing enforces §1 yet. Until a lint fails a schema that declares a markdown-document field, this ADR is a habit rather than a rule, and the next stage added will reintroduce the blob without its author being wrong.

## Implementation Notes

The rule lands in three places, and none of them is the router. `core/router/route.sh` is shared with stages that legitimately return non-JSON — `design` writes `design.md` through the model's Write tool and returns prose — so a JSON gate there would break the one stage that already gets this right. The seam is the Pattern-1 envelope path in `scripts/lib/llm-agent.sh`.

Two helpers are added there:

- `_llm_envelope_classify <json> [<gate>]` → `unparseable` | `schema` | `ok`
- `_llm_envelope_parse_error <json>` → jq's own message, flattened and clamped to 300 chars

`_llm_envelope_parse_error` captures in full and trims in bash rather than piping to `head`: a bare `| head` is banned in `scripts/`, `core/`, and `plugins/` as a SIGPIPE hazard (`tests/unit/sigpipe-antipattern-guard-test.sh`, #1886), and that guard caught the first draft of this function.

`impact` still parses through its own `_impact_recover_envelope_json` rather than the shared `_llm_envelope_parse`. That duplication is real and predates this ADR — the same brace-scanning grammar exists three times (`impact-prefilter.sh`, `plan-context.sh`, `llm-agent.sh`), each commented as mirroring the others. Collapsing them is follow-up work; §6 and §7 are wired into impact's own gate-failure path in the meantime.

`impact.envelope.malformed` is declared in `plugins/agent/impact/manifest.yaml` under `provides.events`, in the plugin's own namespace per ADR-001. The first draft named it `llm.envelope.malformed`, which the #1717 event-declaration audit rejected — correctly, since the emitting plugin owns the namespace.

Verification:

```bash
bash tests/unit/artifact-render-impact-test.sh              # narrative built from missing[]
bash tests/unit/impact-envelope-recovery-test.sh            # gate + classifier, #1833 payload as fixture
bash plugins/agent/impact/tests/impact-prompt-contract-test.sh
bash tests/integration/impact-pipeline-test.sh              # no sidecar is written
bash tests/integration/design-impact-cycle-integration-test.sh
bash tests/integration/impact-router-timeout-782-test.sh    # structured re-iterate signal
npm run test:unit && npm run lint
```

The #1833 reply is a permanent fixture: an envelope carrying `done\_sentinel` must classify as `unparseable`, not `schema`. Before this ADR it aborted the pipeline and reported a version requirement it had actually met.
