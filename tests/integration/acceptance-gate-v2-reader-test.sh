#!/usr/bin/env bash
# Integration (#2161): the acceptance gate's result survives the engine's own
# v2 reader on EVERY path — a green gate must not block the run.
#
# #1840 run 6: the gate passed all 19 SPECs and the run ended `failed/blocked`
# 15 s later — the pass-path result had no `reason` and `disposition: none`,
# a word outside ADR-054's closed set. The failure paths carried the same
# wrong vocabulary (`recoverable`/`terminal`/`advisory`) and were only ever
# tolerated because rc≠0 short-circuits the reader. The cycle-policy word now
# lives in its own field, `severity`.
#
# [SPEC-1] (CHANGE): a PASSING gate (rc 0) read by runner_read_stage_verdict
#   classifies as `pass` with NO stage.verdict.contract_violation; the result
#   carries a non-empty reason and disposition=complete.
# [SPEC-2] (CHANGE): a FAILING gate's result, read with rc 0 (the reader does
#   not short-circuit), raises no contract violation: disposition=complete,
#   reason non-empty, and the cycle-policy word is in `severity`
#   (recoverable here).
# [SPEC-3] (CHANGE): the precondition-unmet no-op and the malformed-block
#   fail both pass the reader; malformed carries severity=terminal.
# [SPEC-4] (GUARD): the orchestrator still halts on a terminal member and the
#   aggregator still demotes an advisory one — read from `severity`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "acceptance-gate result passes the engine's v2 reader on every path (#2161)"
setup_test_env "acceptance-gate-v2-reader"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
GIT="$(command -v git)"
GATE_MANIFEST="$REPO_ROOT/plugins/agent/spec-acceptance/manifest.yaml"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"

