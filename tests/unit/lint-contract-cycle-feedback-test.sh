#!/usr/bin/env bash
# tests/unit/lint-contract-cycle-feedback-test.sh — Wave 18-C (#708).
#
# Asserts the cycle-feedback wiring lint catches stale/honest mismatches
# between a template's `feedback:` block (inside a `type: cycle` stage
# section, per ADR-027 recursive flow format) and the producer/consumer
# manifests. Fixtures construct minimal plugins + a template at
# $TEST_TEMP_DIR and invoke `scripts/lib/lint-contract.sh` with
# ZBUILD_PLUGINS_ROOT + ZBUILD_TEMPLATES_ROOTS pointed at the fixture.
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
  # ADR-055 §9 (#2000): every stage-bound plugin declares one summary.
  - id: producer_summary
    path: "${artifact_dir}/producer-summary.md"
    type: producer-summary.md@1
    format: markdown
    required: true
    summary: true
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
    required: true
  - id: prior_feedback
    type: file
    path: ${cycle_feedback_dir}/prior_feedback.txt
    required: false
outputs:
  - id: consumer_out
    type: file
    path: ${artifact_dir}/consumer.json
    required: true
    primary: true
  # ADR-055 §9 (#2000): every stage-bound plugin declares one summary.
  - id: consumer_summary
    path: "${artifact_dir}/consumer-summary.md"
    type: consumer-summary.md@1
    format: markdown
    required: true
    summary: true
EOF
}

# ─── helper: write template with feedback wire (parameterized) ──────────────
# args: <template_id> <from_stage> <from_output> <to_stage> <to_input>
#
# Copilot P2: clears $TEMPLATES_ROOT before writing, so each test case
# exercises ONLY its own fixture. Without this, run_lint scans every
# template ever written by earlier cases, which can both leak unrelated
# diagnostics and let a stale-case substring satisfy a later assertion.
write_template() {
    local tid="$1" fs="$2" fo="$3" ts="$4" ti="$5"
    find "$TEMPLATES_ROOT" -mindepth 1 -delete 2>/dev/null || true
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

# ─── TC-4 removed by #1825 ──────────────────────────────────────────────────
# It asserted that a feedback edge's target must declare `source: cycle_feedback`.
# ADR-055 §4 retires that kind — a consumer declares only a name — so the rule
# it tested no longer exists. What survives is TC-3: the target must declare an
# input BY THAT NAME, which is the wiring integrity the source check stood in for.

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


# ─── #1865/#1825: no feedback edge names an input that does not exist ────────
# #1865 pinned "every declared cycle_feedback input is wired by a template". The
# source kind is gone (ADR-055 §4), so the same integrity is now pinned from the
# other end: every `feedback.to.input` in a shipped template must name an input
# the target stage actually declares. A dangling wire and an inert declaration
# are the same defect seen from opposite sides.
print_test_section "#1865/#1825 — no feedback edge names a missing input"
_fb_bad=0; _fb_rows=0; _fb_detail=""; _ids=""
for _tpl in "$REPO_ROOT"/config/templates/*.yaml; do
    [[ -f "$_tpl" ]] || continue
    _cur_stage=""
    while IFS= read -r _l; do
        case "$_l" in
            *"stage:"*) _cur_stage="$(printf '%s' "$_l" | sed 's/.*stage:[[:space:]]*//')" ;;
            *"input:"*)
                _in="$(printf '%s' "$_l" | sed 's/.*input:[[:space:]]*//')"
                [[ -n "$_in" && -n "$_cur_stage" ]] || continue
                _fb_rows=$((_fb_rows + 1))
                _mf="$(manifest_graph_resolve_member "$REPO_ROOT/plugins" "$_cur_stage" 2>/dev/null || true)"
                [[ -n "$_mf" ]] || _mf="$(manifest_graph_collect "$REPO_ROOT/plugins" "$_cur_stage" 2>/dev/null || true)"
                [[ -n "$_mf" ]] || continue
                _ids="$(manifest_graph_get_inputs "$_mf" 2>/dev/null | cut -d'|' -f1)"
                if ! grep -qx "$_in" <<< "$_ids"; then
                    _fb_bad=$((_fb_bad + 1)); _fb_detail+="$(basename "$_tpl"):$_cur_stage.$_in "
                fi
                ;;
        esac
    done < "$_tpl"
done
if [[ $_fb_rows -gt 0 ]]; then
    assert_pass "[#1825] the scan parsed $_fb_rows feedback target(s)"
else
    assert_fail "[#1825] the scan parsed at least one feedback target" \
        "zero rows — the assertion below would pass vacuously"
fi
assert_eq "[#1825] every feedback edge names a declared input" "0" "$_fb_bad"
[[ $_fb_bad -ne 0 ]] && printf '    dangling: %s\n' "$_fb_detail" >&2

print_test_results
exit $((FAIL > 0))
