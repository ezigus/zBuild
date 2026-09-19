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
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "fork budget: external execs of a mocked full run (#2151, ADR-065)"
setup_test_env "fork-budget"

# ADR-065 §2. Ratchets down only. History: 8000 (#2151, measured 7,128 macOS).
FORK_BUDGET=8000

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
_fb_count() {
    local trace="$1" sites="$2"
    local pairs="$TEST_TEMP_DIR/pairs.$$"
    # pass 1: one `site<TAB>word` row per candidate command word (no forks per line)
    awk '
        /^\++@[^@]*@ / {
            site = $0; sub(/^\++@/, "", site); sub(/@ .*$/, "", site); n = split(site, sp, "/"); site = sp[n]
            line = $0; sub(/^\++@[^@]*@ /, "", line)
            m = split(line, w, " ")
            for (i = 1; i <= m; i++) {
                t = w[i]
                if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue          # VAR=val prefix
                if (t == "exec" || t == "command" || t == "env" || t == "nice") continue
                # `timeout N cmd` is two processes — timeout forks cmd so it can
                # kill it — so both are counted (one row each), and N is skipped.
                if ((t == "timeout" || t == "gtimeout") && i < m) { print site "\t" t; i++; continue }
                gsub(/^[\x27"]|[\x27"]$/, "", t)
                print site "\t" t
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
    awk -v extlist="$extlist" -v out="$unsorted" '
        BEGIN { n = split(extlist, a, " "); for (i = 1; i <= n; i++) ext[a[i]] = 1 }
        BEGIN { FS = "\t" }
        ($2 in ext) { total++; site[$1 "\t" $2]++ }
        END {
            for (k in site) printf "%d\t%s\n", site[k], k > out
            close(out)
            print total + 0
        }' "$pairs"
    sort -rn "$unsorted" > "$sites" 2>/dev/null || : > "$sites"
    rm -f "$pairs" "$unsorted"
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
if (( _total <= FORK_BUDGET )); then
    assert_pass "[SPEC-4] ${_total} external execs ≤ FORK_BUDGET ${FORK_BUDGET}"
else
    assert_fail "[SPEC-4] external execs ≤ FORK_BUDGET" "${_total} > ${FORK_BUDGET} — see the call sites above; ADR-065 §2: the budget only ratchets down"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
