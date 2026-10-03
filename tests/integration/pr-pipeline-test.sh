#!/usr/bin/env bash
# Integration test: the REAL pr-delivery agent plugin (#756).
#
# Exercises plugins/agent/pr-delivery/plugin.sh directly (not a stub) across its
# lifecycle hooks, including the pr-open delegation path where the run's state
# file must be threaded through (the bug that made the pr stage fail at runtime).
#
# SPEC coverage (A3-pr migration, ADR-013 amendment pr kind:tool→agent):
#   [SPEC-1] simple.yaml resolves to its leaf roster with pr as the LAST leaf
#            (#979: repointed from the retired standard.yaml — the assertion is
#            "pr is the terminal leaf of the shipped roster", template-agnostic)
#   [SPEC-2] plugins/agent/pr-delivery/{plugin.sh,manifest.yaml} exist; id=pr-delivery
#   [SPEC-3] dry-run: real plugin writes pr-url.txt + pr-result.json, exits 0
#   [SPEC-4] a needs_attention review does not block: pr-open opens the PR (ADR-040 §4)
#   [SPEC-5] delegation: non-dry-run threads the state file to pr-open, which
#            writes pr-url.txt from the (mocked) gh pr create — locks the
#            state-file-threading fix that the dogfood shipped broken.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "pr-delivery agent plugin: real plugin integration (#756)"
setup_test_env "pr-pipeline-756"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_RUN_ID="pr-pipeline-test-$$"
mkdir -p "$ZBUILD_EVENTS_DIR"

# ─── SPEC-1: simple.yaml resolves its leaf roster, last leaf is pr ───────────
# #979: standard.yaml retired; the shipped default is simple.yaml. The assertion
# under test is "pr is the terminal leaf of the shipped roster" — pin the last
# leaf by index rather than a brittle absolute count.
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$REPO_ROOT/config/templates/simple.yaml"
_leaf_count="${#_TPL_STAGES[@]}"
assert_eq "[SPEC-1] simple.yaml resolves a non-empty leaf roster" \
    "1" "$(( _leaf_count > 0 ? 1 : 0 ))"
assert_eq "[SPEC-1] simple.yaml last leaf stage id is pr" \
    "pr" "${_TPL_STAGES[$(( _leaf_count - 1 ))]:-}"

# ─── SPEC-2: the real plugin files exist under the pr-delivery id ────────────
assert_file_exists "[SPEC-2] plugins/agent/pr-delivery/plugin.sh exists" \
    "$REPO_ROOT/plugins/agent/pr-delivery/plugin.sh"
assert_file_exists "[SPEC-2] plugins/agent/pr-delivery/manifest.yaml exists" \
    "$REPO_ROOT/plugins/agent/pr-delivery/manifest.yaml"
_pr_id="$(yaml_get "$REPO_ROOT/plugins/agent/pr-delivery/manifest.yaml" "id")"
assert_eq "[SPEC-2] manifest id is pr-delivery (no collision with tool/pr-open id:pr)" \
    "pr-delivery" "$_pr_id"

# ─── Source the REAL plugin (resolves its repo root via bootstrap) ───────────
# shellcheck source=../../plugins/agent/pr-delivery/plugin.sh
source "$REPO_ROOT/plugins/agent/pr-delivery/plugin.sh"

# Helper: fresh state dir + a review.json with the given verdict.
_setup_run() {
    local verdict="$1"
    local d="$TEST_TEMP_DIR/run-$2"
    mkdir -p "$d/artifacts"
    printf '{"schema_version":1,"verdict":"%s","issues":[],"summary":"t"}\n' "$verdict" \
        > "$d/artifacts/review.json"
    printf '{"issue":756}\n' > "$d/pipeline-state.json"
    printf '%s' "$d/pipeline-state.json"
}

# ─── SPEC-3: dry-run writes both artifacts and exits 0 ───────────────────────
print_test_section "SPEC-3: dry-run produces artifacts via the real plugin"
_sf3="$(_setup_run approve s3)"
: > "$ZBUILD_EVENTS_JSONL"
( ZBUILD_DRY_RUN=1 pr_stage_run "pr" "$_sf3" ) >/dev/null 2>&1; _rc3=$?
_art3="$(dirname "$_sf3")/artifacts"
assert_eq "[SPEC-3] dry-run pr_stage_run exits 0" "0" "$_rc3"
assert_file_exists "[SPEC-3] pr-url.txt written" "$_art3/pr-url.txt"
assert_file_exists "[SPEC-3] pr-result.json written" "$_art3/pr-result.json"
# SPEC-9: the non-draft default is observable at the integration level — the
# dry-run pr-result.json records draft=false (fails at baseline, which emitted true).
_draft9="$(jq -r '.data.draft' "$_art3/pr-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-9] dry-run pr-result.json records draft=false (non-draft default)" "false" "$_draft9"

