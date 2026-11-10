#!/usr/bin/env bash
# Unit test (#827, #2185, #2508): a change build may not make never costs it the
# rest of its work.
#
# #2185: whatever stopped the router, build kept only the in-scope work when it
# also wrote out of scope — the router returns 0 on a timeout and says so in
# _ROUTE_LOOP_TERMINATED_REASON=router_timeout, so a branch keyed on rc>=2 never
# fired (#1849 run 35949629759 lost a whole build attempt). #2508 (ADR-030 §8):
# the only change build may not make is one inside the test folders; it is put
# back, and everything else is kept and committed. Build asks for nothing.
# The mocks use the router's REAL shapes: rc=0 + a reason word.
#
#   T1 timeout (rc=0, router_timeout) + a file written in a test folder → it is
#      removed; the rest kept AND committed; reported; no request.
#   T2 clean finish (rc=0, done_sentinel) + the same → the same.
#   T3 clean finish, an EXISTING test file edited → restored to HEAD; reported.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #827: timeout-vs-clean scope-violation distinction"
setup_test_env "build-827-timeout-scope"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-827-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts"

# Operator override so per-iter redaction stub satisfies route_loop.
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# Source plugin first, then override.
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# Mocks. MOCK_ROUTER_RC drives the simulated router exit code and
# MOCK_TERMINATED_REASON its reason word; the loop body
# always writes BOTH a file outside the test folders (in_scope.txt) AND one
# inside them (tests/oos-test.sh) to mimic the partial-work scenario.
MOCK_ROUTER_RC=0
# shellcheck disable=SC2317
route_to_model_loop() {
    local _repo="$3"
    if [[ -n "${MOCK_EDIT_TARGET:-}" ]]; then
        # Edit an EXISTING test file (no other work).
        printf 'NEW value (build edit)\n' > "$_repo/$MOCK_EDIT_TARGET"
    else
        echo "in-scope work from LLM" > "$_repo/in_scope.txt"
        mkdir -p "$_repo/tests"
        echo "OOS work from LLM"      > "$_repo/tests/oos-test.sh"
    fi
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="${MOCK_TERMINATED_REASON:-done_sentinel}"
    _ROUTE_LOOP_INPUT_TOKENS=5
    _ROUTE_LOOP_OUTPUT_TOKENS=3
    _ROUTE_LOOP_LAST_RESPONSE=$'edits\nCOMMIT_SUMMARY: t\nLOOP_COMPLETE'
    return $MOCK_ROUTER_RC
}
# shellcheck disable=SC2317
_route_loop_close_final_banner() { return 0; }
# shellcheck disable=SC2317
_route_resolve_max_iterations() { echo 1; }
# shellcheck disable=SC2317
apply_scope_redaction() {
    if [[ -n "${1:-}" && -n "${2:-}" && -f "$1" ]]; then cp -f "$1" "$2"; fi
    return 0
}

# Per-test fixture: fresh git repo. The plan names in_scope.txt, but build has no
# file list (#2508): only the test folders are not its.
_setup_fixture() {
    local test_id="$1"
    REPO="$TEST_TEMP_DIR/$test_id-repo"
    rm -rf "$REPO"
    mkdir -p "$REPO"
    (
        cd "$REPO"
        git init -q
        git config user.email t@t
        git config user.name t
        echo seed > seed.txt
        git add seed.txt
        git -c commit.gpgsign=false commit -q -m M0
    ) >/dev/null
    BASELINE="$(git -C "$REPO" rev-parse HEAD)"
    export ZBUILD_RUN_START_COMMIT="$BASELINE"

    ARTIFACT_DIR="$ZBUILD_STATE_DIR/artifacts-$test_id"
    mkdir -p "$ARTIFACT_DIR"
    PLAN_JSON="$ARTIFACT_DIR/plan.json"
    SCOPE_MANIFEST="$ZBUILD_STATE_DIR/scope-manifest-$test_id.md"
    DIFF_PATCH="$ARTIFACT_DIR/diff.patch"
    SUMMARY_JSON="$ARTIFACT_DIR/build-summary.json"
    cat > "$PLAN_JSON" <<JSON
{"title":"t","files":["in_scope.txt"]}
JSON
    echo "scope: in_scope.txt" > "$SCOPE_MANIFEST"
    cd "$REPO"
    : > "$ZBUILD_EVENTS_JSONL"
}

