#!/usr/bin/env bash
# tests/unit/stage-summaries-test.sh — a producer marks one output
# `summary: true`; the engine collects completed stages' summaries and injects
# them into every agent prompt (#1976, ADR-055 amendment).
#
# The defect: spec-acceptance writes acceptance-summary.txt — each design SPEC
# line paired against the assertion meant to satisfy it — and never declares it.
# It is the only undeclared output in the tree, so no stage can consume it. What
# reaches the build agent instead is a list of SPEC ids and the word
# "tautological".
#
#   SPEC-1 [change]: manifest_graph_output_summary reads `summary: true`
#   SPEC-2 [guard] : the five-field id|type|source|required|path record is
#                    UNCHANGED — callers unpack path as ${rec##*|} (:117)
#   SPEC-3 [change]: the block renders a completed stage's summary body, in
#                    completion order, annotated with that stage's verdict
#   SPEC-4 [change]: an ADVISORY stage contributes too. This asserted the
#                    opposite until #1986 — the filter existed to hold #1898's
#                    question open, and #1898 is now decided: advisory output
#                    does reach downstream prompts (ADR-040 §4)
#   SPEC-5 [guard] : one entry per stage however many times it ran. ADR-029
#                    exists because per-iteration prompt growth caused three
#                    consecutive 900s max_turns timeouts
#   SPEC-6 [change]: an oversized summary is truncated with an EXPLICIT marker,
#                    so truncation is distinguishable from absence
#   SPEC-7 [guard] : a stage declaring no summary contributes nothing
#   SPEC-8 [change]: injected in _route_redact_prompt BEFORE
#                    apply_scope_redaction, riding the ADR-004 chokepoint
#   SPEC-9 [change]: lint refuses two `summary: true` outputs in one manifest —
#                    "the ONE output offered downstream" must mean one
#  SPEC-10 [change]: a summary output does NOT trip OUTPUT_UNCONSUMED. It IS
#                    consumed — by the engine, into prompts — but by design no
#                    stage declares it, which is exactly the shape that check
#                    was written to reject
#  SPEC-11 [change]: (#2124) the cycle INPUT banner counts the summaries the
#                    next prompt will carry instead of printing "(no feedback —
#                    first iteration)" on every iteration of a cycle that has
#                    no feedback edges (the #1841 misdiagnosis)
#  SPEC-12 [change]: (#2124) injection is evented — prompt.summaries.injected
#                    stages= resolve= bytes= — so a run's events.jsonl proves
#                    what the builder was told
#  SPEC-13 [change]: (#2124) the per-summary cap matches the test stage's own
#                    8192B summary, so the ✗ line at the end of a long
#                    test-failures-summary.md is not the part that is cut
#  SPEC-14 [change]: (#2124) bodies are sanitized (ANSI, stage-io banners) at
#                    the renderer — the one chokepoint every producer crosses
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh" 2>/dev/null || true
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"

print_test_header "stage summaries — declared, collected, injected (#1976)"
setup_test_env "stage-summaries"

unset ZBUILD_STAGE_INPUTS ZBUILD_INPUTS_FLOW 2>/dev/null || true

STATE="$TEST_TEMP_DIR/state"
ART="$STATE/artifacts"
PROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$ART" "$PROOT/tool/ss-gate" "$PROOT/tool/ss-second" \
         "$PROOT/agent/ss-lens" "$PROOT/tool/ss-plain"

# ─── Fixtures ────────────────────────────────────────────────────────────────
# ss-gate  : mechanical, declares a summary  → contributes
# ss-second: mechanical, declares a summary  → contributes (ordering probe)
# ss-lens  : ADVISORY agent, declares one    → must NOT contribute (#1898)
# ss-plain : mechanical, declares none       → contributes nothing
cat > "$PROOT/tool/ss-gate/manifest.yaml" <<'EOF'
id: ss-gate
name: SS Gate
kind: tool
version: 0.0.1
convergence: gate
hooks:
  run: ssg_run
