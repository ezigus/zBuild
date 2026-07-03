# ADR-028 — Shared LLM-agent stage framework

**Status:** Proposed (2026-06-11)
**Supersedes:** N/A (formalizes pattern across ADR-018, ADR-020, ADR-022)

## Context

Each LLM-driven agent plugin (`plan`, `impact`, `review`, `test_assessment`) was implemented independently. Each reimplements:

- OUTPUT CONTRACT prompt block (different phrasings: `OUTPUT CONTRACT` vs `Output contract:` vs inline `Your FINAL response must be...`)
- JSON envelope parser (`extract_first_json_object` vs `extract_json_and_surrounding_prose`)
- Schema validator (per-stage `jq -e` expressions written separately)
- Error event class (`impact.contract.violation` vs generic `plugin.run.error reason=schema_violation`)
- Recovery path (defensive fence stripping, prose-around-envelope handling, etc.)

This created bugs that hit each stage differently:

- `impact` was hardened across PRs #767/#771/#774/#783 with FORBIDDEN list + FINAL RULE — `test_assessment` had the same drift class unprotected, producing the `Now I have all the information I need.` postamble and the unescaped-quote JSON parse failure (dogfood `20260611072619-15296`).
- `_router_rc_classify` from PR #788 was integrated into `impact` plugin only; `plan`/`review`/`test_assessment` got the same `rc=124 → verdict=fail` mis-classification.
- `impact`'s prompt grew 4× redundant across patches; the model gets confused by repetition (decreasing contract-violation prose lengths but never reaching zero).

Patches accrete without consolidation: every fix appends; nothing subtracts. Over time prompts become incoherent.

## Decision

Extract a shared framework at `scripts/lib/llm-agent-stage.sh` that owns the cross-cutting concerns. Each agent plugin becomes a declarative bundle of stage-specific knowledge.

### Framework surface

