#!/usr/bin/env bash
# tests/unit/summary-retire-wiring-test.sh — one path for stage feedback (#1979).
#
# Before #1976 every consumer of another stage's output paid for it twice: a
# `feedback:` wire in each template, and a bespoke reader in the plugin
# (_build_read_prior_gate, _design_read_design_gate_feedback). Two consumers,
# two readers, and a third would have cost a third.
#
# #1977 marked gate_feedback `summary: true` while its wire was still in place,
# so the same content would reach the build prompt TWICE — once framed "resolve
# every finding above", once framed "context, not instruction". Contradictory
# framing of identical text is worse than either alone. This retires the wires
# and the readers, and moves the imperative framing into the collector where it
# applies to any failing gate rather than to two hand-named ones.
#
#   SPEC-1 [change]: a FAILED stage's summary is framed as findings to resolve,
#                    not as passive context — the imperative the wired path
#                    carried must not be lost with the wire
#   SPEC-2 [guard] : a PASSED stage's summary stays plain context
#   SPEC-3 [change]: both bespoke readers are gone
#   SPEC-4 [change]: both retired wires are gone from both templates, and no
#                    inert declaration is left behind (the #1865/#1898 lesson)
#   SPEC-5 [guard] : design's self-feedback wire SURVIVES — it carries design's
#                    own prior output for refinement, not another stage's
#                    summary, and nothing here replaces it
#   SPEC-6 [guard] : no prompt section still cross-references a heading that no
#                    longer exists
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

print_test_header "retire the hand-plumbed feedback wiring (#1979)"
setup_test_env "summary-retire-wiring"

STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"; PROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$ART" "$PROOT/tool/rw-gate"

cat > "$PROOT/tool/rw-gate/manifest.yaml" <<'EOF'
id: rw-gate
name: RW Gate
kind: tool
version: 0.0.1
convergence: gate
hooks:
  run: rwg_run
inputs: []
outputs:
  - id: rw_gate_result
    path: ${artifact_dir}/rw-gate-result.json
    type: json
    required: true
    primary: true
  - id: rw_gate_detail
    path: ${artifact_dir}/rw-gate-detail.txt
    type: text
    required: false
    summary: true
EOF
printf 'rwg_run() { return 0; }\n' > "$PROOT/tool/rw-gate/plugin.sh"
_TPL_STAGES=(rw-gate)
printf 'GATE-FINDINGS-BODY\n' > "$ART/rw-gate-detail.txt"

_state_with_verdict() {
    cat > "$STATE/pipeline-state.json" <<EOF
{"schema_version":1,"stage_statuses":{"rw-gate":"$1"},"stage_verdicts":{"rw-gate":"$2"}}
EOF
    stage_summaries_prompt_block "$STATE/pipeline-state.json" "$PROOT" 2>/dev/null || true
}

# ─── SPEC-1 / SPEC-2: framing follows the verdict ────────────────────────────
print_test_section "1. a failed stage's summary is framed as findings to resolve"

FAILED_BLOCK="$(_state_with_verdict failed fail)"
assert_contains "[SPEC-1] the failing stage's body is present" "$FAILED_BLOCK" "GATE-FINDINGS-BODY"
# Case-insensitive: the requirement is that the framing is imperative, not that
# it is shouted.
if grep -qiF 'resolve' <<< "$FAILED_BLOCK"; then
    assert_pass "[SPEC-1] and it is framed as something to resolve"
else
    assert_fail "[SPEC-1] and it is framed as something to resolve" \
        "no imperative framing on a failed stage"
fi
assert_contains "[SPEC-1] naming the stage that must be satisfied" "$FAILED_BLOCK" "rw-gate"

print_test_section "2. a passing stage's summary stays plain context"

PASS_BLOCK="$(_state_with_verdict complete pass)"
assert_contains "[SPEC-2] the passing stage's body is still present" "$PASS_BLOCK" "GATE-FINDINGS-BODY"
if grep -qiF 'resolve every finding' <<< "$PASS_BLOCK"; then
    assert_fail "[SPEC-2] a passing stage is not framed as findings" \
        "the imperative framing leaked onto a passing stage"
else
    assert_pass "[SPEC-2] a passing stage is not framed as findings"
fi

# ─── SPEC-3: the bespoke readers are gone ────────────────────────────────────
print_test_section "3. the per-plugin readers are retired"

