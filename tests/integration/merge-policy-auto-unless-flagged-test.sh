#!/usr/bin/env bash
# Integration test: merge_policy auto_unless_flagged dispatch (I9-C / #1051)
#
# SPEC coverage:
#   [SPEC-1] auto_unless_flagged + gate pass + merge_readiness=ready
#            → auto-merge: merge-result.json status=merged, gh pr merge called (CHANGE)
#   [SPEC-2] auto_unless_flagged + gate pass + merge_readiness=needs_attention
#            → PR open: pr-url.txt written, gh pr merge NOT called (GUARD)
#   [SPEC-3] auto_unless_flagged + gate artifact absent + merge_readiness=ready
#            → PR open: pr-url.txt written, gh pr merge NOT called (GUARD)
#   [SPEC-4] auto_unless_flagged + gate pass + review-report absent (fail-closed)
#            → PR open: pr-url.txt written, gh pr merge NOT called (GUARD)
#   [SPEC-5] auto_unless_flagged + gate pass + merge_readiness=advisory
#            → auto-merge: merge-result.json status=merged, gh pr merge called (CHANGE)
#   [SPEC-6] auto_unless_flagged + gate verdict=fail + merge_readiness=ready
#            → PR open: pr-url.txt written, gh pr merge NOT called (GUARD)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "merge_policy auto_unless_flagged: escalation on review-report (#1051)"
setup_test_env "merge-policy-auto-unless-flagged"

_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_RUN_ID="merge-policy-auto-unless-flagged-test-$$"
mkdir -p "$ZBUILD_EVENTS_DIR"
: > "$ZBUILD_EVENTS_JSONL"

_MERGE_RECORD="$TEST_TEMP_DIR/merge-calls.txt"

# Helper: build a state dir with optional gate artifact and review-report.json.
# Usage: _setup_run <tag> [gate_verdict] [report_readiness]
#   gate_verdict:    omit = absent, "pass" or "fail"
#   report_readiness: omit = absent, "ready", "advisory", "needs_attention"
_setup_run() {
    local tag="$1" gate_verdict="${2:-}" report_readiness="${3:-}"
    local d="$TEST_TEMP_DIR/run-${tag}"
    mkdir -p "$d/artifacts"
    # review.json required by pr_open_run and merge_run fail-closed guards (ADR-001/#358)
    printf '{"schema_version":1,"verdict":"approve","summary":"ok"}\n' \
        > "$d/artifacts/review.json"
    printf '{"issue":1051,"branch":"zbuild/issue-1051-test"}\n' \
        > "$d/pipeline-state.json"
    if [[ -n "$gate_verdict" ]]; then
        printf '{"schema_version":1,"verdict":"%s"}\n' "$gate_verdict" \
            > "$d/artifacts/gate-aggregator-result.json"
    fi
    if [[ -n "$report_readiness" ]]; then
        printf '{"schema_version":1,"merge_readiness":"%s","findings":[]}\n' "$report_readiness" \
            > "$d/artifacts/review-report.json"
    fi
    printf '%s/pipeline-state.json' "$d"
}

# Install git mock: always returns a feature branch (never main/master).
cat > "$TEST_TEMP_DIR/bin/git" <<'GITMOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--abbrev-ref" ]]; then echo "zbuild/issue-1051-test"
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

# Install gh mock that records pr merge calls and returns a PR URL on create.
cat > "$TEST_TEMP_DIR/bin/gh" <<GHMOCK
#!/usr/bin/env bash
case "\${1:-}" in
    pr)
        case "\${2:-}" in
            create) echo "https://github.com/mock/repo/pull/1051" ;;
            merge)  printf 'merged\n' >> "${_MERGE_RECORD}"; exit 0 ;;
            *)      echo "https://github.com/mock/repo/pull/1051" ;;
        esac ;;
    *) exit 0 ;;
esac
GHMOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

# Source the real pr-delivery plugin (which will delegate to merge plugin when needed).
# shellcheck source=../../plugins/agent/pr-delivery/plugin.sh
source "$REPO_ROOT/plugins/agent/pr-delivery/plugin.sh"

# ─── SPEC-1: gate pass + merge_readiness=ready → auto-merge ──────────────────
print_test_section "SPEC-1: auto_unless_flagged + gate pass + merge_readiness=ready → merged"

_sf1="$(_setup_run s1 pass ready)"
_art1="$(dirname "$_sf1")/artifacts"
> "$_MERGE_RECORD"

export _TPL_MERGE_POLICY="auto_unless_flagged"
( pr_stage_run "pr" "$_sf1" ) >/dev/null 2>&1; _rc1=$?