```bash
# Render the canonical OUTPUT CONTRACT block for a stage.
# Verdict vocab + schema fields parameterize per-stage; FORBIDDEN list,
# FINAL RULE, and the "begins with `{`" rules come from the framework.
_llm_output_contract \
    --stage <name> \
    --verdicts "verdict1,verdict2,..." \
    --schema-json <inline-schema> \
    --markdown-fields "field1,field2,..."

# Parse an LLM response into JSON + prose-around-envelope.
# Single source of truth: handles prefix prose, postfix prose, fences,
# common-escape-error repair.
_llm_envelope_parse <raw_response> <json_var> <prose_var>

# Validate against schema with diagnostic-rich errors.
# Distinguishes parse failure (with column + context) from structural failure.
_llm_envelope_validate <json_text> <schema_expr> <error_var>

# Single error event class with structured reason codes.
_llm_emit_violation <stage> <reason> <prose_length> <sidecar_path>

# Classify router rc → (verdict, reason) — wraps PR #788's helper.
_llm_router_classify <rc> <verdict_var> <reason_var>
```

### Per-stage declaration

Each plugin becomes a thin shell that calls the framework with stage-specific config:

```bash
# plugins/agent/impact/plugin.sh (~30 lines, down from ~300)
_impact_run_inner() {
    local prompt
    prompt="$(_llm_output_contract \
        --stage impact \
        --verdicts "complete,incomplete,error" \
        --schema-json "$IMPACT_SCHEMA" \
        --markdown-fields "impact_feedback_md")"
    prompt+="$plan_content"

    # ... apply_scope_redaction unchanged ...
    raw="$(route_to_model T1 "$prompt")"; rc=$?

    local verdict reason
    _llm_router_classify "$rc" verdict reason
    [[ "$verdict" == "error" ]] && { write impact.json with error; return 0; }

    local json prose
    _llm_envelope_parse "$raw" json prose
    [[ -n "$prose" ]] && _llm_emit_violation impact contract_violation "${#prose}" "$sidecar"

    local err
    if ! _llm_envelope_validate "$json" "$IMPACT_SCHEMA_EXPR" err; then
        emit_event "plugin.run.error" "plugin=impact" "reason=$err"
        return 1
    fi
    # ... impact-specific post-processing (prefilter merge, etc.) ...
}
```

### Migration strategy

One plugin at a time, lowest-risk first. Each PR is a single-plugin migration with full TDD coverage:

1. `plan` → framework migration (lowest contract complexity)
2. `review` → framework migration
3. `test_assessment` → framework migration (folds in the unescaped-quote fix from ADR-022 v2)
4. `impact` → framework migration (last; folds in the consolidation of accreted bloat)

Each migration adds the verdict vocab, schema fields, and markdown-fields metadata to the per-stage manifest so future linters can validate "every plugin's prompt matches the canonical contract."

## Consequences

**Wins:**

- Single fix per cross-cutting bug. The next "model emits postamble" report fixes all 4 stages, not just one.
- Prompt consolidation forced: framework owns the canonical form, plugins can't accrete redundancy.
- Test surface collapses: framework-level tests cover the contract; plugins test their stage-specific logic only.

**Costs:**

- Migration is N=4 PRs of careful TDD work
- Framework is ~250 lines new code with significant test coverage required
- Per-stage declarative config is a new pattern operators learn

**Validation:**

- Re-dogfood after migration: `impact.contract.violation` rate should approach 0 across all stages (currently ~3/run on impact, untracked on others)
- Prompt byte size for each stage: target ≤ 60 lines of static contract (impact is currently ~100)

## Alternatives considered

**Keep one-off patches:** simpler in the short term, but each fix multiplies maintenance burden by N plugins. We've already done this 4 times for impact alone (#767/#771/#774/#783).

**Replace agent plugins with a single generic agent stage:** more invasive; per-stage business logic (impact's prefilter, test_assessment's diff-numstat-vs-build-claim) doesn't fit a single-stage abstraction. Framework + per-stage bundles is the right granularity.

## Status: Proposed → Accepted when implemented

This ADR is accepted in principle; the implementation lands incrementally via the 4 migration PRs. Each migration PR cites this ADR + the specific stage ADR (ADR-018, ADR-022, etc.) being affected.

## Implementation Notes

Migration is staged across 4 PRs, one plugin per PR:

1. **Framework foundation** — `scripts/lib/llm-agent-stage.sh` with the 5 helpers (`_llm_output_contract`, `_llm_envelope_parse`, `_llm_envelope_validate`, `_llm_emit_violation`, `_llm_router_classify`). Comprehensive unit tests; no plugin migration in this PR.
2. **Migrate `plan`** — thinnest stage, lowest risk. Validates the framework contract end-to-end via existing plan-plugin tests.
3. **Migrate `review`** — similar shape to plan. Adds review-specific verdict vocab (`approve|request_changes|block`).
4. **Migrate `test_assessment`** — folds in ADR-022 v2's parse-vs-structure distinction and JSON-string escape requirement.
5. **Migrate `impact`** — last because it has the most accumulated complexity (FORBIDDEN list, FINAL RULE, prefilter integration, contract violation events). Consolidates impact's ~100-line prompt into the framework's ~50-line canonical form.

Each migration PR cites this ADR + the relevant per-stage ADR. Re-dogfood after each migration to measure `*.contract.violation` rate reduction.

---

## Amendment v1.1 (2026-06-11) — foundation PR scope clarification

After multi-agent design synthesis for PR #798 (the framework foundation PR), the following scope clarifications were made:

**File path:** `scripts/lib/llm-agent.sh` (NOT `llm-agent-stage.sh` as the original ADR proposed). The renamed file makes Pattern 1 scope explicit; Pattern 2 (build's loop-with-sentinel) remains separate.

**Escape-repair deferred to v2.** The multi-agent critique flagged in-shim mutation as risky; v1 ships fail-soft (parse error with column + 40-char context, no automatic repair). The ADR-022 dogfood payload (column 3208) is the v2 regression target. Until v2, the cycle's existing feedback loop carries the diagnostic to the next iter's plan/build prompt.

**`_llm_with_json_output` added as a 6th helper.** Pattern 1 stages all save/restore `ZBUILD_ROUTER_JSON_OUTPUT` around `route_to_model`; the helper consolidates that boilerplate (ADR-018 §330-345).

**`_llm_emit_violation` event class is positional, not env.** Original sketch used `_LLM_VIOLATION_EVENT_TYPE` env var; that risks cross-invocation leak. Positional arg per call.

**`--verdicts none` semantics codified.** When a stage's response has no `.verdict` field (plan emits raw plan.json), the contract MUST omit the verdict enum line AND the schema validator MUST NOT assert `.verdict`. This decouples the helper from the verdict-bearing assumption.

**Per-stage OUTPUT CONTRACT goldens.** Each migration PR (2-5) adds a `tests/golden/llm-contract/<stage>-output-contract.golden` byte-pinning the rendered block. Catches accidental contract drift during future patches.

**Renderer interop integration test required as foundation gate.** `_llm_envelope_parse` MUST produce byte-identical splits with `_artifact_split_prose_json` (artifact-render.sh) — guards #510 llm-comment rendering against parser drift.

---

## Amendment v1.2 (2026-07-03) — generalized schema-aware envelope recovery (#944)

**Context.** `extract_json_and_surrounding_prose` (and its sibling `extract_first_json_object`) is LAST-wins: it returns the LAST top-level balanced object in the raw response. This defends against brace-bearing *preamble* examples but fails when the model emits its real envelope FIRST and appends a brace-bearing *postamble*. `impact` (#908) and `plan` (#1052) already have stage-local recovery helpers (`_impact_recover_envelope_json`, `_plan_recover_envelope_json`). `review`, `test_assessment`, and `security-lens` carried no equivalent protection.

**Decision.** Add `_llm_recover_envelope_json` to `scripts/lib/llm-agent.sh` as the framework-level generalization of the impact-local and plan-local patterns. The generalization is that the per-stage schema gate is a passed function name (`$2`) rather than a hardcoded per-stage check, so future stages inherit recovery at zero cost.

Add `--schema-gate <func>` to `_llm_envelope_parse`. When provided and the LAST-wins result fails the gate, `_llm_recover_envelope_json` scans every top-level balanced object (same awk brace-grammar) and recovers only when exactly one passes the gate. Ambiguous cases (≥2 passers or 0 passers) return the LAST-wins result unchanged so the caller's existing schema-violation path fires — **fail-closed-on-ambiguity is preserved**.

**Per-stage gates added:**
- `_review_envelope_schema_ok` — type==object, schema_version==1, verdict in {approve,request_changes,block}, confidence number, issues array
- `_test_assessment_envelope_schema_ok` — type==object, schema_version==1, verdict in {pass,fail,error,inconclusive}, summary string, required_changes array, agrees_with_build_complete boolean
- `_security_lens_envelope_schema_ok` — type==object, findings array (no schema_version in LLM response for this stage)

**Migration.** `review`, `test_assessment`, and `security-lens` are migrated to call `_llm_envelope_parse --schema-gate` in place of their prior `extract_first_json_object` calls. `impact` and `plan` retain their stage-local helpers by design — they are not migrated.

**Invariant.** The exactly-one-gate-bearer rule (≥2 passers → fail closed) applies to all stages regardless of whether they use `schema_version` in their gate. Stage-specific gate logic encodes what uniquely identifies a valid envelope for that stage.
