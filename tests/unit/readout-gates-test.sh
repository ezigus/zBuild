#!/usr/bin/env bash
# Tests: ADR-040 (#1135, EPIC #1129) — lint-gate / coverage-gate / mutation-gate.
# Thin read-out gates that consume the SHARED test-framework result
# (test-results.json from the test stage, #1133) and NEVER re-run any tool.
# Each gate's verdict must match the relevant field of a SYNTHETIC fixture:
#   - skip when the file is absent or the block is skipped/missing
#   - fail on lint fail / coverage below floor / mutation below floor
#   - pass otherwise
# Every gate always returns rc=0; the verdict lives in its own artifact.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../plugins/tool/lint-gate/plugin.sh
source "$REPO_ROOT/plugins/tool/lint-gate/plugin.sh"
# shellcheck source=../../plugins/tool/coverage-gate/plugin.sh
source "$REPO_ROOT/plugins/tool/coverage-gate/plugin.sh"
# shellcheck source=../../plugins/tool/mutation-gate/plugin.sh
source "$REPO_ROOT/plugins/tool/mutation-gate/plugin.sh"

print_test_header "read-out gates — lint/coverage/mutation (#1135, ADR-040)"
setup_test_env "readout-gates"

_test_cleanup_hook() { cleanup_test_env; }

# Per-case work dir + artifacts. Echoes <work>; its state file is <work>/state.json
# (the gate derives artifacts_dir as dirname(state_file)/artifacts).
# Usage: W="$(_mkwork <name>)"
_mkwork() {
    local name="$1"
    local work="$TEST_TEMP_DIR/$name"
    mkdir -p "$work/artifacts"
    printf '{}\n' > "$work/state.json"
    printf '%s' "$work"
}

# Write a synthetic test-results.json carrying ONLY the supplied block.
# Usage: _seed_results <work> <jq-object-string>
_seed_results() {
    local work="$1" block="$2"
    jq -n "$block" > "$work/artifacts/test-results.json"
}

# ─── lint-gate ────────────────────────────────────────────────────────────────

# L1: lint.status pass → verdict=pass
W="$(_mkwork lint-pass)"
_seed_results "$W" '{lint:{status:"pass",exit_code:0,summary:"clean"}}'
lint_gate_run "lint-gate" "$W/state.json" >/dev/null 2>&1
_rc=$?
assert_eq "[L1] lint pass: rc=0" "0" "$_rc"
assert_json_key "[L1] lint pass → verdict=pass" "$(cat "$W/artifacts/lint-result.json")" '.verdict' "pass"

# L2: lint.status fail → verdict=fail
W="$(_mkwork lint-fail)"
_seed_results "$W" '{lint:{status:"fail",exit_code:2,summary:"3 errors"}}'
lint_gate_run "lint-gate" "$W/state.json" >/dev/null 2>&1
assert_json_key "[L2] lint fail → verdict=fail" "$(cat "$W/artifacts/lint-result.json")" '.verdict' "fail"

# L3: lint.status skipped → verdict=skip
W="$(_mkwork lint-skipped)"
_seed_results "$W" '{lint:{status:"skipped",exit_code:null,summary:""}}'
lint_gate_run "lint-gate" "$W/state.json" >/dev/null 2>&1
assert_json_key "[L3] lint skipped → verdict=skip" "$(cat "$W/artifacts/lint-result.json")" '.verdict' "skip"

# L4: no lint block → verdict=skip
W="$(_mkwork lint-noblock)"
_seed_results "$W" '{coverage:{status:"measured",pct:50,floor:29}}'
lint_gate_run "lint-gate" "$W/state.json" >/dev/null 2>&1
assert_json_key "[L4] missing lint block → verdict=skip" "$(cat "$W/artifacts/lint-result.json")" '.verdict' "skip"

# L5: test-results.json absent → verdict=skip
W="$(_mkwork lint-absent)"
lint_gate_run "lint-gate" "$W/state.json" >/dev/null 2>&1
assert_json_key "[L5] absent test-results → verdict=skip" "$(cat "$W/artifacts/lint-result.json")" '.verdict' "skip"

# ─── coverage-gate ────────────────────────────────────────────────────────────

# C1: measured, pct >= floor → pass
W="$(_mkwork cov-pass)"
_seed_results "$W" '{coverage:{status:"measured",pct:42.5,floor:29}}'
coverage_gate_run "coverage-gate" "$W/state.json" >/dev/null 2>&1
_rc=$?
assert_eq "[C1] coverage pass: rc=0" "0" "$_rc"
assert_json_key "[C1] measured pct>=floor → verdict=pass" "$(cat "$W/artifacts/coverage-result.json")" '.verdict' "pass"