assert_eq "[SPEC-1] pr_stage_run exits 0 on auto-merge path (ready)" "0" "$_rc1"
assert_file_exists "[SPEC-1] merge-result.json written when gate+report both pass" \
    "$_art1/merge-result.json"
_merge_status1="$(jq -r '.status // empty' "$_art1/merge-result.json" 2>/dev/null || true)"
assert_eq "[SPEC-1] merge-result.json status==merged (gate pass + ready)" "merged" "$_merge_status1"
_merge_calls1="$(cat "$_MERGE_RECORD" 2>/dev/null || true)"
_merge_called1=0
[[ "$_merge_calls1" == *"merged"* ]] && _merge_called1=1
assert_eq "[SPEC-1] gh pr merge called when gate pass + merge_readiness=ready" "1" "$_merge_called1"

# ─── SPEC-2: gate pass + needs_attention → PR open ───────────────────────────
print_test_section "SPEC-2: auto_unless_flagged + gate pass + needs_attention → PR open"

_sf2="$(_setup_run s2 pass needs_attention)"
# Seed a critical finding to represent the review-report that blocked auto-merge
printf '{"schema_version":1,"merge_readiness":"needs_attention","findings":[{"severity":"critical","title":"Hardcoded secret detected"}]}\n' \
    > "$(dirname "$_sf2")/artifacts/review-report.json"
_art2="$(dirname "$_sf2")/artifacts"
> "$_MERGE_RECORD"

export _TPL_MERGE_POLICY="auto_unless_flagged"
( pr_stage_run "pr" "$_sf2" ) >/dev/null 2>&1; _rc2=$?

assert_eq "[SPEC-2] pr_stage_run exits 0 on PR-open path (needs_attention)" "0" "$_rc2"
assert_file_exists "[SPEC-2] pr-url.txt written (PR opened, not merged)" "$_art2/pr-url.txt"
assert_file_not_exists "[SPEC-2] no merge-result.json when needs_attention (pr-open path)" \
    "$_art2/merge-result.json"
_merge_calls2="$(cat "$_MERGE_RECORD" 2>/dev/null || true)"
_gh_merge2=0
[[ "$_merge_calls2" == *"merged"* ]] && _gh_merge2=1
assert_eq "[SPEC-2] gh pr merge NOT called when needs_attention" "0" "$_gh_merge2"

# ─── SPEC-3: gate artifact absent → PR open ──────────────────────────────────
print_test_section "SPEC-3: auto_unless_flagged + gate artifact absent → PR open"

_sf3="$(_setup_run s3 "" ready)"  # gate absent, report=ready
_art3="$(dirname "$_sf3")/artifacts"
> "$_MERGE_RECORD"

export _TPL_MERGE_POLICY="auto_unless_flagged"
( pr_stage_run "pr" "$_sf3" ) >/dev/null 2>&1; _rc3=$?

assert_eq "[SPEC-3] pr_stage_run exits 0 when gate absent" "0" "$_rc3"
assert_file_exists "[SPEC-3] pr-url.txt written (PR opened, gate absent)" "$_art3/pr-url.txt"
assert_file_not_exists "[SPEC-3] no merge-result.json when gate absent" \
    "$_art3/merge-result.json"
_merge_calls3="$(cat "$_MERGE_RECORD" 2>/dev/null || true)"
_gh_merge3=0
[[ "$_merge_calls3" == *"merged"* ]] && _gh_merge3=1
assert_eq "[SPEC-3] gh pr merge NOT called when gate absent" "0" "$_gh_merge3"

# ─── SPEC-4: review-report absent → PR open (fail-closed) ────────────────────
print_test_section "SPEC-4: auto_unless_flagged + review-report absent → PR open (fail-closed)"

_sf4="$(_setup_run s4 pass "")"  # gate=pass, no review-report.json
_art4="$(dirname "$_sf4")/artifacts"
> "$_MERGE_RECORD"

export _TPL_MERGE_POLICY="auto_unless_flagged"
( pr_stage_run "pr" "$_sf4" ) >/dev/null 2>&1; _rc4=$?

assert_eq "[SPEC-4] pr_stage_run exits 0 when review-report absent (fail-closed)" "0" "$_rc4"
assert_file_exists "[SPEC-4] pr-url.txt written (fail-closed, review-report absent)" \
    "$_art4/pr-url.txt"
assert_file_not_exists "[SPEC-4] no merge-result.json when review-report absent (fail-closed)" \
    "$_art4/merge-result.json"