inputs: []
outputs:
  - id: ss_gate_result
    path: ${artifact_dir}/ss-gate-result.json
    type: json
    required: true
    primary: true
  - id: ss_gate_detail
    path: ${artifact_dir}/ss-gate-detail.txt
    type: text
    format: text
    required: false
    summary: true
EOF
printf 'ssg_run() { return 0; }\n' > "$PROOT/tool/ss-gate/plugin.sh"

cat > "$PROOT/tool/ss-second/manifest.yaml" <<'EOF'
id: ss-second
name: SS Second
kind: tool
version: 0.0.1
convergence: gate
hooks:
  run: sss_run
inputs: []
outputs:
  - id: ss_second_result
    path: ${artifact_dir}/ss-second-result.json
    type: json
    required: true
    primary: true
  - id: ss_second_detail
    path: ${artifact_dir}/ss-second-detail.txt
    type: text
    format: text
    required: false
    summary: true
EOF
printf 'sss_run() { return 0; }\n' > "$PROOT/tool/ss-second/plugin.sh"

cat > "$PROOT/agent/ss-lens/manifest.yaml" <<'EOF'
id: ss-lens
name: SS Lens
kind: agent
version: 0.0.1
convergence: advisory
hooks:
  run: ssl_run
inputs: []
outputs:
  - id: ss_lens_result
    path: ${artifact_dir}/ss-lens-result.json
    type: json
    required: true
    primary: true
  - id: ss_lens_detail
    path: ${artifact_dir}/ss-lens-detail.txt
    type: text
    format: text
    required: false
    summary: true
EOF
printf 'ssl_run() { return 0; }\n' > "$PROOT/agent/ss-lens/plugin.sh"

cat > "$PROOT/tool/ss-plain/manifest.yaml" <<'EOF'
id: ss-plain
name: SS Plain
kind: tool
version: 0.0.1
convergence: gate
hooks:
  run: ssp_run
inputs: []
outputs:
  - id: ss_plain_result
    path: ${artifact_dir}/ss-plain-result.json
    type: json
    required: true
    primary: true
EOF
printf 'ssp_run() { return 0; }\n' > "$PROOT/tool/ss-plain/plugin.sh"

_TPL_STAGES=(ss-gate ss-second ss-lens ss-plain)

# Completion order is the KEY ORDER of .stage_statuses — jq preserves insertion
# order, so no separate bookkeeping is needed. ss-second completed before
# ss-gate here deliberately: template order and completion order differ, and the
# block must follow COMPLETION.
cat > "$STATE/pipeline-state.json" <<'EOF'
{
  "schema_version": 1,
  "run_id": "ss-test",
  "stage_statuses": {
    "ss-second": "complete",
    "ss-gate": "failed",
    "ss-lens": "complete",
    "ss-plain": "complete"
  },
  "stage_verdicts": {
    "ss-second": "pass",
    "ss-gate": "fail",
    "ss-lens": "warn",
    "ss-plain": "pass"
  }
}
EOF

printf 'GATE-DETAIL-BODY\n  design : fields live under data\n  asserts: top level\n' \
    > "$ART/ss-gate-detail.txt"
printf 'SECOND-DETAIL-BODY\n' > "$ART/ss-second-detail.txt"
printf 'LENS-DETAIL-BODY\n' > "$ART/ss-lens-detail.txt"

_block() {
    stage_summaries_prompt_block "$STATE/pipeline-state.json" "$PROOT" 2>/dev/null || true
}

# ─── SPEC-1: the marker parses ───────────────────────────────────────────────
print_test_section "1. summary: true is readable via a dedicated accessor"

if declare -F manifest_graph_output_summary >/dev/null 2>&1; then
    assert_eq "[SPEC-1] summary: true is read back" "true" \
        "$(manifest_graph_output_summary "$PROOT/tool/ss-gate/manifest.yaml" ss_gate_detail)"
    assert_eq "[SPEC-1] an output without the marker is empty" "" \
        "$(manifest_graph_output_summary "$PROOT/tool/ss-gate/manifest.yaml" ss_gate_result)"
    assert_eq "[SPEC-1] an unknown output id is empty" "" \
        "$(manifest_graph_output_summary "$PROOT/tool/ss-gate/manifest.yaml" no_such_id)"