# C2: measured, pct < floor → fail
W="$(_mkwork cov-belowfloor-measured)"
_seed_results "$W" '{coverage:{status:"measured",pct:12.0,floor:29}}'
coverage_gate_run "coverage-gate" "$W/state.json" >/dev/null 2>&1
assert_json_key "[C2] measured pct<floor → verdict=fail" "$(cat "$W/artifacts/coverage-result.json")" '.verdict' "fail"

# C3: status below_floor → fail (regardless of pct)
W="$(_mkwork cov-belowfloor-status)"
_seed_results "$W" '{coverage:{status:"below_floor",pct:5.0,floor:29}}'
coverage_gate_run "coverage-gate" "$W/state.json" >/dev/null 2>&1
assert_json_key "[C3] status below_floor → verdict=fail" "$(cat "$W/artifacts/coverage-result.json")" '.verdict' "fail"

# C4: status skipped → skip
W="$(_mkwork cov-skipped)"
_seed_results "$W" '{coverage:{status:"skipped",pct:null,floor:29}}'
coverage_gate_run "coverage-gate" "$W/state.json" >/dev/null 2>&1
assert_json_key "[C4] status skipped → verdict=skip" "$(cat "$W/artifacts/coverage-result.json")" '.verdict' "skip"

# C5: status error → skip
W="$(_mkwork cov-error)"
_seed_results "$W" '{coverage:{status:"error",pct:null,floor:29}}'
coverage_gate_run "coverage-gate" "$W/state.json" >/dev/null 2>&1
assert_json_key "[C5] status error → verdict=skip" "$(cat "$W/artifacts/coverage-result.json")" '.verdict' "skip"

# C6: recorded floor wins over env default (pct=20 < recorded floor 50 → fail)
W="$(_mkwork cov-recorded-floor)"
_seed_results "$W" '{coverage:{status:"measured",pct:20.0,floor:50}}'
ZBUILD_COVERAGE_FLOOR=10 coverage_gate_run "coverage-gate" "$W/state.json" >/dev/null 2>&1
assert_json_key "[C6] recorded floor wins → verdict=fail" "$(cat "$W/artifacts/coverage-result.json")" '.verdict' "fail"
assert_json_key "[C6] recorded floor reported" "$(cat "$W/artifacts/coverage-result.json")" '.floor' "50"

# C7: no coverage block → skip
W="$(_mkwork cov-noblock)"
_seed_results "$W" '{lint:{status:"pass"}}'
coverage_gate_run "coverage-gate" "$W/state.json" >/dev/null 2>&1
assert_json_key "[C7] missing coverage block → verdict=skip" "$(cat "$W/artifacts/coverage-result.json")" '.verdict' "skip"

# ─── mutation-gate ────────────────────────────────────────────────────────────

# M1: measured, N >= floor → pass
W="$(_mkwork mut-pass)"
_seed_results "$W" '{mutation:{status:"measured",score:"20/22",floor:15}}'
mutation_gate_run "mutation-gate" "$W/state.json" >/dev/null 2>&1
_rc=$?
assert_eq "[M1] mutation pass: rc=0" "0" "$_rc"
assert_json_key "[M1] measured N>=floor → verdict=pass" "$(cat "$W/artifacts/mutation-result.json")" '.verdict' "pass"

# M2: measured, N < floor → fail
W="$(_mkwork mut-fail)"
_seed_results "$W" '{mutation:{status:"measured",score:"5/22",floor:15}}'
mutation_gate_run "mutation-gate" "$W/state.json" >/dev/null 2>&1
assert_json_key "[M2] measured N<floor → verdict=fail" "$(cat "$W/artifacts/mutation-result.json")" '.verdict' "fail"

# M3: status skipped → skip
W="$(_mkwork mut-skipped)"
_seed_results "$W" '{mutation:{status:"skipped",score:null,floor:0}}'
mutation_gate_run "mutation-gate" "$W/state.json" >/dev/null 2>&1
assert_json_key "[M3] status skipped → verdict=skip" "$(cat "$W/artifacts/mutation-result.json")" '.verdict' "skip"

# M4: default floor 0 → any measured score passes
W="$(_mkwork mut-default-floor)"
_seed_results "$W" '{mutation:{status:"measured",score:"0/22",floor:0}}'
mutation_gate_run "mutation-gate" "$W/state.json" >/dev/null 2>&1
assert_json_key "[M4] default floor 0 → verdict=pass" "$(cat "$W/artifacts/mutation-result.json")" '.verdict' "pass"

# M5: no mutation block → skip
W="$(_mkwork mut-noblock)"
_seed_results "$W" '{lint:{status:"pass"}}'
mutation_gate_run "mutation-gate" "$W/state.json" >/dev/null 2>&1
assert_json_key "[M5] missing mutation block → verdict=skip" "$(cat "$W/artifacts/mutation-result.json")" '.verdict' "skip"

