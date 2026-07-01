#!/usr/bin/env bash
# Tests: ADR-040 §2/§5 (#1137, EPIC #1129 B5) — gate-aggregator plugin.
# The single merge-blocking convergence construct: collapses the mechanical
# must-pass gate verdicts into ONE verdict. Truth table:
#   all-pass → pass;  any-fail → fail;  skips ignored;  missing/malformed
#   REQUIRED gate → fail-closed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../plugins/tool/gate-aggregator/plugin.sh
source "$REPO_ROOT/plugins/tool/gate-aggregator/plugin.sh"

print_test_header "gate-aggregator — convergence verdict (#1137, ADR-040)"
setup_test_env "gate-aggregator"

# The seven must-pass gate result filenames (gate_name → artifact filename).
_GATE_FILES=(
    "test-results.json"
    "shape-floor-result.json"
    "acceptance-gate-result.json"
    "lint-result.json"
    "coverage-result.json"
    "mutation-result.json"
    "secret-scan-result.json"
)

# fresh_artifacts — make a clean state dir + artifacts subdir, echo the state file.
fresh_artifacts() {
    local d; d="$(mktemp -d "$TEST_TEMP_DIR/agg.XXXXXX")"
    mkdir -p "$d/artifacts"
    printf '%s\n' "$d/state.json"
}

# write_verdict <artifacts_dir> <filename> <verdict>
write_verdict() {
    printf '{"verdict":"%s"}\n' "$3" > "$1/$2"
}

# write_all <artifacts_dir> <verdict> — write the given verdict to every gate.
write_all() {
    local f
    for f in "${_GATE_FILES[@]}"; do write_verdict "$1" "$f" "$2"; done
}

# run_agg <state_file> → echoes the result JSON.
run_agg() {
    local sf="$1" ad; ad="$(dirname "$1")/artifacts"
    rm -f "$ad/gate-aggregator-result.json"
    gate_aggregator_run "gate-aggregator" "$sf" >/dev/null 2>&1 || true
    cat "$ad/gate-aggregator-result.json"
}

# ── TC-1: all gates pass → verdict=pass ──────────────────────────────────────
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
OUT="$(run_agg "$SF")"
assert_json_key "TC-1: all-pass → verdict=pass" "$OUT" '.verdict' "pass"
assert_eq "TC-1: no failed gates" "0" "$(jq '.failed | length' <<< "$OUT")"

# ── TC-2: skips are ignored (present, verdict=skip) → pass ───────────────────
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
write_verdict "$AD" "shape-floor-result.json" "skip"
write_verdict "$AD" "secret-scan-result.json" "skip"
write_verdict "$AD" "mutation-result.json" "skip"
OUT="$(run_agg "$SF")"
assert_json_key "TC-2: skips ignored → verdict=pass" "$OUT" '.verdict' "pass"

# ── TC-3: any single fail → verdict=fail (named in failed[]) ─────────────────
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
write_verdict "$AD" "coverage-result.json" "fail"
OUT="$(run_agg "$SF")"
assert_json_key "TC-3: one fail → verdict=fail" "$OUT" '.verdict' "fail"
assert_contains "TC-3: failed[] names the coverage gate" "$OUT" "coverage"

# ── TC-4: a missing REQUIRED gate → fail-closed (NOT skip) ───────────────────
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
rm -f "$AD/mutation-result.json"
OUT="$(run_agg "$SF")"
assert_json_key "TC-4: missing gate → fail-closed" "$OUT" '.verdict' "fail"
assert_json_key "TC-4: missing gate status=missing" "$OUT" '.gates.mutation' "missing"

# ── TC-5: a malformed REQUIRED gate (no verdict key) → fail-closed ───────────
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
printf '{ this is not json ' > "$AD/lint-result.json"
OUT="$(run_agg "$SF")"
assert_json_key "TC-5: malformed gate → fail-closed" "$OUT" '.verdict' "fail"
assert_json_key "TC-5: malformed gate status=malformed" "$OUT" '.gates.lint' "malformed"

# ── TC-6: test stage 'error' verdict is indeterminate → fail ─────────────────
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
write_verdict "$AD" "test-results.json" "error"
OUT="$(run_agg "$SF")"
assert_json_key "TC-6: suite error → verdict=fail" "$OUT" '.verdict' "fail"
assert_contains "TC-6: failed[] names the suite gate" "$OUT" "suite"

# ── TC-7: gates map records all seven gate names ─────────────────────────────
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
OUT="$(run_agg "$SF")"
assert_eq "TC-7: gates map has seven entries" "7" "$(jq '.gates | length' <<< "$OUT")"

# ── TC-8: a member with verdict=fail BUT disposition=advisory is NON-blocking ─
# (generic member-disposition contract, ADR-021): an advisory failure (e.g. an
# infra flake) must NOT block convergence — status=advisory, NOT in failed[].
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
printf '{"verdict":"fail","disposition":"advisory","failures":["negctl_error:timeout:SPEC-1"]}\n' \
    > "$AD/acceptance-gate-result.json"
OUT="$(run_agg "$SF")"
assert_json_key "TC-8: advisory fail → verdict=pass (non-blocking)" "$OUT" '.verdict' "pass"
assert_json_key "TC-8: advisory member status=advisory" "$OUT" '.gates."acceptance-gate"' "advisory"
assert_eq "TC-8: advisory member NOT in failed[]" "0" "$(jq '.failed | length' <<< "$OUT")"

# ── TC-9: verdict=fail with disposition=recoverable STAYS blocking ────────────
# recoverable drives another build iteration — it must NOT satisfy convergence.
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
printf '{"verdict":"fail","disposition":"recoverable","failures":["untagged_spec:SPEC-1"]}\n' \
    > "$AD/acceptance-gate-result.json"
OUT="$(run_agg "$SF")"
assert_json_key "TC-9: recoverable fail → verdict=fail (still blocking)" "$OUT" '.verdict' "fail"
assert_contains "TC-9: failed[] names the acceptance-gate" "$OUT" "acceptance-gate"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
