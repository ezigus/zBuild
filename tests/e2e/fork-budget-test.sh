#!/usr/bin/env bash
# E2E (#2151, ADR-065): the engine's process count is a tested contract.
#
# The suite is fork-bound — #1840 run 1 spent 4,910 of 6,989 CPU-seconds in the
# kernel creating processes — which is why it takes ~15 min on a 10-core Mac
# and ~58 min in the daemon's test stage on a 4-vCPU runner. A mocked 7-stage
# run execs ~6,600 external processes; `source runner.sh` alone execs 1,375.
#
# This test runs the mocked full pipeline (the parity fixture, the same launch
# as plugin-event-balance-full-run-test.sh) under bash xtrace and counts every
# external command the engine and its children exec. The count must stay under
# FORK_BUDGET, which only ratchets DOWN (raising it needs an ADR-065 amendment).
# The failure output IS the diagnosis: the top call sites and per-file totals.
#
# SPEC-1: a canary script with exactly one external exec counts exactly 1 — the
#         detector cannot go inert.
# SPEC-1b: the words inside an assigned value (xtrace quotes them) are data,
#          never commands (#1842).
# SPEC-2: the mocked run still exits 0 under tracing and writes events.jsonl.
# SPEC-3: liveness floor — the trace names ≥ 20 source files and ≥ 1,000
#         external execs (an fd-7-closed child traces to stderr; a run that died
#         early must not pass as "under budget").
# SPEC-4: total external execs ≤ FORK_BUDGET.
# SPEC-5: a line marked `# fork-budget-exempt: <why>` is not counted (listed
#         apart instead); an unmarked line in the same loop still is (#2236).
#         How often a wait loop sleeps measures elapsed time, not code — under
#         load the same tree counted 4,528 and 4,610.
# SPEC-7: total processes (programs + subshells) ≤ PROCESS_BUDGET.
# SPEC-6: the worker pool's execs scale with its work units, not with how long
#         they take: its poll sleep is exempt, and no counted pool line runs
#         more than once per unit (#2236).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "fork budget: external execs of a mocked full run (#2151, ADR-065)"
setup_test_env "fork-budget"

