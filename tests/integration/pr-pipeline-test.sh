#!/usr/bin/env bash
# Integration test: the REAL pr-delivery agent plugin (#756).
#
# Exercises plugins/agent/pr-delivery/plugin.sh directly (not a stub) across its
# lifecycle hooks, including the pr-open delegation path where the run's state
# file must be threaded through (the bug that made the pr stage fail at runtime).
#
# SPEC coverage (A3-pr migration, ADR-013 amendment pr kind:tool→agent):
#   [SPEC-1] standard.yaml has 14 leaf stages including pr (stage id "pr")
#   [SPEC-2] plugins/agent/pr-delivery/{plugin.sh,manifest.yaml} exist; id=pr-delivery
#   [SPEC-3] dry-run: real plugin writes pr-url.txt + pr-result.json, exits 0,
#            emits plugin.init.start plugin=pr-delivery
#   [SPEC-4] verdict=block guard: real plugin refuses (rc=1), no pr-url.txt
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

# ─── SPEC-1: standard.yaml resolves to 14 leaf stages, last is pr ────────────
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$REPO_ROOT/config/templates/standard.yaml"
assert_eq "[SPEC-1] standard.yaml resolves to 14 leaf stages including pr" \
    "14" "${#_TPL_STAGES[@]}"
assert_eq "[SPEC-1] _TPL_STAGES[13] stage id is pr" "pr" "${_TPL_STAGES[13]:-}"

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

# ─── SPEC-3: dry-run writes both artifacts, exits 0, emits plugin.init.start ──
print_test_section "SPEC-3: dry-run produces artifacts via the real plugin"
_sf3="$(_setup_run approve s3)"
: > "$ZBUILD_EVENTS_JSONL"
pr_stage_init >/dev/null 2>&1
( ZBUILD_DRY_RUN=1 pr_stage_run "pr" "$_sf3" ) >/dev/null 2>&1; _rc3=$?
_art3="$(dirname "$_sf3")/artifacts"
assert_eq "[SPEC-3] dry-run pr_stage_run exits 0" "0" "$_rc3"
assert_file_exists "[SPEC-3] pr-url.txt written" "$_art3/pr-url.txt"
assert_file_exists "[SPEC-3] pr-result.json written" "$_art3/pr-result.json"
if grep -q '"plugin.init.start"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null \
   && grep '"plugin.init.start"' "$ZBUILD_EVENTS_JSONL" | grep -q '"plugin":"pr-delivery"'; then
    assert_pass "[SPEC-3] plugin.init.start plugin=pr-delivery emitted"
else
    assert_fail "[SPEC-3] plugin.init.start plugin=pr-delivery emitted" \
        "$(grep 'plugin' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -3 || echo '(none)')"
fi

# ─── SPEC-4: verdict=block → the plugin refuses, no PR URL ───────────────────
print_test_section "SPEC-4: verdict=block guard refuses to open a PR"
_sf4="$(_setup_run block s4)"
_art4="$(dirname "$_sf4")/artifacts"
( ZBUILD_DRY_RUN=1 pr_stage_run "pr" "$_sf4" ) >/dev/null 2>&1; _rc4=$?
[[ $_rc4 -ne 0 ]] \
    && assert_pass "[SPEC-4] verdict=block → pr_stage_run returns non-zero" \
    || assert_fail "[SPEC-4] verdict=block → pr_stage_run returns non-zero" "got rc=0"
assert_file_not_exists "[SPEC-4] verdict=block → no pr-url.txt written" "$_art4/pr-url.txt"

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
( unset ZBUILD_STATE_FILE; PATH="$_mockbin:$PATH" ZBUILD_DRY_RUN=0 \
    pr_stage_run "pr" "$_sf5" ) >/dev/null 2>&1; _rc5=$?
assert_eq "[SPEC-5] non-dry-run pr_stage_run exits 0 (state file threaded to pr-open)" "0" "$_rc5"
assert_file_exists "[SPEC-5] pr-url.txt written by pr-open delegation" "$_art5/pr-url.txt"
if [[ -f "$_art5/pr-url.txt" ]]; then
    assert_contains "[SPEC-5] pr-url.txt holds the gh-created URL" \
        "$(cat "$_art5/pr-url.txt")" "github.com/mock/repo/pull/756"
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
assert_eq "[SPEC-6] pr_open_run returns 2 on genuine push failure" "2" "$_rc6"
if [[ -f "$_art6/pr-result.json" ]]; then
    assert_contains "[SPEC-6] pr-result.json .reason surfaces the real push stderr" \
        "$(jq -r '.reason // ""' "$_art6/pr-result.json" 2>/dev/null)" "non-fast-forward-XYZ"
else
    assert_fail "[SPEC-6] pr-result.json written on push failure" "file missing"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
