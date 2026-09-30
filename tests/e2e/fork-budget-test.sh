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
# SPEC-2: the mocked run still exits 0 under tracing and writes events.jsonl.
# SPEC-3: liveness floor — the trace names ≥ 20 source files and ≥ 1,000
#         external execs (an fd-7-closed child traces to stderr; a run that died
#         early must not pass as "under budget").
# SPEC-4: total external execs ≤ FORK_BUDGET.
# SPEC-5: a line marked `# fork-budget-exempt: <why>` is not counted (listed
#         apart instead); an unmarked line in the same loop still is (#2236).
#         How often a wait loop sleeps measures elapsed time, not code — under
#         load the same tree counted 4,528 and 4,610.
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
FORK_BUDGET=4550

# ─── the trace harness (the --coverage-trace precedent, scripts/run-tests.sh) ──
# BASH_ENV injects `set -x` into every child bash (the runner, the mocks, work
# units); PS4 stamps source:line; BASH_XTRACEFD=7 routes it to one file. fd 3 is
# stage-io, 8 is coverage, 9 is flock — 7 is free (run-tests.sh:101-118).
_FB_BASH_ENV="$TEST_TEMP_DIR/bashenv"
printf 'set -x\n' > "$_FB_BASH_ENV"
# Usage: _fb_traced <trace_file> <cmd...> — runs cmd with tracing to trace_file.
_fb_traced() {
    local trace="$1"; shift
    (
        export PS4='+@${BASH_SOURCE[0]-}:${LINENO}@ '
        export BASH_XTRACEFD=7
        export BASH_ENV="$_FB_BASH_ENV"
        "$@" 7>"$trace"
    )
}

# ─── the counter ─────────────────────────────────────────────────────────────
# Usage: _fb_count <trace_file> <sites_out>
# Prints the number of external execs; writes `count<TAB>file:line<TAB>cmd`
# rows (descending) to sites_out. A word is external when the TEST shell
# resolves it to a file on PATH (engine functions are not sourced here, so a
# function named like nothing on PATH is not counted), or it is one of the
# fixture's mocks. Leading `VAR=val` words and wrappers (exec, command, env,
# nice, timeout N) are stripped so the wrapped command is classified — and the
# wrapper counted too when it is itself a binary.
# A source line marked `# fork-budget-exempt: <why>` is a wait whose repeat count
# is elapsed time, not code (#2236): its rows go to <sites_out>.exempt instead.
_fb_count() {
    local trace="$1" sites="$2"
    local pairs="$TEST_TEMP_DIR/pairs.$$" exempt="$TEST_TEMP_DIR/exempt.$$"
    # The marked lines of every traced source file, as `path:line`.
    : > "$exempt"
    local src
    while IFS= read -r src; do
        [[ -f "$src" ]] || continue
        grep -n 'fork-budget-exempt:' "$src" 2>/dev/null | cut -d: -f1 | sed "s|^|$src:|" >> "$exempt" || true
    done < <(awk '/^\++@[^@]*@ /{ s = $0; sub(/^\++@/, "", s); sub(/:[0-9]*@ .*$/, "", s); if (!(s in seen)) { seen[s] = 1; print s } }' "$trace")
    # pass 1: one `site<TAB>word` row per candidate command word (no forks per line);
    # an exempt site's row is tagged so pass 2 lists it apart.
    awk -v exf="$exempt" '
        BEGIN { while ((getline l < exf) > 0) ex[l] = 1 }
        /^\++@[^@]*@ / {
            site = $0; sub(/^\++@/, "", site); sub(/@ .*$/, "", site)
            tag = (site in ex) ? "\tX" : ""
            n = split(site, sp, "/"); site = sp[n]
            line = $0; sub(/^\++@[^@]*@ /, "", line)
            m = split(line, w, " ")
            for (i = 1; i <= m; i++) {
                t = w[i]
                if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue          # VAR=val prefix
                if (t == "exec" || t == "command" || t == "env" || t == "nice") continue
                # `timeout N cmd` is two processes — timeout forks cmd so it can
                # kill it — so both are counted (one row each), and N is skipped.
                if ((t == "timeout" || t == "gtimeout") && i < m) { print site "\t" t tag; i++; continue }
                gsub(/^[\x27"]|[\x27"]$/, "", t)
                print site "\t" t tag
                break
            }
        }' "$trace" > "$pairs"
    # classify each unique word once in this shell
    local w kind; local -A ext=()
    for w in claude gh git rsync; do ext["$w"]=1; done
    while IFS= read -r w; do
        [[ -n "$w" && -z "${ext[$w]+x}" ]] || continue
        kind="$(type -t -- "$w" 2>/dev/null || true)"
        [[ "$kind" == "file" ]] && ext["$w"]=1
    done < <(cut -f2 "$pairs" | sort -u)
    # pass 2: keep external rows, tally by site. The site table goes through a
    # temp file and a synchronous sort — a `2> >(sort …)` process substitution
    # would return before sort finished writing (review on #2153).
    local extlist=""; for w in "${!ext[@]}"; do extlist+="$w "; done
    local unsorted="$TEST_TEMP_DIR/sites-unsorted.$$"
    awk -v extlist="$extlist" -v out="$unsorted" -v xout="$unsorted.x" '
        BEGIN { n = split(extlist, a, " "); for (i = 1; i <= n; i++) ext[a[i]] = 1 }
        BEGIN { FS = "\t" }
        ($2 in ext) && $3 == "X" { xsite[$1 "\t" $2]++; next }
        ($2 in ext) { total++; site[$1 "\t" $2]++ }
        END {
            printf "" > out; printf "" > xout
            for (k in site) printf "%d\t%s\n", site[k], k > out
            for (k in xsite) printf "%d\t%s\n", xsite[k], k > xout
            close(out); close(xout)
            print total + 0
        }' "$pairs"
    sort -rn "$unsorted" > "$sites" 2>/dev/null || : > "$sites"
    sort -rn "$unsorted.x" > "$sites.exempt" 2>/dev/null || : > "$sites.exempt"
    rm -f "$pairs" "$unsorted" "$unsorted.x" "$exempt"
}

