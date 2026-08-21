#!/usr/bin/env bash
# tests/unit/contract-validator-unconsumed-output-test.sh
# ADR-020 bidirectional contract — OUTPUT_UNCONSUMED check.
#
# Every declared output in the resolved flow must be named by at least one
# consumer's input. Outputs marked terminal: true or advisory: true are exempt.
# The CI lint enforces the same rule tree-wide. Both checks use the same two
# new accessors in manifest-graph.sh (manifest_graph_output_terminal /
# manifest_graph_output_advisory).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"
# shellcheck source=../../core/pipeline/contract-validator.sh
source "$REPO_ROOT/core/pipeline/contract-validator.sh"

print_test_header "contract-validator / lint-contract — OUTPUT_UNCONSUMED (ADR-020)"

setup_test_env "cv-unconsumed-output"

_PL="$TEST_TEMP_DIR/plugins"

# ─── fixture helpers ─────────────────────────────────────────────────────────

# _mk_stage <id> <inputs-yaml-or-empty> <outputs-yaml-or-empty>
_mk_stage() {
    local id="$1" ins="$2" outs="$3"
    mkdir -p "$_PL/agent/$id"
    {
        printf 'id: %s\nname: %s\nkind: agent\nversion: 0.0.1\nhooks:\n  run: %s_run\n' \
            "$id" "$id" "${id//-/_}"
        if [[ -n "$ins" ]]; then
            printf 'inputs:\n%s\n' "$ins"
        else
            printf 'inputs: []\n'
        fi
        [[ -n "$outs" ]] && printf 'outputs:\n%s\n' "$outs"
    } > "$_PL/agent/$id/manifest.yaml"
    printf '%s_run() { :; }\n' "${id//-/_}" > "$_PL/agent/$id/plugin.sh"
}

# _validate_rc <stages-newline-separated> — return code only
_validate_rc() {
    local stages="$1" rc=0
    ZBUILD_CONTRACT_VALIDATOR=enforce _contract_validate_pipeline \
        "$stages" "$_PL" "$TEST_TEMP_DIR/state.json" >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}

# _validate_out <stages-newline-separated> — stderr output
_validate_out() {
    local stages="$1"
    ZBUILD_CONTRACT_VALIDATOR=enforce _contract_validate_pipeline \
        "$stages" "$_PL" "$TEST_TEMP_DIR/state.json" 2>&1 || true
}

# _lint_offences — run lint against $_PL, count offences from exit code
# ZBUILD_LINT_UNCONSUMED=1 enables the OUTPUT_UNCONSUMED check for this
# narrow fixture root (the real-repo lint always runs it; custom roots skip
# it by default to avoid false positives from legitimately minimal fixtures).
_lint_offences() {
    local rc=0
    ZBUILD_PLUGINS_ROOT="$_PL" ZBUILD_LINT_UNCONSUMED=1 \
        bash "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>&1 || rc=$?
    printf '%s' "$rc"
}

# _lint_out — capture stderr from lint
_lint_out() {
    ZBUILD_PLUGINS_ROOT="$_PL" ZBUILD_LINT_UNCONSUMED=1 \
        bash "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>&1 || true
}

# ─── Standard output declarations used across TCs ────────────────────────────

_scope_out='  - id: scope_manifest
    path: "${state_dir}/scope-manifest.md"
    type: file@1
    format: text
    required: true
    primary: true
    terminal: true'

_orphan_out='  - id: orphan_out
    path: "${artifact_dir}/orphan.json"
    type: orphan.json@1
    format: json
    required: true
    primary: true'

_orphan_terminal_out='  - id: orphan_out
    path: "${artifact_dir}/orphan.json"
    type: orphan.json@1
    format: json
    required: true
    primary: true
    terminal: true'

_orphan_advisory_out='  - id: orphan_out
    path: "${artifact_dir}/orphan.json"
    type: orphan.json@1
    format: json
    required: true
    primary: true
    advisory: true'

_scope_in='  - id: scope_manifest
    required: true'

_orphan_in='  - id: orphan_out
    required: true'

# ─── TC-1 / SPEC-1: orphaned output — no consumer names it ──────────────────
# CHANGE: at baseline no reverse check existed; an output with no consumer was
# silently accepted. Now it must raise OUTPUT_UNCONSUMED with rc=2.
print_test_section "1. orphaned output raises OUTPUT_UNCONSUMED"
rm -rf "$_PL"; mkdir -p "$_PL"
_mk_stage producer "" "$_scope_out"
_mk_stage consumer "$_scope_in" "$_orphan_out"

rc_tc1="$(_validate_rc "producer
consumer")"
out_tc1="$(_validate_out "producer
consumer")"

assert_eq "[SPEC-1] orphaned output: validator returns rc=2" "2" "$rc_tc1"
assert_contains_regex "[SPEC-1] violation code OUTPUT_UNCONSUMED appears in output" \
    "$out_tc1" "OUTPUT_UNCONSUMED"
assert_contains "[SPEC-1] violation names the orphaned output id" \
    "$out_tc1" "orphan_out"

# Guard: MISSING_OUTPUT must NOT fire — there is no consumer to complain about.
if grep -qF "MISSING_OUTPUT" <<< "$out_tc1"; then
    assert_fail "[SPEC-1] MISSING_OUTPUT does not fire when there is no consumer (guard)" \
        "MISSING_OUTPUT appeared: $out_tc1"
else
    assert_pass "[SPEC-1] MISSING_OUTPUT does not fire when there is no consumer (guard)"
fi