# Asserts shared by T1/T2: the work outside the test folders kept + committed,
# the test-folder file removed and reported, nothing asked for.
_assert_inscope_kept() {
    local tag="$1"
    if grep -q 'in_scope.txt' "$DIFF_PATCH" 2>/dev/null; then
        assert_pass "$tag: diff.patch contains the in-scope change"
    else
        assert_fail "$tag: in-scope work dropped from diff.patch" \
            "size=$(wc -c < "$DIFF_PATCH" 2>/dev/null || echo 0)"
    fi
    if grep -q 'tests/oos-test.sh' "$DIFF_PATCH" 2>/dev/null; then
        assert_fail "$tag: diff.patch leaked the out-of-scope file"
    else
        assert_pass "$tag: diff.patch does not contain the out-of-scope file"
    fi
    if [[ -e "$REPO/tests/oos-test.sh" ]]; then
        assert_fail "$tag: out-of-scope file left in the tree"
    else
        assert_pass "$tag: out-of-scope file reverted"
    fi
    local committed
    committed="$(git -C "$REPO" diff --name-only "$BASELINE" HEAD 2>/dev/null || true)"
    assert_eq "$tag: in-scope work is committed (and nothing else)" "in_scope.txt" "$committed"
    assert_eq "$tag: the summary names the file it put back" "tests/oos-test.sh" \
        "$(jq -r '(.scope_violations // []) | join(",")' "$SUMMARY_JSON" 2>/dev/null || true)"
    assert_eq "$tag: no request for more files" "false" \
        "$(jq 'has("scope_expansion_request")' "$SUMMARY_JSON" 2>/dev/null || true)"
    local fc
    fc="$(jq -r '(.files_changed // []) | join(",")' "$SUMMARY_JSON" 2>/dev/null || true)"
    assert_eq "$tag: build-summary reports the in-scope file it changed" "in_scope.txt" "$fc"
    local v
    v="$(jq -r '.scope_violation // empty' "$SUMMARY_JSON" 2>/dev/null || true)"
    assert_eq "$tag: the violation is still reported (scope_violation)" "true" "$v"
    assert_eq "$tag: ...and the outcome is fail (#2366)" "fail" "$(jq -r '.outcome // empty' "$SUMMARY_JSON" 2>/dev/null || true)"
    if grep -q '"type":"build.scope.inscope_preserved"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
        assert_pass "$tag: build.scope.inscope_preserved emitted"
    else
        assert_fail "$tag: build.scope.inscope_preserved not emitted"
    fi
}

# ─── T1: timeout (router's real shape: rc=0, router_timeout) + OOS edit ─────
_setup_fixture t1
MOCK_ROUTER_RC=0
MOCK_TERMINATED_REASON="router_timeout"
set +e
_build_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$DIFF_PATCH" "$SUMMARY_JSON" "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T1: _build_stage_run_inner returns rc=0 (a timeout is not fatal)" "0" "$rc"
_assert_inscope_kept "T1" || true

# ─── T2: clean finish (rc=0, done_sentinel) + OOS edit ─────────────────────
# Same contract as T1 on purpose: the outcome must not depend on the reason word.
_setup_fixture t2
MOCK_ROUTER_RC=0
MOCK_TERMINATED_REASON="done_sentinel"
set +e
_build_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$DIFF_PATCH" "$SUMMARY_JSON" "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T2: clean run rc=0" "0" "$rc"
_assert_inscope_kept "T2" || true

# ─── T3: clean run + an EDITED existing test file → restored to HEAD ──────────
_setup_fixture t3
OOS_REL="tests/oos-pin-test.sh"
mkdir -p "$REPO/tests"
printf 'assert_eq "pins" "%s" "$n"\n' "'8 stages'" > "$REPO/$OOS_REL"
git -C "$REPO" add "$OOS_REL"
git -C "$REPO" -c commit.gpgsign=false commit -q -m "add oos test"
BASELINE="$(git -C "$REPO" rev-parse HEAD)"
export ZBUILD_RUN_START_COMMIT="$BASELINE"
MOCK_ROUTER_RC=0
MOCK_TERMINATED_REASON="done_sentinel"
MOCK_EDIT_TARGET="$OOS_REL"
set +e
_build_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$DIFF_PATCH" "$SUMMARY_JSON" "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
unset MOCK_EDIT_TARGET
assert_eq "T3: clean run rc=0" "0" "$rc"
assert_eq "T3: the edited test file is reported" "$OOS_REL" \
    "$(jq -r '(.scope_violations // []) | join(",")' "$SUMMARY_JSON" 2>/dev/null)"
if grep -q '8 stages' "$REPO/$OOS_REL" 2>/dev/null && ! grep -q 'NEW value' "$REPO/$OOS_REL" 2>/dev/null; then
    assert_pass "T3: edited test file restored to HEAD (old value back)"
else
    assert_fail "T3: test file not restored" "content: $(cat "$REPO/$OOS_REL" 2>/dev/null)"
fi
assert_eq "T3: nothing is committed" "$BASELINE" "$(git -C "$REPO" rev-parse HEAD)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
