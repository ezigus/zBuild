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
#   3 [guard]  live absent → the restored copy is still offered (warm-start seam)
#   4 [guard]  cycle feedback (iter >= 2) still outranks live — the cycle's own
#              copy is the newest thing in the tree, not the live artifact
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
    ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events.jsonl" ZBUILD_EVENTS_DB=/dev/null \
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

# ─── SPEC-3: live absent → restored is still offered ────────────────────────
print_test_section "3. live absent → the restored copy is still offered"
rm -f "$ART/design-doc.md"
ZBUILD_RESTORED_ARTIFACTS_DIR="$RESTORED" _dispatch >/dev/null 2>&1
assert_eq "[SPEC-3] design_doc falls back to the restored path" \
    "$RESTORED/design-doc.md" "$(_indexed)"
assert_contains "[SPEC-3] and the consumer reads the restored body" \
    "$(_seen body)" "RESTORED-BODY-2095"
# [guard] with NO restored area either, the required input refuses as before.
rm -rf "$RESTORED"
_dispatch >/dev/null 2>"$TEST_TEMP_DIR/d3.err"
_rc3=$?
if [[ "$_rc3" -ne 0 ]]; then
    assert_pass "[SPEC-3-guard] nothing anywhere → the required input still refuses (rc=$_rc3)"
else
    assert_fail "[SPEC-3-guard] nothing anywhere → the required input still refuses" "rc=0"
fi
assert_contains "[SPEC-3-guard] with the INPUT_MISSING code" \
    "$(cat "$TEST_TEMP_DIR/d3.err" 2>/dev/null)" "INPUT_MISSING"

# ─── SPEC-4: cycle feedback still outranks live ─────────────────────────────
print_test_section "4. cycle feedback (iter >= 2) still outranks the live copy"
mkdir -p "$RESTORED"
printf 'LIVE-BODY-2095 written by this run\n'     > "$ART/design-doc.md"
printf 'RESTORED-BODY-2095 from the prior run\n' > "$RESTORED/design-doc.md"
printf 'FEEDBACK-BODY-2095 from the previous iteration\n' > "$FEEDBACK/design_doc.txt"
ZBUILD_CYCLE_ITER=2 ZBUILD_CYCLE_FEEDBACK_DIR="$FEEDBACK" \
ZBUILD_RESTORED_ARTIFACTS_DIR="$RESTORED" _dispatch >/dev/null 2>&1
assert_eq "[SPEC-4] design_doc resolves to the cycle-feedback copy" \
    "$FEEDBACK/design_doc.txt" "$(_indexed)"
assert_contains "[SPEC-4] and the consumer reads the feedback body" \
    "$(_seen body)" "FEEDBACK-BODY-2095"
# [guard] iter 1 has no feedback to prefer — live wins again, not restored.
ZBUILD_CYCLE_ITER=1 ZBUILD_CYCLE_FEEDBACK_DIR="$FEEDBACK" \
ZBUILD_RESTORED_ARTIFACTS_DIR="$RESTORED" _dispatch >/dev/null 2>&1
assert_eq "[SPEC-4-guard] iter 1 resolves to LIVE, not restored" \
    "$ART/design-doc.md" "$(_indexed)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
