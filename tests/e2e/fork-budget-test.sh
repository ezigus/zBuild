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
# SPEC-8: the run's cost in two parts (#2472, ADR-065 §6), each within its
#         budget, which ratchets down toward a floor below it:
#         - start-up: processes and execs before the first plugin.run.start,
#           per plugin manifest discovery reads;
#         - per dispatch: the same run again with three more review lenses —
#           the extra processes and execs over the extra dispatches.
#         A stage or plugin added moves the totals, not these.
# SPEC-6: the worker pool's execs scale with its work units, not with how long
#         they take: its poll sleep is exempt, and no counted pool line runs
#         more than once per unit (#2236).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

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
# 2100 (#2466: validate_manifest reads requires.core, its scalar fields and its
# events with the shell, not three awks a manifest) — measured 2,052 macOS.
# 2040 (#2470: a stage prompt is put together, read back and checked by the
# shell, not by a cat per section and a head) — measured 2,028 macOS.
# 2008 (#2472: an earlier output found by its text is one grep over every
# output, not one grep an output) — measured 1,996 macOS.
# 1995 (#2474: the write-boundary sweep runs one find for the watched folders of
# one depth, not one a folder) — measured 1,987 macOS.
# 1975 (#2477: an attempt's outputs are archived with one cp, not one an
# output, and its fingerprint sums every file with one cksum) — measured 1,964 macOS.
# 1920 (#2476: the router loads its includes and checks one only when it fails
# to load, not a `bash -n` before each of 14 every time a process loads it) —
# measured 1,911 macOS; main measured 1,964.
# 1910 (#2480: Previous work hands jq only a result with a numbered finding —
# a lens's own result lists its findings unnumbered) — measured 1,903 macOS;
# main measured 1,911.
# 1892 (#2482: the manifest check reads which core files a plugin sources by
# the shell, not with a grep a provider a plugin; issue-acceptance and design
# now read the commit the branch started from, the lenses' bundle with no
# subshell) — measured 1,885 macOS; main measured 1,903.
# 1888 (ADR-070 amendment 2026-11-07: intake reads the issue's labels in its
# shell; design's check reads the issue only when it judges the requirements)
# — measured 1,885 macOS; main measured 1,885.
# 1886 (ADR-068 §6 amendment 2026-11-07: a lens's routed output is written with
# one jq, not two) — measured 1,883 macOS; main measured 1,885.
# 1877 (#2487: the template's retry: is read by the shell, not an awk a
# dispatch) — measured 1,874 macOS; main measured 1,883.
# 1876 (#2489: a stop polls for a KILLed child to be gone, one `sleep` the
# run's exit pays; the exit trap's dirname is a parameter expansion now)
# — measured 1,874 macOS; main measured 1,874.
# 1859 (#2491: Previous work reads the state's stages and the input index in
# one jq, sorted by jq, not two jq and a sort a dispatch) — measured 1,856
# macOS; main measured 1,874.
# 1779 (#2507: the private paths and a call's permission rules are read and
# built by the shell, not by sed, grep, awk and five jq a model call; a judge
# is named the change by one git call, not handed a diff by two) — measured
# 1,776 macOS; main measured 1,856.
# 1772 (#2508: build has no file list and reads no scope manifest; a SPEC's
# tests are found by tag in one git and one grep) — measured 1,769 macOS.
# 1760 (#2517: teardown names a stage file by the shell, not two basename) —
# measured 1,757 macOS; main measured 1,769.
FORK_BUDGET=1760
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
# 2870 (#2464: validate_manifest reads each router knob's range and words in its
# shell, not in two `$( )` a knob — measured 2,853 macOS with the judges' kept
# answers added; main was at 2,879). 2800 (#2466, the same change as
# FORK_BUDGET 2100 — measured 2,762 macOS). 2790 (#2467: the build, lens and
# test-author readers read the acceptance block once, not once per SPEC —
# measured 2,756 macOS). 2745 (#2470: Previous work finds each stage's summary
# path in its shell, not in a `$( )` a stage; the prompt's first line is read
# without a `$( )` — measured 2,724 macOS). 2640 (#2472: the contract check
# reads each output's format, the formats and its summary mark in its shell,
# not in three `$( )` an output — measured 2,622 macOS). 2620 (#2474: the
# sweep's finds grouped by depth, its watch list read without a `$( )` —
# measured 2,604 macOS).
# 2610 (#2477: no subshell change; the budget only closes on what was
# measured — 2,604 macOS). 2555 (#2476, the same
# change as FORK_BUDGET 1920 — measured 2,546 macOS). 2545 (#2480, the same
# change as FORK_BUDGET 1910 — measured 2,538 macOS). 2541 (#2482, the same
# change as FORK_BUDGET 1892 — measured 2,534 macOS). 2537 (the same change
# as FORK_BUDGET 1888 — measured 2,534 macOS). 2535 (the same change as
# FORK_BUDGET 1886 — measured 2,532 macOS). 2526 (#2487, the same change as
# FORK_BUDGET 1877 — measured 2,523 macOS). 2525 (#2489, the same change as
# FORK_BUDGET 1876 — measured 2,522 macOS).
# FORK_BUDGET 1877 — measured 2,523 macOS). 2508 (#2491, the same change as
# FORK_BUDGET 1859 — measured 2,504 macOS; main measured 2,522).
# 2401 (#2507, the same change as FORK_BUDGET 1779 — measured 2,398 macOS;
# main measured 2,504).
# 2374 (#2508, the same change as FORK_BUDGET 1772 — measured 2,371 macOS).
# 2359 (#2517, the same change as FORK_BUDGET 1760 — measured 2,356 macOS;
# main measured 2,371).
PROCESS_BUDGET=2359
# The run's cost in two parts (ADR-065 §6, #2472). Each budget ratchets down
# like the totals; each floor is the goal, an estimate, measured again when
# reached. History: 505 / 298 a dispatch, 12 / 7 a plugin at start-up (#2472 —
# first measured on macOS: one more lens dispatch costs 500 processes and 294
# execs; the start-up, 472 and 257 over 43 plugins, 11 and 6 a plugin).
# 503 / 297 a dispatch (#2474: the write-boundary sweep after each dispatch —
# measured 498 processes and 293 execs). 503 / 293 (#2477: one cp an attempt —
# measured 498 processes and 289 execs). 490 / 280 a dispatch (#2476: the
# router's includes checked only when one fails to load — measured 485 and 277).
# 484 / 276 a dispatch (#2480: a result with no numbered finding is not handed
# to jq — measured 483 and 275). 482 / 275 a dispatch, 11 / 6 a plugin (#2482:
# a lens reads its change bundle with no subshell; the manifest check's grep is
# gone — measured 481 and 275; 472 and 236 over 43 plugins). 479 / 273 a
# dispatch (#2487 — measured 478 and 272). 477 / 271 a dispatch (#2491: one jq
# and no sort for Previous work's state and index — measured 476 and 270).
# 436 / 240 a dispatch (#2508: no scope manifest or request a build dispatch —
# measured 433 and 237). 435 / 240 a dispatch (#2517: a lens finds a SPEC's
# tests among the files its branch wrote, one git diff that finds the base
# itself and one git ls-files — measured 434 and 239; main measured 433 and 237).
# 440 / 240 a dispatch (#2507: a call's permission rules and private paths
# built by the shell; a lens is named the change by one git call — measured
# 438 and 238; the start-up is unchanged, 469 and 233 over 43 plugins: the
# run's check of every call's tools starts no program).
# - Per dispatch, the extra cost of one more dispatch. A dispatch needs a shell
#   to isolate the plugin, one for the model call and a few for its time limit
#   and watchers (~20 processes); and its programs: jq for its result and
#   state (~10), git for the snapshot (~8), a lock an event (~10), the scope
#   and write checks (~4), safe writes (~6), the model call (~2) — ~50 execs.
# - Start-up, per plugin manifest: discovery and the manifest checks; about one
#   process and one exec a plugin once each read is in the shell.
DISPATCH_PROCS_BUDGET=435
DISPATCH_PROCS_FLOOR=20
DISPATCH_EXECS_BUDGET=240
DISPATCH_EXECS_FLOOR=50
STARTUP_PROCS_PER_PLUGIN_BUDGET=11
STARTUP_PROCS_PER_PLUGIN_FLOOR=1
STARTUP_EXECS_PER_PLUGIN_BUDGET=6
STARTUP_EXECS_PER_PLUGIN_FLOOR=1

