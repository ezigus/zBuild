#!/usr/bin/env bash
# Tests: ADR-040 §2 (EPIC #1129 B1) — ROSTER-DRIVEN gate-aggregator.
# The must-pass set is discovered at runtime from the cycle members' own
# `convergence:` markers — no hardcoded gate list. A `convergence: gate` member
# is in the must-pass set; `advisory`/absent members are excluded; the aggregator
# excludes itself. Adding/removing a member from the cycle changes the must-pass
# set with NO edit to the plugin. When no cycle is in scope, it falls back to the
# legacy fixed set (regression safety — covered by gate-aggregator-test.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../plugins/tool/gate-aggregator/plugin.sh
source "$REPO_ROOT/plugins/tool/gate-aggregator/plugin.sh"

print_test_header "gate-aggregator — roster-driven must-pass (ADR-040 §2, B1)"
setup_test_env "gate-aggregator-roster"

# ─── Fixture plugins root: minimal manifests carrying convergence markers ─────
FX_ROOT="$TEST_TEMP_DIR/plugins"
# write_plugin <subdir> <id> <kind> <convergence|""> <role> <artifact_type>
write_plugin() {
    local dir="$FX_ROOT/$1" id="$2" kind="$3" conv="$4" role="$5" at="$6"
    mkdir -p "$dir"
    {
        printf 'id: %s\n' "$id"
        printf 'name: %s\n' "$id"
        printf 'kind: %s\n' "$kind"
        [[ -n "$conv" ]] && printf 'convergence: %s\n' "$conv"
        printf 'version: 0.1.0\n'
        printf 'hooks:\n  run: r\n'
        printf 'provides:\n  role: %s\n  artifact_type: %s\n' "$role" "$at"
        printf 'inputs: []\n'
        printf 'outputs:\n  - id: %s_result\n    type: file\n    path: ${artifact_dir}/%s\n    required: true\n    primary: true\n' "$id" "$at"
    } > "$dir/manifest.yaml"
}
# Two id-matching mechanical gates, one advisory lens, one role-bound gate (the
# member id differs from the manifest id — mirrors simple.yaml lint→lint-gate),
# and one marker-less "work" stage (mirrors build).
write_plugin tool/g_alpha  g_alpha   tool  gate     g_alpha   g-alpha-result.json
write_plugin tool/g_beta   g_beta    tool  gate     g_beta    g-beta-result.json
write_plugin agent/l_adv   l_adv     agent advisory l_adv     l-adv-result.json
write_plugin tool/g_role   g_role_pl tool  gate     g_role    g-role-result.json
write_plugin agent/worker  worker    agent ""       worker    work-summary.json

export ZBUILD_PLUGINS_ROOT="$FX_ROOT"

# fresh_state — clean state dir + artifacts subdir; echo the state file path.
fresh_state() {
    local d; d="$(mktemp -d "$TEST_TEMP_DIR/agg.XXXXXX")"
    mkdir -p "$d/artifacts"
    printf '%s\n' "$d/state.json"
}
write_verdict() { printf '{"verdict":"%s"}\n' "$3" > "$1/$2"; }
run_agg() {
    local sf="$1" ad; ad="$(dirname "$1")/artifacts"
    rm -f "$ad/gate-aggregator-result.json"
    gate_aggregator_run "gate-aggregator" "$sf" >/dev/null 2>&1 || true
    cat "$ad/gate-aggregator-result.json"
}

# Enter cycle scope: ZBUILD_CYCLE_ID + the exported cycle roster + the role
# binding for the role-bound member (grole → role g_role → manifest g_role_pl).
export ZBUILD_CYCLE_ID="mycycle"
export _TPL_CYCLE_STAGES_mycycle="worker,g_alpha,g_beta,l_adv,grole,gate-aggregator"
export _TPL_STAGE_ROLES_grole="g_role"

# ─── TC-1: all mechanical gates pass → verdict=pass; roster = the 3 gates ─────
print_test_section "TC-1: roster = present convergence:gate members; all pass → pass"
SF="$(fresh_state)"; AD="$(dirname "$SF")/artifacts"
write_verdict "$AD" "g-alpha-result.json" "pass"
write_verdict "$AD" "g-beta-result.json"  "pass"
write_verdict "$AD" "g-role-result.json"  "pass"
OUT="$(run_agg "$SF")"
assert_json_key "TC-1: all gates pass → verdict=pass" "$OUT" '.verdict' "pass"
assert_eq "TC-1: must-pass set has exactly 3 gates (the convergence:gate members)" \
    "3" "$(jq '.gates | length' <<< "$OUT")"
