#!/usr/bin/env bash
# Integration test: merge_policy auto dispatch (I9-B / #1050)
#
# SPEC coverage:
#   [SPEC-1] merge_policy==auto + gate verdict==pass → merge path: merge-result.json
#            status==merged, gh pr merge called (not a draft PR)
#   [SPEC-2] merge_policy==auto + gate verdict==fail → PR fallback: pr-url.txt
#            written, merge-result.json status==pr_fallback
#   [SPEC-3] merge_policy==auto + gate artifact absent → PR fallback: same as SPEC-2
#   [SPEC-4] merge_policy==auto_unless_flagged + review-report absent → PR (fail-closed):
#            pr-url.txt written, no merge-result.json (review-report absent → fail-closed)
#   [SPEC-5] merge_policy==auto + gate pass but review.json absent → fail-closed:
#            PR fallback (status==pr_fallback), gh pr merge NOT called (ADR-001/#358)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "merge_policy auto dispatch: auto-merge on clean gates (#1050)"
setup_test_env "merge-policy-auto"

_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_RUN_ID="merge-policy-auto-test-$$"
mkdir -p "$ZBUILD_EVENTS_DIR"
: > "$ZBUILD_EVENTS_JSONL"

_MERGE_RECORD="$TEST_TEMP_DIR/merge-calls.txt"

# Helper: build a state dir with review.json and optional gate-aggregator artifact.
# Usage: _setup_run <tag> [gate_verdict]
#   gate_verdict: omit = absent, "pass" or "fail"
_setup_run() {
    local tag="$1" gate_verdict="${2:-}"
    local d="$TEST_TEMP_DIR/run-${tag}"
    mkdir -p "$d/artifacts"
    # review.json required by pr_open_run's fail-closed guard (ADR-001, #358)
    printf '{"schema_version":1,"verdict":"approve","summary":"ok"}\n' \
        > "$d/artifacts/review.json"
    printf '{"issue":1050,"branch":"zbuild/issue-1050-test"}\n' \
        > "$d/pipeline-state.json"
    if [[ -n "$gate_verdict" ]]; then
        printf '{"schema_version":1,"verdict":"%s"}\n' "$gate_verdict" \
            > "$d/artifacts/gate-aggregator-result.json"
    fi
    printf '%s/pipeline-state.json' "$d"
}

# Install a git mock that always returns a feature branch (never main/master).
cat > "$TEST_TEMP_DIR/bin/git" <<'GITMOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--abbrev-ref" ]]; then echo "zbuild/issue-1050-test"
        elif [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        else echo "/tmp/mock-repo"
        fi ;;
    checkout) exit 0 ;;
    push)     exit 0 ;;
    config)   exit 0 ;;
    *)        exit 0 ;;
esac
GITMOCK
chmod +x "$TEST_TEMP_DIR/bin/git"

# Install a gh mock that records pr merge calls.
cat > "$TEST_TEMP_DIR/bin/gh" <<GHMOCK
#!/usr/bin/env bash
case "\${1:-}" in
    pr)
        case "\${2:-}" in
            create) echo "https://github.com/mock/repo/pull/1050" ;;
            merge)  printf 'merged\n' >> "${_MERGE_RECORD}"; exit 0 ;;
            *)      echo "https://github.com/mock/repo/pull/1050" ;;
        esac ;;
    *) exit 0 ;;
esac
GHMOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

# Source the real pr-delivery plugin (which will delegate to merge plugin).
# shellcheck source=../../plugins/agent/pr-delivery/plugin.sh
source "$REPO_ROOT/plugins/agent/pr-delivery/plugin.sh"

# ─── SPEC-1: auto + gate pass → merge path ────────────────────────────────────
print_test_section "SPEC-1: merge_policy==auto + gate verdict==pass → merged"

_sf1="$(_setup_run s1 pass)"
_art1="$(dirname "$_sf1")/artifacts"
> "$_MERGE_RECORD"

export _TPL_MERGE_POLICY="auto"
( pr_stage_run "pr" "$_sf1" ) >/dev/null 2>&1; _rc1=$?

assert_eq "[SPEC-1] pr_stage_run exits 0 on merge path" "0" "$_rc1"
assert_file_exists "[SPEC-1] merge-result.json written on merge path" \
    "$_art1/merge-result.json"
