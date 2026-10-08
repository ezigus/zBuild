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
printf '{"verdict":"fail","severity":"advisory","failures":["negctl_error:timeout:SPEC-1"]}\n' \
    > "$AD/acceptance-gate-result.json"
OUT="$(run_agg "$SF")"
assert_json_key "TC-8: advisory fail → verdict=pass (non-blocking)" "$OUT" '.verdict' "pass"
assert_json_key "TC-8: advisory member status=advisory" "$OUT" '.gates."acceptance-gate"' "advisory"
assert_eq "TC-8: advisory member NOT in failed[]" "0" "$(jq '.failed | length' <<< "$OUT")"

# ── TC-8b (#1850): the v1 shape — `advisory` in disposition, no severity — is
# no longer read: it does not demote the failure (the word lives in severity).
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
printf '{"verdict":"fail","disposition":"advisory","failures":["negctl_error:timeout:SPEC-1"]}\n' \
    > "$AD/acceptance-gate-result.json"
OUT="$(run_agg "$SF")"
assert_json_key "TC-8b: a v1-shape disposition=advisory does not demote the fail (#1850)" "$OUT" '.verdict' "fail"

# ── TC-9: verdict=fail with disposition=recoverable STAYS blocking ────────────
# recoverable drives another build iteration — it must NOT satisfy convergence.
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
printf '{"verdict":"fail","severity":"recoverable","failures":["untagged_spec:SPEC-1"]}\n' \
    > "$AD/acceptance-gate-result.json"
OUT="$(run_agg "$SF")"
assert_json_key "TC-9: recoverable fail → verdict=fail (still blocking)" "$OUT" '.verdict' "fail"
assert_contains "TC-9: failed[] names the acceptance-gate" "$OUT" "acceptance-gate"

# ── TC-10 (#1219, retained mechanism): a FAILED gate carrying fault → verdict=route_<target> ─
# ADR-045/ADR-040: the generic `fault` rollup is RETAINED (dormant) for any
# future genuinely design-rooted class. As of #1583 tautology NO LONGER sets
# fault (it is build-fixable — see TC-10b), so this case uses a SYNTHETIC
# fault=specification result to exercise the aggregator's generic rollup path.
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
printf '{"verdict":"fail","severity":"terminal","fault":"specification","reason":"a hypothetical design-rooted failure","failures":["some_design_rooted_class:SPEC-1"]}\n' \
    > "$AD/acceptance-gate-result.json"
OUT="$(run_agg "$SF")"
# #1987: the verdict stays pass/fail and the FAULT says whose problem it is.
# exit_when still binds to verdict==pass; the template's route_back keys on the
# fault, so no stage names a stage.
assert_json_key "TC-10: design-rooted fail → verdict stays fail" "$OUT" '.verdict' "fail"
# #2271 (ADR-068): a fault a gate still writes is not rolled up — the engine no
# longer decides whose problem a failure is.
assert_eq "TC-10: a gate's fault is not rolled up into the aggregate" "" "$(jq -r '.fault // ""' <<< "$OUT")"
assert_contains "TC-10: failed[] still names the acceptance-gate" "$OUT" "acceptance-gate"
# #1988: the aggregator renders nothing. The SPEC reaches design through the
# acceptance gate's own summary; what this stage still owns is the roll-up.
assert_file_not_exists "TC-10: the aggregator renders no design payload" "$AD/design-feedback.md"

# ── TC-10b (#1583): a TAUTOLOGY failure carries NO fault → build-routed fail ─
# Since #1477 removed design's stub-writer, BUILD authors assertion bodies, so a
# tautology is build-fixable: the acceptance-gate sets NO fault. The
# aggregator must therefore emit a PLAIN verdict=fail (NOT a specification fault), write NO
# design-feedback.md, and surface the tautology in gate-feedback.md so it routes to
# build via the build_test_cycle gate_feedback → build edge.
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
printf '{"verdict":"fail","severity":"recoverable","reason":"SPEC-1 tautological (pass at baseline)","failures":["tautology:SPEC-1"]}\n' \
    > "$AD/acceptance-gate-result.json"
OUT="$(run_agg "$SF")"
assert_json_key "TC-10b: tautology (no fault) → verdict=fail" "$OUT" '.verdict' "fail"
assert_eq "TC-10b: no fault mirrored for tautology" "" "$(jq -r '.fault // ""' <<< "$OUT")"
assert_file_not_exists "TC-10b: NO design-feedback.md for a tautology (build-fixable)" "$AD/design-feedback.md"
assert_file_not_exists "TC-10b: the aggregator renders no build payload" \
    "$AD/gate-feedback.md"
