#!/usr/bin/env bash
# Unit test (#1265, SPEC-7): pr-open halts terminally (return 2,
# reason=no_committed_changes) BEFORE push + `gh pr create` when the branch has
# 0 commits ahead of the merge-base. Belt-and-suspenders for the #1214 dogfood:
# a branch with nothing to ship must fail fast, not after a wasted push and a
# confusing `gh` "No commits between main and branch" error.
#
# RED at baseline: today pr-open pushes first → the failure surfaces as a push /
# gh error (a DIFFERENT reason), and `gh pr create` IS invoked. GREEN after: the
# preflight returns 2 with reason=no_committed_changes and gh is never called.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "pr-open: 0-commit branch halts before push (#1265)"
setup_test_env "pr-open-1265-zero-commits"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_RUN_ID="pr-open-1265-$$"
mkdir -p "$ZBUILD_EVENTS_DIR"
: > "$ZBUILD_EVENTS_JSONL"

# ─── git fixture: feature branch at the SAME commit as main (0 ahead) ────────
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init --quiet >/dev/null 2>&1
git -C "$REPO" config user.email 'test@example.com' >/dev/null
git -C "$REPO" config user.name 'test' >/dev/null
git -C "$REPO" checkout -b main --quiet >/dev/null 2>&1 || git -C "$REPO" branch -m main >/dev/null 2>&1 || true
printf 'seed\n' > "$REPO/SEED"
git -C "$REPO" add SEED >/dev/null
git -C "$REPO" commit -m baseline --quiet >/dev/null
# Feature branch points at the same commit — nothing committed ahead of main.
git -C "$REPO" checkout -b zbuild/issue-1265 --quiet >/dev/null 2>&1
cd "$REPO" || exit 1

STATE_DIR="$TEST_TEMP_DIR/state"
ART="$STATE_DIR/artifacts"
mkdir -p "$ART"
printf '{"schema_version":1,"verdict":"approve","issues":[],"summary":"t"}\n' \
    > "$ART/review.json"
STATE_FILE="$STATE_DIR/pipeline-state.json"
printf '{"issue":1265,"branch":"zbuild/issue-1265"}\n' > "$STATE_FILE"

# Mock gh so we can PROVE it is never reached (sentinel absent on halt).
MOCKBIN="$TEST_TEMP_DIR/bin"; mkdir -p "$MOCKBIN"
GH_SENTINEL="$TEST_TEMP_DIR/gh-was-called"
cat > "$MOCKBIN/gh" <<MOCK
#!/usr/bin/env bash
touch "$GH_SENTINEL"
echo "https://github.com/mock/repo/pull/1265"
exit 0
MOCK
chmod +x "$MOCKBIN/gh"

# shellcheck source=../../plugins/tool/pr-open/plugin.sh
source "$REPO_ROOT/plugins/tool/pr-open/plugin.sh"

( PATH="$MOCKBIN:$PATH" pr_open_run "pr" "$STATE_FILE" ) >/dev/null 2>&1; RC=$?

# ── (1) returns 2 (terminal halt) ──────────────────────────────────────────
assert_eq "pr_open_run returns 2 on 0-commit branch" "2" "$RC"

# ── (2) reason=no_committed_changes (not a push/gh error) ──────────────────
if [[ -f "$ART/pr-result.json" ]]; then
    reason="$(jq -r '.reason // ""' "$ART/pr-result.json" 2>/dev/null || echo "")"
    assert_contains "pr-result.json .reason cites no committed changes" \
        "$reason" "no committed changes"
else
    assert_fail "pr-result.json written on halt" "file missing"
fi
if grep -q '"reason":"no_committed_changes"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "plugin.run.error reason=no_committed_changes emitted"
else
    assert_fail "plugin.run.error reason=no_committed_changes emitted" "missing"
fi

# ── (3) gh pr create was NEVER invoked (halt is BEFORE gh) ──────────────────
assert_file_not_exists "gh pr create not reached (halt before push/gh)" "$GH_SENTINEL"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
