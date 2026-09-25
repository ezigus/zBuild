#!/usr/bin/env bash
# Unit: _build_guard_false_completion (#1532) — 0-diff + red acceptance testfile
# overrides verdict to inert_build before downstream test+gate run.
#
# Case A: LOOP_COMPLETE with 0-file diff + failing acceptance testfile
#         → helper returns failing path (non-zero exit)
# Case B: LOOP_COMPLETE with 0-file diff + passing acceptance testfile
#         → helper returns empty (zero exit)
# Case C: LOOP_COMPLETE with 0-file diff + no acceptance block
#         → helper returns empty (zero exit, empty testfiles input)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build _build_guard_false_completion — false-completion guard (#1532)"
setup_test_env "build-false-completion-guard"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-false-completion-guard-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts"

# Minimal mocks for plugin bootstrap dependencies.
# shellcheck disable=SC2317
route_to_model_loop() {
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    _ROUTE_LOOP_LAST_RESPONSE="LOOP_COMPLETE"
    return 0
}
# shellcheck disable=SC2317
_route_resolve_max_iterations() { echo 3; }
# shellcheck disable=SC2317
_route_loop_close_final_banner() { return 0; }
# shellcheck disable=SC2317
apply_scope_redaction() { local in="$1" out="$2"; [[ -f "$in" ]] && cp "$in" "$out"; return 0; }

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# ── Fixture repo ──────────────────────────────────────────────────────────────
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
(
    cd "$REPO"
    git init -q
    git config user.email t@t
    git config user.name t
    printf 'seed\n' > seed.txt
    git add seed.txt
    git commit -q -m seed
) >/dev/null

# ── Acceptance testfiles ──────────────────────────────────────────────────────
mkdir -p "$REPO/tests/unit"

# Failing testfile: always exits 1.
cat > "$REPO/tests/unit/failing-test.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$REPO/tests/unit/failing-test.sh"

# Passing testfile: always exits 0.
cat > "$REPO/tests/unit/passing-test.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$REPO/tests/unit/passing-test.sh"

# ── Case A: failing testfile → helper returns path + exits 1 ─────────────────
print_test_section "A: failing acceptance testfile → returns failing path"

TESTFILES_A="tests/unit/failing-test.sh"
failing_out=""
if ! failing_out="$(_build_guard_false_completion "$TESTFILES_A" "$REPO" 2>/dev/null)"; then
    assert_eq "A: failing testfile → helper exits 1" "1" "1"
else
    assert_eq "A: failing testfile → helper exits 1" "0" "1"
fi
assert_eq "A: failing_out is the failing testfile path" \
    "tests/unit/failing-test.sh" "$failing_out"

# ── Case B: passing testfile → helper returns empty + exits 0 ────────────────
print_test_section "B: passing acceptance testfile → no override"

TESTFILES_B="tests/unit/passing-test.sh"
passing_out=""
if passing_out="$(_build_guard_false_completion "$TESTFILES_B" "$REPO" 2>/dev/null)"; then
    assert_eq "B: passing testfile → helper exits 0" "0" "0"
else
    assert_eq "B: passing testfile → helper exits 0" "1" "0"
fi
assert_eq "B: passing_out is empty (no failing testfile)" "" "$passing_out"

# ── Case C: empty testfiles list → helper returns empty + exits 0 ────────────
print_test_section "C: no acceptance block (empty testfiles) → no override"

empty_out=""
if empty_out="$(_build_guard_false_completion "" "$REPO" 2>/dev/null)"; then
    assert_eq "C: empty testfiles → helper exits 0" "0" "0"
else
    assert_eq "C: empty testfiles → helper exits 0" "1" "0"
fi
assert_eq "C: empty_out is empty (no testfiles)" "" "$empty_out"

# ── SPEC-7 [change]: inert_build writes verdict=fail + data.build_kind (#1832) ─
# Previously wrote verdict="inert_build"; now writes verdict="fail" +
# data: {build_kind: "inert_build"} + disposition="broken" (ADR-054 §6).
print_test_section "SPEC-7 [change]: inert_build → verdict=fail + data.build_kind=inert_build (#1832)"

