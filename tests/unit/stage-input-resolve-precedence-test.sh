#!/usr/bin/env bash
# tests/unit/stage-input-resolve-precedence-test.sh — a consumer reads what its
# producer wrote THIS run, not the prior run's restored copy (#2095).
#
# ADR-059 records that "input-resolve.sh reads the live path first" and that a
# stage's own output "is never overwritten by an older copy of itself". Run
# 34837524723 showed the opposite: hydrate restored the prior run's design.md,
# design_verify_cycle converged on a fresh one, and impact was handed the
# restored one. The cycle-feedback path masked it inside a cycle; it bites at
# every consumer of an artifact produced OUTSIDE its own cycle.
#
#   1 [change] live and restored both present, different → the index names LIVE
#   2 [change] the consumer READS the live body through the index (not just a path)
#   3 [change] live absent → nothing is offered: there is no second "restored"
#              area to fall back to — hydrate puts an earlier run's outputs in
#              the live places (ADR-050, amended)
#   4 [change] on a cycle's later try, a stage reads its producer's LATEST output,
#              never the copy the orchestrator took when the try began (#1932's
#              run: spec-coverage judged the design design had already replaced)
#
# Sibling of stage-input-resolve-test.sh, which is already over the 500-line
# guideline; the fixture here is the minimum one producer / one consumer pair.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"

print_test_header "stage input precedence — live beats restored (#2095)"
setup_test_env "stage-input-resolve-precedence"

unset ZBUILD_STAGE_INPUTS ZBUILD_INPUTS_FLOW 2>/dev/null || true
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR ZBUILD_RESTORED_ARTIFACTS_DIR 2>/dev/null || true

STATE="$TEST_TEMP_DIR/state"
ART="$STATE/artifacts"
RESTORED="$STATE/restored-artifacts/artifacts"
FEEDBACK="$STATE/cycle-x/iter-2/feedback"
PROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$ART" "$RESTORED" "$FEEDBACK" "$PROOT/tool/pp-producer" "$PROOT/tool/pp-consumer"

# ─── Fixtures: one producer, one consumer that knows only the input's NAME ──
cat > "$PROOT/tool/pp-producer/manifest.yaml" <<'EOF'
id: pp-producer
name: Precedence Producer
kind: tool
version: 0.0.1
hooks:
  run: ppp_run
inputs: []
outputs:
  - id: design_doc
    path: ${artifact_dir}/design-doc.md
    type: markdown
    required: true
    primary: true
EOF
printf 'ppp_run() { return 0; }\n' > "$PROOT/tool/pp-producer/plugin.sh"

cat > "$PROOT/tool/pp-consumer/manifest.yaml" <<'EOF'
id: pp-consumer
name: Precedence Consumer
kind: tool
version: 0.0.1
hooks:
  run: ppc_run
inputs:
  - id: design_doc
    required: true
outputs:
  - id: consumer_out
    path: ${artifact_dir}/pp-consumer-out.json
    type: json
    required: true
    primary: true
EOF
{
    printf '_PPC_OUT=%q\n' "$TEST_TEMP_DIR/ppc-seen.txt"
    cat <<'FIXTURE'
ppc_run() {
    printf '{"verdict":"pass"}\n' > "${ZBUILD_STATE_DIR:?}/artifacts/pp-consumer-out.json"
    {
        _p=""
        if [[ -n "${ZBUILD_STAGE_INPUTS:-}" && -s "${ZBUILD_STAGE_INPUTS:-}" ]]; then
            _p="$(jq -r '.inputs.design_doc // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null)"
        fi
        printf 'path=%s\n' "${_p:-<none>}"
        printf 'body=%s\n' "$( [[ -n "$_p" && -s "$_p" ]] && cat "$_p" || echo '<unreadable>' )"
    } > "$_PPC_OUT"
    return 0
}
FIXTURE
} > "$PROOT/tool/pp-consumer/plugin.sh"

_TPL_STAGES=(pp-producer pp-consumer)
CONSUMER_DIR="$PROOT/tool/pp-consumer"

_dispatch() {
    rm -f "$TEST_TEMP_DIR/ppc-seen.txt" "$STATE/stage-inputs/pp-consumer.json"
    ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events.jsonl" \
    ZBUILD_STATE_DIR="$STATE" \
        plugin_hook_call "$CONSUMER_DIR" run "pp-consumer" "$STATE/pipeline-state.json"
}
_seen() { grep "^$1=" "$TEST_TEMP_DIR/ppc-seen.txt" 2>/dev/null | head -1 | cut -d= -f2-; }
_indexed() { jq -r '.inputs.design_doc // empty' "$STATE/stage-inputs/pp-consumer.json" 2>/dev/null; }

