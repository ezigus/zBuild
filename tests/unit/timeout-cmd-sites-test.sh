#!/usr/bin/env bash
# Tests: every converted timeout site still bounds its command on a host that has
# only `gtimeout` (#1752, ADR-036 amendment 2026-10-09). macOS has no `timeout`
# — Homebrew's coreutils installs it as `gtimeout` — and a site that called
# `timeout` bare there ran its command unbounded or not at all (#2113).
#
# S1 scripts/run-tests.sh          per-file bound, with -k <ZBUILD_TEST_KILL_GRACE>
# S2 scripts/run-mutation.sh       per-mutant bound, with -k <ZBUILD_MUTATION_KILL_GRACE>
# S3 core/router/route.sh          _route_call_claude — TERM-only, as before
# S4 core/router/route.sh          route_to_model_loop — TERM-only, as before
# S5 scripts/lib/gh-automation.sh  gha_compute_similarity_llm — TERM-only, as before
# S6 scripts/lib/acceptance-negctl.sh _negctl_run — with -k <ZBUILD_NEGCTL_KILL_GRACE>
# S7 build's false-completion guard: a red acceptance testfile is still reported
#    (#1532 → inert_build), and it ran under the bound
#
# The host is a PATH holding every tool on this machine except timeout/gtimeout,
# plus a recording `gtimeout` shim — not test-helpers.sh's `timeout` mock, which
# ignores its duration and so cannot show whether a bound was applied.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "timeout sites bound their command on a gtimeout-only host (#1752)"
setup_test_env "timeout-cmd-sites"
_test_cleanup_hook() { cleanup_test_env; }

# ─── the gtimeout-only host ──────────────────────────────────────────────────
FARM="$TEST_TEMP_DIR/farm"; SHIM="$TEST_TEMP_DIR/shim"
mkdir -p "$FARM" "$SHIM"
IFS=: read -r -a _path_dirs <<< "$PATH"
for _d in "${_path_dirs[@]}"; do
    [[ -d "$_d" ]] || continue
    for _f in "$_d"/*; do
        _n="${_f##*/}"
        [[ "$_n" == timeout || "$_n" == gtimeout ]] && continue
        [[ -x "$_f" && ! -e "$FARM/$_n" ]] && ln -s "$_f" "$FARM/$_n" 2>/dev/null || true
    done
done
cat > "$SHIM/gtimeout" <<SH
#!$BASH
printf '%s\n' "\$*" >> "\$GT_LOG"
[[ "\$1" == "-k" ]] && shift 2
shift
exec "\$@"
SH
chmod +x "$SHIM/gtimeout"
export GT_LOG="$TEST_TEMP_DIR/gt.log"
GT_ONLY="$SHIM:$FARM"
# _logged <ERE> — 1 when a recorded gtimeout call (not the -k probe) matches.
_logged() {
    if /usr/bin/grep -v -- '^-k 1 1 true$' "$GT_LOG" 2>/dev/null | /usr/bin/grep -qE -- "$1"; then  # sigpipe-ok: grep -q after a finished grep in a test
        echo 1
    else
        echo 0
    fi
}
REAL_GIT="$(command -v git)"

# ─── S1: run-tests.sh ────────────────────────────────────────────────────────
print_test_section "S1: scripts/run-tests.sh"
FIX="$TEST_TEMP_DIR/fix"; mkdir -p "$FIX/unit"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/unit/a-test.sh"
: > "$GT_LOG"
env -u _ACCEPTANCE_TIMEOUT_KILL_OK PATH="$GT_ONLY" ZBUILD_TESTS_DIR="$FIX" \
    ZBUILD_PLUGINS_DIR="$TEST_TEMP_DIR/empty" ZBUILD_CORE_DIR="$TEST_TEMP_DIR/empty" \
    ZBUILD_TEST_FILE_TIMEOUT=17 ZBUILD_TEST_KILL_GRACE=3 ZBUILD_TEST_PARALLEL_JOBS=0 \
    bash "$REPO_ROOT/scripts/run-tests.sh" --tier unit >"$TEST_TEMP_DIR/s1.out" 2>&1 || true
assert_eq "[S1] each test file runs under gtimeout -k <grace> <bound>" "1" \
    "$(_logged '^-k 3 17 bash .*/a-test\.sh$')"