# The tautology reaches build through the acceptance gate's own summary now.

# ── TC-11 (#1219): a FAILED gate WITHOUT fault → plain verdict=fail ─────
# The existing verdict=fail path is UNCHANGED when no failing gate is design-
# rooted: no a specification fault, no mirrored fault, and NO design-feedback.md.
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
write_verdict "$AD" "coverage-result.json" "fail"
OUT="$(run_agg "$SF")"
assert_json_key "TC-11: no declared fault → verdict=fail" "$OUT" '.verdict' "fail"
assert_eq "TC-11: no fault mirrored" "" "$(jq -r '.fault // ""' <<< "$OUT")"
assert_file_not_exists "TC-11: no design-feedback.md when not design-rooted" "$AD/design-feedback.md"

# ── TC-12 (#1219): fault on a PASSING gate is ignored (must FAIL to route) ─
# The scalar is read ONLY from gates that BLOCKED convergence. A stray
# fault on a gate whose verdict=pass must not trigger a specification fault.
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
printf '{"verdict":"pass","fault":"specification"}\n' > "$AD/acceptance-gate-result.json"
OUT="$(run_agg "$SF")"
assert_json_key "TC-12: fault on a passing gate ignored → verdict=pass" "$OUT" '.verdict' "pass"

# ── TC-13 (#1244 → #1988): the suite gate's output reaches a reader ──────────
# The aggregator used to surface .test_output in its rendered payload. It
# renders nothing now; the test stage publishes test-failures-summary.md as its
# own summary, and tests/integration/core-pipeline-cycle-build-test-wiring-test.sh
# T6 asserts that chain end-to-end. What remains here is that a failing suite
# still lands in the aggregate's failed[] list.
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
printf '{"verdict":"fail","test_output":"FAIL tests/unit/x-test.sh"}\n' > "$AD/test-results.json"
OUT="$(run_agg "$SF")"
assert_contains "TC-13: a failing suite is named in failed[]" "$OUT" "suite"
assert_file_not_exists "TC-13: and no payload is rendered" "$AD/gate-feedback.md"


# ── TC-14 (#1686, [SPEC-3]): wiring_not_on_path + fault=specification → a specification fault ─
# First live activation of the dormant fault carrier (ADR-036 #1583):
# the acceptance-gate writes fault=specification when wiring_not_on_path fires.
# The aggregator must roll it up to the declared fault and write design-feedback.md.
# disposition=recoverable (not terminal) — gate-aggregator must still treat it as
# a blocking fail (recoverable blocks convergence, only advisory is non-blocking).
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
printf '{"verdict":"fail","severity":"recoverable","fault":"specification","reason":"WIRING .github/workflows/ci.yml referenced by no declared TESTFILE — declare WIRING: none or name a target the tests actually load","failures":["wiring_not_on_path:.github/workflows/ci.yml"]}\n' \
    > "$AD/acceptance-gate-result.json"
OUT="$(run_agg "$SF")"
assert_json_key "[SPEC-3] wiring_not_on_path → verdict stays fail" \
    "$OUT" '.verdict' "fail"
assert_eq "[SPEC-3] no fault in the aggregate (#2271)" "" "$(jq -r '.fault // ""' <<< "$OUT")"
assert_contains "[SPEC-3] failed[] names the acceptance-gate" "$OUT" "acceptance-gate"
assert_file_not_exists "[SPEC-3] the aggregator renders no design payload" "$AD/design-feedback.md"

# ── TC-15 (#1757): a MIXED failure set feeds BOTH payloads ───────────────────
# Reproduces run 20260822073243 (issue #1831): shape-floor escalates
# fault=specification (its missing floor files are all out of build's scope)
# while the suite and a `tautology:SPEC-1` fail beside it. The tautology carries
# NO fault on purpose (#1583 — build re-authors its own assertion), so it
# is build-fixable. The old three-way branch let the one routed gate `rm -f` the
# build-facing payload, and both build-fixable findings reached nobody: build saw
# an empty prompt, made an empty diff, and the cycle spun for five iterations.
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
printf '{"verdict":"fail","reason":"missing_floor_files","fault":"specification"}\n' \
    > "$AD/shape-floor-result.json"
