#!/usr/bin/env bash
# Tests: gate v2 result contract — result_contract:2, disposition, reason across
# all seven gate plugins (ADR-054, ADR-055 §9, issue #1848).
#
# SPEC-1: every manifest declares result_contract: 2
# SPEC-2: every gate result JSON carries result_contract:2, disposition:complete, reason
# SPEC-3: shape-floor emits disposition:broken when _sf_shape_floor is undefined
# SPEC-4: design-gate writes feedback on every verdict (including pass); manifest required:true
# SPEC-5: coverage/lint/mutation resolve test_results path via ZBUILD_STAGE_INPUTS
# SPEC-6: design-gate resolves design.md path via ZBUILD_STAGE_INPUTS
# SPEC-7: gate-aggregator aggregates correctly (all-pass→pass, any-fail→fail, advisory→pass, missing→fail-closed)
# SPEC-8: all seven gates return rc=0 on every exit path
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "gate v2 contract — result_contract:2 disposition reason (#1848)"
setup_test_env "gate-v2-contract"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENTS_DB="/dev/null"

# Source all seven gate plugins.
# shellcheck source=../../plugins/tool/coverage-gate/plugin.sh
source "$REPO_ROOT/plugins/tool/coverage-gate/plugin.sh"
# shellcheck source=../../plugins/tool/lint-gate/plugin.sh
source "$REPO_ROOT/plugins/tool/lint-gate/plugin.sh"
# shellcheck source=../../plugins/tool/mutation-gate/plugin.sh
source "$REPO_ROOT/plugins/tool/mutation-gate/plugin.sh"
# shellcheck source=../../plugins/tool/secret-scan/plugin.sh
source "$REPO_ROOT/plugins/tool/secret-scan/plugin.sh"
# shellcheck source=../../plugins/tool/shape-floor/plugin.sh
source "$REPO_ROOT/plugins/tool/shape-floor/plugin.sh"
# shellcheck source=../../plugins/tool/gate-aggregator/plugin.sh
source "$REPO_ROOT/plugins/tool/gate-aggregator/plugin.sh"
# shellcheck source=../../plugins/tool/design-gate/plugin.sh
source "$REPO_ROOT/plugins/tool/design-gate/plugin.sh"

_mkwork() {
    local name="$1"
    local work="$TEST_TEMP_DIR/$name"
    mkdir -p "$work/artifacts"
    printf '{}\n' > "$work/state.json"
    printf '%s' "$work"
}

_seed_results() {
    local work="$1" block="$2"
    jq -n "$block" > "$work/artifacts/test-results.json"
}

# gate-aggregator helpers: write result files for a roster of seven gates.
_GA_FILES=(test-results.json shape-floor-result.json acceptance-gate-result.json
           lint-result.json coverage-result.json mutation-result.json secret-scan-result.json)
_write_all_ga() {
    local dir="$1" verdict="$2"
    local f
    for f in "${_GA_FILES[@]}"; do
        printf '{"result_contract":2,"verdict":"%s","disposition":"complete","reason":"test"}\n' \
            "$verdict" > "$dir/$f"
    done
}

# ── SPEC-1: all seven manifests declare result_contract: 2 under provides: ────
for _plugin in coverage-gate design-gate gate-aggregator lint-gate mutation-gate secret-scan shape-floor; do
    _mf="$REPO_ROOT/plugins/tool/$_plugin/manifest.yaml"
    assert_contains "[SPEC-1] $_plugin manifest declares result_contract: 2" \
        "$(cat "$_mf")" "result_contract: 2"
done

# ── SPEC-4 (manifest): design_gate_feedback output must be required:true ──────
assert_eq "[SPEC-4] design-gate manifest has no required:false output (design_gate_feedback is now required:true)" \
    "0" "$(grep -c 'required: false' "$REPO_ROOT/plugins/tool/design-gate/manifest.yaml" 2>/dev/null || echo 0)"

# ── SPEC-5: coverage/lint/mutation resolve test_results via ZBUILD_STAGE_INPUTS ─
_SI_DIR="$TEST_TEMP_DIR/si-inputs"
mkdir -p "$_SI_DIR"

jq -n '{coverage:{status:"measured",pct:80,floor:29}}' > "$_SI_DIR/cv.json"
_CV_SI="$TEST_TEMP_DIR/cv-si.json"
jq -n --arg p "$_SI_DIR/cv.json" '{inputs:{test_results:$p}}' > "$_CV_SI"

