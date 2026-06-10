#!/usr/bin/env bash
# Tests: end-to-end propagation of branch-state context into the build
# prompt — the actual symptom that #618 fixes.
#
# Scenario: intake records a baseline SHA at $ZBUILD_STATE_DIR/intake-baseline-ref.txt.
# Several commits land on the issue branch on top of that baseline. When the
# runner reaches the build stage, the build plugin invokes route_to_model_loop,
# which is supposed to inject "## BRANCH STATE since intake" into the iter
# prompt (per #617). Before #618, ZBUILD_STATE_DIR was never exported by the
# runner, so the route loop couldn't find the baseline file and silently
# skipped the block. This test drives the runner end-to-end and asserts the
# block lands in the prompt that the (mocked) LLM receives.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build prompt e2e: BRANCH STATE block appears (#618)"
setup_test_env "build-618-branch-state-e2e"
# Wave 12-E (#664): default is enforce. Stub plugins used here lack honest
# inputs/outputs blocks; opt out — this suite tests branch-state injection.
export ZBUILD_CONTRACT_VALIDATOR=warn

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
# State dir matches runner.sh's default ($HOME/.zbuild/state) since we do not
# export ZBUILD_STATE_DIR — the test's whole point is that the runner exports
# it for its own children.
STATE_DIR="$HOME/.zbuild/state"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
PROMPT_CAPTURE="$TEST_TEMP_DIR/build-prompt-capture.txt"

export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
# NOTE: ZBUILD_STATE_DIR is intentionally NOT exported here. The whole point
# of this test is that the runner exports it for child plugins; if we leaked
# it via the parent shell, both pre- and post-#618 runners would pass.
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_CYCLES_ENABLED=0
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

# ─── Fixture repo: seed → BASELINE → 3 follow-on commits ────────────────────
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

(
    cd "$REPO"
    echo a > a.txt; git add a.txt; git commit -q -m "add a"
    echo b > b.txt; git add b.txt; git commit -q -m "add b"
    echo c >> a.txt;    git add a.txt; git commit -q -m "tweak a"
) >/dev/null

# ─── Intake stub: writes intake-baseline-ref.txt into $ZBUILD_STATE_DIR ─────
mkdir -p "$PLUGINS_ROOT/agent/intake"
cat > "$PLUGINS_ROOT/agent/intake/manifest.yaml" <<EOF
id: intake
name: Intake (writes baseline ref)
kind: agent
version: 0.0.1
hooks:
  run: intake_run
requires:
  core:
    - redaction
EOF
cat > "$PLUGINS_ROOT/agent/intake/plugin.sh" <<EOF
intake_run() {
    # Reads ZBUILD_STATE_DIR from runner-exported env (the #618 contract).
    # If it's unset, the file lands in /intake-baseline-ref.txt which fails fast.
    : "\${ZBUILD_STATE_DIR:?intake_run: ZBUILD_STATE_DIR not exported by runner}"
    printf '%s' "$BASELINE_SHA" > "\$ZBUILD_STATE_DIR/intake-baseline-ref.txt"
    return 0
}
EOF

# ─── Plan stub: pass-through ────────────────────────────────────────────────
mock_plugin_factory "plan" "agent" 0 >/dev/null
# #746: standard template now includes impact between plan and build (plan_impact_cycle).
mock_plugin_factory "impact" "agent" 0 >/dev/null
mock_plugin_factory "design" "agent" 0 "" "designer" >/dev/null

# ─── Build stub: sources route.sh and invokes route_to_model_loop ───────────
# This mirrors what the real build plugin does at runner.sh dispatch time —
# it reads ZBUILD_STATE_DIR (which the runner must have exported) and runs
# the route loop, which is the code path that injects the BRANCH STATE block.
PROMPT_FILE_FOR_BUILD="$TEST_TEMP_DIR/build-static-prompt.txt"
echo "static build prompt body" > "$PROMPT_FILE_FOR_BUILD"

mkdir -p "$PLUGINS_ROOT/agent/build"
cat > "$PLUGINS_ROOT/agent/build/manifest.yaml" <<EOF
id: build
name: Build (calls route_to_model_loop)
kind: agent
version: 0.0.1
hooks:
  run: build_run
requires:
  core:
    - redaction
EOF
cat > "$PLUGINS_ROOT/agent/build/plugin.sh" <<EOF
# shellcheck disable=SC1091
source "$REPO_ROOT/core/router/route.sh"
build_run() {
    : "\${ZBUILD_STATE_DIR:?build_run: ZBUILD_STATE_DIR not exported by runner}"
    route_to_model_loop T2 "$PROMPT_FILE_FOR_BUILD" "$REPO" 1 >/dev/null 2>&1 || true
    return 0
}
EOF

# ─── Pass-through stubs for downstream stages ───────────────────────────────
mock_plugin_factory "test"            "tool"  0 >/dev/null
mock_plugin_factory "test_assessment" "agent" 0 >/dev/null
mock_plugin_factory "review"          "agent" 0 >/dev/null

# ─── Mock claude shim: capture the iter-1 prompt to PROMPT_CAPTURE ──────────
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

# ─── Run the runner end-to-end ──────────────────────────────────────────────
rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json" "$PROMPT_CAPTURE"
set +e
bash "$RUNNER" --issue 618 >/dev/null 2>&1
rc=$?
set -e

assert_eq "runner exits 0" "0" "$rc"
assert_file_exists "intake wrote baseline ref" "$STATE_DIR/intake-baseline-ref.txt"
assert_file_exists "build captured iter-1 prompt" "$PROMPT_CAPTURE"

captured="$(cat "$PROMPT_CAPTURE" 2>/dev/null || echo)"

# Headline: the BRANCH STATE block lands in the iter prompt.
if [[ "$captured" == *"## BRANCH STATE since intake (HEAD:"* ]]; then
    assert_pass "build prompt contains '## BRANCH STATE since intake (HEAD:' header"
else
    assert_fail "build prompt contains '## BRANCH STATE since intake (HEAD:' header" \
        "captured prompt: $(printf '%s' "$captured" | head -c 600)"
fi

if [[ "$captured" == *"Commits:"* ]]; then
    assert_pass "build prompt contains 'Commits:' label under BRANCH STATE block"
else
    assert_fail "build prompt contains 'Commits:' label" \
        "captured prompt: $(printf '%s' "$captured" | head -c 600)"
fi

# Sanity: at least one of the follow-on commit subjects landed.
landed=0
for msg in "add a" "add b" "tweak a"; do
    if [[ "$captured" == *"$msg"* ]]; then landed=1; break; fi
done
if [[ $landed -eq 1 ]]; then
    assert_pass "build prompt lists at least one follow-on commit"
else
    assert_fail "build prompt lists at least one follow-on commit" \
        "expected 'add a' / 'add b' / 'tweak a' in: $(printf '%s' "$captured" | head -c 400)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
