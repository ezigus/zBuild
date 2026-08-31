#!/usr/bin/env bash
# tests/unit/unconsumed-check-retired-test.sh — an output no stage names is not
# an error (#1980, ADR-020 / ADR-055 §4).
#
# OUTPUT_UNCONSUMED refused any output no `inputs:` block named, and the
# annotation that silenced it (`terminal:` / `advisory:`) lived in the
# PRODUCER's manifest — while the fact it asserted, "does anyone consume this?",
# is a property of the TEMPLATE. The same plugin in a different flow needs a
# different answer, so a producer was asked to declare something it cannot know.
# 24 annotations across 16 plugins were the evidence.
#
# The mirror check stays: a stage naming an input nothing produces breaks the
# run; an output nobody reads costs a few bytes. Only one of those is an error.
#
#   SPEC-1 [change]: an unconsumed output is accepted, with no annotation
#   SPEC-2 [guard] : INPUT_UNRESOLVED still refuses a required input that names
#                    no producer — the half of the contract that is real
#   SPEC-3 [guard] : OUTPUT_DUP still fires — asserted in
#                    contract-validator-output-uniqueness-test.sh, which owns
#                    that check (the lint never had it)
#   SPEC-4 [change]: the dead vocabulary is gone from the tree — both accessors
#                    and every terminal:/advisory: annotation. Leaving them
#                    inert would reproduce the defect in a new coat: a
#                    declaration that reads as meaningful and does nothing
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"

print_test_header "the unconsumed-output check is retired (#1980)"
setup_test_env "unconsumed-check-retired"

PL="$TEST_TEMP_DIR/plugins"
mkdir -p "$PL/tool/uc-producer" "$PL/tool/uc-consumer"

# A producer whose output NOTHING names, carrying no annotation at all.
cat > "$PL/tool/uc-producer/manifest.yaml" <<'EOF'
id: uc-producer
name: UC Producer
kind: tool
version: 0.0.1
hooks:
  run: ucp_run
inputs:
  - id: gh_issue_body
    source: external
    required: true
outputs:
  - id: uc_producer_out
    path: ${artifact_dir}/uc-producer-out.json
    type: json
    required: true
    primary: true
EOF
printf 'ucp_run() { return 0; }\n' > "$PL/tool/uc-producer/plugin.sh"

cat > "$PL/tool/uc-consumer/manifest.yaml" <<'EOF'
id: uc-consumer
name: UC Consumer
kind: tool
version: 0.0.1
hooks:
  run: ucc_run
inputs:
  - id: gh_issue_body
    source: external
    required: true
outputs:
  - id: uc_consumer_out
    path: ${artifact_dir}/uc-consumer-out.json
    type: json
    required: true
    primary: true
EOF
printf 'ucc_run() { return 0; }\n' > "$PL/tool/uc-consumer/plugin.sh"

# ZBUILD_LINT_UNCONSUMED=1 forced the check ON for a fixture tree. Passing it
# after the removal is harmless, and passing it BEFORE is what makes this test
# actually exercise the check rather than pass because fixture trees skipped it.
_lint() {
    ZBUILD_PLUGINS_ROOT="$PL" ZBUILD_LINT_UNCONSUMED=1 \
        bash "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>&1 || true
}

# ─── SPEC-1: an unconsumed output is fine ────────────────────────────────────
print_test_section "1. an output no stage names is accepted"

_out="$(_lint)"
if grep -qF 'UNCONSUMED' <<< "$_out"; then
    assert_fail "[SPEC-1] an unconsumed output is not reported" "$(grep UNCONSUMED <<< "$_out" | head -1)"
else
    assert_pass "[SPEC-1] an unconsumed output is not reported"
fi
_rc=0; ZBUILD_PLUGINS_ROOT="$PL" ZBUILD_LINT_UNCONSUMED=1 \
    bash "$REPO_ROOT/scripts/lib/lint-contract.sh" >/dev/null 2>&1 || _rc=$?
assert_eq "[SPEC-1] and the lint exits clean" "0" "$_rc"

# Also on the real tree, which is what CI runs.
_rc2=0; bash "$REPO_ROOT/scripts/lib/lint-contract.sh" >/dev/null 2>&1 || _rc2=$?
assert_eq "[SPEC-1] the real tree lints clean with no annotations left" "0" "$_rc2"

# ─── SPEC-2: the half that IS an error still fires ───────────────────────────
print_test_section "2. an input naming no producer is still refused"

cat > "$PL/tool/uc-consumer/manifest.yaml" <<'EOF'
id: uc-consumer
name: UC Consumer
kind: tool
version: 0.0.1
hooks:
  run: ucc_run
inputs:
  - id: nothing_produces_this
    required: true
outputs:
  - id: uc_consumer_out
    path: ${artifact_dir}/uc-consumer-out.json
    type: json
    required: true
    primary: true
EOF
_out2="$(_lint)"
assert_contains "[SPEC-2] a required input with no producer is reported" \
    "$_out2" "nothing_produces_this"

# ─── SPEC-4: the dead vocabulary is gone ─────────────────────────────────────
print_test_section "4. no dead annotation or accessor remains"

_ann="$(grep -rlE '^[[:space:]]+(terminal|advisory):[[:space:]]*true' \
    --include='manifest.yaml' "$REPO_ROOT/plugins" 2>/dev/null || true)"
assert_eq "[SPEC-4] no manifest still carries terminal:/advisory:" "" "$_ann"

for _fn in manifest_graph_output_terminal manifest_graph_output_advisory; do
    if declare -F "$_fn" >/dev/null 2>&1; then
        assert_fail "[SPEC-4] $_fn is gone" "the accessor is still defined"
    else
        assert_pass "[SPEC-4] $_fn is gone"
    fi
done

# The marker the summaries collector depends on must NOT be swept up with them.
if declare -F manifest_graph_output_summary >/dev/null 2>&1; then
    assert_pass "[SPEC-4] manifest_graph_output_summary survives (#1976 needs it)"
else
    assert_fail "[SPEC-4] manifest_graph_output_summary survives (#1976 needs it)" \
        "the summaries collector's accessor was removed"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
