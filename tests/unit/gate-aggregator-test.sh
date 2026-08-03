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

# ── TC-10 (#1219, retained mechanism): a FAILED gate carrying route_target → verdict=route_<target> ─
# ADR-045/ADR-040: the generic `route_target` rollup is RETAINED (dormant) for any
# future genuinely design-rooted class. As of #1583 tautology NO LONGER sets
# route_target (it is build-fixable — see TC-10b), so this case uses a SYNTHETIC
# route_target=design result to exercise the aggregator's generic rollup path.
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
printf '{"verdict":"fail","disposition":"terminal","route_target":"design","reason":"a hypothetical design-rooted failure","failures":["some_design_rooted_class:SPEC-1"]}\n' \
    > "$AD/acceptance-gate-result.json"
OUT="$(run_agg "$SF")"
assert_json_key "TC-10: design-rooted fail → verdict=route_design" "$OUT" '.verdict' "route_design"
assert_json_key "TC-10: route_target mirrored into the aggregate" "$OUT" '.route_target' "design"
assert_contains "TC-10: failed[] still names the acceptance-gate" "$OUT" "acceptance-gate"
assert_file_exists "TC-10: design-feedback.md written on route_design" "$AD/design-feedback.md"
assert_contains "TC-10: design-feedback names the SPEC" "$(cat "$AD/design-feedback.md")" "SPEC-1"

# ── TC-10b (#1583): a TAUTOLOGY failure carries NO route_target → build-routed fail ─
# Since #1477 removed design's stub-writer, BUILD authors assertion bodies, so a
# tautology is build-fixable: the acceptance-gate sets NO route_target. The
# aggregator must therefore emit a PLAIN verdict=fail (NOT route_design), write NO
# design-feedback.md, and surface the tautology in gate-feedback.md so it routes to
# build via the build_test_cycle gate_feedback → build edge.
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
printf '{"verdict":"fail","disposition":"recoverable","reason":"SPEC-1 tautological (pass at baseline)","failures":["tautology:SPEC-1"]}\n' \
    > "$AD/acceptance-gate-result.json"
OUT="$(run_agg "$SF")"
assert_json_key "TC-10b: tautology (no route_target) → verdict=fail (NOT route_design)" "$OUT" '.verdict' "fail"
assert_eq "TC-10b: no route_target mirrored for tautology" "" "$(jq -r '.route_target // ""' <<< "$OUT")"
assert_file_not_exists "TC-10b: NO design-feedback.md for a tautology (not design-rooted)" "$AD/design-feedback.md"
assert_file_exists "TC-10b: gate-feedback.md written (routes to build)" "$AD/gate-feedback.md"
assert_contains "TC-10b: gate-feedback surfaces the tautological SPEC for build" "$(cat "$AD/gate-feedback.md")" "SPEC-1"

# ── TC-11 (#1219): a FAILED gate WITHOUT route_target → plain verdict=fail ─────
# The existing verdict=fail path is UNCHANGED when no failing gate is design-
# rooted: no route_design, no mirrored route_target, and NO design-feedback.md.
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
write_verdict "$AD" "coverage-result.json" "fail"
OUT="$(run_agg "$SF")"
assert_json_key "TC-11: no route_target → verdict=fail (not route_design)" "$OUT" '.verdict' "fail"
assert_eq "TC-11: no route_target mirrored" "" "$(jq -r '.route_target // ""' <<< "$OUT")"
assert_file_not_exists "TC-11: no design-feedback.md when not design-rooted" "$AD/design-feedback.md"

# ── TC-12 (#1219): route_target on a PASSING gate is ignored (must FAIL to route) ─
# The scalar is read ONLY from gates that BLOCKED convergence. A stray
# route_target on a gate whose verdict=pass must not trigger route_design.
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
printf '{"verdict":"pass","route_target":"design"}\n' > "$AD/acceptance-gate-result.json"
OUT="$(run_agg "$SF")"
assert_json_key "TC-12: route_target on a passing gate ignored → verdict=pass" "$OUT" '.verdict' "pass"

# ── TC-13 (#1244): the suite gate's .test_output is surfaced in gate-feedback ─
# The test stage writes failing-test detail into test-results.json's .test_output
# (NOT .summary/.reason/.failures[]/.findings[]). The gate→build feedback MUST
# list WHICH tests failed so the next build iter has an actionable path — not just
# "verdict=fail (no structured detail)".
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
# jq -n so the multi-line .test_output is a VALID JSON string (escaped \n), exactly
# as the test plugin writes it — a raw newline inside the JSON literal is invalid.
jq -n '{verdict:"fail",exit_code:1,passed:482,failed:2,
        test_output:"FAIL tests/unit/foo-test.sh: expected 3 got 4\nFAIL tests/unit/bar-test.sh: assertion baz failed"}' \
    > "$AD/test-results.json"
run_agg "$SF" >/dev/null
FB="$(cat "$AD/gate-feedback.md")"
assert_file_exists "TC-13: gate-feedback.md written on suite fail" "$AD/gate-feedback.md"
assert_contains "TC-13: feedback lists the first failing test" "$FB" "tests/unit/foo-test.sh"
assert_contains "TC-13: feedback lists the second failing test" "$FB" "tests/unit/bar-test.sh"
if grep -qF -- "no structured detail" <<< "$FB"; then
    assert_fail "TC-13: feedback is NOT the empty 'no structured detail' fallback" \
        "fallback text still present despite test_output detail"
else
    assert_pass "TC-13: feedback is NOT the empty 'no structured detail' fallback"
fi

# ── TC-14 (#1686, [SPEC-3]): wiring_not_on_path + route_target=design → route_design ─
# First live activation of the dormant route_target carrier (ADR-036 #1583):
# the acceptance-gate writes route_target=design when wiring_not_on_path fires.
# The aggregator must roll it up to verdict=route_design and write design-feedback.md.
# disposition=recoverable (not terminal) — gate-aggregator must still treat it as
# a blocking fail (recoverable blocks convergence, only advisory is non-blocking).
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
printf '{"verdict":"fail","disposition":"recoverable","route_target":"design","reason":"WIRING .github/workflows/ci.yml not in this commit'\''s diff — declare WIRING: none or name the correct target","failures":["wiring_not_on_path:.github/workflows/ci.yml"]}\n' \
    > "$AD/acceptance-gate-result.json"
OUT="$(run_agg "$SF")"
assert_json_key "[SPEC-3] wiring_not_on_path route_target=design → verdict=route_design" \
    "$OUT" '.verdict' "route_design"
assert_json_key "[SPEC-3] route_target mirrored into aggregate" "$OUT" '.route_target' "design"
assert_contains "[SPEC-3] failed[] names the acceptance-gate" "$OUT" "acceptance-gate"
assert_file_exists "[SPEC-3] design-feedback.md written on route_design" "$AD/design-feedback.md"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