else
    assert_fail "[SPEC-1] manifest_graph_output_summary exists" "function not defined"
fi

# ─── SPEC-2: the five-field record is untouched ──────────────────────────────
# manifest-graph.sh:117 warns that appending to this record silently breaks
# input-resolve.sh and cycle-orchestrator.sh, which unpack path as ${rec##*|}.
print_test_section "2. the five-field output record is unchanged"

_rec="$(manifest_graph_get_outputs "$PROOT/tool/ss-gate/manifest.yaml" | grep '^ss_gate_detail|')"
assert_eq "[SPEC-2] record still has exactly 5 fields" "5" \
    "$(printf '%s' "$_rec" | awk -F'|' '{print NF}')"
assert_eq "[SPEC-2] path is still the last field" "\${artifact_dir}/ss-gate-detail.txt" \
    "${_rec##*|}"

# ─── SPEC-3: rendered in completion order, with verdicts ─────────────────────
print_test_section "3. completed stages render in completion order, with verdicts"

OUT_B="$(_block)"
assert_contains "[SPEC-3] the gate's summary body is present" "$OUT_B" "GATE-DETAIL-BODY"
assert_contains "[SPEC-3] the design/assert pairing survives" "$OUT_B" "design : fields live under data"
assert_contains "[SPEC-3] the second stage's body is present" "$OUT_B" "SECOND-DETAIL-BODY"
assert_contains "[SPEC-3] the stage is named" "$OUT_B" "ss-gate"
assert_contains "[SPEC-3] the stage's verdict is annotated" "$OUT_B" "fail"

# Completion order, not template order: ss-second completed first.
_pos_second="$(printf '%s\n' "$OUT_B" | grep -n 'SECOND-DETAIL-BODY' | head -1 | cut -d: -f1)"
_pos_gate="$(printf '%s\n' "$OUT_B" | grep -n 'GATE-DETAIL-BODY' | head -1 | cut -d: -f1)"
if [[ -n "$_pos_second" && -n "$_pos_gate" && "$_pos_second" -lt "$_pos_gate" ]]; then
    assert_pass "[SPEC-3] entries follow completion order, not template order"
else
    assert_fail "[SPEC-3] entries follow completion order, not template order" \
        "second=$_pos_second gate=$_pos_gate (expected second < gate)"
fi

# ─── SPEC-4: advisory stages contribute ──────────────────────────────────────
# #1986 (closes #1898). ADR-040 §5 is untouched: it governs whether a stage may
# BLOCK, and injecting text into a prompt places nothing on a convergence path.
print_test_section "4. an advisory stage contributes (#1898 decided)"

assert_contains "[SPEC-4] the advisory stage's summary is present" \
    "$OUT_B" "LENS-DETAIL-BODY"

# ─── SPEC-5: one entry per stage, however many iterations ────────────────────
print_test_section "5. one entry per stage — no per-iteration accumulation"

assert_eq "[SPEC-5] the gate appears exactly once" "1" \
    "$(printf '%s\n' "$OUT_B" | grep -cF 'GATE-DETAIL-BODY' || true)"

# A re-run rewrites the artifact in place; the block must still yield one entry.
printf 'GATE-DETAIL-BODY\nITER-2-CONTENT\n' > "$ART/ss-gate-detail.txt"
OUT_B2="$(_block)"
assert_eq "[SPEC-5] still exactly one entry after a second iteration" "1" \
    "$(printf '%s\n' "$OUT_B2" | grep -cF 'GATE-DETAIL-BODY' || true)"
assert_contains "[SPEC-5] and it carries the LATEST body" "$OUT_B2" "ITER-2-CONTENT"

# ─── SPEC-6: oversized summaries truncate visibly ────────────────────────────
print_test_section "6. an oversized summary truncates with an explicit marker"