# ─── the harness and the counter (tests/lib/fork-census.sh) ────────────────
# shellcheck source=../../tests/lib/fork-census.sh
source "$REPO_ROOT/tests/lib/fork-census.sh"

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
    printf 'processes: %s (budget %s)\n' "$_procs" "$PROCESS_BUDGET"
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

# SPEC-8 (#2472): the cost in two parts.
_fb_disp() { jq -r 'select(.type == "plugin.run.start") | 1' "$1" 2>/dev/null | grep -c . || true; }
_dA="$(_fb_disp "$RUN_DIR/events/events.jsonl")"; _dA="${_dA:-0}"
# The same run with three more review lenses: three more dispatches.
RUN_B="$TEST_TEMP_DIR/run-b"; BIN_B="$TEST_TEMP_DIR/bin-b"; TRACE_B="$TEST_TEMP_DIR/run-b.trace"
mkdir -p "$RUN_B/events" "$BIN_B"
set +e
(
    unset GITHUB_ACTIONS CI GITHUB_STEP_SUMMARY RUNNER_OS 2>/dev/null || true
    export FIXTURE_STATE_DIR="$RUN_B" FIXTURE_BIN_DIR="$BIN_B" FIXTURE_LENSES="correctness red-team performance sre"
    fork_census_traced "$TRACE_B" bash "$FIXTURE" >/dev/null 2>&1
)
_run_b_rc=$?
set -e
assert_eq "[SPEC-8] the run with four lenses exits 0 under tracing" "0" "$_run_b_rc"
_dB="$(_fb_disp "$RUN_B/events/events.jsonl")"; _dB="${_dB:-0}"
_totB="$(fork_census_count "$TRACE_B" "$TEST_TEMP_DIR/run-b.sites")"; _procsB="$(fork_census_processes "$TRACE_B")"
_dd=$(( _dB - _dA ))
assert_eq "[SPEC-8] three more lenses are three more dispatches (${_dA} → ${_dB})" "3" "$_dd"
(( _dd > 0 )) || _dd=1
_dp=$(( (_procsB - _procs + _dd - 1) / _dd )); _de=$(( (_totB - _total + _dd - 1) / _dd ))
# Start-up: everything traced before the first dispatch.
_first="$(awk '/^\++@[^ ]*@ eb_emit_event (["'"'"']?)plugin\.run\.start/ { print NR; exit }' "$TRACE")"
head -n "$(( ${_first:-1} - 1 ))" "$TRACE" > "$TEST_TEMP_DIR/start.trace"
_sE="$(fork_census_count "$TEST_TEMP_DIR/start.trace" "$TEST_TEMP_DIR/start.sites")"; _sP="$(fork_census_processes "$TEST_TEMP_DIR/start.trace")"
_mf=(); while IFS= read -r _m; do _mf+=("$_m"); done < <(find "$REPO_ROOT/plugins" -maxdepth 3 -name manifest.yaml -type f)
_plugins=${#_mf[@]}
assert_eq "[SPEC-8] plugin manifests are found (${_plugins})" "1" "$(( _plugins > 0 ))"
(( _plugins > 0 )) || _plugins=1
_spp=$(( (_sP + _plugins - 1) / _plugins )); _spe=$(( (_sE + _plugins - 1) / _plugins ))
echo "  per dispatch (${_dA} → ${_dB}): ${_dp} processes (budget ${DISPATCH_PROCS_BUDGET}, floor ${DISPATCH_PROCS_FLOOR}), ${_de} execs (budget ${DISPATCH_EXECS_BUDGET}, floor ${DISPATCH_EXECS_FLOOR})"
echo "  start-up (${_sP} processes, ${_sE} execs over ${_plugins} plugins): ${_spp} processes a plugin (budget ${STARTUP_PROCS_PER_PLUGIN_BUDGET}, floor ${STARTUP_PROCS_PER_PLUGIN_FLOOR}), ${_spe} execs (budget ${STARTUP_EXECS_PER_PLUGIN_BUDGET}, floor ${STARTUP_EXECS_PER_PLUGIN_FLOOR})"
assert_eq "[SPEC-8] the start-up is traced (before the first dispatch, ${_first:-none})" "1" "$(( ${_first:-0} > 1 && _sP > 0 ))"
assert_eq "[SPEC-8] ${_dp} processes a dispatch ≤ DISPATCH_PROCS_BUDGET ${DISPATCH_PROCS_BUDGET}" "1" "$(( _dp <= DISPATCH_PROCS_BUDGET ))"
assert_eq "[SPEC-8] ${_de} execs a dispatch ≤ DISPATCH_EXECS_BUDGET ${DISPATCH_EXECS_BUDGET}" "1" "$(( _de <= DISPATCH_EXECS_BUDGET ))"
assert_eq "[SPEC-8] ${_spp} start-up processes a plugin ≤ STARTUP_PROCS_PER_PLUGIN_BUDGET ${STARTUP_PROCS_PER_PLUGIN_BUDGET}" "1" "$(( _spp <= STARTUP_PROCS_PER_PLUGIN_BUDGET ))"
assert_eq "[SPEC-8] ${_spe} start-up execs a plugin ≤ STARTUP_EXECS_PER_PLUGIN_BUDGET ${STARTUP_EXECS_PER_PLUGIN_BUDGET}" "1" "$(( _spe <= STARTUP_EXECS_PER_PLUGIN_BUDGET ))"
assert_eq "[SPEC-8] each floor is below its budget: the goal still ahead" "1" \
    "$(( DISPATCH_PROCS_FLOOR < DISPATCH_PROCS_BUDGET && DISPATCH_EXECS_FLOOR < DISPATCH_EXECS_BUDGET && STARTUP_PROCS_PER_PLUGIN_FLOOR < STARTUP_PROCS_PER_PLUGIN_BUDGET && STARTUP_EXECS_PER_PLUGIN_FLOOR < STARTUP_EXECS_PER_PLUGIN_BUDGET ))"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