# ─── S2: run-mutation.sh ─────────────────────────────────────────────────────
print_test_section "S2: scripts/run-mutation.sh"
SB="$TEST_TEMP_DIR/sandbox"
mkdir -p "$SB/scripts/lib" "$SB/core" "$SB/tests/unit" "$SB/tests/mutation"
cp "$REPO_ROOT/scripts/run-mutation.sh" "$SB/scripts/run-mutation.sh"
cp "$REPO_ROOT/scripts/lib/timeout-cmd.sh" "$SB/scripts/lib/timeout-cmd.sh" 2>/dev/null || true
printf 'widget_ok() {\n    return 0\n}\n' > "$SB/core/widget.sh"
printf 'source core/widget.sh\nwidget_ok\n' > "$SB/tests/unit/widget-test.sh"
{
    printf '## File\n`core/widget.sh` — widget_ok.\n\n'
    printf '## Mutation\nFlip widget_ok'"'"'s return.\n\n'
    printf '## Patch\n```bash\n'
    printf "sed -i.bak 's/return 0/return 1/' core/widget.sh && rm -f core/widget.sh.bak\n"
    printf '```\n\n'
    printf '## Expected failing test\n`tests/unit/widget-test.sh` — runs widget_ok.\n\n'
    printf '## Result\nCaught.\n\n'
    printf '## Test\n```bash\nbash tests/unit/widget-test.sh\n```\n'
} > "$SB/tests/mutation/flip.md"
( cd "$SB" && "$REAL_GIT" init -q && "$REAL_GIT" config user.email t@t \
    && "$REAL_GIT" config user.name t && "$REAL_GIT" config commit.gpgsign false \
    && "$REAL_GIT" add -A && "$REAL_GIT" commit -q -m seed ) >/dev/null 2>&1
: > "$GT_LOG"
( cd "$SB" && env -u _ACCEPTANCE_TIMEOUT_KILL_OK PATH="$GT_ONLY" TMPDIR="$TEST_TEMP_DIR/_tmp" \
    ZBUILD_MUTATION_TEST_TIMEOUT=9 ZBUILD_MUTATION_KILL_GRACE=4 ZBUILD_MUTATION_PARALLEL_JOBS=1 \
    bash scripts/run-mutation.sh ) >"$TEST_TEMP_DIR/s2.out" 2>&1 || true
assert_contains "[S2] premise: the tier scored the mutant" "$(cat "$TEST_TEMP_DIR/s2.out")" "mutation: 1/1"
assert_eq "[S2] each mutant's test runs under gtimeout -k <grace> <bound>" "1" \
    "$(_logged '^-k 4 9 bash -c ')"

# ─── S3/S4: route.sh, both paths ─────────────────────────────────────────────
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$HOME/.zbuild"; printf 'bootstrap' > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1
CLBIN="$TEST_TEMP_DIR/claude-bin"; mkdir -p "$CLBIN"
cat > "$CLBIN/claude" <<'MOCK'
#!/usr/bin/env bash
cat >/dev/null
jq -n '{type:"result",result:"done\nLOOP_COMPLETE",usage:{input_tokens:1,output_tokens:1}}'
MOCK
chmod +x "$CLBIN/claude"
REPO="$TEST_TEMP_DIR/repo"; mkdir -p "$REPO"
( cd "$REPO" && "$REAL_GIT" init -q && "$REAL_GIT" config user.email t@t && "$REAL_GIT" config user.name t \
    && echo seed > seed.txt && "$REAL_GIT" add seed.txt && "$REAL_GIT" commit -q -m seed ) >/dev/null 2>&1
printf 'Do the work.\n' > "$TEST_TEMP_DIR/prompt.txt"
cat > "$TEST_TEMP_DIR/template.yaml" <<'YAML'
id: standard
name: Standard Pipeline
extends: null
defaults:
  strategy: fanout
stages:
  - id: build
    gate: auto
    roles: [builder]
YAML

print_test_section "S3: core/router/route.sh _route_call_claude"
: > "$GT_LOG"
(
    export PATH="$CLBIN:$GT_ONLY"
    unset _ACCEPTANCE_TIMEOUT_KILL_OK ZBUILD_ROUTER_MAX_TURNS ZBUILD_CURRENT_STAGE ZBUILD_ROUTER_JSON_OUTPUT
    source "$REPO_ROOT/core/pipeline/template.sh"
    source "$REPO_ROOT/core/router/route.sh"
    route_to_model "T2" "ping" --skip-precondition
) >"$TEST_TEMP_DIR/s3.out" 2>&1 || true
assert_eq "[S3] the model call runs under gtimeout <secs>, TERM-only as before" "1" \
    "$(_logged '^[0-9]+ claude ')"