_merge_calls4="$(cat "$_MERGE_RECORD" 2>/dev/null || true)"
_gh_merge4=0
[[ "$_merge_calls4" == *"merged"* ]] && _gh_merge4=1
assert_eq "[SPEC-4] gh pr merge NOT called when review-report absent" "0" "$_gh_merge4"

# ─── SPEC-5: gate pass + advisory → auto-merge ───────────────────────────────
print_test_section "SPEC-5: auto_unless_flagged + gate pass + merge_readiness=advisory → merged"

_sf5="$(_setup_run s5 pass advisory)"
_art5="$(dirname "$_sf5")/artifacts"
> "$_MERGE_RECORD"

export _TPL_MERGE_POLICY="auto_unless_flagged"
( pr_stage_run "pr" "$_sf5" ) >/dev/null 2>&1; _rc5=$?

assert_eq "[SPEC-5] pr_stage_run exits 0 on auto-merge path (advisory)" "0" "$_rc5"
assert_file_exists "[SPEC-5] merge-result.json written when gate pass + advisory" \
    "$_art5/merge-result.json"
_merge_status5="$(jq -r '.status // empty' "$_art5/merge-result.json" 2>/dev/null || true)"
assert_eq "[SPEC-5] merge-result.json status==merged (gate pass + advisory)" "merged" "$_merge_status5"
_merge_calls5="$(cat "$_MERGE_RECORD" 2>/dev/null || true)"
_merge_called5=0
[[ "$_merge_calls5" == *"merged"* ]] && _merge_called5=1
assert_eq "[SPEC-5] gh pr merge called when merge_readiness=advisory" "1" "$_merge_called5"

# ─── SPEC-6: gate verdict=fail + review-report ready → PR open ───────────────
print_test_section "SPEC-6: auto_unless_flagged + gate fail + merge_readiness=ready → PR open"

_sf6="$(_setup_run s6 fail ready)"
_art6="$(dirname "$_sf6")/artifacts"
> "$_MERGE_RECORD"

export _TPL_MERGE_POLICY="auto_unless_flagged"
( pr_stage_run "pr" "$_sf6" ) >/dev/null 2>&1; _rc6=$?

assert_eq "[SPEC-6] pr_stage_run exits 0 when gate fails (PR open)" "0" "$_rc6"
assert_file_exists "[SPEC-6] pr-url.txt written when gate fails" "$_art6/pr-url.txt"
assert_file_not_exists "[SPEC-6] no merge-result.json when gate fails" \
    "$_art6/merge-result.json"
_merge_calls6="$(cat "$_MERGE_RECORD" 2>/dev/null || true)"
_gh_merge6=0
[[ "$_merge_calls6" == *"merged"* ]] && _gh_merge6=1
assert_eq "[SPEC-6] gh pr merge NOT called when gate verdict=fail" "0" "$_gh_merge6"

# ─── SPEC-7: gate pass + HIGH finding but readiness=advisory → PR open ───────
# DoD #1051: a top-severity (critical/high) finding must escalate even when the
# aggregator classified readiness as advisory (lenses.sh forces needs_attention
# only on `critical`/low score, so a `high` finding lands as advisory). The
# policy independently guards on findings[].severity. (Copilot #1068.)
print_test_section "SPEC-7: auto_unless_flagged + gate pass + high finding + advisory → PR open"

_sf7="$(_setup_run s7 pass advisory)"
printf '{"schema_version":1,"merge_readiness":"advisory","findings":[{"severity":"high","title":"SQL injection in query builder"}]}\n' \
    > "$(dirname "$_sf7")/artifacts/review-report.json"
_art7="$(dirname "$_sf7")/artifacts"
> "$_MERGE_RECORD"

export _TPL_MERGE_POLICY="auto_unless_flagged"
( pr_stage_run "pr" "$_sf7" ) >/dev/null 2>&1; _rc7=$?

assert_eq "[SPEC-7] pr_stage_run exits 0 on PR-open path (high+advisory)" "0" "$_rc7"
assert_file_exists "[SPEC-7] pr-url.txt written (escalated despite advisory)" "$_art7/pr-url.txt"
assert_file_not_exists "[SPEC-7] no merge-result.json for high finding + advisory" \
    "$_art7/merge-result.json"
_merge_calls7="$(cat "$_MERGE_RECORD" 2>/dev/null || true)"
_gh_merge7=0
[[ "$_merge_calls7" == *"merged"* ]] && _gh_merge7=1
assert_eq "[SPEC-7] gh pr merge NOT called for high-severity finding (advisory)" "0" "$_gh_merge7"

# ─── Results ──────────────────────────────────────────────────────────────────
print_test_results