# M6: test-results.json absent → skip
W="$(_mkwork mut-absent)"
mutation_gate_run "mutation-gate" "$W/state.json" >/dev/null 2>&1
assert_json_key "[M6] absent test-results → verdict=skip" "$(cat "$W/artifacts/mutation-result.json")" '.verdict' "skip"

# ─── SPEC-2: result JSON carries result_contract:2 and disposition:complete ───
W="$(_mkwork rg-spec2-lint)"
_seed_results "$W" '{lint:{status:"pass"}}'
lint_gate_run "lint-gate" "$W/state.json" >/dev/null 2>&1
_J="$(cat "$W/artifacts/lint-result.json")"
assert_json_key "[SPEC-2] lint-gate → result_contract:2" "$_J" '.result_contract' "2"
assert_json_key "[SPEC-2] lint-gate → disposition:complete" "$_J" '.disposition' "complete"

W="$(_mkwork rg-spec2-cov)"
_seed_results "$W" '{coverage:{status:"measured",pct:50,floor:29}}'
coverage_gate_run "coverage-gate" "$W/state.json" >/dev/null 2>&1
_J="$(cat "$W/artifacts/coverage-result.json")"
assert_json_key "[SPEC-2] coverage-gate → result_contract:2" "$_J" '.result_contract' "2"
assert_json_key "[SPEC-2] coverage-gate → disposition:complete" "$_J" '.disposition' "complete"

W="$(_mkwork rg-spec2-mut)"
_seed_results "$W" '{mutation:{status:"measured",score:"10/10",floor:0}}'
mutation_gate_run "mutation-gate" "$W/state.json" >/dev/null 2>&1
_J="$(cat "$W/artifacts/mutation-result.json")"
assert_json_key "[SPEC-2] mutation-gate → result_contract:2" "$_J" '.result_contract' "2"
assert_json_key "[SPEC-2] mutation-gate → disposition:complete" "$_J" '.disposition' "complete"

# ─── SPEC-5: coverage/lint/mutation resolve test_results via ZBUILD_STAGE_INPUTS
_si_dir="$TEST_TEMP_DIR/si"
mkdir -p "$_si_dir"

jq -n '{lint:{status:"pass"}}' > "$_si_dir/lt.json"
_lt_si="$TEST_TEMP_DIR/lt-si.json"
jq -n --arg p "$_si_dir/lt.json" '{inputs:{test_results:$p}}' > "$_lt_si"
W="$(_mkwork rg-spec5-lint)"
# No test-results.json in artifacts dir — path must come from ZBUILD_STAGE_INPUTS.
ZBUILD_STAGE_INPUTS="$_lt_si" lint_gate_run "lint-gate" "$W/state.json" >/dev/null 2>&1
unset ZBUILD_STAGE_INPUTS
assert_json_key "[SPEC-5] lint-gate reads test_results from ZBUILD_STAGE_INPUTS → verdict=pass" \
    "$(cat "$W/artifacts/lint-result.json")" '.verdict' "pass"

jq -n '{coverage:{status:"measured",pct:80,floor:29}}' > "$_si_dir/cv.json"
_cv_si="$TEST_TEMP_DIR/cv-si.json"
jq -n --arg p "$_si_dir/cv.json" '{inputs:{test_results:$p}}' > "$_cv_si"
W="$(_mkwork rg-spec5-cov)"
ZBUILD_STAGE_INPUTS="$_cv_si" coverage_gate_run "coverage-gate" "$W/state.json" >/dev/null 2>&1
unset ZBUILD_STAGE_INPUTS
assert_json_key "[SPEC-5] coverage-gate reads test_results from ZBUILD_STAGE_INPUTS → verdict=pass" \
    "$(cat "$W/artifacts/coverage-result.json")" '.verdict' "pass"

jq -n '{mutation:{status:"measured",score:"10/10",floor:0}}' > "$_si_dir/mg.json"
_mg_si="$TEST_TEMP_DIR/mg-si.json"
jq -n --arg p "$_si_dir/mg.json" '{inputs:{test_results:$p}}' > "$_mg_si"
W="$(_mkwork rg-spec5-mut)"
ZBUILD_STAGE_INPUTS="$_mg_si" mutation_gate_run "mutation-gate" "$W/state.json" >/dev/null 2>&1
unset ZBUILD_STAGE_INPUTS
assert_json_key "[SPEC-5] mutation-gate reads test_results from ZBUILD_STAGE_INPUTS → verdict=pass" \
    "$(cat "$W/artifacts/mutation-result.json")" '.verdict' "pass"

# ─── Results ─────────────────────────────────────────────────────────────────

print_test_results
