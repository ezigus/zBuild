#!/usr/bin/env bash
# tests/unit/pr-open-v2-inputs-test.sh
# pr-open reads its declared inputs from the engine's index only (issue #1849).
# Split from pr-open-v2-result-test.sh to keep both files under the 500-line
# guideline; the result-shape SPECs stay there.
# SPEC coverage:
#   [SPEC-14] reads review_report ONLY via ZBUILD_STAGE_INPUTS; plugin.sh constructs no
#             review-report.json / plan.json / test-results.json path (#1849 acceptance)
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

# _make_pr_state <dir> [review_verdict]
# Sets up a state dir. review_verdict is written to review.json when given.
_make_pr_state() {
    local d="$1" review_verdict="${2:-}"
    mkdir -p "$d/artifacts"
    printf '{"issue":1849,"branch":"zbuild/issue-1849-test"}\n' > "$d/pipeline-state.json"
    [[ -n "$review_verdict" ]] && \
        printf '{"schema_version":1,"verdict":"%s","summary":"ok"}\n' "$review_verdict" \
            > "$d/artifacts/review.json"
    printf '%s/pipeline-state.json' "$d"
}

# Git/gh stub functions shared across tests.

# ─── SPEC-14: review_report path resolved via ZBUILD_STAGE_INPUTS with artifacts_dir fallback
print_test_section "SPEC-14: review_report resolved via ZBUILD_STAGE_INPUTS with artifacts_dir fallback"

# SPEC-14a: ZBUILD_STAGE_INPUTS maps review_report to a custom path.
# Custom review-report.json has 2 findings; standard artifacts_dir has NONE.
# If the plugin honors ZBUILD_STAGE_INPUTS, the PR body shows "2 finding(s)".
# If it reads only the hardcoded artifacts_dir path, it shows "no advisory review ran".
_s14a_dir="$TEST_TEMP_DIR/spec14a"
_make_pr_state "$_s14a_dir" "approve" >/dev/null
_s14a_art="$_s14a_dir/artifacts"
# Intentionally: no review-report.json in artifacts_dir

_s14a_custom="$TEST_TEMP_DIR/custom-review-report.json"
cat > "$_s14a_custom" <<'JSON'
{"schema_version":1,"merge_readiness":"advisory","lenses":[{"name":"security"}],
 "findings":[
   {"severity":"high","file":"foo.sh","line":1,"lenses":["security"],"messages":["finding A"]},
   {"severity":"medium","file":"bar.sh","line":2,"lenses":["security"],"messages":["finding B"]}
 ]}
JSON

_s14a_si="$TEST_TEMP_DIR/spec14a-si.json"
printf '{"inputs":{"review_report":"%s"}}\n' "$_s14a_custom" > "$_s14a_si"

_s14a_body="$TEST_TEMP_DIR/spec14a-body.txt"
mkdir -p "$TEST_TEMP_DIR/bin14a"
cat > "$TEST_TEMP_DIR/bin14a/git" <<'GITMOCK'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "rev-parse --abbrev-ref" ]]; then echo "zbuild/issue-1849-test"
else exit 0; fi
GITMOCK
cat > "$TEST_TEMP_DIR/bin14a/gh" <<GHMOCK
#!/usr/bin/env bash
next=0
for arg in "\$@"; do
    [[ \$next -eq 1 ]] && { printf '%s' "\$arg" > "${_s14a_body}"; next=0; }
    [[ "\$arg" == "--body" ]] && next=1
done
case "\${1:-} \${2:-}" in
    "pr list") echo "" ;;
    *) echo "https://github.com/mock/repo/pull/1849" ;;
esac
exit 0
GHMOCK
chmod +x "$TEST_TEMP_DIR/bin14a/git" "$TEST_TEMP_DIR/bin14a/gh"

