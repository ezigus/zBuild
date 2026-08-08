#!/usr/bin/env bash
# Tests: pr-open advisory review-report rendering in PR body (#1707)
# Covers: _pr_open_render_advisory_section + body assembly in advisory mode.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "pr-open: advisory review-report body rendering (#1707)"

setup_test_env "pr-open-advisory-review"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# ─── State and artifact setup ─────────────────────────────────────────────────
STATE_DIR="$TEST_TEMP_DIR/state"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
STATE_FILE="$STATE_DIR/pipeline-state.json"
REVIEW_JSON="$ARTIFACTS_DIR/review.json"
REVIEW_REPORT_JSON="$ARTIFACTS_DIR/review-report.json"
PR_RESULT_JSON="$ARTIFACTS_DIR/pr-result.json"
BODY_FILE="$TEST_TEMP_DIR/captured-body.txt"
export BODY_FILE  # must be exported so gh() sees it in subshells

mkdir -p "$ARTIFACTS_DIR"
printf '{"schema_version":1,"run_id":"test-run","issue":"999","stage_statuses":{}}\n' \
    > "$STATE_FILE"

# ─── Source plugin under test ─────────────────────────────────────────────────
PLUGIN_DIR="$REPO_ROOT/plugins/tool/pr-open"
# shellcheck source=../../plugins/tool/pr-open/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# Stubs must be exported: _pr_open_run_inner reaches git/gh from subshells.
_stub_git_gh() {
    git() {
        if [[ "${1:-} ${2:-}" == "rev-parse --abbrev-ref" ]]; then
            echo "zbuild/issue-999"
        else
            return 0
        fi
    }
    gh() {
        local capture_next=0 arg
        for arg in "$@"; do
            if [[ $capture_next -eq 1 ]]; then
                printf '%s' "$arg" > "$BODY_FILE"
                capture_next=0
            fi
            [[ "$arg" == "--body" ]] && capture_next=1
        done
        case "${1:-} ${2:-}" in
            "pr list") echo "" ;;
            *) echo "https://github.com/ezigus/zBuild/pull/999" ;;
        esac
        return 0
    }
    export -f git gh
}

# Runs pr-open against the current fixtures and echoes the captured body.
# Sets RUN_RC; leaves BODY_FILE on disk for the caller to assert against.
_run_pr_open() {
    _stub_git_gh
    set +e
    _pr_open_run_inner "$REVIEW_JSON" "$STATE_FILE" "$PR_RESULT_JSON" "999"
    RUN_RC=$?
    set -e
    unset -f git gh
}

_reset_fixtures() {
    rm -f "$PR_RESULT_JSON" "$REVIEW_JSON" "$REVIEW_REPORT_JSON" "$BODY_FILE"
}

# ─── SPEC-1: advisory mode with findings → count + top bullets + no N/A ─────
print_test_section "SPEC-1: review-report.json with findings → body has count, top findings, no verdict N/A"

_reset_fixtures
cat > "$REVIEW_REPORT_JSON" <<'JSON'
{
    "schema_version": 1,
    "merge_readiness": "advisory",
    "lenses": [{"name": "security", "score": 6, "findings": []}],
    "findings": [
        {
            "severity": "high",
            "file": "foo.sh",
            "line": 42,
            "lenses": ["security"],
            "messages": ["potential injection via unquoted expansion"]
        },
        {
            "severity": "medium",
            "file": "bar.sh",
            "lenses": ["correctness"],
            "messages": ["missing error check"]
        }
    ]
}
JSON

_run_pr_open
assert_exit_code "[SPEC-1] advisory mode with findings: rc=0" "0" "$RUN_RC"

if [[ -f "$BODY_FILE" ]]; then
    spec1_body="$(cat "$BODY_FILE")"
    assert_contains "[SPEC-1] body contains finding count" \
        "$spec1_body" "2 finding(s)"
    assert_contains "[SPEC-1] body contains severity indicator" \
        "$spec1_body" "[high]"
    assert_contains "[SPEC-1] body contains lens name" \
        "$spec1_body" "security"
    # The point of #1707: a human must be able to read WHAT was found, so the
    # bullet carries file:line and the finding text, not just a file path.
    assert_contains "[SPEC-1] body contains file:line locator" \
        "$spec1_body" "foo.sh:42"
    assert_contains "[SPEC-1] body contains the finding message" \
        "$spec1_body" "potential injection via unquoted expansion"
    if grep -qF '**Review verdict:** N/A' <<< "$spec1_body" 2>/dev/null; then
        assert_fail "[SPEC-1] advisory mode: no misleading 'Review verdict: N/A'" \
            "body still contains 'Review verdict: N/A'"
    else
        assert_pass "[SPEC-1] advisory mode: no misleading 'Review verdict: N/A'"
    fi