printf '{"verdict":"fail","severity":"recoverable","reason":"acceptance SPEC violations — SPEC-1 tautological (pass at baseline)","failures":["tautology:SPEC-1"]}\n' \
    > "$AD/acceptance-gate-result.json"
printf '{"verdict":"fail","test_output":"FAIL sigpipe-antipattern-guard-test.sh"}\n' \
    > "$AD/test-results.json"
OUT="$(run_agg "$SF")"

assert_json_key "TC-15: one routed gate still leaves verdict=fail" \
    "$OUT" '.verdict' "fail"
assert_file_not_exists "TC-15: the aggregator renders no design payload" \
    "$AD/design-feedback.md"
# THE REGRESSION: this file used to be rm -f'd, taking both build-fixable
# findings with it.
assert_file_not_exists "TC-15: the aggregator renders no build payload" \
    "$AD/gate-feedback.md"

# #1988: there are no payloads to partition. Every failing gate publishes its
# own detail and all of them reach the prompt — so the routed/residual split
# this block tested no longer exists as a concept. What survives is that BOTH
# kinds of failure are still named in the aggregate, which is what the #1757
# regression (a routed gate taking build-fixable findings with it) was about.
assert_contains "TC-15: the routed gate is named in the aggregate" "$OUT" "shape-floor"
assert_contains "TC-15: and so is the build-fixable one" "$OUT" "acceptance-gate"
# The "handled elsewhere" framing existed because build read a PARTIAL payload
# and had to be told the rest went to design. With no partition, build sees every
# failing gate's own detail — there is no partial view to caveat.

# ── TC-16 (#1757): an ALL-routed failure set still suppresses the build payload ─
# No build-fixable gate failed, so there is nothing for build to act on and
# gate-feedback.md must stay absent — the pre-#1757 behaviour, unchanged.
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
printf '{"verdict":"fail","reason":"missing_floor_files","fault":"specification"}\n' \
    > "$AD/shape-floor-result.json"
OUT="$(run_agg "$SF")"
assert_json_key "TC-16: all-routed → verdict stays fail" "$OUT" '.verdict' "fail"
assert_eq "TC-16: and no fault in the aggregate (#2271)" "" "$(jq -r '.fault // ""' <<< "$OUT")"
assert_file_not_exists "TC-16: the aggregator renders no design payload" "$AD/design-feedback.md"
assert_file_not_exists "TC-16: gate-feedback.md absent (nothing build can fix)" \
    "$AD/gate-feedback.md"

# ── TC-17 (#1757): a plain fail is unchanged — build payload only ─────────────
# Guards the byte-shape of the path #1757 must not touch: no fault
# anywhere → residual[] == failed[], design-feedback.md dropped.
SF="$(fresh_artifacts)"; AD="$(dirname "$SF")/artifacts"
write_all "$AD" "pass"
printf '{"verdict":"fail","reason":"coverage below floor"}\n' > "$AD/coverage-result.json"
OUT="$(run_agg "$SF")"
assert_json_key "TC-17: plain fail → verdict=fail (no route)" "$OUT" '.verdict' "fail"
assert_file_not_exists "TC-17: the aggregator renders no build payload" \
    "$AD/gate-feedback.md"
assert_file_not_exists "TC-17: design-feedback.md absent on a plain fail" \
    "$AD/design-feedback.md"
# #1988: no payloads at all, so no partial-view caveat to emit.
assert_file_not_exists "TC-17: nor a build payload" "$AD/gate-feedback.md"

# ── TC-18 (#1757): stale payloads from a prior iteration are dropped ──────────
# The artifacts dir is shared across cycle iterations, so a payload left by the
# previous verdict must not be read as current.
write_all "$AD" "pass"
OUT="$(run_agg "$SF")"
assert_json_key "TC-18: all-pass after a fail → verdict=pass" "$OUT" '.verdict' "pass"
assert_file_not_exists "TC-18: stale gate-feedback.md removed on pass" \
    "$AD/gate-feedback.md"
assert_file_not_exists "TC-18: stale design-feedback.md removed on pass" \
    "$AD/design-feedback.md"

# TC-19..TC-22 (#1757, #1987, #2269) tested the fault-class roll-up, its
# conflict signal and its plain wording; #2271 retired fault classes.

cleanup_test_env
print_test_results
exit $((FAIL > 0))
