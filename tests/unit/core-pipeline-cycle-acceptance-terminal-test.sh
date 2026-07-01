#!/usr/bin/env bash
# Tests: cycle-orchestrator _cycle_member_terminal_failure (#1044, #1188, Phase 2)
#
# GENERIC member-disposition contract (ADR-021). The engine no longer knows the
# acceptance-gate's failure vocabulary — it iterates THIS cycle's member roster
# (_CYCLE_STAGES), resolves each member's result artifact via the shared roster
# mechanism (manifest_graph_resolve_member / manifest_graph_result_filename), and
# HALTS only when a FAILING member declares an EXPLICIT `disposition: terminal`.
#   terminal    → halt (rc 0, echoes the member id).
#   recoverable → NOT terminal (rc 1)  — the #951 build feedback loop.
#   advisory    → NOT terminal (rc 1)  — infra flake / non-blocking.
#   absent      → NOT terminal (rc 1)  — fail-safe (only explicit terminal halts).
# Decoupling: a NON-acceptance member declaring disposition=terminal ALSO halts,
# proving the engine is plugin-agnostic. Membership guard: only cycle members are
# considered. Missing/unparseable artifact → never falsely blocks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — generic member terminal disposition (#1044, ADR-021)"
setup_test_env "cycle-member-terminal"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# ── Manifest fixtures: two members with distinct artifact filenames. ───────────
# acceptance-gate resolves via provides.artifact_type; custom-check via its
# primary output basename — exercising BOTH resolution paths.
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$PLUGINS_ROOT/agent/acceptance-gate" "$PLUGINS_ROOT/tool/custom-check"
cat > "$PLUGINS_ROOT/agent/acceptance-gate/manifest.yaml" <<'EOF'
id: acceptance-gate
name: Test acceptance-gate
kind: agent
version: 0.0.1
convergence: gate
hooks:
  run: acceptance_gate_run
provides:
  role: acceptance_gate
  artifact_type: acceptance-gate-result.json
EOF
cat > "$PLUGINS_ROOT/tool/custom-check/manifest.yaml" <<'EOF'
id: custom-check
name: Test custom-check
kind: tool
version: 0.0.1
convergence: gate
hooks:
  run: custom_check_run
outputs:
  - id: custom_result
    path: ${artifact_dir}/custom-check-result.json
    type: json
    required: true
    primary: true
EOF
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$STATE_DIR/artifacts"
ACC="$STATE_DIR/artifacts/acceptance-gate-result.json"
CUST="$STATE_DIR/artifacts/custom-check-result.json"

_write_acc()  { printf '%s' "$1" > "$ACC"; }
_write_cust() { printf '%s' "$1" > "$CUST"; }
_reset()      { rm -f "$ACC" "$CUST"; }

# ── [SPEC-1] disposition=terminal on a member → terminal (rc 0), echoes member ─
_CYCLE_STAGES=(build acceptance-gate review)

_reset; _write_acc '{"verdict":"fail","disposition":"terminal","failures":["inert_wiring:config/x.yaml"]}'
set +e; out="$(_cycle_member_terminal_failure "$STATE_DIR")"; rc=$?; set -e
assert_eq "[SPEC-1] terminal disposition → terminal (rc=0)" "0" "$rc"
assert_eq "[SPEC-1] echoes the failing member id" "acceptance-gate" "$out"

# ── [SPEC-2] disposition=recoverable → NOT terminal (rc 1) — #951 preserved ────
_reset; _write_acc '{"verdict":"fail","disposition":"recoverable","failures":["untagged_spec:SPEC-1"]}'
set +e; _cycle_member_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-2] recoverable → NOT terminal (rc=1)" "1" "$rc"

# ── [SPEC-5] disposition=advisory → NOT terminal (rc 1) — infra non-blocking ───
_reset; _write_acc '{"verdict":"fail","disposition":"advisory","failures":["negctl_error:timeout:SPEC-1"]}'
set +e; _cycle_member_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-5] advisory → NOT terminal (rc=1)" "1" "$rc"

# ── disposition ABSENT on a fail → NOT terminal (fail-safe, preserves behavior) ─
_reset; _write_acc '{"verdict":"fail","failures":["inert_wiring:config/x.yaml"]}'
set +e; _cycle_member_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-2] disposition absent → NOT terminal (rc=1)" "1" "$rc"

# ── verdict=pass is never terminal regardless of disposition. ──────────────────
_reset; _write_acc '{"verdict":"pass","disposition":"none","failures":[]}'
set +e; _cycle_member_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-2] verdict=pass → NOT terminal (rc=1)" "1" "$rc"

# ── [DECOUPLING] a NON-acceptance member declaring terminal ALSO halts. ────────
# Proves the engine is plugin-agnostic: no literal "acceptance-gate" knowledge.
_CYCLE_STAGES=(build custom-check review)
_reset; _write_cust '{"verdict":"fail","disposition":"terminal","failures":["policy_violation"]}'
set +e; out="$(_cycle_member_terminal_failure "$STATE_DIR")"; rc=$?; set -e
assert_eq "[DECOUPLING] non-acceptance member terminal → terminal (rc=0)" "0" "$rc"
assert_eq "[DECOUPLING] echoes the custom member id" "custom-check" "$out"

# ── [SPEC-3] membership guard: artifact present but member NOT in the cycle. ───
_CYCLE_STAGES=(build test)
_reset; _write_acc '{"verdict":"fail","disposition":"terminal","failures":["inert_wiring:config/x.yaml"]}'
set +e; _cycle_member_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-3] not a member → never blocks (rc=1)" "1" "$rc"

# ── [SPEC-3] member again, but result file missing → never falsely block. ──────
_CYCLE_STAGES=(build acceptance-gate review)
_reset
set +e; _cycle_member_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-3] missing result file → returns 1" "1" "$rc"

# ── [SPEC-3] garbage / unparseable JSON → never falsely block. ─────────────────
_reset; _write_acc 'not json at all'
set +e; _cycle_member_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-3] unparseable result → returns 1" "1" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