_big="$TEST_TEMP_DIR/big.txt"
awk 'BEGIN{for(i=0;i<4000;i++) print "PADDING-LINE-BODY-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"}' > "$_big"
cp "$_big" "$ART/ss-gate-detail.txt"
OUT_BIG="$(_block)"
_bytes="$(printf '%s' "$OUT_BIG" | wc -c | tr -d ' ')"
assert_contains "[SPEC-6] truncation is announced, not silent" "$OUT_BIG" "truncated"
if [[ "$_bytes" -lt 40000 ]]; then
    assert_pass "[SPEC-6] the block stays bounded (${_bytes}B < 40000B)"
else
    assert_fail "[SPEC-6] the block stays bounded" "block was ${_bytes} bytes"
fi
printf 'GATE-DETAIL-BODY\n' > "$ART/ss-gate-detail.txt"

# ─── SPEC-7: a non-declaring stage contributes nothing ───────────────────────
print_test_section "7. a stage declaring no summary contributes nothing"

OUT_B3="$(_block)"
if grep -qE '(^|[^-])ss-plain' <<< "$OUT_B3"; then
    assert_fail "[SPEC-7] a non-declaring stage is absent from the block" \
        "ss-plain appeared despite declaring no summary output"
else
    assert_pass "[SPEC-7] a non-declaring stage is absent from the block"
fi

# A run where NO stage declares a summary must render nothing at all, so a
# non-adopting repo's prompts stay byte-identical.
cat > "$TEST_TEMP_DIR/empty-state.json" <<'EOF'
{"schema_version":1,"stage_statuses":{"ss-plain":"complete"},"stage_verdicts":{"ss-plain":"pass"}}
EOF
assert_eq "[SPEC-7] no declaring stage → empty block" "" \
    "$(stage_summaries_prompt_block "$TEST_TEMP_DIR/empty-state.json" "$PROOT" 2>/dev/null || true)"

# ─── SPEC-8: injected before redaction ───────────────────────────────────────
# Proven behaviourally: a stub apply_scope_redaction snapshots the prompt file at
# the moment it is called. If the marker is in that snapshot, injection happened
# first and the block rides the ADR-004 chokepoint rather than bypassing it.
print_test_section "8. injected before apply_scope_redaction (ADR-004 chokepoint)"

# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh" 2>/dev/null || true

if declare -F _route_redact_prompt >/dev/null 2>&1; then
    SNAP="$TEST_TEMP_DIR/redaction-snapshot.txt"
    apply_scope_redaction() { cp "$1" "$SNAP" 2>/dev/null; cp "$1" "$2" 2>/dev/null; return 0; }

    IN="$TEST_TEMP_DIR/prompt.txt"; OUT="$TEST_TEMP_DIR/prompt.out"
    printf 'ORIGINAL PROMPT BODY\n' > "$IN"
    ZBUILD_STATE_DIR="$STATE" ZBUILD_PLUGINS_ROOT="$PROOT" \
        ZBUILD_SCOPE_MANIFEST="$PROOT/tool/ss-gate/manifest.yaml" \
        _route_redact_prompt "$IN" "$OUT" 0 "" >/dev/null 2>&1 || true

    assert_contains "[SPEC-8] the funnel injects the block" "$(cat "$IN" 2>/dev/null)" \
        "STAGE SUMMARIES"
    assert_contains "[SPEC-8] and it was present BEFORE redaction ran" \
        "$(cat "$SNAP" 2>/dev/null)" "STAGE SUMMARIES"
    assert_contains "[SPEC-8] the original prompt body survives" "$(cat "$IN" 2>/dev/null)" \
        "ORIGINAL PROMPT BODY"

    # Idempotent: the agentic loop redacts the same file once per iteration.
    ZBUILD_STATE_DIR="$STATE" ZBUILD_PLUGINS_ROOT="$PROOT" \
        ZBUILD_SCOPE_MANIFEST="$PROOT/tool/ss-gate/manifest.yaml" \
        _route_redact_prompt "$IN" "$OUT" 1 "" >/dev/null 2>&1 || true
    assert_eq "[SPEC-8] exactly one block after a second pass (idempotent)" "1" \
        "$(grep -cF 'STAGE SUMMARIES' "$IN" 2>/dev/null || true)"

    unset -f apply_scope_redaction 2>/dev/null || true