_spec7_summary="$TEST_TEMP_DIR/spec7-build-summary.json"
# Set up the caller-scope variables that _build_write_build_summary reads.
scope_violation="false"
terminated_reason="done_sentinel"
files_changed_count=0
files_changed_json='[]'
lines_added=0
lines_removed=0
iterations=1
loop_input_tokens=0
loop_output_tokens=0
output_diff_patch=""
output_summary_json="$_spec7_summary"
_acceptance_testfiles="tests/unit/failing-test.sh"
repo_root="$REPO"
scope_violations=()
scope_violations_created=()
_feedback_body=""
plan_files_csv=""
issue=0
router_rc=0
build_verdict=""

_build_write_build_summary 2>/dev/null

_s7_verdict="$(jq -r '.verdict' "$_spec7_summary" 2>/dev/null)"
_s7_kind="$(jq -r '.data.build_kind // ""' "$_spec7_summary" 2>/dev/null)"
_s7_disp="$(jq -r '.disposition // ""' "$_spec7_summary" 2>/dev/null)"
assert_eq "[SPEC-7] inert_build summary: verdict=fail (#1832)" "fail" "$_s7_verdict"
assert_eq "[SPEC-7] inert_build summary: data.build_kind=inert_build (#1832)" "inert_build" "$_s7_kind"
assert_eq "[SPEC-7] inert_build summary: disposition=complete — the verdict carries it (#2187)" "complete" "$_s7_disp"

# SPEC-10: result_contract:2 present on inert_build branch (guard — unchanged from prior work).
_s7_rc="$(jq -r '.result_contract // ""' "$_spec7_summary" 2>/dev/null)"
assert_eq "[SPEC-10] inert_build summary: result_contract:2 present" "2" "$_s7_rc"

# ─── #2138: the guard reads the design's TESTFILES as the design writes them ──
# The block binds testfiles per SPEC ("SPEC-1: tests/unit/failing-test.sh");
# passed through verbatim, `-f "$repo/SPEC-1: tests/…"` is false and the guard
# silently probes nothing — run 35355623656's build kept verdict=pass with its
# only acceptance testfile red.
print_test_section "#2138: SPEC-n: bound testfiles are probed; a slow green file is not red"
TESTFILES_D="$(printf 'SPEC-1: tests/unit/failing-test.sh\nSPEC-2: tests/unit/failing-test.sh\n')"
set +e; d_out="$(_build_guard_false_completion "$TESTFILES_D" "$REPO" 2>/dev/null)"; d_rc=$?; set -e
assert_eq "[#2138] a SPEC-bound red testfile is reported" "tests/unit/failing-test.sh" "$d_out"
assert_eq "[#2138] …and the guard exits 1" "1" "$d_rc"
# A green file slower than the stage bound is bounded by what the test stage
# MEASURED (#2110), not killed at 60s and mistaken for red.
cat > "$REPO/tests/unit/slow-green-test.sh" <<'EOF'
#!/usr/bin/env bash
sleep 2
exit 0
EOF
chmod +x "$REPO/tests/unit/slow-green-test.sh"
printf 'file 2100 %s/tests/unit/slow-green-test.sh\n' "$REPO" > "$TEST_TEMP_DIR/timing.log"
set +e; e_out="$(ZBUILD_NEGCTL_TIMEOUT=1 ZBUILD_NEGCTL_TIMING_LOG="$TEST_TEMP_DIR/timing.log" _build_guard_false_completion "tests/unit/slow-green-test.sh" "$REPO" 2>/dev/null)"; e_rc=$?; set -e
assert_eq "[#2138] a slow green testfile is not reported red" "" "$e_out"
assert_eq "[#2138] …and the guard exits 0" "0" "$e_rc"