# ADR-065 §2. Ratchets down only. History: 8000 (#2151, measured 7,128 macOS);
# 4800 (#2152 manifest index, measured 4,335 macOS); 4600 (#1849 follow-up:
# _eb_strip_ansi skips sed when no ESC byte is present — measured 4,187 macOS
# with the issue-acceptance stage added); 4550 (#2236: the pool's poll wait is
# exempt and its clock read a builtin — measured 4,499 macOS, the same under load).
# 6340 (#1842, ADR-065 §2 amendment): the fixture now runs what production runs —
# a real mock repo (hydrate, build's diff, persist's snapshot used to fail fast),
# and review_lenses -> review-aggregator -> pr. Measured 6,280 macOS; the same
# counter on main's fixture reads 4,367 (132 phantom execs in quoted values are
# gone, SPEC-1b). The biggest new site is persist's per-file git, #2249.
# 5740 (#2249): persist stages a snapshot in two git calls instead of two per
# file, and the fixture's git plumbing is real so snapshots actually save —
# measured 5,685 macOS (artifact-persist.sh 1,072 → 305).
# 5540 (#1844): a v2 result is read with one jq instead of eight
# (verdict.sh _verdict_read_result) — measured 5,481 macOS, even though design,
# pr-open and pr-delivery are now read as v2 (their results became primary).
# 5480 (#2271): the per-stage owner and fault lookups in the summary collector
# are gone with fault routing, which more than pays for numbered findings and
# answers — measured 5,426 macOS (Linux CI census 5,276).
# 5040 (#1806): one emit starts one jq and the lock — no jq per field, no
# date, no mkdir, no sed for the mirror — measured 4,991 macOS.
# 4440 (ADR-065 §5 amendment, 2026-10-24): a manifest walk and a role lookup are
# one awk each, validate_manifest's structural checks one awk, atomic_write has
# no dirname/tail/awk, the run-status comment reads a row with one jq —
# measured 4,378 macOS.
# 4380 (round 3: discovery's tree check is one find; status rows and output
# paths fill variables) — measured 4,312 macOS. 4020 (round 4: atomic_write
# has no df or mktemp and keeps a .bak only for state; a state update has no
# dirname, mktemp, cp or date) — measured 3,955 macOS. 3160 (round 5: persist's
# secret scan greps the dir, not each file; the attempt record sums only what
# can compare; a plain-ASCII event line is written by the shell; a router-knob
# lookup and a requires.core check each read once) — measured 3,098 macOS.
# 3070 (round 6: the write boundary's mark and check, the producer-index key and
# a collect memo hit are done by the shell) — measured 3,008 macOS. 2890 (round
# 6, C1: the outputs block read by the shell; the trunk, git dir and stage limit
# once per shell; symlinked personas indexed) — measured 2,827 macOS. 2720
# (round 6, C2: a dispatch's dirname/mkdir/rm/date/tr/cut/cat done by the shell)
# — measured 2,659 macOS. 2250 (round 7: outputs and results parsed once per
# change, the clock and a library's folder from the shell, eight manifest
# readers in bash) — measured 2,196 macOS. 2190 (round 9: a snapshot names its
# temp files without mktemp; main measured 2,196) — measured 2,142 macOS.
FORK_BUDGET=2190
# PROCESS_BUDGET (ADR-065 §1, amended 2026-10-24): every process bash ran in —
# the programs above plus each `$( )` subshell, a copy of the whole engine shell
# that FORK_BUDGET cannot see. Ratchets down only, like FORK_BUDGET. History:
# 7050 (round 3: manifest reads through yaml_get_v — measured 6,967 macOS;
# main before it measured 8,331). 6220 (round 3: output paths, status-row
# times, discovery's tree check and the manifest_graph memo name fill variables
# instead of subshells — measured 6,139 macOS). 6000 (round 4, the same
# changes — measured 5,930 macOS). 5330 (round 5, the same changes — measured
# 5,255 macOS). 5200 (round 6, the same changes — measured 5,129 macOS). 5140
# (round 6, C1 — measured 5,076 macOS). 5040 (round 6, C2 — measured 4,977 macOS).
# 4840 (round 7 — measured 4,735 macOS). 3680 (round 8: the shell's own lookups
# and per-dispatch helpers in the caller's shell, not in `$( )` — measured 3,608 macOS).
# 2880 (round 9: a dispatch's result readers, input index, prompt blocks and
# setup, the manifest checks and the snapshot's names fill variables in the
# shell that asks — measured 2,819 macOS).
PROCESS_BUDGET=2880

# ─── the harness and the counter (scripts/lib/fork-census.sh) ────────────────
# shellcheck source=../../scripts/lib/fork-census.sh
source "$REPO_ROOT/scripts/lib/fork-census.sh"

# ─── SPEC-1: the canary ──────────────────────────────────────────────────────
print_test_section "SPEC-1: a script with one external exec counts exactly 1"
CANARY="$TEST_TEMP_DIR/canary.sh"
cat > "$CANARY" <<'EOF'
#!/usr/bin/env bash
x="$(dirname /a/b)"
y="${x%/*}"
printf '%s\n' "$y" >/dev/null
EOF
fork_census_traced "$TEST_TEMP_DIR/canary.trace" bash "$CANARY"
_canary_n="$(fork_census_count "$TEST_TEMP_DIR/canary.trace" "$TEST_TEMP_DIR/canary.sites")"
assert_eq "[SPEC-1] the canary's one dirname is counted, its builtins are not" "1" "$_canary_n"
assert_contains "[SPEC-1] …and attributed to its call site" "$(cat "$TEST_TEMP_DIR/canary.sites")" "canary.sh:2"$'\t'"dirname"