else
    assert_fail "[SPEC-8] _route_redact_prompt is available" "function not defined"
fi

# ─── SPEC-9: at most one summary per manifest ────────────────────────────────
# Mirrors the exactly-one-`primary` rule (lint-contract.sh:177). Two summaries
# would make "the stage's summary" ambiguous and the renderer's first-wins scan
# order-dependent.
print_test_section "9. lint refuses two summary outputs in one manifest"

LINTDIR="$TEST_TEMP_DIR/lintfix/plugins/tool/ss-double"
mkdir -p "$LINTDIR"
cat > "$LINTDIR/manifest.yaml" <<'EOF'
id: ss-double
name: SS Double
kind: tool
version: 0.0.1
convergence: gate
hooks:
  run: ssd_run
inputs:
  - id: gh_issue_body
    source: external
    required: true
outputs:
  - id: ss_double_result
    path: ${artifact_dir}/ss-double-result.json
    type: json
    required: true
    primary: true
    summary: true
  - id: ss_double_detail
    path: ${artifact_dir}/ss-double-detail.txt
    type: text
    required: false
    summary: true
EOF
printf 'ssd_run() { return 0; }\n' > "$LINTDIR/plugin.sh"

_lint_out="$(ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/lintfix/plugins" \
    bash "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>&1 || true)"
assert_contains "[SPEC-9] two summary outputs are reported" "$_lint_out" "summary: true"
assert_contains "[SPEC-9] the offending manifest is named" "$_lint_out" "ss-double"

# ─── SPEC-10: a summary is consumed, just not by a declared input ────────────
# OUTPUT_UNCONSUMED (ADR-020) rejects an output no `inputs:` names, offering
# `terminal: true` or `advisory: true` as the escapes. Neither fits: the summary
# is not a pipeline terminus, and `advisory` means "not consumed by stages"
# (#1750) — which is false, the engine consumes it. Without this, declaring a
# summary would be impossible without mislabelling it.
print_test_section "10. a summary output does not trip OUTPUT_UNCONSUMED"

UNCDIR="$TEST_TEMP_DIR/uncfix/plugins/tool/ss-unc"
mkdir -p "$UNCDIR"
cat > "$UNCDIR/manifest.yaml" <<'EOF'
id: ss-unc
name: SS Unconsumed
kind: tool
version: 0.0.1
convergence: gate
hooks:
  run: ssu_run
inputs:
  - id: gh_issue_body
    source: external
    required: true
outputs:
  - id: ss_unc_result
    path: ${artifact_dir}/ss-unc-result.json
    type: json
    required: true
    primary: true
    terminal: true
  - id: ss_unc_detail
    path: ${artifact_dir}/ss-unc-detail.txt
    type: text
    required: false
    summary: true
EOF
printf 'ssu_run() { return 0; }\n' > "$UNCDIR/plugin.sh"

_unc_out="$(ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/uncfix/plugins" ZBUILD_LINT_UNCONSUMED=1 \
    bash "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>&1 || true)"
if grep -qF "ss_unc_detail" <<< "$_unc_out"; then
    assert_fail "[SPEC-10] a summary output is exempt from OUTPUT_UNCONSUMED" \
        "the summary was reported as unconsumed"
else
    assert_pass "[SPEC-10] a summary output is exempt from OUTPUT_UNCONSUMED"
fi

# ─── SPEC-11: the banner counts summaries (#2124) ────────────────────────────
# #1841: the job log printed "(no feedback — first iteration)" on every
# iteration and the run was misread as "the builder never got the findings".
# The banner reports feedback EDGES; simple.yaml's cycle has none since #1979,
# and the findings travel as summaries. Count what actually ships.
print_test_section "11. the cycle banner counts summaries, not edges (#2124)"