W="$(_mkwork cv-si5)"
# Deliberately no test-results.json in artifacts dir — must come from ZBUILD_STAGE_INPUTS.
export ZBUILD_STAGE_INPUTS="$_CV_SI"
set +e; coverage_gate_run "coverage-gate" "$W/state.json" >/dev/null 2>&1; set -e
unset ZBUILD_STAGE_INPUTS
assert_json_key "[SPEC-5] coverage-gate reads test_results from ZBUILD_STAGE_INPUTS → verdict=pass" \
    "$(cat "$W/artifacts/coverage-result.json")" '.verdict' "pass"

jq -n '{lint:{status:"pass"}}' > "$_SI_DIR/lt.json"
_LT_SI="$TEST_TEMP_DIR/lt-si.json"
jq -n --arg p "$_SI_DIR/lt.json" '{inputs:{test_results:$p}}' > "$_LT_SI"

W="$(_mkwork lt-si5)"
export ZBUILD_STAGE_INPUTS="$_LT_SI"
set +e; lint_gate_run "lint-gate" "$W/state.json" >/dev/null 2>&1; set -e
unset ZBUILD_STAGE_INPUTS
assert_json_key "[SPEC-5] lint-gate reads test_results from ZBUILD_STAGE_INPUTS → verdict=pass" \
    "$(cat "$W/artifacts/lint-result.json")" '.verdict' "pass"

jq -n '{mutation:{status:"measured",score:"10/10",floor:0}}' > "$_SI_DIR/mg.json"
_MG_SI="$TEST_TEMP_DIR/mg-si.json"
jq -n --arg p "$_SI_DIR/mg.json" '{inputs:{test_results:$p}}' > "$_MG_SI"

W="$(_mkwork mg-si5)"
export ZBUILD_STAGE_INPUTS="$_MG_SI"
set +e; mutation_gate_run "mutation-gate" "$W/state.json" >/dev/null 2>&1; set -e
unset ZBUILD_STAGE_INPUTS
assert_json_key "[SPEC-5] mutation-gate reads test_results from ZBUILD_STAGE_INPUTS → verdict=pass" \
    "$(cat "$W/artifacts/mutation-result.json")" '.verdict' "pass"

# ── SPEC-6: design-gate resolves design.md via ZBUILD_STAGE_INPUTS ────────────
_DG_REPO="$TEST_TEMP_DIR/dg-repo"
mkdir -p "$_DG_REPO/scripts"
touch "$_DG_REPO/scripts/wire.sh"
export ZBUILD_REPO_ROOT="$_DG_REPO"

_DG_MD="$TEST_TEMP_DIR/custom-design.md"
printf '# Design\n\n```scope\nscripts/wire.sh\n```\n\n```acceptance\nSPEC-1[change]: thing\nTESTFILES:\ntests/v2-test.sh\nWIRING: scripts/wire.sh\n```\n' \
    > "$_DG_MD"
_DG_SI="$TEST_TEMP_DIR/dg-si.json"
jq -n --arg p "$_DG_MD" '{inputs:{design:$p}}' > "$_DG_SI"

W="$(_mkwork dg-si6)"
export ZBUILD_STAGE_INPUTS="$_DG_SI"
set +e; design_gate_run "design-gate" "$W/state.json" >/dev/null 2>&1; set -e
unset ZBUILD_STAGE_INPUTS
assert_json_key "[SPEC-6] design-gate reads design.md from ZBUILD_STAGE_INPUTS path → verdict=pass" \
    "$(cat "$W/artifacts/design-gate-result.json")" '.verdict' "pass"

# ── SPEC-4 (functional): design-gate writes feedback on every verdict ──────────
W="$(_mkwork dg-pass4)"
printf '# Design\n\n```scope\nscripts/wire.sh\n```\n\n```acceptance\nSPEC-1[change]: thing\nTESTFILES:\ntests/v2-test.sh\nWIRING: scripts/wire.sh\n```\n' \
    > "$W/artifacts/design.md"
set +e; design_gate_run "design-gate" "$W/state.json" >/dev/null 2>&1; _rc=$?; set -e
assert_eq "[SPEC-4][SPEC-8] design-gate clean design → rc=0" "0" "$_rc"
assert_eq "[SPEC-4] design-gate pass verdict → feedback file written" "present" \
    "$([[ -f "$W/artifacts/design-gate-feedback.md" ]] && echo present || echo absent)"