# ─── SPEC-5: non-dry-run delegates to pr-open with the threaded state file ───
# Locks the runtime fix: the run's state file (not the unset ZBUILD_STATE_FILE)
# reaches pr-open, which reads .issue and writes pr-url.txt from `gh pr create`.
print_test_section "SPEC-5: delegation to pr-open threads the state file"
_sf5="$(_setup_run approve s5)"
_art5="$(dirname "$_sf5")/artifacts"
_mockbin="$TEST_TEMP_DIR/bin"; mkdir -p "$_mockbin"
cat > "$_mockbin/gh" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "pr" && "${2:-}" == "create" ]] && { echo "https://github.com/mock/repo/pull/756"; exit 0; }
echo ""; exit 0
MOCK
cat > "$_mockbin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) [[ "${2:-}" == "--abbrev-ref" ]] && echo "zbuild/issue-756" || echo "/tmp/mock"; ;;
    push|checkout) exit 0 ;;
    *) echo "" ;;
esac
exit 0
MOCK
chmod +x "$_mockbin/gh" "$_mockbin/git"

# ─── SPEC-4: a review that needs attention never blocks delivery ──────────────
# ADR-040 §4 (#1844, Eric 2026-10-03): the review is advisory. A needs_attention
# report — read through ZBUILD_STAGE_INPUTS at a non-standard path — does not
# refuse delivery; pr-delivery hands over to pr-open, which opens the PR.
# Runs under the gh/git mocks: unmocked, the real pr-open would create a branch
# in the checkout the suite runs from (it did, in the #1844 worktree).
print_test_section "SPEC-4: a needs_attention review does not block — pr-open opens the PR"
_sf4="$(_setup_run approve s4)"
_art4="$(dirname "$_sf4")/artifacts"
_rr4="$TEST_TEMP_DIR/review-report-s4.json"
jq -n '{merge_readiness:"needs_attention",findings:[{severity:"critical",summary:"blocking"}],summary:"t"}' \
    > "$_rr4"
_si4="$TEST_TEMP_DIR/si-s4.json"
printf '{"inputs":{"review_report":"%s"}}\n' "$_rr4" > "$_si4"
( unset ZBUILD_STATE_FILE; PATH="$_mockbin:$PATH" ZBUILD_STAGE_INPUTS="$_si4" ZBUILD_DRY_RUN=0 \
    pr_stage_run "pr" "$_sf4" ) >/dev/null 2>&1; _rc4=$?
assert_eq "[SPEC-4] a needs_attention review → pr_stage_run delivers (rc=0)" "0" "$_rc4"
assert_file_exists "[SPEC-4] a needs_attention review → pr-open wrote pr-url.txt" "$_art4/pr-url.txt"
( unset ZBUILD_STATE_FILE; PATH="$_mockbin:$PATH" ZBUILD_DRY_RUN=0 \
    pr_stage_run "pr" "$_sf5" ) >/dev/null 2>&1; _rc5=$?
assert_eq "[SPEC-5] non-dry-run pr_stage_run exits 0 (state file threaded to pr-open)" "0" "$_rc5"
assert_file_exists "[SPEC-5] pr-url.txt written by pr-open delegation" "$_art5/pr-url.txt"
if [[ -f "$_art5/pr-url.txt" ]]; then
    assert_contains "[SPEC-5] pr-url.txt holds the gh-created URL" \
        "$(cat "$_art5/pr-url.txt")" "github.com/mock/repo/pull/756"
fi