print_test_section "S4: core/router/route.sh route_to_model_loop"
: > "$GT_LOG"
_s4="$TEST_TEMP_DIR/s4"; mkdir -p "$_s4/events" "$_s4/state/artifacts/stage-io"; : > "$_s4/events/events.jsonl"
(
    export PATH="$CLBIN:$GT_ONLY"
    unset _ACCEPTANCE_TIMEOUT_KILL_OK
    export ZBUILD_EVENTS_DIR="$_s4/events" ZBUILD_EVENTS_JSONL="$_s4/events/events.jsonl"
    export ZBUILD_STATE_DIR="$_s4/state" ZBUILD_RUN_ID="timeout-sites-$$" ZBUILD_CURRENT_STAGE=build
    source "$REPO_ROOT/core/event-bus/event-bus.sh"
    source "$REPO_ROOT/core/pipeline/template.sh"
    source "$REPO_ROOT/core/output/stage-io.sh"
    source "$REPO_ROOT/core/router/route.sh"
    load_template "$TEST_TEMP_DIR/template.yaml" >/dev/null 2>&1
    route_to_model_loop T2 "$TEST_TEMP_DIR/prompt.txt" "$REPO" 1
) >"$TEST_TEMP_DIR/s4.out" 2>&1 || true
assert_eq "[S4] each loop call runs under gtimeout <secs>, TERM-only as before" "1" \
    "$(_logged '^[0-9]+ claude ')"

# ─── S5: gh-automation.sh ────────────────────────────────────────────────────
print_test_section "S5: scripts/lib/gh-automation.sh gha_compute_similarity_llm"
cat > "$CLBIN/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"{\"score\":0.75}"}'
MOCK
: > "$GT_LOG"
_s5="$(
    export PATH="$CLBIN:$GT_ONLY" ANTHROPIC_API_KEY=test LLM_TIEBREAKER_ENABLED=1 \
        LLM_TIEBREAKER_TIMEOUT_SECS=21 LLM_TIEBREAKER_CACHE_DIR="$TEST_TEMP_DIR/llm-cache"
    unset _ACCEPTANCE_TIMEOUT_KILL_OK
    source "$REPO_ROOT/scripts/lib/gh-automation.sh"
    gha_compute_similarity_llm "alpha beta" "alpha gamma" "0.50"
)"
assert_eq "[S5] premise: the tiebreak answered" "0.75|_LLM_OK" "${_s5##*$'\n'}"
assert_eq "[S5] the model call runs under gtimeout <secs>, TERM-only as before" "1" \
    "$(_logged '^21 claude ')"

# ─── S6: the acceptance gate's own runner ────────────────────────────────────
print_test_section "S6: scripts/lib/acceptance-negctl.sh _negctl_run"
printf '#!/usr/bin/env bash\nexit 0\n' > "$REPO/ok-test.sh"
: > "$GT_LOG"
(
    export PATH="$GT_ONLY" ZBUILD_NEGCTL_TIMEOUT=13 ZBUILD_NEGCTL_KILL_GRACE=5 ZBUILD_NEGCTL_TIMING_LOG=""
    unset _ACCEPTANCE_TIMEOUT_KILL_OK
    source "$REPO_ROOT/scripts/lib/acceptance-negctl.sh"
    _negctl_run "$REPO/ok-test.sh" "$REPO"
) >/dev/null 2>&1 || true
assert_eq "[S6] the testfile runs under gtimeout -k <grace> <bound>" "1" \
    "$(_logged '^-k 5 13 bash .*ok-test\.sh$')"

# ─── S7: build's false-completion guard (#1532 unregressed) ──────────────────
print_test_section "S7: a red acceptance testfile still yields inert_build"
mkdir -p "$REPO/tests/unit"
printf '#!/usr/bin/env bash\nexit 1\n' > "$REPO/tests/unit/red-test.sh"
: > "$GT_LOG"
_s7="$(
    export PATH="$GT_ONLY" ZBUILD_NEGCTL_TIMING_LOG="" ZBUILD_NEGCTL_TIMEOUT=5 ZBUILD_TEST_FILE_TIMEOUT=11
    unset _ACCEPTANCE_TIMEOUT_KILL_OK
    source "$REPO_ROOT/plugins/agent/build/lib/summary.sh" >/dev/null 2>&1
    _build_guard_false_completion "tests/unit/red-test.sh" "$REPO" 2>/dev/null
)" || true
assert_eq "[S7] the red testfile is reported (the inert_build trigger)" "tests/unit/red-test.sh" "$_s7"
assert_eq "[S7] ...and it ran under gtimeout -k <grace> <bound>" "1" \
    "$(_logged '^-k 10 11 bash .*red-test\.sh$')"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