mkdir -p "$TEST_TEMP_DIR/repo14a"
( PATH="$TEST_TEMP_DIR/bin14a:$PATH" \
  ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo14a" \
  ZBUILD_STAGE_INPUTS="$_s14a_si" \
  pr_open_run "pr" "$_s14a_dir/pipeline-state.json" ) >/dev/null 2>&1; _s14a_rc=$?

if [[ -f "$_s14a_body" ]]; then
    _s14a_body_text="$(cat "$_s14a_body")"
    # If ZBUILD_STAGE_INPUTS was honored the custom 2-finding report was read;
    # the advisory section shows the finding count, not "no advisory review ran".
    if grep -q "2 finding" <<< "$_s14a_body_text" 2>/dev/null; then
        assert_pass "[SPEC-14] ZBUILD_STAGE_INPUTS: custom review_report path honoured (finding count present)"
    else
        assert_fail "[SPEC-14] ZBUILD_STAGE_INPUTS: custom review_report path honoured (finding count present)" \
            "body does not show '2 finding' — ZBUILD_STAGE_INPUTS not read for review_report"
    fi
    if grep -q "no advisory review ran" <<< "$_s14a_body_text" 2>/dev/null; then
        assert_fail "[SPEC-14] ZBUILD_STAGE_INPUTS: body must not say 'no advisory review ran'" \
            "body says 'no advisory review ran' — hardcoded path used instead of ZBUILD_STAGE_INPUTS"
    else
        assert_pass "[SPEC-14] ZBUILD_STAGE_INPUTS: body does not fall back to 'no advisory review ran'"
    fi
else
    assert_fail "[SPEC-14] ZBUILD_STAGE_INPUTS: PR body was captured from gh call" "BODY_FILE not written"
fi

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
printf '{"schema_version":1,"goal":"ON-DISK GOAL"}\n' > "$_s14b_art/plan.json"
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
assert_eq "[SPEC-14] no index entry: a review-report.json on disk is not read" "0" "$(grep -c "1 finding" <<< "$_s14b_body_text" || true)"
assert_eq "[SPEC-14] no index entry: a plan.json on disk is not read" "0" "$(grep -c "ON-DISK GOAL" <<< "$_s14b_body_text" || true)"
assert_contains "[SPEC-14] …and the PR was still opened (body captured)" "$_s14b_body_text" "Closes #1849"
_pr_code="$(grep -v '^[[:space:]]*#' "$REPO_ROOT/plugins/tool/pr-open/plugin.sh")"
for _f in review-report.json plan.json test-results.json; do
    assert_eq "[SPEC-14] plugin.sh constructs no $_f path" "0" "$(grep -cF "$_f" <<< "$_pr_code" || true)"
done

# ─── SPEC-31: plan goal and test verdict come from the index ──────────────────
print_test_section "SPEC-31: the PR body's plan goal and test verdict are read from declared inputs"
_s31_dir="$TEST_TEMP_DIR/spec31"
_make_pr_state "$_s31_dir" "approve" >/dev/null
mkdir -p "$TEST_TEMP_DIR/elsewhere31"
printf '{"schema_version":1,"goal":"INDEXED GOAL"}\n' > "$TEST_TEMP_DIR/elsewhere31/plan.json"
printf '{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"ok"}\n' > "$TEST_TEMP_DIR/elsewhere31/test-results.json"
printf '{"inputs":{"plan":"%s","test_results":"%s"}}\n' \
    "$TEST_TEMP_DIR/elsewhere31/plan.json" "$TEST_TEMP_DIR/elsewhere31/test-results.json" > "$_s31_dir/stage-inputs.json"
_s14b_body="$TEST_TEMP_DIR/spec31-body.txt"
sed -i.bak "s|spec14b-body.txt|spec31-body.txt|" "$TEST_TEMP_DIR/bin14b/gh"
( PATH="$TEST_TEMP_DIR/bin14b:$PATH" \
  ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo14b" \
  ZBUILD_STAGE_INPUTS="$_s31_dir/stage-inputs.json" \
  pr_open_run "pr" "$_s31_dir/pipeline-state.json" ) >/dev/null 2>&1
_s31_body_text="$(cat "$TEST_TEMP_DIR/spec31-body.txt" 2>/dev/null || true)"
assert_contains "[SPEC-31] plan goal comes from the index's plan" "$_s31_body_text" "INDEXED GOAL"
assert_contains "[SPEC-31] test verdict comes from the index's test_results" "$_s31_body_text" "**Test verdict:** pass"


# ─── Teardown ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