# ─── SPEC-1b: an assignment's value is not a command ─────────────────────────
# xtrace prints `v='review lens: security'` for an assignment whose value has
# spaces. The words inside the quotes are data; `security` is a binary on macOS,
# and 178 phantom execs per site were counted from such values (#1842).
QUOTED="$TEST_TEMP_DIR/quoted.sh"
cat > "$QUOTED" <<'EOF'
#!/usr/bin/env bash
v="first ls second"
w='x cat y'
z=$'a\tmkdir b'
EOF
fork_census_traced "$TEST_TEMP_DIR/quoted.trace" bash "$QUOTED"
assert_eq "[SPEC-1b] words inside an assigned value are not counted" "0" \
    "$(fork_census_count "$TEST_TEMP_DIR/quoted.trace" "$TEST_TEMP_DIR/quoted.sites")"

# ─── SPEC-5: an exempt wait is listed, not counted ───────────────────────────
print_test_section "SPEC-5: a marked wait is not counted"
WAITER="$TEST_TEMP_DIR/waiter.sh"
cat > "$WAITER" <<'EOF'
#!/usr/bin/env bash
for _ in 1 2 3; do
    sleep 0  # fork-budget-exempt: canary wait
    sleep 0
done
EOF
fork_census_traced "$TEST_TEMP_DIR/waiter.trace" bash "$WAITER"
_waiter_n="$(fork_census_count "$TEST_TEMP_DIR/waiter.trace" "$TEST_TEMP_DIR/waiter.sites")"
assert_eq "[SPEC-5] only the unmarked sleep is counted (3 of 6)" "3" "$_waiter_n"
assert_contains "[SPEC-5] …the marked one is listed apart" \
    "$(cat "$TEST_TEMP_DIR/waiter.sites.exempt" 2>/dev/null)" "waiter.sh:3"$'\t'"sleep"

# ─── SPEC-2: the mocked full run under tracing ───────────────────────────────
print_test_section "SPEC-2: the mocked full run under tracing"
FIXTURE="$REPO_ROOT/tests/golden/parity/run-fixture.sh"
RUN_DIR="$TEST_TEMP_DIR/run"; BIN_DIR="$TEST_TEMP_DIR/bin"
mkdir -p "$RUN_DIR/events" "$BIN_DIR" "$TEST_TEMP_DIR/pc"
TRACE="$TEST_TEMP_DIR/run.trace"
set +e
(
    unset GITHUB_ACTIONS CI GITHUB_STEP_SUMMARY RUNNER_OS 2>/dev/null || true
    export FIXTURE_STATE_DIR="$RUN_DIR" FIXTURE_BIN_DIR="$BIN_DIR"
    fork_census_traced "$TRACE" bash "$FIXTURE" >/dev/null 2>&1
)
_run_rc=$?
set -e
assert_eq "[SPEC-2] the mocked full run exits 0 under tracing" "0" "$_run_rc"
assert_file_exists "[SPEC-2] …and produced events.jsonl" "$RUN_DIR/events/events.jsonl"

# ─── SPEC-3/4: the count ─────────────────────────────────────────────────────
print_test_section "SPEC-3/4: liveness floor and the budget"
SITES="$TEST_TEMP_DIR/run.sites"
_total="$(fork_census_count "$TRACE" "$SITES")"
_procs="$(fork_census_processes "$TRACE")"
echo "  processes: $_procs (budget $PROCESS_BUDGET)"
_files="$(awk -F'\t' '{ split($2, p, ":"); f[p[1]] = 1 } END { print length(f) }' "$SITES")"
echo "  external execs: $_total (budget $FORK_BUDGET) across $_files source files"
echo "  top call sites:"
awk -F'\t' 'NR <= 12 { printf "    %5d  %-34s %s\n", $1, $2, $3 }' "$SITES"
if [[ -s "$SITES.exempt" ]]; then
    echo "  exempt waits (not counted — their repeat count is elapsed time):"
    awk -F'\t' '{ printf "    %5d  %-34s %s\n", $1, $2, $3 }' "$SITES.exempt"
