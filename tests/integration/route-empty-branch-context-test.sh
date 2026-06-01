#!/usr/bin/env bash
# Tests: core/router/route.sh — when no commits exist past the intake baseline,
# the BRANCH STATE block still renders, with "(none)" / "(no changes)" (#614).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "route: empty-branch context renders (none)/(no changes) (#614)"
setup_test_env "route-614-empty-branch"

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

# Repo with seed commit only — baseline == HEAD, no follow-on commits.
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

BASELINE_SHA="$(git -C "$REPO" rev-parse HEAD)"

STATE_DIR="$TEST_TEMP_DIR/state-614"
mkdir -p "$STATE_DIR"
printf '%s' "$BASELINE_SHA" > "$STATE_DIR/intake-baseline-ref.txt"
export ZBUILD_STATE_DIR="$STATE_DIR"

PROMPT_CAPTURE="$TEST_TEMP_DIR/claude-prompt-iter1.txt"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
prompt=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -p) prompt="\$2"; shift 2 ;;
        *)  shift ;;
    esac
done
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

if [[ "$captured" == *"## BRANCH STATE since intake"* ]]; then
    assert_pass "block rendered even with no follow-on commits"
else
    assert_fail "block rendered even with no follow-on commits" \
        "got: $(printf '%s' "$captured" | head -c 400)"
fi

if [[ "$captured" == *"(none)"* ]]; then
    assert_pass "empty Commits section shows '(none)'"
else
    assert_fail "empty Commits section shows '(none)'" "missing"
fi

if [[ "$captured" == *"(no changes)"* ]]; then
    assert_pass "empty diff section shows '(no changes)'"
else
    assert_fail "empty diff section shows '(no changes)'" "missing"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