W="$(_mkwork dg-fail4)"
printf '# Design\n\n```scope\n```\n' > "$W/artifacts/design.md"
set +e; design_gate_run "design-gate" "$W/state.json" >/dev/null 2>&1; set -e
assert_eq "[SPEC-4] design-gate fail verdict → feedback file also written" "present" \
    "$([[ -f "$W/artifacts/design-gate-feedback.md" ]] && echo present || echo absent)"
unset ZBUILD_REPO_ROOT

# ── SPEC-2 + SPEC-8: every gate result JSON carries v2 fields on all paths ────

# coverage-gate: pass / fail / skip
W="$(_mkwork cv-v2-pass)"
_seed_results "$W" '{coverage:{status:"measured",pct:80,floor:29}}'
set +e; coverage_gate_run "coverage-gate" "$W/state.json" >/dev/null 2>&1; _rc=$?; set -e
assert_eq "[SPEC-8] coverage-gate pass → rc=0" "0" "$_rc"
_J="$(cat "$W/artifacts/coverage-result.json")"
assert_json_key "[SPEC-2] coverage-gate pass → result_contract:2" "$_J" '.result_contract' "2"
assert_json_key "[SPEC-2] coverage-gate pass → disposition:complete" "$_J" '.disposition' "complete"
assert_contains "[SPEC-2] coverage-gate pass → reason present" "$_J" '"reason"'

W="$(_mkwork cv-v2-fail)"
_seed_results "$W" '{coverage:{status:"measured",pct:10,floor:29}}'
set +e; coverage_gate_run "coverage-gate" "$W/state.json" >/dev/null 2>&1; _rc=$?; set -e
assert_eq "[SPEC-8] coverage-gate fail → rc=0" "0" "$_rc"
assert_json_key "[SPEC-2] coverage-gate fail → result_contract:2" \
    "$(cat "$W/artifacts/coverage-result.json")" '.result_contract' "2"

W="$(_mkwork cv-v2-skip)"
set +e; coverage_gate_run "coverage-gate" "$W/state.json" >/dev/null 2>&1; _rc=$?; set -e
assert_eq "[SPEC-8] coverage-gate skip → rc=0" "0" "$_rc"
assert_json_key "[SPEC-2] coverage-gate skip → result_contract:2" \
    "$(cat "$W/artifacts/coverage-result.json")" '.result_contract' "2"

# lint-gate: pass / fail / skip
W="$(_mkwork lt-v2-pass)"
_seed_results "$W" '{lint:{status:"pass"}}'
set +e; lint_gate_run "lint-gate" "$W/state.json" >/dev/null 2>&1; _rc=$?; set -e
assert_eq "[SPEC-8] lint-gate pass → rc=0" "0" "$_rc"
_J="$(cat "$W/artifacts/lint-result.json")"
assert_json_key "[SPEC-2] lint-gate pass → result_contract:2" "$_J" '.result_contract' "2"
assert_json_key "[SPEC-2] lint-gate pass → disposition:complete" "$_J" '.disposition' "complete"
assert_contains "[SPEC-2] lint-gate pass → reason present" "$_J" '"reason"'

W="$(_mkwork lt-v2-fail)"
_seed_results "$W" '{lint:{status:"fail"}}'
set +e; lint_gate_run "lint-gate" "$W/state.json" >/dev/null 2>&1; _rc=$?; set -e
assert_eq "[SPEC-8] lint-gate fail → rc=0" "0" "$_rc"
assert_json_key "[SPEC-2] lint-gate fail → result_contract:2" \
    "$(cat "$W/artifacts/lint-result.json")" '.result_contract' "2"

W="$(_mkwork lt-v2-skip)"
set +e; lint_gate_run "lint-gate" "$W/state.json" >/dev/null 2>&1; _rc=$?; set -e
assert_eq "[SPEC-8] lint-gate skip → rc=0" "0" "$_rc"
assert_json_key "[SPEC-2] lint-gate skip → result_contract:2" \
    "$(cat "$W/artifacts/lint-result.json")" '.result_contract' "2"

