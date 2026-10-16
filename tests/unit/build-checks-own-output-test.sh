#!/usr/bin/env bash
# tests/unit/build-checks-own-output-test.sh — build checks its own change for
# secrets and goes back to its model with what it finds (#2371, ADR-040, ADR-068).
#
# Why: a check that reads one stage's output belongs to that stage. The scan
# that was the secret-scan stage runs inside build, over the change build made.
# A secret found goes back to build's model, with where it is (never the value),
# until the change is clean or build's rounds (config.check_rounds: 3) run out;
# then build's one outcome is fail, with the findings.
#
# K1 [change] a secret in pass 1 goes back to the model, naming where it is;
#             a clean pass 2 passes
# K2 [change] still a secret when the rounds run out: outcome fail, the result
#             lists the finding (file and line, never the value)
# K3 [guard]  a clean change takes one pass
# K4 [change] the rounds come from build's own manifest (3)
# K5 [change] secret-scan is no longer a stage, and the build loop requires
#             build to pass
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "build checks its own change for secrets (#2371)"
setup_test_env "build-checks-own-output"

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

SECRET='aws_key = "AKIAABCDEFGHIJKLMNOP"'
# One build pass: pass n commits ${PASSES[n-1]} as src/app.sh, keeps the prompt
# it was given, and writes a passing result.
PASSES=()
_build_stage_run_inner() {
    local n; n=$(( $(cat "$TEST_TEMP_DIR/passes" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/passes"
    printf '%s' "${_BUILD_CHECK_FOUND:-}" > "$TEST_TEMP_DIR/found-$n"
    printf '%s\n' "${PASSES[$((n - 1))]:-${PASSES[${#PASSES[@]}-1]}}" > "$R/src/app.sh"
    git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm "pass $n" >/dev/null 2>&1
    printf '{"schema_version":4,"files_changed_count":1}' > "$4"
    stage_result_add "$4" pass "built" >/dev/null 2>&1
    return 0
}

_run() {
    rm -rf "$TEST_TEMP_DIR/run" "$TEST_TEMP_DIR"/passes "$TEST_TEMP_DIR"/found-*
    local d="$TEST_TEMP_DIR/run"; R="$d/repo"; A="$d/state/artifacts"
    mkdir -p "$A" "$R/src"
    ( cd "$R" && git init -q -b main . && git config user.email t@e.st && git config user.name t \
        && printf 'seed\n' > README && git add -A && git commit -q -m seed \
        && git checkout -q -b zbuild/issue-1 ) >/dev/null 2>&1
    export ZBUILD_REPO_ROOT="$R" ZBUILD_EVENTS_JSONL="$d/events.jsonl"
    _build_stage_run_checked "$d/state/scope.md" "$A/plan.json" "$A/diff.patch" "$A/build-summary.json" "$A" >/dev/null 2>&1
    RC=$?
    OUTCOME="$(jq -r '.outcome // "MISSING"' "$A/build-summary.json" 2>/dev/null || echo MISSING)"
    FINDINGS="$(jq -r '.data.findings[]?.text // empty' "$A/build-summary.json" 2>/dev/null || true)"
    N="$(cat "$TEST_TEMP_DIR/passes" 2>/dev/null || echo 0)"
}

# ── K1 ───────────────────────────────────────────────────────────────────────
PASSES=("$SECRET" 'aws_key="${AWS_KEY:?}"')
_run
assert_eq "[K1] a secret sends build round again" "2" "$N"
assert_contains "[K1] the next pass is told where it is" "$(cat "$TEST_TEMP_DIR/found-2" 2>/dev/null)" "src/app.sh:1"
assert_eq "[K1] ...never the value" "0" "$(grep -c 'AKIAABCDEFGHIJKLMNOP' "$TEST_TEMP_DIR/found-2" 2>/dev/null || true)"
assert_eq "[K1] a clean pass 2 passes" "pass" "$OUTCOME"

# ── K2 ───────────────────────────────────────────────────────────────────────
PASSES=("$SECRET")
_run
assert_eq "[K2] one pass per round, no more" "3" "$N"
assert_eq "[K2] still a secret when the rounds run out: outcome fail" "fail" "$OUTCOME"
assert_eq "[K2] ...rc 0 (the stage finished)" "0" "$RC"
assert_contains "[K2] the result lists where it is" "$FINDINGS" "src/app.sh:1"
assert_eq "[K2] ...never the value" "0" "$(grep -c 'AKIAABCDEFGHIJKLMNOP' "$A/build-summary.json" || true)"

# ── K3 ───────────────────────────────────────────────────────────────────────
PASSES=('echo hello')
_run
assert_eq "[K3] a clean change takes one pass" "1" "$N"
assert_eq "[K3] ...and passes" "pass" "$OUTCOME"

# ── K4 / K5 ──────────────────────────────────────────────────────────────────
assert_eq "[K4] build's manifest sets its rounds" "3" \
    "$(yaml_get "$REPO_ROOT/plugins/agent/build/manifest.yaml" config.check_rounds 2>/dev/null)"
assert_eq "[K5] secret-scan is no longer a plugin" "absent" \
    "$([[ -d "$REPO_ROOT/plugins/tool/secret-scan" ]] && echo present || echo absent)"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$REPO_ROOT/config/templates/simple.yaml" >/dev/null 2>&1
_req=""
for (( i = 1; i <= ${_TPL_CYCLE_EXIT_COUNT_build_test_cycle:-0}; i++ )); do
    v="_TPL_CYCLE_EXIT_${i}_STAGE_build_test_cycle"; _req+="${!v} "
done
assert_contains "[K5] the build loop requires build to pass" " $_req" " build "
assert_eq "[K5] ...nor in a template" "0" "$(grep -c 'secret-scan' "$REPO_ROOT"/config/templates/*.yaml | awk -F: '{s+=$2} END {print s+0}')"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