# [#1844/SPEC-16]: passing pr-open delegation produces pr-result.json with the
# v2 structure matching tests/golden/pr-result-artifact.golden.
# reason is FIRST: at baseline the real pr-open writes reason:"PR opened" so the
# first tagged assertion fails there — making the negctl check non-tautological.
if [[ -f "$_art5/pr-result.json" ]]; then
    # pr-delivery writes its OWN result over pr-open's: its reason names the
    # hand-over ("PR opened by pr-open: <url>"), where pr-open's reads "PR opened".
    # Non-empty — ADR-054 §5 makes reason mandatory, and the engine refuses "".
    assert_contains "[#1844/SPEC-16] pr-result.json reason is pr-delivery's (names the hand-over)" \
        "$(jq -r '.reason // ""' "$_art5/pr-result.json" 2>/dev/null || true)" "PR opened by pr-open"
    assert_eq "[#1844/SPEC-16] pr-result.json result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_art5/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-16] pr-result.json verdict is pass" "pass" \
        "$(jq -r '.verdict // empty' "$_art5/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-16] pr-result.json disposition is complete" "complete" \
        "$(jq -r '.disposition // empty' "$_art5/pr-result.json" 2>/dev/null || true)"
    _s16_url="$(jq -r '.data.pr_url // empty' "$_art5/pr-result.json" 2>/dev/null || true)"
    [[ -n "$_s16_url" ]] \
        && assert_pass "[#1844/SPEC-16] pr-result.json data.pr_url is non-empty" \
        || assert_fail "[#1844/SPEC-16] pr-result.json data.pr_url is non-empty" "empty"
    assert_eq "[#1844/SPEC-16] pr-result.json data.draft is false" "false" \
        "$(jq -r '.data.draft' "$_art5/pr-result.json" 2>/dev/null || echo MISSING)"
else
    assert_fail "[#1844/SPEC-16] pr-result.json written by pr-open delegation" "file absent"
fi

# ─── SPEC-6: pr-open surfaces the real push stderr in pr-result.json .reason ──
# Issue PR: the push now goes through zbuild_push_reconcile, which captures git's
# stderr instead of discarding it (was `git push -u origin B 2>/dev/null`). When
# the reconciled (force-with-lease) push genuinely fails, the distinctive git
# stderr must reach pr-result.json .reason so a human can see WHY it failed.
print_test_section "SPEC-6: pr-open surfaces push stderr in pr-result.json"
# shellcheck source=../../plugins/tool/pr-open/plugin.sh
source "$REPO_ROOT/plugins/tool/pr-open/plugin.sh"
_sf6="$TEST_TEMP_DIR/run-s6/pipeline-state.json"
mkdir -p "$TEST_TEMP_DIR/run-s6/artifacts"
printf '{"schema_version":1,"verdict":"approve","issues":[],"summary":"t"}\n' \
    > "$TEST_TEMP_DIR/run-s6/artifacts/review.json"
printf '{"issue":756,"branch":"zbuild/issue-756"}\n' > "$_sf6"
_art6="$TEST_TEMP_DIR/run-s6/artifacts"
_mockbin6="$TEST_TEMP_DIR/bin-s6"; mkdir -p "$_mockbin6"
cat > "$_mockbin6/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--abbrev-ref" ]]; then echo "zbuild/issue-756"
        else echo "newsha"; fi ;;
    ls-remote)    echo "divsha refs/heads/zbuild/issue-756" ;;   # present + divergent
    merge-base)   exit 1 ;;                                       # not ancestor ⇒ diverged
    cat-file)     exit 0 ;;
    symbolic-ref) echo "origin/main" ;;                          # default != target
    fetch|config) exit 0 ;;
    push)         echo "non-fast-forward-XYZ rejected" >&2; exit 1 ;;
    *)            echo ""; exit 0 ;;
esac
exit 0
MOCK
cat > "$_mockbin6/gh" <<'MOCK'
#!/usr/bin/env bash
echo "https://github.com/mock/repo/pull/756"; exit 0
MOCK
chmod +x "$_mockbin6/git" "$_mockbin6/gh"
( PATH="$_mockbin6:$PATH" pr_open_run "pr" "$_sf6" ) >/dev/null 2>&1; _rc6=$?
assert_eq "[SPEC-6] pr_open_run returns 1 on genuine push failure (#1849: v2 rc ∈ {0,1})" "1" "$_rc6"
if [[ -f "$_art6/pr-result.json" ]]; then
    assert_contains "[SPEC-6] pr-result.json .reason surfaces the real push stderr" \
        "$(jq -r '.reason // ""' "$_art6/pr-result.json" 2>/dev/null)" "non-fast-forward-XYZ"
else
    assert_fail "[SPEC-6] pr-result.json written on push failure" "file missing"
fi