# ─── #2142: a slow RED file is caught even with no measurement ───────────────
# #2138 made a probe killed at its bound "inconclusive" (a false inert_build
# blocks a good build). Build declares no test_timing input, so on run
# 35412141973 the probe ran at the 60 s default, was killed at 60 s on a
# 139 s file, and a red acceptance testfile went unreported. With no
# measurement the bound is ZBUILD_TEST_FILE_TIMEOUT (480 s), not 60.
print_test_section "#2142: unmeasured → the file-timeout ceiling; measured via the declared input"
cat > "$REPO/tests/unit/slow-red-test.sh" <<'EOF'
#!/usr/bin/env bash
sleep 3
exit 1
EOF
chmod +x "$REPO/tests/unit/slow-red-test.sh"
set +e; f_out="$(ZBUILD_NEGCTL_TIMEOUT=1 ZBUILD_TEST_FILE_TIMEOUT=10 ZBUILD_NEGCTL_TIMING_LOG="" _build_guard_false_completion "tests/unit/slow-red-test.sh" "$REPO" 2>/dev/null)"; f_rc=$?; set -e
assert_eq "[#2142] an unmeasured slow red file is reported red" "tests/unit/slow-red-test.sh" "$f_out"
assert_eq "[#2142] …and the guard exits 1" "1" "$f_rc"
# The measurement reaches the probe through the DECLARED test_timing input
# (ZBUILD_STAGE_INPUTS), as it reaches the gate — not an ambient env var.
printf 'file 3100 %s/tests/unit/slow-red-test.sh\n' "$REPO" > "$TEST_TEMP_DIR/timing2.log"
printf '{"inputs":{"test_timing":"%s"}}\n' "$TEST_TEMP_DIR/timing2.log" > "$TEST_TEMP_DIR/si-2142.json"
set +e; g_out="$(ZBUILD_NEGCTL_TIMEOUT=1 ZBUILD_TEST_FILE_TIMEOUT=10 ZBUILD_NEGCTL_TIMING_LOG="" ZBUILD_STAGE_INPUTS="$TEST_TEMP_DIR/si-2142.json" _build_guard_false_completion "tests/unit/slow-red-test.sh" "$REPO" 2>/dev/null)"; g_rc=$?; set -e
assert_eq "[#2142] a measured slow red file (via test_timing input) is reported red" "tests/unit/slow-red-test.sh" "$g_out"
# review on PR #2147: the case above passes on the floor alone. What the
# measurement buys is a TIGHTER bound: a file measured at 1 s that now hangs
# is killed at 3× its measurement, not held to the 10 s ceiling. Elapsed
# time is the observable — only the declared-input path can make it short.
cat > "$REPO/tests/unit/hang-test.sh" <<'EOF'
#!/usr/bin/env bash
sleep 30
exit 1
EOF
chmod +x "$REPO/tests/unit/hang-test.sh"
printf 'file 1000 %s/tests/unit/hang-test.sh\n' "$REPO" > "$TEST_TEMP_DIR/timing3.log"
printf '{"inputs":{"test_timing":"%s"}}\n' "$TEST_TEMP_DIR/timing3.log" > "$TEST_TEMP_DIR/si-2142b.json"
_t0=$SECONDS
set +e; h_out="$(ZBUILD_NEGCTL_TIMEOUT=1 ZBUILD_TEST_FILE_TIMEOUT=10 ZBUILD_NEGCTL_TIMING_LOG="" ZBUILD_STAGE_INPUTS="$TEST_TEMP_DIR/si-2142b.json" _build_guard_false_completion "tests/unit/hang-test.sh" "$REPO" 2>/dev/null)"; h_rc=$?; set -e
_el=$(( SECONDS - _t0 ))
if (( _el <= 6 )); then assert_pass "[#2142] a measured file that hangs is bounded by 3× its measurement, not the ceiling (${_el}s)"; else assert_fail "[#2142] a measured file that hangs is bounded by 3× its measurement, not the ceiling" "took ${_el}s (ceiling 10 s — the declared input was not read)"; fi
assert_eq "[#2142] …and a kill at the bound is UNKNOWN, not red (rc 0, nothing reported)" "0|" "${h_rc}|${h_out}"
assert_eq "[#2142] the probe leaves no ZBUILD_NEGCTL_TIMING_LOG behind in the caller's environment" "" "${ZBUILD_NEGCTL_TIMING_LOG:-}"
assert_contains "[#2142] build declares test_timing as an optional input" \
    "$(awk '/^inputs:/,/^outputs:/' "$REPO_ROOT/plugins/agent/build/manifest.yaml")" "id: test_timing"

cleanup_test_env

print_test_results
exit $((FAIL > 0))
