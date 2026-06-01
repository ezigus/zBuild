#!/usr/bin/env bash
# Tests: core/router/route.sh — injects branch-cumulative context into iter
# prompt when $ZBUILD_STATE_DIR/intake-baseline-ref.txt exists (#614).
#
# Setup: seed branch with N commits AFTER an intake baseline SHA, then drive
# route_to_model_loop and assert the iter-1 prompt the mock claude saw
# contains the "## BRANCH STATE since intake" block including the commits
# and the diff stat.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "route: injects branch-cumulative context (#614)"
setup_test_env "route-614-branch-context"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
echo -n "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1
unset ZBUILD_RUN_ID 2>/dev/null || true

# ─── Build a repo with: seed → BASELINE → 3 follow-on commits ───────────────
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
(
    cd "$REPO"
    git init -q -b main 2>/dev/null || git init -q
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    echo seed > seed.txt; git add seed.txt; git commit -q -m seed
) >/dev/null

# BASELINE = HEAD at "intake time"
BASELINE_SHA="$(git -C "$REPO" rev-parse HEAD)"

# Now add 3 follow-on commits — these should appear in BRANCH STATE.
(
    cd "$REPO"
    echo a > a.txt; git add a.txt; git commit -q -m "add a"
    echo b > b.txt; git add b.txt; git commit -q -m "add b"
    echo c >> a.txt;    git add a.txt; git commit -q -m "tweak a"
) >/dev/null

# ─── State dir: write intake-baseline-ref.txt ────────────────────────────────
STATE_DIR="$TEST_TEMP_DIR/state-614"
mkdir -p "$STATE_DIR"
printf '%s' "$BASELINE_SHA" > "$STATE_DIR/intake-baseline-ref.txt"
export ZBUILD_STATE_DIR="$STATE_DIR"

# ─── Mock claude: record the prompt arg ($2 after -p) and emit LOOP_COMPLETE ─
PROMPT_CAPTURE="$TEST_TEMP_DIR/claude-prompt-iter1.txt"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
# Capture the -p prompt arg (claude is called: -p "<prompt>" --print --model ...).
prompt=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -p) prompt="\$2"; shift 2 ;;
        *)  shift ;;
    esac
done
# Only capture the first iter prompt.
if [[ ! -f "$PROMPT_CAPTURE" ]]; then
    printf '%s' "\$prompt" > "$PROMPT_CAPTURE"
fi
jq -n --arg r \$'done\nLOOP_COMPLETE' \
   '{result:\$r, usage:{input_tokens:1, output_tokens:1}}'
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"

PROMPT_FILE="$TEST_TEMP_DIR/prompt.txt"
echo "static build prompt" > "$PROMPT_FILE"

set +e
route_to_model_loop T2 "$PROMPT_FILE" "$REPO" 1 >/dev/null 2>&1
rc=$?
set -e
assert_exit_code "loop rc=0 (DONE on iter 1)" "0" "$rc"

assert_file_exists "iter-1 prompt captured" "$PROMPT_CAPTURE"
captured="$(cat "$PROMPT_CAPTURE" 2>/dev/null || echo)"

# Block header
if [[ "$captured" == *"## BRANCH STATE since intake"* ]]; then
    assert_pass "prompt contains '## BRANCH STATE since intake' header"
else
    assert_fail "prompt contains '## BRANCH STATE since intake' header" \
        "got: $(printf '%s' "$captured" | head -c 400)"
fi

# Commits section
for msg in "add a" "add b" "tweak a"; do
    if [[ "$captured" == *"$msg"* ]]; then
        assert_pass "branch state lists commit: $msg"
    else
        assert_fail "branch state lists commit: $msg" "missing from prompt"
    fi
done

# Diff stat — at least one file path should show up in --stat output
if [[ "$captured" == *"a.txt"* && "$captured" == *"b.txt"* ]]; then
    assert_pass "diff stat references a.txt and b.txt"
else
    assert_fail "diff stat references a.txt and b.txt" "missing"
fi

# Both labels present (Commits + Diff vs intake baseline)
if [[ "$captured" == *"Commits:"* ]]; then
    assert_pass "block contains 'Commits:' label"
else
    assert_fail "block contains 'Commits:' label" "missing"
fi
if [[ "$captured" == *"Diff vs intake baseline"* ]]; then
    assert_pass "block contains 'Diff vs intake baseline' label"
else
    assert_fail "block contains 'Diff vs intake baseline' label" "missing"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
