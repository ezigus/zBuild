#!/usr/bin/env bash
# Unit test (#827, #2185): a scope violation never costs build its in-scope work.
#
# ADR-030 Layer 3: build emits a scope_expansion_request "alongside its in-scope
# diff, and does NOT touch the out-of-scope file". #827 kept the in-scope work
# only when the router returned rc>=2; since #1208 the router returns 0 on a
# timeout and says so in _ROUTE_LOOP_TERMINATED_REASON=router_timeout, so that
# branch could never fire (#1849 run 35949629759 lost a whole build attempt).
# The mocks below use the router's REAL shapes: rc=0 + a reason word.
#
#   T1 timeout (rc=0, router_timeout) + OOS edit → OOS reverted, in-scope diff
#      kept AND committed, scope request emitted.
#   T2 clean finish (rc=0, done_sentinel) + OOS edit → the same.
#   T3 clean finish, edited existing OOS collateral only → request + revert.
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
# always writes BOTH an in-scope file (in_scope.txt) AND an out-of-scope
# file (docs/oos.md — collateral, so it can be asked for) to mimic the partial-work scenario.
MOCK_ROUTER_RC=0
# shellcheck disable=SC2317
route_to_model_loop() {
    local _repo="$3"
    if [[ -n "${MOCK_EDIT_TARGET:-}" ]]; then
        # REC-2: edit an EXISTING out-of-scope file (no in-scope work).
        printf 'NEW value (build edit)\n' > "$_repo/$MOCK_EDIT_TARGET"
    else
        echo "in-scope work from LLM" > "$_repo/in_scope.txt"
        mkdir -p "$_repo/docs"
        echo "OOS work from LLM"      > "$_repo/docs/oos.md"
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

# Per-test fixture: fresh git repo, plan with only in_scope.txt in scope.
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
    printf '%s' "$BASELINE" > "$ZBUILD_STATE_DIR/intake-baseline-ref.txt"

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

# Asserts shared by T1/T2: in-scope work kept + committed, OOS reverted, asked for.
_assert_inscope_kept() {
    local tag="$1"
    if grep -q 'in_scope.txt' "$DIFF_PATCH" 2>/dev/null; then
        assert_pass "$tag: diff.patch contains the in-scope change"
    else
        assert_fail "$tag: in-scope work dropped from diff.patch" \
            "size=$(wc -c < "$DIFF_PATCH" 2>/dev/null || echo 0)"
    fi
    if grep -q 'docs/oos.md' "$DIFF_PATCH" 2>/dev/null; then
        assert_fail "$tag: diff.patch leaked the out-of-scope file"
    else
        assert_pass "$tag: diff.patch does not contain the out-of-scope file"
    fi
    if [[ -e "$REPO/docs/oos.md" ]]; then
        assert_fail "$tag: out-of-scope file left in the tree"
    else
        assert_pass "$tag: out-of-scope file reverted"
    fi
    local committed
    committed="$(git -C "$REPO" diff --name-only "$BASELINE" HEAD 2>/dev/null || true)"
    assert_eq "$tag: in-scope work is committed (and nothing else)" "in_scope.txt" "$committed"
    local req
    req="$(jq -r '.scope_expansion_request.files[]?.path // empty' "$SUMMARY_JSON" 2>/dev/null || true)"
    assert_eq "$tag: scope request names the out-of-scope file" "docs/oos.md" "$req"
    local fc
    fc="$(jq -r '(.files_changed // []) | join(",")' "$SUMMARY_JSON" 2>/dev/null || true)"
    assert_eq "$tag: build-summary reports the in-scope file it changed" "in_scope.txt" "$fc"
    local v
    v="$(jq -r '.verdict // empty' "$SUMMARY_JSON" 2>/dev/null || true)"
    assert_eq "$tag: the violation is still reported (verdict)" "scope_violation" "$v"
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
_setup_fixture t2
MOCK_ROUTER_RC=0
MOCK_TERMINATED_REASON="done_sentinel"
set +e
_build_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$DIFF_PATCH" "$SUMMARY_JSON" "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T2: clean run rc=0" "0" "$rc"
_assert_inscope_kept "T2" || true

# ─── T3 (REC-2 #880): clean run + EDITED existing OOS collateral → request + revert ─
# build edits an existing out-of-scope test file (no in-scope work). Instead of
# silently reverting with no record, build emits a governed scope_expansion_request
# for it AND reverts the file to HEAD (old value restored for the evidence check).
_setup_fixture t3
OOS_REL="tests/oos-pin-test.sh"
mkdir -p "$REPO/tests"
printf 'assert_eq "pins" "%s" "$n"\n' "'8 stages'" > "$REPO/$OOS_REL"
git -C "$REPO" add "$OOS_REL"
git -C "$REPO" -c commit.gpgsign=false commit -q -m "add oos test"
BASELINE="$(git -C "$REPO" rev-parse HEAD)"
printf '%s' "$BASELINE" > "$ZBUILD_STATE_DIR/intake-baseline-ref.txt"
# Feedback names the OOS file with the old value → evidence for the grant.
# shellcheck disable=SC2317
_build_read_prior_assessment() { printf "test failed: %s pins '8 stages'\n" "$OOS_REL"; }
MOCK_ROUTER_RC=0
MOCK_TERMINATED_REASON="done_sentinel"
MOCK_EDIT_TARGET="$OOS_REL"
set +e
_build_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$DIFF_PATCH" "$SUMMARY_JSON" "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
unset MOCK_EDIT_TARGET
unset -f _build_read_prior_assessment
assert_eq "T3: clean run rc=0" "0" "$rc"
# A scope_expansion_request for the edited OOS collateral is emitted.
req_path="$(jq -r '.scope_expansion_request.files[]?.path // empty' "$SUMMARY_JSON" 2>/dev/null | head -1)"
assert_eq "T3: request emitted for edited OOS file" "$OOS_REL" "$req_path"
req_cat="$(jq -r '.scope_expansion_request.files[]? | select(.path=="'"$OOS_REL"'") | .category' "$SUMMARY_JSON" 2>/dev/null)"
assert_eq "T3: classified collateral_tests" "collateral_tests" "$req_cat"
req_ev="$(jq -r '.scope_expansion_request.files[]? | select(.path=="'"$OOS_REL"'") | .evidence' "$SUMMARY_JSON" 2>/dev/null)"
assert_eq "T3: evidence = old value (file reverted, token present)" "8 stages" "$req_ev"
# The OOS file was reverted to HEAD (old value restored, not build's new value).
if grep -q '8 stages' "$REPO/$OOS_REL" 2>/dev/null && ! grep -q 'NEW value' "$REPO/$OOS_REL" 2>/dev/null; then
    assert_pass "T3: edited OOS file reverted to HEAD (old value restored)"
else
    assert_fail "T3: OOS file not reverted" "content: $(cat "$REPO/$OOS_REL" 2>/dev/null)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