_ctx="$REPO_ROOT/plugins/agent/build/lib/context.sh"
if grep -qF '_build_read_prior_gate' "$_ctx" "$REPO_ROOT/plugins/agent/build/plugin.sh" 2>/dev/null; then
    assert_fail "[SPEC-3] _build_read_prior_gate is gone" "the bespoke reader survives"
else
    assert_pass "[SPEC-3] _build_read_prior_gate is gone"
fi

if grep -qF '_design_read_design_gate_feedback' "$REPO_ROOT/plugins/agent/design/plugin.sh" 2>/dev/null; then
    assert_fail "[SPEC-3] _design_read_design_gate_feedback is gone" "the reader survives"
else
    assert_pass "[SPEC-3] _design_read_design_gate_feedback is gone"
fi

# ─── SPEC-4: the wires are gone, and nothing inert is left ───────────────────
print_test_section "4. the retired wires are gone from both templates"

for _t in simple deployed; do
    _f="$REPO_ROOT/config/templates/${_t}.yaml"
    if grep -qF 'output: gate_feedback' "$_f" 2>/dev/null; then
        assert_fail "[SPEC-4] $_t: the gate_feedback wire is retired" "wire still present"
    else
        assert_pass "[SPEC-4] $_t: the gate_feedback wire is retired"
    fi
    if grep -qF 'output: design_gate_feedback' "$_f" 2>/dev/null; then
        assert_fail "[SPEC-4] $_t: the design_gate_feedback wire is retired" "wire still present"
    else
        assert_pass "[SPEC-4] $_t: the design_gate_feedback wire is retired"
    fi
done

# An input declaration nothing wires is exactly the inert-declaration defect
# #1865 deleted and #1898 was split out of.
for _m in "$REPO_ROOT/plugins/agent/build/manifest.yaml" \
          "$REPO_ROOT/plugins/agent/design/manifest.yaml"; do
    _n="$(basename "$(dirname "$_m")")"
    _inputs_blob="$(manifest_graph_get_inputs "$_m")"
    if grep -qE '^(gate_feedback|design_gate_feedback)\|' <<< "$_inputs_blob"; then
        assert_fail "[SPEC-4] $_n leaves no inert input declaration" \
            "a retired wire's input is still declared"
    else
        assert_pass "[SPEC-4] $_n leaves no inert input declaration"
    fi
done

# ─── SPEC-5: design's self-feedback survives ─────────────────────────────────
# It carries design's OWN prior output for refinement (#773), not another
# stage's summary. Nothing in this change replaces it, so removing it would be
# an unrelated regression.
print_test_section "5. design's self-feedback wire is untouched"

_sf="$(awk '/^ *feedback:/,/^[a-z_]+:/' "$REPO_ROOT/config/templates/simple.yaml")"
assert_contains "[SPEC-5] design still receives its own prior design" "$_sf" "output: design"

# #2042: the SPEC says the wire carries design's OWN prior output, NOT another
# stage's summary. A `contains` check establishes the first half only — it would
# pass just as well on a feedback block that ALSO wired a summary in, which is
# precisely the regression the sentence rules out. Pin the edge's endpoints.
_dfb="$(sed -n '/^design_verify_cycle:/,/^# ───/p' "$REPO_ROOT/config/templates/simple.yaml" \
        | sed -n '/feedback:/,$p')"
assert_contains "[SPEC-5] the edge's source stage is design itself" "$_dfb" "stage: design"
assert_eq "[SPEC-5] and it wires no OTHER stage's output into design" \
    "0" "$(grep -cE '^ +output: (summary|gate_feedback|acceptance|impact)' <<< "$_dfb" || true)"

# ─── SPEC-6: no dangling cross-reference ─────────────────────────────────────
# The tautology section pointed at "the PRIOR GATE FEEDBACK above". A heading
# that no longer exists is a prompt asserting an engine fact nothing provides
# (EPIC #1811).
print_test_section "6. no prompt text references a heading that is gone"

_pr="$REPO_ROOT/plugins/agent/build/lib/prompt.sh"
if grep -qF 'PRIOR GATE FEEDBACK' "$_pr" 2>/dev/null; then
    assert_fail "[SPEC-6] nothing still references the retired heading" \
        "PRIOR GATE FEEDBACK is still referenced in the prompt"
else
    assert_pass "[SPEC-6] nothing still references the retired heading"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