# ─── #1844/SPEC-8: pr-open returns verdict=blocked → rc=1, error/complete/review_signal_missing
# Uses the real pr-delivery plugin with a fake pr-open that writes verdict=blocked.
print_test_section "#1844/SPEC-8: pr-open blocked verdict → pr-delivery rc=1/error/complete/review_signal_missing"
_fake8="$TEST_TEMP_DIR/fake-pr-open-s8"
mkdir -p "$_fake8/plugins/tool/pr-open"
cat > "$_fake8/plugins/tool/pr-open/plugin.sh" <<'PROMOCK'
pr_open_run() {
    local d; d="$(dirname "$2")/artifacts"
    mkdir -p "$d"
    jq -n '{result_contract:2,verdict:"blocked",disposition:"complete",reason:"review_signal_missing"}' \
        > "$d/pr-result.json"
    return 0
}
PROMOCK
_sf8="$(_setup_run approve s8)"
_art8="$(dirname "$_sf8")/artifacts"
_si8="$TEST_TEMP_DIR/si-s8.json"
printf '{"inputs":{}}\n' > "$_si8"
( _PR_ROOT="$_fake8" _TPL_MERGE_POLICY=manual ZBUILD_DRY_RUN=0 \
    ZBUILD_STAGE_INPUTS="$_si8" _pr_stage_run_inner "$_sf8" ) >/dev/null 2>&1; _rc8=$?
assert_eq "[#1844/SPEC-8] pr-open blocked → rc=1" "1" "$_rc8"
if [[ -f "$_art8/pr-result.json" ]]; then
    assert_eq "[#1844/SPEC-8] pr-result.json result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_art8/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-8] a refusal is verdict fail (Eric 2026-10-03)" "fail" \
        "$(jq -r '.verdict // empty' "$_art8/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-8] pr-result.json disposition is complete" "complete" \
        "$(jq -r '.disposition // empty' "$_art8/pr-result.json" 2>/dev/null || true)"
    _s8_reason="$(jq -r '.reason // empty' "$_art8/pr-result.json" 2>/dev/null || true)"
    if grep -q 'review_signal_missing' <<< "$_s8_reason"; then
        assert_pass "[#1844/SPEC-8] pr-result.json reason contains review_signal_missing"
    else
        assert_fail "[#1844/SPEC-8] pr-result.json reason contains review_signal_missing" \
            "got: $_s8_reason"
    fi
else
    assert_fail "[#1844/SPEC-8] pr-result.json written on pr-open blocked" "file absent"
fi

# ─── #1844/SPEC-10: fallback gh-pr-create failure → rc=1, error/unavailable ──
# No pr-open plugin in fake root → direct gh fallback; gh fails → unavailable.
print_test_section "#1844/SPEC-10: fallback gh-pr-create failure → rc=1/error/unavailable"
_fake10="$TEST_TEMP_DIR/fake-pr-open-s10"
mkdir -p "$_fake10/plugins/tool"
_bin10="$TEST_TEMP_DIR/bin-s10"
mkdir -p "$_bin10"
cat > "$_bin10/gh" <<'GHMOCK'
#!/usr/bin/env bash
[[ "${1:-} ${2:-}" == "pr create" ]] && { echo "gh failed" >&2; exit 1; }
exit 0
GHMOCK
cat > "$_bin10/git" <<'GITMOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "zbuild/issue-756"; exit 0 ;;
    *) exit 0 ;;
esac
GITMOCK
chmod +x "$_bin10/gh" "$_bin10/git"
_sf10="$(_setup_run approve s10)"
_art10="$(dirname "$_sf10")/artifacts"
_si10="$TEST_TEMP_DIR/si-s10.json"
printf '{"inputs":{}}\n' > "$_si10"
( _PR_ROOT="$_fake10" _TPL_MERGE_POLICY=manual ZBUILD_DRY_RUN=0 \
    ZBUILD_STAGE_INPUTS="$_si10" PATH="$_bin10:$PATH" \
    _pr_stage_run_inner "$_sf10" ) >/dev/null 2>&1; _rc10=$?
assert_eq "[#1844/SPEC-10] fallback gh failure → rc=1" "1" "$_rc10"
if [[ -f "$_art10/pr-result.json" ]]; then
    assert_eq "[#1844/SPEC-10] pr-result.json result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_art10/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-10] pr-result.json verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_art10/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-10] pr-result.json disposition is unavailable" "unavailable" \
        "$(jq -r '.disposition // empty' "$_art10/pr-result.json" 2>/dev/null || true)"
else
    assert_fail "[#1844/SPEC-10] pr-result.json written on fallback gh failure" "file absent"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