else
    assert_fail "[SPEC-1] body captured from gh call" "BODY_FILE not written"
fi

# ─── SPEC-2: review.json present, no review-report.json → "no advisory review ran" ─
print_test_section "SPEC-2: review.json present, review-report.json absent → 'no advisory review ran' in body"

_reset_fixtures
cat > "$REVIEW_JSON" <<'JSON'
{"schema_version":1,"verdict":"approve","summary":"looks good"}
JSON

_run_pr_open
assert_exit_code "[SPEC-2] review.json present, no report: rc=0" "0" "$RUN_RC"

if [[ -f "$BODY_FILE" ]]; then
    spec2_body="$(cat "$BODY_FILE")"
    assert_contains "[SPEC-2] body contains 'no advisory review ran'" \
        "$spec2_body" "no advisory review ran"
else
    assert_fail "[SPEC-2] body captured from gh call" "BODY_FILE not written"
fi

# ─── SPEC-3: advisory mode, findings=[] → "no findings" in body ──────────────
print_test_section "SPEC-3: review-report.json with findings=[] → 'no findings' in body"

_reset_fixtures
cat > "$REVIEW_REPORT_JSON" <<'JSON'
{"schema_version":1,"merge_readiness":"advisory","lenses":[],"findings":[]}
JSON

_run_pr_open
assert_exit_code "[SPEC-3] advisory mode, no findings: rc=0" "0" "$RUN_RC"

if [[ -f "$BODY_FILE" ]]; then
    spec3_body="$(cat "$BODY_FILE")"
    assert_contains "[SPEC-3] body contains 'no findings'" \
        "$spec3_body" "no findings"
else
    assert_fail "[SPEC-3] body captured from gh call" "BODY_FILE not written"
fi

# ─── SPEC-4: blocking-review mode — verdict preserved, not replaced by advisory ─
print_test_section "SPEC-4: review.json present with advisory report → body keeps blocking verdict"

_reset_fixtures
cat > "$REVIEW_JSON" <<'JSON'
{"schema_version":1,"verdict":"approve","summary":"looks good"}
JSON
cat > "$REVIEW_REPORT_JSON" <<'JSON'
{
    "schema_version": 1,
    "merge_readiness": "advisory",
    "lenses": [{"name": "security", "score": 3, "findings": []}],
    "findings": [
        {
            "severity": "high",
            "file": "plugin.sh",
            "lenses": ["security"],
            "messages": ["high severity advisory finding"]
        }
    ]
}
JSON

_run_pr_open
assert_exit_code "[SPEC-4] blocking-review mode with advisory report: rc=0" "0" "$RUN_RC"

if [[ -f "$BODY_FILE" ]]; then
    spec4_body="$(cat "$BODY_FILE")"
    assert_contains "[SPEC-4] body still contains blocking verdict line when review.json present" \
        "$spec4_body" "Review verdict:"
    # ADR-040 §4: a high-severity advisory finding must not block the PR.
    assert_json_key "[SPEC-4] PR still opened despite a high advisory finding" \
        "$(cat "$PR_RESULT_JSON")" ".status" "opened"
else
    assert_fail "[SPEC-4] body captured from gh call" "BODY_FILE not written"
fi

# ─── SPEC-5: unparseable report → says so, never "no findings" ───────────────
print_test_section "SPEC-5: unreadable review-report.json → explicit 'could not be read', not 'no findings'"

_reset_fixtures
# Truncated mid-object: jq cannot parse it.
printf '%s\n' '{"findings": [ {"severity":"high"' > "$REVIEW_REPORT_JSON"

_run_pr_open
assert_exit_code "[SPEC-5] unreadable report: rc=0" "0" "$RUN_RC"