assert_eq "TC-1: id-matching gate g_alpha present"  "true" "$(jq '.gates | has("g_alpha")' <<< "$OUT")"
assert_eq "TC-1: role-bound gate grole present"     "true" "$(jq '.gates | has("grole")'   <<< "$OUT")"

# ─── TC-2: advisory + marker-less members are NOT in the must-pass set ────────
print_test_section "TC-2: advisory member (l_adv) and marker-less stage (worker) excluded"
assert_eq "TC-2: advisory l_adv NOT in must-pass set" "false" "$(jq '.gates | has("l_adv")' <<< "$OUT")"
assert_eq "TC-2: marker-less worker NOT in must-pass set" "false" "$(jq '.gates | has("worker")' <<< "$OUT")"

# ─── TC-3: one mechanical gate fails → verdict=fail, named in failed[] ────────
print_test_section "TC-3: one gate fails → verdict=fail"
SF="$(fresh_state)"; AD="$(dirname "$SF")/artifacts"
write_verdict "$AD" "g-alpha-result.json" "pass"
write_verdict "$AD" "g-beta-result.json"  "fail"
write_verdict "$AD" "g-role-result.json"  "pass"
OUT="$(run_agg "$SF")"
assert_json_key "TC-3: g_beta fail → verdict=fail" "$OUT" '.verdict' "fail"
assert_contains "TC-3: failed[] names g_beta" "$OUT" "g_beta"
# B2: consolidated feedback artifact written on fail.
assert_file_exists "TC-3: gate-feedback.md written on fail" "$AD/gate-feedback.md"
assert_contains "TC-3: feedback names the failing gate" "$(cat "$AD/gate-feedback.md")" "g_beta"

# ─── TC-4: removing a gate from the cycle changes the must-pass set (no plugin
#          edit) — g_beta is no longer required, so its fail no longer blocks ──
print_test_section "TC-4: roster adapts when a member is removed (NO plugin edit)"
export _TPL_CYCLE_STAGES_mycycle="worker,g_alpha,l_adv,grole,gate-aggregator"
SF="$(fresh_state)"; AD="$(dirname "$SF")/artifacts"
write_verdict "$AD" "g-alpha-result.json" "pass"
write_verdict "$AD" "g-beta-result.json"  "fail"   # present but no longer in roster
write_verdict "$AD" "g-role-result.json"  "pass"
OUT="$(run_agg "$SF")"
assert_json_key "TC-4: g_beta removed from cycle → verdict=pass despite its fail" "$OUT" '.verdict' "pass"
assert_eq "TC-4: must-pass set shrank to 2 gates" "2" "$(jq '.gates | length' <<< "$OUT")"
assert_eq "TC-4: g_beta no longer in must-pass set" "false" "$(jq '.gates | has("g_beta")' <<< "$OUT")"

# ─── TC-5: adding a gate member (re-add g_beta) makes its fail block again ────
print_test_section "TC-5: roster adapts when a member is added back (NO plugin edit)"
export _TPL_CYCLE_STAGES_mycycle="worker,g_alpha,g_beta,l_adv,grole,gate-aggregator"
OUT="$(run_agg "$SF")"   # same artifacts (g_beta still fail)
assert_json_key "TC-5: g_beta re-added → its fail blocks again (verdict=fail)" "$OUT" '.verdict' "fail"
assert_eq "TC-5: must-pass set back to 3 gates" "3" "$(jq '.gates | length' <<< "$OUT")"

# ─── TC-6: fallback path (no cycle env) still uses the legacy fixed set ───────
print_test_section "TC-6: no cycle in scope → legacy fallback (7 fixed gates)"
unset ZBUILD_CYCLE_ID _TPL_CYCLE_STAGES_mycycle
SF="$(fresh_state)"; AD="$(dirname "$SF")/artifacts"
for f in test-results.json shape-floor-result.json acceptance-gate-result.json \
         lint-result.json coverage-result.json mutation-result.json secret-scan-result.json; do
    write_verdict "$AD" "$f" "pass"
done
OUT="$(run_agg "$SF")"
assert_json_key "TC-6: fallback all-pass → verdict=pass" "$OUT" '.verdict' "pass"
assert_eq "TC-6: fallback must-pass set has the 7 legacy gates" "7" "$(jq '.gates | length' <<< "$OUT")"
assert_eq "TC-6: legacy 'suite' name present (not member-id mode)" "true" "$(jq '.gates | has("suite")' <<< "$OUT")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