# ─── SPEC-1: the canary ──────────────────────────────────────────────────────
print_test_section "SPEC-1: a script with one external exec counts exactly 1"
CANARY="$TEST_TEMP_DIR/canary.sh"
cat > "$CANARY" <<'EOF'
#!/usr/bin/env bash
x="$(dirname /a/b)"
y="${x%/*}"
printf '%s\n' "$y" >/dev/null
EOF
_fb_traced "$TEST_TEMP_DIR/canary.trace" bash "$CANARY"
_canary_n="$(_fb_count "$TEST_TEMP_DIR/canary.trace" "$TEST_TEMP_DIR/canary.sites")"
assert_eq "[SPEC-1] the canary's one dirname is counted, its builtins are not" "1" "$_canary_n"
assert_contains "[SPEC-1] …and attributed to its call site" "$(cat "$TEST_TEMP_DIR/canary.sites")" "canary.sh:2"$'\t'"dirname"

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
_fb_traced "$TEST_TEMP_DIR/waiter.trace" bash "$WAITER"
_waiter_n="$(_fb_count "$TEST_TEMP_DIR/waiter.trace" "$TEST_TEMP_DIR/waiter.sites")"
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
    export FIXTURE_STATE_DIR="$RUN_DIR" FIXTURE_BIN_DIR="$BIN_DIR" ZBUILD_PLAN_CONTEXT_DIR="$TEST_TEMP_DIR/pc"
    _fb_traced "$TRACE" bash "$FIXTURE" >/dev/null 2>&1
)
_run_rc=$?
set -e
assert_eq "[SPEC-2] the mocked full run exits 0 under tracing" "0" "$_run_rc"
assert_file_exists "[SPEC-2] …and produced events.jsonl" "$RUN_DIR/events/events.jsonl"

# ─── SPEC-3/4: the count ─────────────────────────────────────────────────────
print_test_section "SPEC-3/4: liveness floor and the budget"
SITES="$TEST_TEMP_DIR/run.sites"
_total="$(_fb_count "$TRACE" "$SITES")"
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
assert_contains "[SPEC-6] the worker pool's poll sleep is listed as an exempt wait" \
    "$(cat "$SITES.exempt" 2>/dev/null)" $'local_engine.sh:'
_pool_max="$(awk -F'\t' '$2 ~ /^local_engine\.sh:/ && $1 > m { m = $1 } END { print m + 0 }' "$SITES")"
assert_eq "[SPEC-6] …and no counted pool line runs more than once per work unit" "1" "$(( _pool_max <= 2 ))"
if (( _total <= FORK_BUDGET )); then
    assert_pass "[SPEC-4] ${_total} external execs ≤ FORK_BUDGET ${FORK_BUDGET}"
else
    assert_fail "[SPEC-4] external execs ≤ FORK_BUDGET" "${_total} > ${FORK_BUDGET} — see the call sites above; ADR-065 §2: the budget only ratchets down"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
