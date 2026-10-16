#!/usr/bin/env bash
# tests/unit/pr-open-v2-inputs-test.sh
# pr-open reads its declared inputs from the engine's index only (issue #1849).
# Split from pr-open-v2-result-test.sh to keep both files under the 500-line
# guideline; the result-shape SPECs stay there.
# SPEC coverage:
#   [SPEC-14] reads its inputs ONLY via ZBUILD_STAGE_INPUTS; plugin.sh constructs no
#             plan.json / test-results.json path (#1849; review_report retired, #2368)
#   [SPEC-31] the PR body's plan goal and test verdict are read from declared inputs
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "pr-open plugin: inputs from the engine's index (issue #1849)"
setup_test_env "pr-open-v2-inputs"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_RUN_ID="pr-open-v2-inputs-test-$$"
mkdir -p "$ZBUILD_EVENTS_DIR"
: > "$ZBUILD_EVENTS_JSONL"

# shellcheck source=../../plugins/tool/pr-open/plugin.sh
source "$REPO_ROOT/plugins/tool/pr-open/plugin.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"

# _make_pr_state <dir> [review_verdict]
# Sets up a state dir. With a review_verdict, a review ran (#2364: the engine
# says so with ZBUILD_RUN_FLAGGED, yes|no; nothing reads review.json); without
# one, none did.
_make_pr_state() {
    local d="$1" review_verdict="${2:-}"
    mkdir -p "$d/artifacts"
    printf '{"issue":1849,"branch":"zbuild/issue-1849-test"}\n' > "$d/pipeline-state.json"
    if [[ -n "$review_verdict" ]]; then export ZBUILD_RUN_FLAGGED=no
    else unset ZBUILD_RUN_FLAGGED; fi
    printf '%s/pipeline-state.json' "$d"
}

# Git/gh stub functions shared across tests.

# ─── SPEC-14: review_report path resolved via ZBUILD_STAGE_INPUTS with artifacts_dir fallback
print_test_section "SPEC-14: inputs come from ZBUILD_STAGE_INPUTS only"

# SPEC-14b: no index entry → no advisory report, even with one sitting in
# artifacts_dir. The engine exports ZBUILD_STAGE_INPUTS for every dispatched
# stage (lifecycle.sh), pr-delivery included, and this plugin runs inside it.
_s14b_dir="$TEST_TEMP_DIR/spec14b"
_make_pr_state "$_s14b_dir" "approve" >/dev/null
_s14b_art="$_s14b_dir/artifacts"
cat > "$_s14b_art/review-report.json" <<'JSON'
{"schema_version":1,"merge_readiness":"advisory","lenses":[{"name":"perf"}],
 "findings":[
   {"severity":"low","file":"baz.sh","line":5,"lenses":["perf"],"messages":["finding C"]}
 ]}
JSON
# A real work plan (it has its steps), so only the index keeps it out.
printf '{"schema_version":1,"goal":"ON-DISK GOAL","steps":[]}\n' > "$_s14b_art/plan.json"
printf '{"inputs":{}}\n' > "$_s14b_dir/stage-inputs.json"

_s14b_body="$TEST_TEMP_DIR/spec14b-body.txt"
mkdir -p "$TEST_TEMP_DIR/bin14b"
cat > "$TEST_TEMP_DIR/bin14b/git" <<'GITMOCK'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "rev-parse --abbrev-ref" ]]; then echo "zbuild/issue-1849-test"
else exit 0; fi
GITMOCK
cat > "$TEST_TEMP_DIR/bin14b/gh" <<GHMOCK
#!/usr/bin/env bash
next=0
for arg in "\$@"; do
    [[ \$next -eq 1 ]] && { printf '%s' "\$arg" > "${_s14b_body}"; next=0; }
    [[ "\$arg" == "--body" ]] && next=1
done
case "\${1:-} \${2:-}" in
    "pr list") echo "" ;;
    *) echo "https://github.com/mock/repo/pull/1849" ;;
esac
exit 0
GHMOCK
chmod +x "$TEST_TEMP_DIR/bin14b/git" "$TEST_TEMP_DIR/bin14b/gh"

mkdir -p "$TEST_TEMP_DIR/repo14b"
( PATH="$TEST_TEMP_DIR/bin14b:$PATH" \
  ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo14b" \
  ZBUILD_STAGE_INPUTS="$_s14b_dir/stage-inputs.json" \
  pr_open_run "pr" "$_s14b_dir/pipeline-state.json" ) >/dev/null 2>&1; _s14b_rc=$?
_s14b_body_text="$(cat "$_s14b_body" 2>/dev/null || true)"
assert_eq "[SPEC-14] no index entry: a plan.json on disk is not read" "0" "$(grep -c "ON-DISK GOAL" <<< "$_s14b_body_text" || true)"
assert_contains "[SPEC-14] …and the PR was still opened (body captured)" "$_s14b_body_text" "Closes #1849"
_pr_code="$(grep -v '^[[:space:]]*#' "$REPO_ROOT/plugins/tool/pr-open/plugin.sh")"
for _f in plan.json test-results.json; do
    assert_eq "[SPEC-14] plugin.sh constructs no $_f path" "0" "$(grep -cF "$_f" <<< "$_pr_code" || true)"
done

# ─── SPEC-31: plan goal and test verdict come from the index ──────────────────
print_test_section "SPEC-31: the PR body's plan goal and test verdict are read from declared inputs"
_s31_dir="$TEST_TEMP_DIR/spec31"
_make_pr_state "$_s31_dir" "approve" >/dev/null
mkdir -p "$TEST_TEMP_DIR/elsewhere31"
# #2364: a work plan (steps) and a test run (test's own writer), under any name.
printf '{"schema_version":1,"goal":"INDEXED GOAL","steps":[]}\n' > "$TEST_TEMP_DIR/elsewhere31/plan.json"
zb_test_test_run_output "$TEST_TEMP_DIR/elsewhere31" pass 1 0 >/dev/null
printf '{"inputs":{"a":"%s","b":"%s"}}\n' \
    "$TEST_TEMP_DIR/elsewhere31/plan.json" "$TEST_TEMP_DIR/elsewhere31/test-results.json" > "$_s31_dir/stage-inputs.json"
_s14b_body="$TEST_TEMP_DIR/spec31-body.txt"
sed -i.bak "s|spec14b-body.txt|spec31-body.txt|" "$TEST_TEMP_DIR/bin14b/gh"
( PATH="$TEST_TEMP_DIR/bin14b:$PATH" \
  ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo14b" \
  ZBUILD_STAGE_INPUTS="$_s31_dir/stage-inputs.json" \
  pr_open_run "pr" "$_s31_dir/pipeline-state.json" ) >/dev/null 2>&1
_s31_body_text="$(cat "$TEST_TEMP_DIR/spec31-body.txt" 2>/dev/null || true)"
assert_contains "[SPEC-31] plan goal comes from the work plan among the earlier outputs" "$_s31_body_text" "INDEXED GOAL"
assert_contains "[SPEC-31] test verdict comes from the test run among the earlier outputs" "$_s31_body_text" "**Tests:** pass"


# ─── Teardown ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