# mutation-gate: pass / fail / skip
W="$(_mkwork mg-v2-pass)"
_seed_results "$W" '{mutation:{status:"measured",score:"10/10",floor:0}}'
set +e; mutation_gate_run "mutation-gate" "$W/state.json" >/dev/null 2>&1; _rc=$?; set -e
assert_eq "[SPEC-8] mutation-gate pass → rc=0" "0" "$_rc"
_J="$(cat "$W/artifacts/mutation-result.json")"
assert_json_key "[SPEC-2] mutation-gate pass → result_contract:2" "$_J" '.result_contract' "2"
assert_json_key "[SPEC-2] mutation-gate pass → disposition:complete" "$_J" '.disposition' "complete"
assert_contains "[SPEC-2] mutation-gate pass → reason present" "$_J" '"reason"'

W="$(_mkwork mg-v2-fail)"
_seed_results "$W" '{mutation:{status:"measured",score:"5/22",floor:15}}'
set +e; mutation_gate_run "mutation-gate" "$W/state.json" >/dev/null 2>&1; _rc=$?; set -e
assert_eq "[SPEC-8] mutation-gate fail → rc=0" "0" "$_rc"
assert_json_key "[SPEC-2] mutation-gate fail → result_contract:2" \
    "$(cat "$W/artifacts/mutation-result.json")" '.result_contract' "2"

W="$(_mkwork mg-v2-skip)"
set +e; mutation_gate_run "mutation-gate" "$W/state.json" >/dev/null 2>&1; _rc=$?; set -e
assert_eq "[SPEC-8] mutation-gate skip → rc=0" "0" "$_rc"
assert_json_key "[SPEC-2] mutation-gate skip → result_contract:2" \
    "$(cat "$W/artifacts/mutation-result.json")" '.result_contract' "2"

# secret-scan: skip (no baseline in temp dir with no git history)
W="$(_mkwork ss-v2)"
_SS_TMPROOT="$TEST_TEMP_DIR/ss-no-repo"
mkdir -p "$_SS_TMPROOT"
export ZBUILD_REPO_ROOT="$_SS_TMPROOT"
set +e; secret_scan_run "secret-scan" "$W/state.json" >/dev/null 2>&1; _rc=$?; set -e
unset ZBUILD_REPO_ROOT
assert_eq "[SPEC-8] secret-scan skip → rc=0" "0" "$_rc"
_J="$(cat "$W/artifacts/secret-scan-result.json")"
assert_json_key "[SPEC-2] secret-scan skip → result_contract:2" "$_J" '.result_contract' "2"
assert_json_key "[SPEC-2] secret-scan skip → disposition:complete" "$_J" '.disposition' "complete"
assert_contains "[SPEC-2] secret-scan skip → reason present" "$_J" '"reason"'

# shape-floor: normal path (stub _sf_shape_floor to return skip)
_sf_shape_floor() { echo "SHAPE_FLOOR SKIP no shape-change files (test stub)"; }
W="$(_mkwork sf-v2-skip)"
set +e; shape_floor_run "shape-floor" "$W/state.json" >/dev/null 2>&1; _rc=$?; set -e
assert_eq "[SPEC-8] shape-floor skip → rc=0" "0" "$_rc"
_J="$(cat "$W/artifacts/shape-floor-result.json")"
assert_json_key "[SPEC-2] shape-floor skip → result_contract:2" "$_J" '.result_contract' "2"
assert_json_key "[SPEC-2] shape-floor skip → disposition:complete" "$_J" '.disposition' "complete"
assert_contains "[SPEC-2] shape-floor skip → reason present" "$_J" '"reason"'

# design-gate: v2 fields on pass path
export ZBUILD_REPO_ROOT="$_DG_REPO"
W="$(_mkwork dg-v2)"
printf '# Design\n\n```scope\nscripts/wire.sh\n```\n\n```acceptance\nSPEC-1[change]: thing\nTESTFILES:\ntests/v2-test.sh\nWIRING: scripts/wire.sh\n```\n' \
    > "$W/artifacts/design.md"
set +e; design_gate_run "design-gate" "$W/state.json" >/dev/null 2>&1; _rc=$?; set -e
unset ZBUILD_REPO_ROOT
assert_eq "[SPEC-8] design-gate pass → rc=0" "0" "$_rc"
_J="$(cat "$W/artifacts/design-gate-result.json")"
assert_json_key "[SPEC-2] design-gate pass → result_contract:2" "$_J" '.result_contract' "2"
assert_json_key "[SPEC-2] design-gate pass → disposition:complete" "$_J" '.disposition' "complete"
assert_contains "[SPEC-2] design-gate pass → reason present" "$_J" '"reason"'

