#!/usr/bin/env bash
# tests/unit/gates-contract3-test.sh — the gate and housekeeping stages write
# result contract 3: one outcome from the engine's closed list (#2366, ADR-054 §6).
#
#   G1 [change] each manifest declares result_contract 3 and no valid_verdicts
#   G2 [change] lint/coverage/mutation: pass → pass, fail → fail, skip → pass;
#               no verdict or disposition field; the detail under data
#   G3 retired with design-gate (#2369: design checks its own design.md and
#      writes one outcome — design-checks-own-output-test.sh C1, C2)
#   G4 [change] assertion-integrity: nothing recorded yet → pass
#   G5 [change] secret-scan: no baseline → pass
#   G6 [change] teardown: hooks all clean → pass
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "gate and housekeeping stages write contract 3 (#2366)"
setup_test_env "gates-contract3"
export ZBUILD_EVENTS_DB="/dev/null"

for _p in lint-gate coverage-gate mutation-gate secret-scan shape-floor assertion-integrity hydrate persist teardown; do
    # shellcheck source=/dev/null
    source "$REPO_ROOT/plugins/tool/$_p/plugin.sh" >/dev/null 2>&1
done

_v3() {  # _v3 <label> <file> <outcome>
    local f="$2"
    assert_eq "$1: contract 3" "3" "$(jq -r '.result_contract' "$f" 2>/dev/null)"
    assert_eq "$1: outcome $3" "$3" "$(jq -r '.outcome' "$f" 2>/dev/null)"
    assert_eq "$1: no verdict or disposition" "false" "$(jq 'has("verdict") or has("disposition")' "$f" 2>/dev/null)"
}
_mkwork() { local w="$TEST_TEMP_DIR/$1"; mkdir -p "$w/artifacts"; printf '{}\n' > "$w/state.json"; printf '%s' "$w"; }

print_test_section "G1: manifests"
for _p in lint-gate coverage-gate mutation-gate secret-scan shape-floor assertion-integrity hydrate persist teardown; do
    _mf="$REPO_ROOT/plugins/tool/$_p/manifest.yaml"
    assert_eq "[G1] $_p declares result_contract 3" "3" \
        "$(awk '/^provides:/{f=1;next} f&&/^[a-zA-Z]/{exit} f&&/result_contract:/{sub(/.*result_contract:[[:space:]]*/,""); print; exit}' "$_mf")"
    if grep -q 'valid_verdicts' "$_mf"; then
        assert_fail "[G1] $_p declares no valid_verdicts" "found"
    else
        assert_pass "[G1] $_p declares no valid_verdicts"
    fi
done

print_test_section "G2: lint / coverage / mutation"
for _case in "pass|pass" "fail|fail" "skipped|pass"; do
    IFS='|' read -r _st _want <<< "$_case"
    W="$(_mkwork "lint-$_st")"
    jq -n --arg s "$_st" '{lint:{status:$s}}' > "$W/artifacts/test-results.json"
    lint_gate_run lint-gate "$W/state.json" >/dev/null 2>&1
    _v3 "[G2] lint status=$_st" "$W/artifacts/lint-result.json" "$_want"
done
assert_eq "[G2] lint's status is under data" "skipped" "$(jq -r '.data.status' "$W/artifacts/lint-result.json" 2>/dev/null)"
W="$(_mkwork cov-fail)"
jq -n '{coverage:{status:"measured",pct:10,floor:29}}' > "$W/artifacts/test-results.json"
coverage_gate_run coverage-gate "$W/state.json" >/dev/null 2>&1
_v3 "[G2] coverage below floor" "$W/artifacts/coverage-result.json" fail
assert_eq "[G2] coverage's pct is under data" "10" "$(jq -r '.data.pct' "$W/artifacts/coverage-result.json" 2>/dev/null)"
W="$(_mkwork cov-none)"
coverage_gate_run coverage-gate "$W/state.json" >/dev/null 2>&1
_v3 "[G2] no coverage block" "$W/artifacts/coverage-result.json" pass
W="$(_mkwork mut-pass)"
jq -n '{mutation:{status:"measured",score:"10/10",floor:0}}' > "$W/artifacts/test-results.json"
mutation_gate_run mutation-gate "$W/state.json" >/dev/null 2>&1
_v3 "[G2] mutation at floor" "$W/artifacts/mutation-result.json" pass

print_test_section "G4: assertion-integrity"
W="$(_mkwork ai)"
ZBUILD_REPO_ROOT="$TEST_TEMP_DIR" assertion_integrity_run assertion-integrity "$W/state.json" >/dev/null 2>&1
_v3 "[G4] nothing recorded yet" "$W/artifacts/assertion-integrity-result.json" pass

print_test_section "G5: secret-scan"
W="$(_mkwork ss)"
ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/not-a-repo" secret_scan_run secret-scan "$W/state.json" >/dev/null 2>&1
_v3 "[G5] no baseline" "$W/artifacts/secret-scan-result.json" pass

print_test_section "G6: teardown"
W="$(_mkwork td)"
printf '{"stage_statuses":{}}\n' > "$W/pipeline-state.json"
ZBUILD_STATE_DIR="$W" ZBUILD_ARTIFACT_DIR="$W/artifacts" teardown_run teardown "$W/pipeline-state.json" >/dev/null 2>&1
_v3 "[G6] nothing to clean" "$W/artifacts/teardown-result.json" pass

cleanup_test_env
print_test_results
exit $((FAIL > 0))