printf 'GATE-DETAIL-BODY\n' > "$ART/ss-gate-detail.txt"
if declare -F stage_summaries_count >/dev/null 2>&1; then
    assert_eq "[SPEC-11] stage_summaries_count → '<stages> <resolve>'" "3 1" \
        "$(stage_summaries_count "$STATE/pipeline-state.json" "$PROOT" 2>/dev/null || true)"
    assert_eq "[SPEC-11] no declaring stage → '0 0'" "0 0" \
        "$(stage_summaries_count "$TEST_TEMP_DIR/empty-state.json" "$PROOT" 2>/dev/null || true)"
else
    assert_fail "[SPEC-11] stage_summaries_count exists" "function not defined"
fi

# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh" 2>/dev/null || true
if declare -F _cycle_render_feedback_digest >/dev/null 2>&1; then
    _CYCLE_TRAP_CYCLE_ID="build_test_cycle"
    _CYCLE_FEEDBACK=()
    _dig="$(ZBUILD_PLUGINS_ROOT="$PROOT" _cycle_render_feedback_digest 2 "$STATE" 2>/dev/null || true)"
    assert_contains "[SPEC-11] iter 2, no edges: banner names the summary count" "$_dig" "3 stage summaries"
    assert_contains "[SPEC-11] …and how many are framed RESOLVE" "$_dig" "1 RESOLVE"
    if [[ "$_dig" == *"first iteration"* ]]; then
        assert_fail "[SPEC-11] iter 2 must not claim 'first iteration'" "$_dig"
    else
        assert_pass "[SPEC-11] iter 2 does not claim 'first iteration'"
    fi
    mkdir -p "$TEST_TEMP_DIR/empty-state"; cp "$TEST_TEMP_DIR/empty-state.json" "$TEST_TEMP_DIR/empty-state/pipeline-state.json"
    _dig0="$(ZBUILD_PLUGINS_ROOT="$PROOT" _cycle_render_feedback_digest 2 "$TEST_TEMP_DIR/empty-state" 2>/dev/null || true)"
    assert_contains "[SPEC-11] iter 2 with nothing to ship says so" "$_dig0" "no stage summaries"
    _dig1="$(ZBUILD_PLUGINS_ROOT="$PROOT" _cycle_render_feedback_digest 1 "$STATE" 2>/dev/null || true)"
    assert_contains "[SPEC-11] iter 1 keeps the first-iteration wording" "$_dig1" "first iteration"
else
    assert_fail "[SPEC-11] _cycle_render_feedback_digest is available" "function not defined"
fi

# ─── SPEC-12: injection is evented (#2124) ───────────────────────────────────
print_test_section "12. prompt.summaries.injected names what shipped (#2124)"

if declare -F _route_redact_prompt >/dev/null 2>&1; then
    apply_scope_redaction() { cp "$1" "$2" 2>/dev/null; return 0; }
    export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events-12"; mkdir -p "$ZBUILD_EVENTS_DIR"
    export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
    IN12="$TEST_TEMP_DIR/prompt12.txt"; OUT12="$TEST_TEMP_DIR/prompt12.out"
    printf 'PROMPT\n' > "$IN12"
    ZBUILD_STATE_DIR="$STATE" ZBUILD_PLUGINS_ROOT="$PROOT" ZBUILD_CURRENT_STAGE="build" \
        ZBUILD_SCOPE_MANIFEST="$PROOT/tool/ss-gate/manifest.yaml" \
        _route_redact_prompt "$IN12" "$OUT12" 0 "" >/dev/null 2>&1 || true
    assert_event_emitted "[SPEC-12] prompt.summaries.injected is emitted" "$ZBUILD_EVENTS_JSONL" "prompt.summaries.injected"
    _ev12="$(jq -c 'select(.type=="prompt.summaries.injected")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"
    assert_contains "[SPEC-12] it counts the stages shipped" "$_ev12" '"stages":"3"'
    assert_contains "[SPEC-12] it counts the RESOLVE framings" "$_ev12" '"resolve":"1"'
    assert_contains "[SPEC-12] it names the consuming stage" "$_ev12" '"stage":"build"'
    assert_contains_regex "[SPEC-12] it carries the block size" "$_ev12" '"bytes":"[1-9][0-9]*"'
    # A second pass on the same file injects nothing and must not re-event.
    ZBUILD_STATE_DIR="$STATE" ZBUILD_PLUGINS_ROOT="$PROOT" ZBUILD_CURRENT_STAGE="build" \
        ZBUILD_SCOPE_MANIFEST="$PROOT/tool/ss-gate/manifest.yaml" \
        _route_redact_prompt "$IN12" "$OUT12" 0 "" >/dev/null 2>&1 || true
    assert_eq "[SPEC-12] exactly one event across two passes (idempotent with the block)" "1" \
        "$(grep -c 'prompt.summaries.injected' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
    assert_contains "[SPEC-12] the event is registered in config/event-schema.json" \
        "$(cat "$REPO_ROOT/config/event-schema.json")" '"prompt.summaries.injected"'
    unset -f apply_scope_redaction 2>/dev/null || true