# gate-aggregator: v2 fields on pass path
W="$(_mkwork ga-v2-pass)"
_write_all_ga "$W/artifacts" "pass"
set +e; gate_aggregator_run "gate-aggregator" "$W/state.json" >/dev/null 2>&1; _rc=$?; set -e
assert_eq "[SPEC-8] gate-aggregator pass → rc=0" "0" "$_rc"
_J="$(cat "$W/artifacts/gate-aggregator-result.json")"
assert_json_key "[SPEC-2] gate-aggregator pass → result_contract:2" "$_J" '.result_contract' "2"
assert_json_key "[SPEC-2] gate-aggregator pass → disposition:complete" "$_J" '.disposition' "complete"
assert_contains "[SPEC-2] gate-aggregator pass → reason present" "$_J" '"reason"'

# ── SPEC-3: shape-floor emits disposition:broken when _sf_shape_floor undefined ─
unset -f _sf_shape_floor 2>/dev/null || true
W="$(_mkwork sf-broken)"
set +e; shape_floor_run "shape-floor" "$W/state.json" >/dev/null 2>&1; _rc=$?; set -e
assert_eq "[SPEC-3][SPEC-8] shape-floor library not loaded → rc=0" "0" "$_rc"
_J="$(cat "$W/artifacts/shape-floor-result.json")"
assert_json_key "[SPEC-3] shape-floor library not loaded → disposition:broken" "$_J" '.disposition' "broken"
assert_json_key "[SPEC-3] shape-floor library not loaded → reason:library_load_failure" "$_J" '.reason' "library_load_failure"

# ── SPEC-7: gate-aggregator aggregation cases (all-pass/fail/advisory/missing) ─

W="$(_mkwork ga-7-pass)"
_write_all_ga "$W/artifacts" "pass"
set +e; gate_aggregator_run "gate-aggregator" "$W/state.json" >/dev/null 2>&1; _rc=$?; set -e
assert_eq "[SPEC-7][SPEC-8] gate-aggregator all-pass → rc=0" "0" "$_rc"
assert_json_key "[SPEC-7] gate-aggregator all-pass → verdict=pass" \
    "$(cat "$W/artifacts/gate-aggregator-result.json")" '.verdict' "pass"

W="$(_mkwork ga-7-fail)"
_write_all_ga "$W/artifacts" "pass"
printf '{"result_contract":2,"verdict":"fail","disposition":"complete","reason":"cov below floor"}\n' \
    > "$W/artifacts/coverage-result.json"
set +e; gate_aggregator_run "gate-aggregator" "$W/state.json" >/dev/null 2>&1; _rc=$?; set -e
assert_eq "[SPEC-8] gate-aggregator any-fail path → rc=0" "0" "$_rc"
assert_json_key "[SPEC-7] gate-aggregator any-fail → verdict=fail" \
    "$(cat "$W/artifacts/gate-aggregator-result.json")" '.verdict' "fail"

W="$(_mkwork ga-7-advisory)"
_write_all_ga "$W/artifacts" "pass"
printf '{"result_contract":2,"verdict":"fail","disposition":"advisory","reason":"infra flake"}\n' \
    > "$W/artifacts/acceptance-gate-result.json"
set +e; gate_aggregator_run "gate-aggregator" "$W/state.json" >/dev/null 2>&1; _rc=$?; set -e
assert_json_key "[SPEC-7] gate-aggregator advisory-demoted → verdict=pass" \
    "$(cat "$W/artifacts/gate-aggregator-result.json")" '.verdict' "pass"

W="$(_mkwork ga-7-missing)"
_write_all_ga "$W/artifacts" "pass"
rm -f "$W/artifacts/lint-result.json"
set +e; gate_aggregator_run "gate-aggregator" "$W/state.json" >/dev/null 2>&1; _rc=$?; set -e
assert_eq "[SPEC-8] gate-aggregator missing-gate → rc=0" "0" "$_rc"
assert_json_key "[SPEC-7] gate-aggregator missing gate → fail-closed" \
    "$(cat "$W/artifacts/gate-aggregator-result.json")" '.verdict' "fail"

print_test_results