_run_gate() {   # <repo> → RC, RESULT, STATE (state dir), EVENTS
    local repo="$1"
    STATE="$repo/.zbuild-state"
    mkdir -p "$STATE/artifacts"
    export ZBUILD_EVENTS_DIR="$STATE/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
    export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
    cp "$repo/design.md" "$STATE/artifacts/design.md" 2>/dev/null || true
    unset _ZBUILD_ACCEPTANCE_GATE_LOADED _ACCEPTANCE_REACHABILITY_LOADED \
          _ACCEPTANCE_NEGCTL_LOADED _ACCEPTANCE_BLOCK_LOADED _ZBUILD_MERGE_BASE_LOADED \
          _ACCEPTANCE_COVERAGE_LOADED
    # shellcheck disable=SC1090
    ( cd "$repo" && source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" \
        && acceptance_gate_run "acceptance-gate" "$STATE/pipeline-state.json" )
    RC=$?
    RESULT="$(cat "$STATE/artifacts/acceptance-gate-result.json" 2>/dev/null || echo '{}')"
    EVENTS="$ZBUILD_EVENTS_JSONL"
}
# The engine's reader over the result on disk, with rc 0 so nothing short-circuits.
_read() { runner_read_stage_verdict "$STATE" "$GATE_MANIFEST" "acceptance-gate" 0; }
_violations() { grep -c 'stage.verdict.contract_violation' "$EVENTS" 2>/dev/null || true; }
_field() { jq -r --arg k "$1" '.[$k] // ""' <<< "$RESULT" 2>/dev/null; }

# ─── fixture: one [change] SPEC, assertion fails at baseline, passes at HEAD ──
_mk_repo() {   # <name> <head-mark ✓|✗> → path  (the gate judges tagged ✓/✗ lines)
    local repo; repo="$(setup_git_temp_repo "$1")"
    (
        cd "$repo"
        "$GIT" checkout -q -b feature
        mkdir -p tests
        printf '#!/usr/bin/env bash\nexit 0\n' > impl.sh
        printf '#!/usr/bin/env bash\n# [SPEC-1] fails at baseline (impl absent)\n[[ -f impl.sh ]] || exit 1\necho "%s [SPEC-1] impl present"\n[[ "%s" == "✓" ]]\n' "$2" "$2" > tests/feature-test.sh
        chmod +x tests/feature-test.sh impl.sh
        "$GIT" add -A; "$GIT" commit -q -m "feat"
    ) >/dev/null 2>&1
    cat > "$repo/design.md" <<'EOF2'
```acceptance
SPEC-1[change]: the implementation file exists
TESTFILES:
tests/feature-test.sh
```
EOF2
    printf '%s' "$repo"
}

# ─── SPEC-1: a passing gate is a pass to the engine ──────────────────────────
print_test_section "SPEC-1: a green gate reads as pass — no contract violation"
REPO_PASS="$(_mk_repo "gate-v2-pass" "✓")"
set +e; _run_gate "$REPO_PASS"; set -e
assert_eq "[SPEC-1] the gate itself passed (rc 0)" "0" "$RC"
assert_eq "[SPEC-1] verdict pass" "pass" "$(_field verdict)"
_cls="$(_read)"
assert_eq "[SPEC-1] runner_read_stage_verdict classifies the result as pass (was error: missing_field:reason)" "pass" "$_cls"
assert_eq "[SPEC-1] no stage.verdict.contract_violation emitted" "0" "$(_violations)"
assert_eq "[SPEC-1] disposition is complete (was none)" "complete" "$(_field disposition)"
if [[ -n "$(_field reason)" ]]; then assert_pass "[SPEC-1] reason is non-empty: $(_field reason)"; else assert_fail "[SPEC-1] reason is non-empty" "absent"; fi
assert_eq "[SPEC-1] severity none on a pass" "none" "$(_field severity)"

# ─── SPEC-2: a failing gate carries its policy word in severity ──────────────
print_test_section "SPEC-2: a failing gate's result also passes the reader; policy word in severity"
REPO_FAIL="$(_mk_repo "gate-v2-fail" "✗")"   # red at HEAD too → not_passing_at_head (recoverable)
set +e; _run_gate "$REPO_FAIL"; set -e
assert_eq "[SPEC-2] the gate failed (rc 1)" "1" "$RC"
assert_eq "[SPEC-2] verdict fail" "fail" "$(_field verdict)"
_cls="$(_read)"
assert_eq "[SPEC-2] read with rc 0 the reader still sees a valid v2 result (fail, not error)" "fail" "$_cls"
assert_eq "[SPEC-2] no contract violation (was unknown_disposition:recoverable)" "0" "$(_violations)"
assert_eq "[SPEC-2] disposition is complete" "complete" "$(_field disposition)"
assert_eq "[SPEC-2] severity carries the cycle-policy word" "recoverable" "$(_field severity)"
assert_contains "[SPEC-2] reason names the SPEC" "$(_field reason)" "SPEC-1"

# ─── SPEC-3: the no-op and the malformed paths ───────────────────────────────
print_test_section "SPEC-3: precondition-unmet no-op and malformed block pass the reader"
REPO_NOOP="$(_mk_repo "gate-v2-noop" "✓")"; rm -f "$REPO_NOOP/design.md"
set +e; _run_gate "$REPO_NOOP"; set -e
assert_eq "[SPEC-3] no design → precondition_unmet pass" "pass|precondition_unmet" "$(_field verdict)|$(_field reason)"
assert_eq "[SPEC-3] …reads as pass with no violation" "pass|0" "$(_read)|$(_violations)"
assert_eq "[SPEC-3] …disposition complete, severity none" "complete|none" "$(_field disposition)|$(_field severity)"
REPO_BAD="$(_mk_repo "gate-v2-bad" "✓")"
printf '```acceptance\nthis is not a SPEC line\n```\n' > "$REPO_BAD/design.md"
set +e; _run_gate "$REPO_BAD"; set -e
assert_eq "[SPEC-3] malformed block → fail/malformed_acceptance_block" "fail|malformed_acceptance_block" "$(_field verdict)|$(_field reason)"
assert_eq "[SPEC-3] …no violation; severity terminal; disposition complete" "0|terminal|complete" "$(_violations)|$(_field severity)|$(_field disposition)"

# ─── SPEC-4: the two consumers of the policy word read severity ──────────────
print_test_section "SPEC-4: orchestrator halt-on-terminal and aggregator advisory read severity"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck source=../../plugins/tool/gate-aggregator/plugin.sh
source "$REPO_ROOT/plugins/tool/gate-aggregator/plugin.sh"
SD="$TEST_TEMP_DIR/sd"; mkdir -p "$SD/artifacts"
# A member id that resolves by id (the live gate resolves by ROLE through the
# template, which this unit-level probe does not load).
PR4="$TEST_TEMP_DIR/plugins4"; mkdir -p "$PR4/agent/acceptance-gate"
cat > "$PR4/agent/acceptance-gate/manifest.yaml" <<'EOF'
id: acceptance-gate
name: probe
kind: agent
version: 0.0.1
convergence: gate
hooks:
  run: acceptance_gate_run
provides:
  role: acceptance_gate
outputs:
  - id: acceptance_result
    path: ${artifact_dir}/acceptance-gate-result.json
    type: acceptance-gate-result.json@1
    required: true
    primary: true
EOF
export ZBUILD_PLUGINS_ROOT="$PR4"
_CYCLE_STAGES=(acceptance-gate)
printf '{"result_contract":2,"verdict":"fail","disposition":"complete","severity":"terminal","reason":"malformed_acceptance_block","failures":["malformed_acceptance_block"]}\n' > "$SD/artifacts/acceptance-gate-result.json"
_m="$(_cycle_member_terminal_failure "$SD" 2>/dev/null || true)"
assert_eq "[SPEC-4] the orchestrator halts on severity=terminal (disposition=complete)" "acceptance-gate" "$_m"
printf '{"result_contract":2,"verdict":"fail","disposition":"complete","severity":"recoverable","reason":"x","failures":["untagged_spec:SPEC-1"]}\n' > "$SD/artifacts/acceptance-gate-result.json"
_m="$(_cycle_member_terminal_failure "$SD" 2>/dev/null || true)"
assert_eq "[SPEC-4] …and not on severity=recoverable" "" "$_m"
printf '{"result_contract":2,"verdict":"fail","disposition":"complete","severity":"advisory","reason":"negctl harness","failures":["negctl_error:harness:SPEC-1"]}\n' > "$SD/artifacts/adv.json"
assert_eq "[SPEC-4] the aggregator demotes severity=advisory to non-blocking" "advisory" "$(_ga_read_gate_verdict "$SD/artifacts/adv.json")"
printf '{"verdict":"fail","disposition":"advisory","reason":"legacy fixture"}\n' > "$SD/artifacts/adv1.json"
assert_eq "[SPEC-4] a v1-shaped fixture with the word in disposition still demotes (fallback)" "advisory" "$(_ga_read_gate_verdict "$SD/artifacts/adv1.json")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