_merge_status1="$(jq -r '.status // empty' "$_art1/merge-result.json" 2>/dev/null || true)"
assert_eq "[SPEC-1] merge-result.json status==merged" "merged" "$_merge_status1"
_merge_calls1="$(cat "$_MERGE_RECORD" 2>/dev/null || true)"
_merge_called=0
[[ "$_merge_calls1" == *"merged"* ]] && _merge_called=1
assert_eq "[SPEC-1] gh pr merge --squash called on gate-pass path" "1" "$_merge_called"
# pr-delivery's manifest declares pr-result.json a REQUIRED output on every pr-stage
# path (#1064 review) — the merge path must write it, not only merge-result.json.
assert_file_exists "[SPEC-1] pr-result.json written on merge path (manifest output)" \
    "$_art1/pr-result.json"
_pr_result_status1="$(jq -r '.status // empty' "$_art1/pr-result.json" 2>/dev/null || true)"
assert_eq "[SPEC-1] pr-result.json status==merged" "merged" "$_pr_result_status1"

# ─── SPEC-2: auto + gate verdict==fail → PR fallback ─────────────────────────
print_test_section "SPEC-2: merge_policy==auto + gate verdict==fail → PR fallback"

_sf2="$(_setup_run s2 fail)"
_art2="$(dirname "$_sf2")/artifacts"
> "$_MERGE_RECORD"

export _TPL_MERGE_POLICY="auto"
( pr_stage_run "pr" "$_sf2" ) >/dev/null 2>&1; _rc2=$?

assert_eq "[SPEC-2] pr_stage_run exits 0 on PR fallback (gate fail)" "0" "$_rc2"
assert_file_exists "[SPEC-2] pr-url.txt written on gate-fail fallback" "$_art2/pr-url.txt"
assert_file_exists "[SPEC-2] merge-result.json written on fallback" "$_art2/merge-result.json"
_merge_status2="$(jq -r '.status // empty' "$_art2/merge-result.json" 2>/dev/null || true)"
assert_eq "[SPEC-2] merge-result.json status==pr_fallback on gate fail" \
    "pr_fallback" "$_merge_status2"
_merge_calls2="$(cat "$_MERGE_RECORD" 2>/dev/null || true)"
_gh_merge2=0
[[ "$_merge_calls2" == *"merged"* ]] && _gh_merge2=1
assert_eq "[SPEC-2] gh pr merge NOT called on gate-fail fallback" "0" "$_gh_merge2"

# ─── SPEC-3: auto + gate artifact absent → PR fallback ───────────────────────
print_test_section "SPEC-3: merge_policy==auto + gate artifact absent → PR fallback"

_sf3="$(_setup_run s3)"  # no gate artifact
_art3="$(dirname "$_sf3")/artifacts"
> "$_MERGE_RECORD"

export _TPL_MERGE_POLICY="auto"
( pr_stage_run "pr" "$_sf3" ) >/dev/null 2>&1; _rc3=$?

assert_eq "[SPEC-3] pr_stage_run exits 0 on PR fallback (gate absent)" "0" "$_rc3"
assert_file_exists "[SPEC-3] pr-url.txt written on gate-absent fallback" "$_art3/pr-url.txt"
assert_file_exists "[SPEC-3] merge-result.json written on gate-absent fallback" \
    "$_art3/merge-result.json"
_merge_status3="$(jq -r '.status // empty' "$_art3/merge-result.json" 2>/dev/null || true)"
assert_eq "[SPEC-3] merge-result.json status==pr_fallback on gate absent" \
    "pr_fallback" "$_merge_status3"
_merge_calls3="$(cat "$_MERGE_RECORD" 2>/dev/null || true)"
_gh_merge3=0
[[ "$_merge_calls3" == *"merged"* ]] && _gh_merge3=1
assert_eq "[SPEC-3] gh pr merge NOT called when gate artifact absent" "0" "$_gh_merge3"