# ─── TC-2 / SPEC-2: terminal: true suppresses OUTPUT_UNCONSUMED ──────────────
print_test_section "2. terminal: true suppresses OUTPUT_UNCONSUMED"
rm -rf "$_PL"; mkdir -p "$_PL"
_mk_stage producer "" "$_scope_out"
_mk_stage consumer "$_scope_in" "$_orphan_terminal_out"

rc_tc2="$(_validate_rc "producer
consumer")"
assert_eq "[SPEC-2] terminal: true output: validator returns rc=0" "0" "$rc_tc2"

# ─── TC-3 / SPEC-3: advisory: true suppresses OUTPUT_UNCONSUMED ──────────────
print_test_section "3. advisory: true suppresses OUTPUT_UNCONSUMED"
rm -rf "$_PL"; mkdir -p "$_PL"
_mk_stage producer "" "$_scope_out"
_mk_stage consumer "$_scope_in" "$_orphan_advisory_out"

rc_tc3="$(_validate_rc "producer
consumer")"
assert_eq "[SPEC-3] advisory: true output: validator returns rc=0" "0" "$rc_tc3"

# ─── TC-4 / SPEC-4: output consumed by a downstream stage — no violation ─────
print_test_section "4. output consumed downstream: no violation"
rm -rf "$_PL"; mkdir -p "$_PL"
_mk_stage producer "" "$_scope_out"
_mk_stage consumer "$_scope_in" "$_orphan_out"
_mk_stage downstream "$_orphan_in" "  - id: final_out
    path: \"\${artifact_dir}/final.txt\"
    type: final.txt@1
    format: text
    required: true
    primary: true
    terminal: true"

rc_tc4="$(_validate_rc "producer
consumer
downstream")"
assert_eq "[SPEC-4] consumed output: validator returns rc=0" "0" "$rc_tc4"

# ─── TC-5 / SPEC-5: lint flags orphaned output in scope ──────────────────────
# The lint's tree-wide check: a stage that consumes a stage output is in scope;
# its own orphaned output must be flagged.
print_test_section "5. lint flags orphaned output for in-scope stage"
rm -rf "$_PL"; mkdir -p "$_PL"

# producer: outputs scope_manifest (consumed by consumer → producer in scope)
mkdir -p "$_PL/agent/producer"
cat > "$_PL/agent/producer/manifest.yaml" <<'EOF'
id: producer
name: Producer
kind: agent
version: 0.0.1
hooks:
  run: producer_run
inputs: []
outputs:
  - id: scope_manifest
    path: ${state_dir}/scope-manifest.md
    type: file@1
    format: text
    required: true
    primary: true
    terminal: true
EOF

# consumer: consumes scope_manifest (→ in scope), outputs orphan_out (unconsumed)
mkdir -p "$_PL/agent/consumer"
cat > "$_PL/agent/consumer/manifest.yaml" <<'EOF'
id: consumer
name: Consumer
kind: agent
version: 0.0.1
hooks:
  run: consumer_run
inputs:
  - id: scope_manifest
    required: true
outputs:
  - id: orphan_out
    path: ${artifact_dir}/orphan.json
    type: orphan.json@1
    format: json
    required: true
    primary: true
EOF

lint_out_tc5="$(_lint_out)"
if grep -qF "OUTPUT_UNCONSUMED" <<< "$lint_out_tc5"; then
    assert_pass "[SPEC-5] lint flags orphaned output for in-scope stage"
else
    assert_fail "[SPEC-5] lint flags orphaned output for in-scope stage" \
        "OUTPUT_UNCONSUMED not found in lint output: $lint_out_tc5"
fi
assert_contains "[SPEC-5] lint names the orphaned output id" "$lint_out_tc5" "orphan_out"

# Guard: forward checks unaffected — scope_manifest IS consumed so no complaint.
if grep -qE "scope_manifest.*OUTPUT_UNCONSUMED|OUTPUT_UNCONSUMED.*scope_manifest" <<< "$lint_out_tc5"; then
    assert_fail "[SPEC-5] consumed output scope_manifest does not trigger OUTPUT_UNCONSUMED (guard)" \
        "False positive: $lint_out_tc5"
else
    assert_pass "[SPEC-5] consumed output scope_manifest does not trigger OUTPUT_UNCONSUMED (guard)"
fi

# ─── TC-6 / SPEC-6: lint skips output marked terminal: true ──────────────────
print_test_section "6. lint skips terminal: true output"
rm -rf "$_PL"; mkdir -p "$_PL"

mkdir -p "$_PL/agent/producer"
cat > "$_PL/agent/producer/manifest.yaml" <<'EOF'
id: producer
name: Producer
kind: agent
version: 0.0.1
hooks:
  run: producer_run
inputs: []
outputs:
  - id: scope_manifest
    path: ${state_dir}/scope-manifest.md
    type: file@1
    format: text
    required: true
    primary: true
    terminal: true
EOF

mkdir -p "$_PL/agent/consumer"
cat > "$_PL/agent/consumer/manifest.yaml" <<'EOF'
id: consumer
name: Consumer
kind: agent
version: 0.0.1
hooks:
  run: consumer_run
inputs:
  - id: scope_manifest
    required: true
outputs:
  - id: orphan_out
    path: ${artifact_dir}/orphan.json
    type: orphan.json@1
    format: json
    required: true
    primary: true
    terminal: true
EOF

lint_rc_tc6=0
ZBUILD_PLUGINS_ROOT="$_PL" bash "$REPO_ROOT/scripts/lib/lint-contract.sh" >/dev/null 2>&1 || lint_rc_tc6=$?
assert_eq "[SPEC-6] lint with terminal: true output returns rc=0" "0" "$lint_rc_tc6"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
