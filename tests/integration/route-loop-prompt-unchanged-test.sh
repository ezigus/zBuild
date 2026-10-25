#!/usr/bin/env bash
# tests/integration/route-loop-prompt-unchanged-test.sh — every call of a
# stage's model loop gets the stage's prompt as the stage composed it
# (ADR-067 §8, amended).
#
# The loop used to add, on every call, an "## Iteration N/M" header, the diff so
# far, a "previous round ran out of time" warning and a "## BRANCH STATE since
# intake" summary — none of them in the stage's prompt order. The code is in the
# worktree; the stage's notes file and Previous work carry what earlier calls did.
#
#   LP1 [change]: a later call in the loop sends exactly the stage's prompt
#   LP2 [change]: no call carries an Iteration header or a BRANCH STATE block
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "route: a loop sends the stage prompt unchanged"
setup_test_env "route-loop-prompt"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
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
    cd "$REPO" || exit 1  # #2103: a failed cd must not run git in the caller checkout
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
    cd "$REPO" || exit 1  # #2103: a failed cd must not run git in the caller checkout
    echo a > a.txt; git add a.txt; git commit -q -m "add a"
    echo b > b.txt; git add b.txt; git commit -q -m "add b"
    echo c >> a.txt;    git add a.txt; git commit -q -m "tweak a"
) >/dev/null

# ─── State dir: write intake-baseline-ref.txt ────────────────────────────────
STATE_DIR="$TEST_TEMP_DIR/state-614"
mkdir -p "$STATE_DIR"
export ZBUILD_RUN_START_COMMIT="$BASELINE_SHA"
export ZBUILD_STATE_DIR="$STATE_DIR"

# ─── Mock claude: record the prompt arg ($2 after -p) and emit LOOP_COMPLETE ─
PROMPT_DIR="$TEST_TEMP_DIR/prompts"
mkdir -p "$PROMPT_DIR"
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
# The router sends the prompt on stdin (#1849: argv overflowed at 128 KiB).
[[ -n "\$prompt" ]] || prompt="\$(cat)"
# Only capture the first iter prompt.
n=\$(ls "$PROMPT_DIR" | wc -l | tr -d ' ')
printf '%s' "\$prompt" > "$PROMPT_DIR/call-\$((n + 1)).txt"
# A change each call, so the loop sees progress and calls again.
echo "\$n" >> "$REPO/work-\$n.txt"
if [[ "\$n" -ge 1 ]]; then
    jq -n --arg r \$'done\nLOOP_COMPLETE' '{result:\$r, usage:{input_tokens:1, output_tokens:1}}'
else
    jq -n --arg r 'working' '{result:\$r, usage:{input_tokens:1, output_tokens:1}}'
fi
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"

PROMPT_FILE="$TEST_TEMP_DIR/prompt.txt"
printf 'the stage prompt, as composed\n' > "$PROMPT_FILE"

set +e
route_to_model_loop T2 "$PROMPT_FILE" "$REPO" 3 >/dev/null 2>&1
set +e

assert_file_exists "the first call was made" "$PROMPT_DIR/call-1.txt"
assert_file_exists "a second call was made" "$PROMPT_DIR/call-2.txt"
assert_eq "[LP1] the first call sends the stage prompt exactly" \
    "$(cat "$PROMPT_FILE")" "$(cat "$PROMPT_DIR/call-1.txt" 2>/dev/null)"
assert_eq "[LP1] a later call sends the stage prompt exactly" \
    "$(cat "$PROMPT_FILE")" "$(cat "$PROMPT_DIR/call-2.txt" 2>/dev/null)"
all="$(cat "$PROMPT_DIR"/*.txt 2>/dev/null)"
if [[ "$all" == *"## Iteration"* || "$all" == *"BRANCH STATE"* || "$all" == *"Cumulative diff"* ]]; then
    assert_fail "[LP2] no call carries an Iteration header, a diff or a BRANCH STATE block" \
        "found one in: $(printf '%s' "$all" | head -c 300)"
else
    assert_pass "[LP2] no call carries an Iteration header, a diff or a BRANCH STATE block"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
