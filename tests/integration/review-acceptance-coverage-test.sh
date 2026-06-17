#!/usr/bin/env bash
# Integration (843-H #923): review's mechanical acceptance-coverage gate.
# When the LLM returns approve but a design SPEC-n has no [SPEC-n]-tagged
# TESTFILE present in the diff under review, review downgrades approve →
# request_changes. No acceptance block → no-op (approve stands).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "review acceptance-coverage gate (843-H #923)"
setup_test_env "review-acceptance-coverage"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
emit_event() { eb_emit_event "$@"; }
export -f emit_event
# shellcheck source=../../plugins/agent/review/plugin.sh
source "$REPO_ROOT/plugins/agent/review/plugin.sh"

# LLM returns approve; assessment+test pass so the §485 gate does NOT pre-empt.
route_to_model() { printf '{"verdict":"approve","confidence":0.9,"issues":[],"summary":"ok"}'; return 0; }
export -f route_to_model
apply_scope_redaction() { cp "$1" "$2"; return 0; }
export -f apply_scope_redaction
render_artifact() { printf '%s' "$2"; }
export -f render_artifact

GIT="$(command -v git)"

# _seed_repo <name> <commit-testfile?> → echoes repo path; feature HEAD ahead of main
_seed_repo() {
    local name="$1" commit_tf="$2"
    local repo; repo="$(setup_git_temp_repo "$name")"
    mkdir -p "$repo/.art"
    (
        cd "$repo"
        "$GIT" checkout -q -b feature
        mkdir -p tests
        printf '#!/usr/bin/env bash\n# [SPEC-1] behavior is load-bearing\nexit 0\n' > tests/feat-test.sh
        if [[ "$commit_tf" == "commit" ]]; then
            "$GIT" add -A; "$GIT" commit -q -m "add tagged test (in diff)"
        else
            # Commit something else so HEAD is ahead of main, but NOT the testfile
            # (so it is absent from `git diff merge-base..HEAD`).
            printf 'x\n' > other.txt; "$GIT" add other.txt; "$GIT" commit -q -m "unrelated"
        fi
    )
    printf '%s' "$repo"
}

_run_review() {  # _run_review <repo> → sets VERDICT
    local repo="$1"
    local art="$repo/.art"; mkdir -p "$art"
    printf '+ .\n' > "$art/scope.md"
    printf '{"steps":[]}' > "$art/plan.json"
    printf 'diff\n' > "$art/diff.patch"
    printf '{"verdict":"pass","passed":1,"failed":0}' > "$art/test-results.json"
    printf '{"verdict":"pass"}' > "$art/test-assessment.json"
    : > "$ZBUILD_EVENTS_JSONL"
    ( cd "$repo" && _review_run_inner "$art/scope.md" "$art/plan.json" "$art/diff.patch" \
        "$art/test-results.json" "$art/review.json" "$art" >/dev/null 2>&1 )
    VERDICT="$(jq -r '.verdict' "$art/review.json" 2>/dev/null)"
}

# ── C1: SPEC tagged-test IS in the diff → approve stands ──────────────────────
REPO1="$(_seed_repo cov-ok commit)"
cat > "$REPO1/.art/design.md" <<'EOF'
```acceptance
SPEC-1: behavior is load-bearing
TESTFILES:
tests/feat-test.sh
```
EOF
_run_review "$REPO1"
assert_eq "C1: tagged test in diff → approve stands" "approve" "$VERDICT"

# ── C2: SPEC's tagged test NOT in the diff → downgrade to request_changes ──────
REPO2="$(_seed_repo cov-gap nocommit)"
cat > "$REPO2/.art/design.md" <<'EOF'
```acceptance
SPEC-1: behavior is load-bearing
TESTFILES:
tests/feat-test.sh
```
EOF
_run_review "$REPO2"
assert_eq "C2: tagged test absent from diff → request_changes" "request_changes" "$VERDICT"
if grep -q '"type":"review.acceptance_coverage.gap"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "C2: review.acceptance_coverage.gap emitted"
else
    assert_fail "C2: coverage gap event" "missing"
fi

# ── C3: no acceptance block → no-op (approve stands) ──────────────────────────
REPO3="$(_seed_repo cov-noblock commit)"
printf '# Design\nNo acceptance block.\n' > "$REPO3/.art/design.md"
_run_review "$REPO3"
assert_eq "C3: no acceptance block → approve stands (no-op)" "approve" "$VERDICT"

cleanup_test_env
print_test_results