fi
echo "  by file:"
awk -F'\t' '{ split($2, p, ":"); f[p[1]] += $1 } END { for (k in f) printf "%d\t%s\n", f[k], k }' "$SITES" \
    | sort -rn | awk 'NR <= 10 { printf "    %5d  %s\n", $1, $2 }'

# The tier runner buffers a passing test's output, so the Linux number — the
# one the ratchet is set from — would be invisible in CI. Write the census where
# CI can carry it: the job summary, and a file the e2e job uploads as an
# artifact (test.yml: fork-budget-census.txt under RUNNER_TEMP).
_fb_census() {
    printf '### fork budget: %s external execs (budget %s) across %s source files\n\n```\n' "$_total" "$FORK_BUDGET" "$_files"
    awk -F'\t' 'NR <= 15 { printf "%5d  %-34s %s\n", $1, $2, $3 }' "$SITES"
    printf '```\n'
}
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && { [[ -w "$GITHUB_STEP_SUMMARY" ]] || [[ ! -e "$GITHUB_STEP_SUMMARY" && -w "$(dirname "$GITHUB_STEP_SUMMARY")" ]]; }; then
    _fb_census >> "$GITHUB_STEP_SUMMARY"
fi
if [[ -n "${RUNNER_TEMP:-}" && -d "${RUNNER_TEMP:-/nonexistent}" ]]; then
    _fb_census > "$RUNNER_TEMP/fork-budget-census.txt" 2>/dev/null || true
fi

if (( _files >= 20 && _total >= 1000 )); then
    assert_pass "[SPEC-3] the trace is live (${_files} files, ${_total} execs)"
else
    assert_fail "[SPEC-3] the trace is live" "only ${_files} files / ${_total} execs — fd 7 lost, or the run died early"
fi
# The pool's own execs scale with the work units it runs (the fixture dispatches
# 2), never with how long they take: its poll sleep is exempt, and no counted
# pool line runs more than once per unit.
if grep -qE $'\tlocal_engine\\.sh:[0-9]+\tsleep$' "$SITES.exempt" 2>/dev/null; then
    assert_pass "[SPEC-6] the worker pool's poll sleep is listed as an exempt wait"
else
    assert_fail "[SPEC-6] the worker pool's poll sleep is listed as an exempt wait" "exempt: $(cat "$SITES.exempt" 2>/dev/null)"
fi
_pool_max="$(awk -F'\t' '$2 ~ /^local_engine\.sh:/ && $1 > m { m = $1 } END { print m + 0 }' "$SITES")"
echo "  busiest counted pool line: ${_pool_max} execs (2 work units)"
assert_eq "[SPEC-6] …and no counted pool line runs more than once per work unit (max ${_pool_max})" "1" "$(( _pool_max <= 2 ))"
if (( _procs <= PROCESS_BUDGET )); then
    assert_pass "[SPEC-7] ${_procs} processes ≤ PROCESS_BUDGET ${PROCESS_BUDGET}"
else
    assert_fail "[SPEC-7] processes ≤ PROCESS_BUDGET" "${_procs} > ${PROCESS_BUDGET} — a \$( ) around an engine function copies the whole shell; ADR-065 §2: the budget only ratchets down"
fi
if (( _total <= FORK_BUDGET )); then
    assert_pass "[SPEC-4] ${_total} external execs ≤ FORK_BUDGET ${FORK_BUDGET}"
else
    assert_fail "[SPEC-4] external execs ≤ FORK_BUDGET" "${_total} > ${FORK_BUDGET} — see the call sites above; ADR-065 §2: the budget only ratchets down"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
