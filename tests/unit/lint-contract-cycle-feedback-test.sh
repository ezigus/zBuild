#!/usr/bin/env bash
# tests/unit/lint-contract-cycle-feedback-test.sh — Wave 18-C (#708).
#
# Asserts the cycle-feedback wiring lint catches stale/honest mismatches
# between a template's `cycles[].feedback[]` block and the producer/consumer
# manifests. Fixtures construct minimal plugins + a template at $TEST_TEMP_DIR
# and invoke `scripts/lib/lint-contract.sh` with ZBUILD_PLUGINS_ROOT +
# ZBUILD_TEMPLATES_ROOTS pointed at the fixture.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/lib/lint-contract.sh — cycle-feedback wiring (Wave 18-C, #708)"
setup_test_env "lint-contract-cycle-feedback"

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
TEMPLATES_ROOT="$TEST_TEMP_DIR/templates"
mkdir -p "$PLUGINS_ROOT/agent/producer" "$PLUGINS_ROOT/agent/consumer" "$TEMPLATES_ROOT"

# ─── helper: write the canonical producer/consumer plugin pair ──────────────
write_good_plugins() {
    cat > "$PLUGINS_ROOT/agent/producer/manifest.yaml" <<'EOF'
id: producer
name: Producer
kind: agent
version: 0.1.0
hooks:
  run: r
requires:
  core: [redaction]
inputs: []
outputs:
  - id: producer_main
    type: file
    path: ${artifact_dir}/producer.json
    required: true
    primary: true
  - id: producer_feedback_md
    type: markdown
    path: ${artifact_dir}/producer.md
    required: false
EOF

    cat > "$PLUGINS_ROOT/agent/consumer/manifest.yaml" <<'EOF'
id: consumer
name: Consumer
kind: agent
version: 0.1.0
hooks:
  run: r
requires:
  core: [redaction]
inputs:
  - id: producer_main
    type: file
    source: stage:producer
    required: true
  - id: prior_feedback
    type: file
    path: ${cycle_feedback_dir}/prior_feedback.txt
    source: cycle_feedback
    required: false
outputs:
  - id: consumer_out
    type: file
    path: ${artifact_dir}/consumer.json
    required: true
    primary: true
EOF
}

# ─── helper: write template with feedback wire (parameterized) ──────────────
# args: <template_id> <from_stage> <from_output> <to_stage> <to_input>
write_template() {
    local tid="$1" fs="$2" fo="$3" ts="$4" ti="$5"
    cat > "$TEMPLATES_ROOT/$tid.yaml" <<EOF
id: $tid
name: $tid
extends: null
defaults:
  strategy: fanout
flow:
  - cyc

cyc:
  type: cycle
  flow:
    - producer
    - consumer
  exit_when:
    stage: consumer
    field: verdict
    op: eq
    value: pass
  max_iterations: 2
  on_max: continue
  feedback:
    - from:
        stage: $fs
        output: $fo
      to:
        stage: $ts
        input: $ti
        required: false

producer:
  gate: auto
  roles: [producer]
  io: { destinations: [file], tail_lines: 50 }

consumer:
  gate: auto
  roles: [consumer]
  io: { destinations: [file], tail_lines: 50 }
EOF
}

run_lint() {
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_TEMPLATES_ROOTS="$TEMPLATES_ROOT" \
    bash "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>&1
}

# ─── TC-1: honest wire passes ───────────────────────────────────────────────
write_good_plugins
write_template "good" "producer" "producer_feedback_md" "consumer" "prior_feedback"
rc=0
out="$(run_lint)" || rc=$?
assert_eq "TC-1: honest feedback wire passes (rc=0)" "0" "$rc"

# ─── TC-2: from.output not declared by source stage ─────────────────────────
write_good_plugins
write_template "bad_from_output" "producer" "ghost_output" "consumer" "prior_feedback"
rc=0
out="$(run_lint)" || rc=$?
assert_eq "TC-2: missing from.output detected (rc=1)" "1" "$rc"
assert_contains "TC-2: diagnostic names ghost output id" "$out" "ghost_output"
assert_contains "TC-2: diagnostic names source stage" "$out" "producer"

# ─── TC-3: to.input not declared by target stage ────────────────────────────
write_good_plugins
write_template "bad_to_input" "producer" "producer_feedback_md" "consumer" "ghost_input"
rc=0
out="$(run_lint)" || rc=$?
assert_eq "TC-3: missing to.input detected (rc=1)" "1" "$rc"
assert_contains "TC-3: diagnostic names ghost input id" "$out" "ghost_input"
assert_contains "TC-3: diagnostic names target stage" "$out" "consumer"

# ─── TC-4: to.input declared but source != cycle_feedback ───────────────────
write_good_plugins
# Rewrite consumer so prior_feedback exists but source is stage:producer.
cat > "$PLUGINS_ROOT/agent/consumer/manifest.yaml" <<'EOF'
id: consumer
name: Consumer
kind: agent
version: 0.1.0
hooks:
  run: r
requires:
  core: [redaction]
inputs:
  - id: producer_main
    type: file
    source: stage:producer
    required: true
  - id: prior_feedback
    type: file
    source: stage:producer
    required: false
outputs:
  - id: consumer_out
    type: file
    path: ${artifact_dir}/consumer.json
    required: true
    primary: true
EOF
write_template "bad_to_source" "producer" "producer_feedback_md" "consumer" "prior_feedback"
rc=0
out="$(run_lint)" || rc=$?
assert_eq "TC-4: wrong-source to.input detected (rc=1)" "1" "$rc"
assert_contains "TC-4: diagnostic mentions cycle_feedback" "$out" "cycle_feedback"
assert_contains "TC-4: diagnostic names input id" "$out" "prior_feedback"

# ─── TC-5: from.stage not in template's stage set ───────────────────────────
write_good_plugins
write_template "bad_from_stage" "ghost_stage" "producer_feedback_md" "consumer" "prior_feedback"
rc=0
out="$(run_lint)" || rc=$?
assert_eq "TC-5: missing from.stage detected (rc=1)" "1" "$rc"
assert_contains "TC-5: diagnostic names ghost stage" "$out" "ghost_stage"

# ─── TC-6: to.stage not in template's stage set ─────────────────────────────
write_good_plugins
write_template "bad_to_stage" "producer" "producer_feedback_md" "ghost_target" "prior_feedback"
rc=0
out="$(run_lint)" || rc=$?
assert_eq "TC-6: missing to.stage detected (rc=1)" "1" "$rc"
assert_contains "TC-6: diagnostic names ghost target stage" "$out" "ghost_target"

# ─── TC-7: real repo templates pass after Wave 18-B ─────────────────────────
rc=0
ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins" \
ZBUILD_TEMPLATES_ROOTS="$REPO_ROOT/config/templates" \
bash "$REPO_ROOT/scripts/lib/lint-contract.sh" >/dev/null 2>&1 || rc=$?
assert_eq "TC-7: real repo template + plugins pass cycle-feedback lint" "0" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