else
    assert_fail "[SPEC-12] _route_redact_prompt is available" "function not defined"
fi

# ─── SPEC-13: per-summary cap = 8192 (#2124) ─────────────────────────────────
# The test stage writes up to 8192B and puts the extracted ✗ lines LAST; a
# 4096B per-summary cap cuts exactly the part the builder needs.
print_test_section "13. a 6000B summary ships whole (#2124)"

awk 'BEGIN{for(i=0;i<100;i++) print "PADDING-LINE-BODY-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"; print "TAIL-LINE-SURVIVES"}' > "$ART/ss-gate-detail.txt"
_sz13="$(wc -c < "$ART/ss-gate-detail.txt" | tr -d ' ')"
assert_gt "[SPEC-13] fixture is over 4096B" "$_sz13" "4096"
OUT13="$(env -u ZBUILD_SUMMARY_MAX_BYTES bash -c 'source "$0/core/pipeline/input-resolve.sh"; stage_summaries_prompt_block "$1" "$2"' "$REPO_ROOT" "$STATE/pipeline-state.json" "$PROOT" 2>/dev/null || true)"
assert_contains "[SPEC-13] the last line of a 6000B summary reaches the prompt" "$OUT13" "TAIL-LINE-SURVIVES"
printf 'GATE-DETAIL-BODY\n' > "$ART/ss-gate-detail.txt"

# ─── SPEC-14: bodies are sanitized at the chokepoint (#2124) ─────────────────
# #1841's test-failures-summary.md carried the ✗ lines with their ANSI colour
# codes; #721's sanitizer lived in the readers this item retires. The renderer
# is the one place every producer passes through, so it strips there.
print_test_section "14. summary bodies reach the prompt without ANSI or banners (#2124)"

_ESC14=$''
printf '%s
' "${_ESC14}[31mRED-BODY-LINE${_ESC14}[0m" "══ NESTED-BANNER-LINE ══" "PLAIN-BODY-LINE" > "$ART/ss-gate-detail.txt"
OUT14="$(_block)"
assert_eq "[SPEC-14] no ESC bytes in the block" "0" "$(printf '%s' "$OUT14" | LC_ALL=C tr -cd "$_ESC14" | wc -c | tr -d ' ')"
assert_contains "[SPEC-14] the coloured line's text survives" "$OUT14" "RED-BODY-LINE"
assert_contains "[SPEC-14] plain text survives" "$OUT14" "PLAIN-BODY-LINE"
if [[ "$OUT14" == *"NESTED-BANNER-LINE"* ]]; then
    assert_fail "[SPEC-14] a stage-io banner line is dropped" "banner present"
else
    assert_pass "[SPEC-14] a stage-io banner line is dropped"
fi
printf 'GATE-DETAIL-BODY\n' > "$ART/ss-gate-detail.txt"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