# ─── SPEC-1 / SPEC-2: both present, different — LIVE wins and is READ ───────
print_test_section "1. live and restored both present → the index names the LIVE copy"
printf 'LIVE-BODY-2095 written by this run\n'     > "$ART/design-doc.md"
printf 'RESTORED-BODY-2095 from the prior run\n' > "$RESTORED/design-doc.md"

ZBUILD_RESTORED_ARTIFACTS_DIR="$RESTORED" _dispatch >/dev/null 2>"$TEST_TEMP_DIR/d1.err"
_rc1=$?
if [[ "$_rc1" -eq 0 ]]; then
    assert_pass "[SPEC-1] the dispatch succeeded"
else
    assert_fail "[SPEC-1] the dispatch succeeded" \
        "rc=$_rc1; stderr: $(tr '\n' ' ' < "$TEST_TEMP_DIR/d1.err" 2>/dev/null | tail -c 400)"
fi
assert_eq "[SPEC-1] design_doc resolves to the producer's LIVE path" \
    "$ART/design-doc.md" "$(_indexed)"
# [guard] the two bodies differ, so SPEC-2 cannot pass by reading either file.
if cmp -s "$ART/design-doc.md" "$RESTORED/design-doc.md"; then
    assert_fail "[SPEC-1-guard] live and restored fixtures differ" "identical bodies — SPEC-2 would be vacuous"
else
    assert_pass "[SPEC-1-guard] live and restored fixtures differ"
fi

print_test_section "2. the consumer reads THIS run's body through the index"
assert_contains "[SPEC-2] the body is the live one" "$(_seen body)" "LIVE-BODY-2095"
if grep -qF 'RESTORED-BODY-2095' "$TEST_TEMP_DIR/ppc-seen.txt" 2>/dev/null; then
    assert_fail "[SPEC-2] the prior run's body is NOT what the consumer saw" \
        "consumer read RESTORED-BODY-2095 — the stale copy outranked the fresh one"
else
    assert_pass "[SPEC-2] the prior run's body is NOT what the consumer saw"
fi

# ─── SPEC-3: live absent → nothing is offered ────────────────────────────────
print_test_section "3. live absent → there is no second area to fall back to"
rm -f "$ART/design-doc.md"
ZBUILD_RESTORED_ARTIFACTS_DIR="$RESTORED" _dispatch >/dev/null 2>&1
assert_eq "[SPEC-3] design_doc is not indexed from a restored area" "" "$(_indexed)"
if grep -qF "RESTORED-BODY-2095" <<< "$(_seen body)"; then
    assert_fail "[SPEC-3] the consumer reads no copy from a restored area" "it did"
else
    assert_pass "[SPEC-3] the consumer reads no copy from a restored area"
fi

# ─── SPEC-4: a later try reads the producer's latest output, not the try-start copy
# #1932's run: design_verify_cycle's feedback edge (design → design) made the
# orchestrator copy design.md into iter-2/feedback/design.txt as try 2 began.
# Design then wrote a fixed design.md, and spec-coverage — which reads an input
# of the same name — was handed the copy, so it judged the design design had
# already replaced and the loop ran out of tries. The latest output of a stage
# is what every later stage gets.
print_test_section "4. on try 2 the consumer reads the producer's latest output"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
_TPL_STAGES=(pp-producer pp-consumer)   # sourcing the orchestrator resets the roster
rm -rf "$RESTORED"
printf 'TRY-1-BODY design as try 1 left it\n' > "$ART/design-doc.md"
# The try boundary runs the orchestrator's own code for the template's self-edge.
_CYCLE_TRAP_CYCLE_ID="cycle-x"
_CYCLE_FEEDBACK=("pp-producer:design_doc|pp-producer:design_doc:false")
ZBUILD_PLUGINS_ROOT="$PROOT" ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events.jsonl" \
    _cycle_apply_feedback 2 "$STATE" >/dev/null 2>&1
# Try 2: the producer replaces its output before the consumer runs.
printf 'TRY-2-BODY design as try 2 rewrote it\n' > "$ART/design-doc.md"
ZBUILD_CYCLE_ITER=2 _dispatch >/dev/null 2>&1
assert_eq "[SPEC-4] design_doc resolves to the producer's live path on try 2" \
    "$ART/design-doc.md" "$(_indexed)"
assert_contains "[SPEC-4] and the consumer reads try 2's body" "$(_seen body)" "TRY-2-BODY"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