if [[ -f "$BODY_FILE" ]]; then
    spec5_body="$(cat "$BODY_FILE")"
    assert_contains "[SPEC-5] body says the report could not be read" \
        "$spec5_body" "could not be read"
    # #1618 lesson: never imply a clean result that was not verified.
    if grep -qF 'no findings' <<< "$spec5_body" 2>/dev/null; then
        assert_fail "[SPEC-5] unreadable report never claims 'no findings'" \
            "body claims 'no findings' for a report it could not parse"
    else
        assert_pass "[SPEC-5] unreadable report never claims 'no findings'"
    fi
else
    assert_fail "[SPEC-5] body captured from gh call" "BODY_FILE not written"
fi

# ─── SPEC-6: finding text cannot inject markdown/HTML into the PR body ───────
print_test_section "SPEC-6: hostile finding text is escaped, not rendered as active markup"

_reset_fixtures
cat > "$REVIEW_REPORT_JSON" <<'JSON'
{
    "schema_version": 1,
    "merge_readiness": "advisory",
    "lenses": [{"name": "security"}],
    "findings": [
        {
            "severity": "high",
            "file": "[evil](http://attacker.example)",
            "line": 7,
            "lenses": ["security"],
            "messages": ["<img src=x onerror=alert(1)> and [link](http://bad)"]
        }
    ]
}
JSON

_run_pr_open
assert_exit_code "[SPEC-6] hostile finding text: rc=0" "0" "$RUN_RC"

if [[ -f "$BODY_FILE" ]]; then
    spec6_body="$(cat "$BODY_FILE")"
    # An escaped "\<img" still contains the substring "<img", so match only an
    # occurrence NOT preceded by a backslash — that is the one GitHub renders.
    if grep -qE '(^|[^\\])<img' <<< "$spec6_body" 2>/dev/null; then
        assert_fail "[SPEC-6] raw HTML tag from a finding is escaped" \
            "body contains an unescaped '<img' tag"
    else
        assert_pass "[SPEC-6] raw HTML tag from a finding is escaped"
    fi
    if grep -qE '(^|[^\\])\[evil\]\(' <<< "$spec6_body" 2>/dev/null; then
        assert_fail "[SPEC-6] markdown link from a finding is escaped" \
            "body contains an active markdown link"
    else
        assert_pass "[SPEC-6] markdown link from a finding is escaped"
    fi
    assert_contains "[SPEC-6] the HTML tag is present in escaped form" \
        "$spec6_body" '\<img'
    # Escaping must neutralise markup without deleting the text itself.
    assert_contains "[SPEC-6] finding text is still present after escaping" \
        "$spec6_body" "attacker.example"
else
    assert_fail "[SPEC-6] body captured from gh call" "BODY_FILE not written"
fi

# ─── SPEC-7: more than five findings → overflow moves to a <details> block ───
print_test_section "SPEC-7: >5 findings → top five inline, remainder in <details>"

_reset_fixtures
jq -n '{schema_version:1, merge_readiness:"advisory", lenses:[{name:"sre"}],
        findings: [ range(0;7) | {severity:"low", file:"f\(.).sh", line:.,
                                  lenses:["sre"], messages:["finding number \(.)"]} ]}' \
    > "$REVIEW_REPORT_JSON"

_run_pr_open
assert_exit_code "[SPEC-7] seven findings: rc=0" "0" "$RUN_RC"

if [[ -f "$BODY_FILE" ]]; then
    spec7_body="$(cat "$BODY_FILE")"
    assert_contains "[SPEC-7] body reports the full finding count" \
        "$spec7_body" "7 finding(s)"
    assert_contains "[SPEC-7] overflow is collapsed into a details block" \
        "$spec7_body" "<details><summary>2 more finding(s)</summary>"
    assert_contains "[SPEC-7] details block is closed" \
        "$spec7_body" "</details>"
    # GitHub keeps consuming an HTML block until a blank line, so without one
    # the next line renders as raw HTML instead of markdown. Matched with a
    # bash glob, not assert_contains: grep -F is line-based, so a multi-line
    # needle degrades into separate patterns (one of them empty, matching all).
    _nl=$'\n'
    if [[ "$spec7_body" == *"</details>${_nl}${_nl}**Test verdict:**"* ]]; then
        assert_pass "[SPEC-7] a blank line separates </details> from the next line"
    else
        assert_fail "[SPEC-7] a blank line separates </details> from the next line" \
            "no blank line after </details>; the next line would render as raw HTML"
    fi
else
    assert_fail "[SPEC-7] body captured from gh call" "BODY_FILE not written"
fi

# ─── Teardown ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
