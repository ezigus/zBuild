#!/usr/bin/env bash
# Integration test (#529): reproduce the dogfood failure shape from issue
# #529 — a real `git diff HEAD` truncated mid-hunk should classify as
# reason=corrupt_format (not tool_unavailable) at the build-summary boundary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #529: dogfood-shape integration (truncated diff)"
setup_test_env "build-apply-check-dogfood-529"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# ── Build a real repo with a real file (50 lines) ─────────────────────────
REPO="$TEST_TEMP_DIR/dogfood"
mkdir -p "$REPO"
(
    cd "$REPO"
    git init -q
    git config user.email t@t
    git config user.name t
    for i in $(seq 1 50); do
        printf 'line %02d\n' "$i"
    done > file.txt
    git add file.txt
    git commit -q -m seed
    # Mutate enough lines to produce a multi-hunk diff.
    sed -i.bak \
        -e '5s/.*/LINE 05 CHANGED/' \
        -e '10s/.*/LINE 10 CHANGED/' \
        -e '20s/.*/LINE 20 CHANGED/' \
        -e '30s/.*/LINE 30 CHANGED/' \
        -e '40s/.*/LINE 40 CHANGED/' \
        file.txt
    rm -f file.txt.bak
)
FULL_DIFF="$TEST_TEMP_DIR/full.patch"
( cd "$REPO" && git diff HEAD ) > "$FULL_DIFF"

DIFF_LINES="$(wc -l < "$FULL_DIFF" | tr -d ' ')"
if [[ "$DIFF_LINES" -lt 34 ]]; then
    assert_fail "precond: diff has ≥34 lines" "got $DIFF_LINES"
    cleanup_test_env
    print_test_results
    exit 1
fi

# Truncate to 33 lines mid-hunk (matches issue #529's wire shape).
TRUNC_DIFF="$TEST_TEMP_DIR/truncated.patch"
head -n 33 "$FULL_DIFF" > "$TRUNC_DIFF"

# ── Run the gate ─────────────────────────────────────────────────────────
RESULT="$TEST_TEMP_DIR/apply-check-result.json"
set +e
_build_apply_check "$REPO" "$TRUNC_DIFF" "$RESULT"
gate_rc=$?
set -e

# ── Assert dogfood-shape classification ──────────────────────────────────
ok="$(jq -r '.ok' "$RESULT" 2>/dev/null || echo '?')"
reason="$(jq -r '.reason // ""' "$RESULT" 2>/dev/null || echo '')"
branch="$(jq -r '.classifier_branch // ""' "$RESULT" 2>/dev/null || echo '')"
grc="$(jq -r '.git_apply_rc // ""' "$RESULT" 2>/dev/null || echo '')"

assert_eq "gate fail-closed rc=1" "1" "$gate_rc"
assert_eq "ok=false" "false" "$ok"
# Load-bearing: dogfood NEVER classifies as tool_unavailable.
if [[ "$reason" == "tool_unavailable" ]]; then
    assert_fail "dogfood reason != tool_unavailable" "regression of issue #529"
else
    assert_pass "dogfood reason != tool_unavailable (got $reason)"
fi
assert_eq "reason=corrupt_format" "corrupt_format" "$reason"
assert_eq "classifier_branch=corrupt_format" "corrupt_format" "$branch"
assert_eq "git_apply_rc=128" "128" "$grc"

# ── Simulate build-summary embedding the apply_check object ──────────────
SUMMARY="$TEST_TEMP_DIR/build-summary.json"
jq -n --slurpfile ac "$RESULT" \
    '{verdict:"corrupt_diff", apply_check:$ac[0]}' > "$SUMMARY"
downstream_reason="$(jq -r '.apply_check.reason' "$SUMMARY")"
assert_eq "build-summary apply_check.reason=corrupt_format" \
    "corrupt_format" "$downstream_reason"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
