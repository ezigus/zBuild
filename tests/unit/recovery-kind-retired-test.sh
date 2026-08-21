#!/usr/bin/env bash
# tests/unit/recovery-kind-retired-test.sh
# Issue #1900 — `kind: recovery` is RETIRED, not merely unimplemented.
#
# It was never a plugin kind in practice (no manifest ever declared it), and every
# action verb it existed to return is owned by the engine now: retry/escalate/halt
# by the `disposition` response table (ADR-054 §6, core/pipeline/disposition.sh) and
# backtrack by `route_back` (ADR-045). ADR-054 also inverted its premise — retry
# policy moved OUT of plugins — so the kind has nothing left to own.
#
# The [change] assertions all fail at merge-base (where `recovery` is a valid kind
# with `classify`/`act` hooks and the three events are registered). The [guard]
# assertions prove the removal was surgical: the five surviving kinds and their
# kind-specific hooks are untouched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/manifest-validation.sh
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh"

print_test_header "kind:recovery retired — kind, hooks, and events (issue #1900)"

setup_test_env "recovery-kind-retired"
FIXTURE_DIR="$TEST_TEMP_DIR/fixtures"
mkdir -p "$FIXTURE_DIR"

SCHEMA="$REPO_ROOT/config/event-schema.json"

# ─── SPEC-1 [change]: `recovery` is gone from the valid-kind set ─────────────
found=0
for k in "${ZBUILD_PLUGIN_KINDS[@]}"; do
    [[ "$k" == "recovery" ]] && found=1
done
assert_eq "[SPEC-1][change] 'recovery' is NOT in ZBUILD_PLUGIN_KINDS" "0" "$found"

# ─── SPEC-2 [change]: a kind:recovery manifest is REFUSED ────────────────────
# The whole point of the retirement: the engine must reject one, not merely stop
# documenting it. Without this the kind would still be silently constructible.
MANIFEST="$FIXTURE_DIR/recovery.yaml"
cat > "$MANIFEST" <<'EOF'
id: some-recovery
name: Some Recovery
kind: recovery
version: 0.1.0
hooks:
  classify: some_recovery_classify
  act: some_recovery_act
EOF

set +e
err_out="$(validate_manifest "$MANIFEST" 2>&1)"
rc=$?
set -e
assert_eq "[SPEC-2][change] kind:recovery manifest fails validate_manifest" "1" "$rc"
assert_contains "[SPEC-2][change] error reports the invalid kind" "$err_out" "invalid kind: recovery"

# ─── SPEC-3 [guard]: control — the same shape as kind:tool still PASSES ──────
# Guards SPEC-2 against passing for an unrelated reason (a malformed fixture would
# fail validation whatever its kind).
MANIFEST="$FIXTURE_DIR/tool.yaml"
cat > "$MANIFEST" <<'EOF'
id: some-tool
name: Some Tool
kind: tool
version: 0.1.0
hooks:
  run: some_tool_run
EOF

set +e
validate_manifest "$MANIFEST" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-3][guard] control: an otherwise-identical kind:tool manifest validates" "0" "$rc"

# ─── SPEC-4 [change]: `classify`/`act` are no longer required hooks ──────────
recovery_hooks="$(_required_hooks_for_kind recovery)"
assert_eq "[SPEC-4][change] _required_hooks_for_kind recovery returns nothing" "" "$recovery_hooks"

# ─── SPEC-5 [guard]: the surviving kinds keep their kind-specific hooks ──────
# Proves the edit removed one case arm, not the kind-specific-hook mechanism —
# `classify`/`act` were NOT a lifecycle violation, they were the same shape as
# these, so a careless fix could have taken them too.
assert_eq "[SPEC-5][guard] agent still requires run" "run" "$(_required_hooks_for_kind agent)"
assert_eq "[SPEC-5][guard] tool still requires run" "run" "$(_required_hooks_for_kind tool)"
assert_eq "[SPEC-5][guard] orchestrator still requires run" "run" "$(_required_hooks_for_kind orchestrator)"
assert_eq "[SPEC-5][guard] claim-coordinator keeps its four hooks" \
    "claim release heartbeat list_claims" "$(_required_hooks_for_kind claim-coordinator)"
assert_eq "[SPEC-5][guard] daemon still requires tick" "tick" "$(_required_hooks_for_kind daemon)"

# ─── SPEC-6 [guard]: all five surviving kinds are still registered ───────────
for k in agent tool orchestrator claim-coordinator daemon persona; do
    _f=0
    for reg in "${ZBUILD_PLUGIN_KINDS[@]}"; do
        [[ "$reg" == "$k" ]] && _f=1
    done
    assert_eq "[SPEC-6][guard] '$k' is still a valid kind" "1" "$_f"
done

# ─── SPEC-7 [change]: the three recovery.* events are deregistered ───────────
# They never had an emitter — their one documented producer (`cq-backtrack`,
# ADR-013) was never built either — so nothing regresses by removing them.
for ev in recovery.suggestion recovery.action recovery.exhausted; do
    if jq -e --arg t "$ev" '.known_types | index($t)' "$SCHEMA" >/dev/null 2>&1; then
        assert_fail "[SPEC-7][change] '$ev' is absent from event-schema.json" \
            "still present in known_types"
    else
        assert_pass "[SPEC-7][change] '$ev' is absent from event-schema.json"
    fi
done

# ─── SPEC-8 [guard]: the schema is still valid and its neighbours survive ────
# A blunt delete could have broken JSON syntax or taken adjacent entries with it;
# stage_io.fd_fallback and cycle.start bracket the removed block.
if jq -e '.known_types | length > 0' "$SCHEMA" >/dev/null 2>&1; then
    assert_pass "[SPEC-8][guard] event-schema.json is still valid JSON with a non-empty known_types"
else
    assert_fail "[SPEC-8][guard] event-schema.json is still valid JSON with a non-empty known_types" \
        "jq could not read known_types"
fi
for ev in stage_io.fd_fallback cycle.start; do
    if jq -e --arg t "$ev" '.known_types | index($t)' "$SCHEMA" >/dev/null 2>&1; then
        assert_pass "[SPEC-8][guard] neighbouring event '$ev' survived the removal"
    else
        assert_fail "[SPEC-8][guard] neighbouring event '$ev' survived the removal" \
            "removed alongside the recovery block"
    fi
done

# ─── SPEC-9 [change]: no manifest anywhere declares the retired kind ─────────
# /usr/bin/grep, not `grep`: the repo default may be ugrep. `|| true` because a
# clean repo means grep matches nothing and exits 1 — which is the passing case,
# and under `set -o pipefail` would otherwise abort the test before it asserts.
_SYSGREP=/usr/bin/grep; [[ -x "$_SYSGREP" ]] || _SYSGREP="grep"
_decl="$("$_SYSGREP" -rl '^kind: *recovery' "$REPO_ROOT/plugins" 2>/dev/null | wc -l | tr -d ' ')" || true
assert_eq "[SPEC-9][change] no plugin manifest declares kind:recovery" "0" "$_decl"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