# ─── SPEC-8 (#1219): auto + gate verdict==route_design → PR fallback ──────────
# ADR-045: a design-rooted acceptance failure surfaces as gate-aggregator
# verdict==route_design (≠pass). The merge guard (verdict != pass → PR path) must
# treat it exactly like any non-pass verdict: NEVER auto-merge, fall back to a PR.
# This guards the invariant that a route_design in-flight (the bounded rewind is
# handled by the runner, not merge) can never ship to main.
print_test_section "SPEC-8: merge_policy==auto + gate verdict==route_design → PR fallback"

_sf8="$(_setup_run s8 route_design)"
_art8="$(dirname "$_sf8")/artifacts"
> "$_MERGE_RECORD"

export _TPL_MERGE_POLICY="auto"
( pr_stage_run "pr" "$_sf8" ) >/dev/null 2>&1; _rc8=$?

assert_eq "[SPEC-8] pr_stage_run exits 0 on route_design PR fallback" "0" "$_rc8"
assert_file_exists "[SPEC-8] pr-url.txt written on route_design fallback" "$_art8/pr-url.txt"
_merge_status8="$(jq -r '.status // empty' "$_art8/merge-result.json" 2>/dev/null || true)"
assert_eq "[SPEC-8] merge-result.json status==pr_fallback on route_design" \
    "pr_fallback" "$_merge_status8"
_merge_calls8="$(cat "$_MERGE_RECORD" 2>/dev/null || true)"
_gh_merge8=0
[[ "$_merge_calls8" == *"merged"* ]] && _gh_merge8=1
assert_eq "[SPEC-8] gh pr merge NOT called under route_design" "0" "$_gh_merge8"

# ─── SPEC-4: auto_unless_flagged + review-report absent → PR (fail-closed) ────
print_test_section "SPEC-4: merge_policy==auto_unless_flagged + review-report absent → opens draft PR (fail-closed)"

_sf4="$(_setup_run s4 pass)"  # no review-report.json → fail-closed, opens PR
_art4="$(dirname "$_sf4")/artifacts"
> "$_MERGE_RECORD"

export _TPL_MERGE_POLICY="auto_unless_flagged"
( pr_stage_run "pr" "$_sf4" ) >/dev/null 2>&1; _rc4=$?

assert_eq "[SPEC-4] pr_stage_run exits 0 for auto_unless_flagged" "0" "$_rc4"
assert_file_exists "[SPEC-4] pr-url.txt written (PR opened, not merged)" "$_art4/pr-url.txt"
assert_file_not_exists "[SPEC-4] no merge-result.json for auto_unless_flagged path" \
    "$_art4/merge-result.json"
_merge_calls4="$(cat "$_MERGE_RECORD" 2>/dev/null || true)"
_gh_merge4=0
[[ "$_merge_calls4" == *"merged"* ]] && _gh_merge4=1
assert_eq "[SPEC-4] gh pr merge NOT called for auto_unless_flagged" "0" "$_gh_merge4"

# ─── SPEC-5: auto + gate pass but review.json ABSENT → fail-closed PR fallback ─
# ADR-001/#358: pr-open refuses to publish without a review verdict on disk;
# merge_run must mirror that and NEVER auto-merge an unreviewed branch even on a
# clean objective gate (#1064 review).
print_test_section "SPEC-5: merge_policy==auto + gate pass + review.json absent → fail-closed (no merge)"

_sf5="$(_setup_run s5 pass)"
_art5="$(dirname "$_sf5")/artifacts"
rm -f "$_art5/review.json"   # no review verdict on disk
> "$_MERGE_RECORD"

export _TPL_MERGE_POLICY="auto"
_rc5=0
( pr_stage_run "pr" "$_sf5" ) >/dev/null 2>&1 || _rc5=$?

_merge_status5="$(jq -r '.status // empty' "$_art5/merge-result.json" 2>/dev/null || true)"
assert_eq "[SPEC-5] gate pass but review absent → status==pr_fallback (not merged)" \
    "pr_fallback" "$_merge_status5"
_merge_calls5="$(cat "$_MERGE_RECORD" 2>/dev/null || true)"
_gh_merge5=0
[[ "$_merge_calls5" == *"merged"* ]] && _gh_merge5=1
assert_eq "[SPEC-5] gh pr merge NOT called when review.json absent (fail-closed)" "0" "$_gh_merge5"

# ─── Results ──────────────────────────────────────────────────────────────────
print_test_results
