#!/usr/bin/env bash
# Integration test (#602): build plugin no longer stashes the working tree.
# The LLM edits files in place; `git diff HEAD` captures them directly.
# Assert post-build: numstat is non-zero AND `git stash list` is empty.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #602: no stash, in-place edits visible to git diff HEAD"
setup_test_env "build-602-no-stash"

# #1921 follow-up: reserved test identity — the QUOTED assignment form.
# These were real issue numbers used as run identity.
_ZB_ID="$(zb_test_issue)"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-602-$$"
export ZBUILD_ISSUE="$_ZB_ID"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# ── Real git repo so `git diff HEAD` returns real output ───────────────────
REPO="$(setup_git_temp_repo build602repo)"
[[ -d "$REPO" ]] || { echo "setup_git_temp_repo failed" >&2; exit 1; }
mkdir -p "$REPO/tests/fixtures"
( cd "$REPO" \
    && echo "seed" > tests/fixtures/seed.txt \
    && git add tests/fixtures/seed.txt \
    && git commit -q -m "seed" ) >/dev/null

# ── Snapshot pre-existing stashes (other test runs may have left some) ─────
PRE_STASHES="$(cd "$REPO" && git stash list 2>/dev/null | wc -l | tr -d ' ' || echo 0)"

# ── Stub claude: writes a NEW in-scope file every iter, then LOOP_COMPLETE ─
MARK_FILE="$TEST_TEMP_DIR/llm-call.mark"
if [[ -n "$MARK_FILE" ]]; then
    assert_pass "[SPEC-1] MARK_FILE non-empty at setup"
else
    assert_fail "[SPEC-1] MARK_FILE non-empty at setup" "MARK_FILE is empty or unset"
fi
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
mark="$MARK_FILE"
n=\$(wc -l < "\$mark" 2>/dev/null | tr -d ' ' || echo 0)
n=\$(( n + 1 ))
echo "MARK_iter_\${n}" >> "\$mark"
mkdir -p "\$PWD/tests/fixtures"
printf 'iter-%d-content\n' "\$n" >> "\$PWD/tests/fixtures/build-602-newfile.txt"
jq -n --arg r \$'wrote file\nLOOP_COMPLETE' \
    '{result:\$r, usage:{input_tokens:7, output_tokens:4}}'
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
assert_contains "[SPEC-2] mock-claude bakes concrete MARK_FILE path at write time" \
    "$(cat "$TEST_TEMP_DIR/bin/claude")" "$MARK_FILE"
mock_body="$(cat "$TEST_TEMP_DIR/bin/claude")"
if ! grep -qF '/tmp/mark' <<< "$mock_body" 2>/dev/null; then
    assert_pass "[SPEC-3] mock-claude has no /tmp/mark fallback"
else
    assert_fail "[SPEC-3] mock-claude has no /tmp/mark fallback" "found /tmp/mark in mock body"
fi
export PATH="$TEST_TEMP_DIR/bin:$PATH"
export MARK_FILE

cat > "$TEST_TEMP_DIR/template.yaml" <<'YAML'
id: standard
name: Standard Pipeline
extends: null
defaults:
  strategy: fanout
stages:
  - id: build
    gate: auto
    roles: [builder]
    io:
      destinations: [file]
      tail_lines: 40
YAML

STATE_DIR="$TEST_TEMP_DIR/state-build"
mkdir -p "$STATE_DIR/artifacts"
cat > "$STATE_DIR/artifacts/plan.json" <<'EOF'
{
  "schema_version": 1,
  "goal": "Create fixture (#602)",
  "files": ["tests/fixtures/build-602-newfile.txt"],
  "steps": [
    {"id": "s1", "description": "create file",
     "files": ["tests/fixtures/build-602-newfile.txt"], "estimated_lines": 1}
  ]
}
EOF
cat > "$STATE_DIR/scope-manifest.md" <<'EOF'
+ tests/
+ plugins/
+ core/
EOF
STATE_FILE="$STATE_DIR/state.json"
printf '{"issue":$_ZB_ID,"branch":"feat/602"}' > "$STATE_FILE"

# #661: pin intake baseline so build emits cumulative diff.patch (the
# post-commit `git diff $baseline..HEAD` covers the agent's edits which
# `git diff HEAD` no longer does after #608 committed them).
# Mirror intake's `printf '%s'` write — raw 40-char SHA, no trailing newline.
printf '%s' "$(git -C "$REPO" rev-parse HEAD)" > "$STATE_DIR/intake-baseline-ref.txt"

STAGE_INPUTS_DRIVER="$TEST_TEMP_DIR/stage-inputs-driver.json"
jq -n \
    --arg sm "$STATE_DIR/scope-manifest.md" \
    --arg pl "$STATE_DIR/artifacts/plan.json" \
    '{"schema_version":1,"stage":"build","inputs":{"scope_manifest":$sm,"plan":$pl}}' \
    > "$STAGE_INPUTS_DRIVER"

DRIVER="$TEST_TEMP_DIR/driver.sh"
cat > "$DRIVER" <<EOF
set -euo pipefail
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/event-bus/event-bus.sh"
source "$REPO_ROOT/core/pipeline/template.sh"
source "$REPO_ROOT/core/output/stage-io.sh"
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

export ZBUILD_EVENTS_DIR="$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$ZBUILD_EVENT_SCHEMA"
export ZBUILD_STATE_DIR="$ZBUILD_STATE_DIR"
export ZBUILD_MODELS_FILE="$ZBUILD_MODELS_FILE"
export ZBUILD_RUN_ID="$ZBUILD_RUN_ID"
export ZBUILD_ISSUE="$ZBUILD_ISSUE"
export ZBUILD_REPO_ROOT="$REPO"
export HOME="$HOME"
export ZBUILD_SCOPE_OVERRIDE=1
export PATH="$PATH"
export MARK_FILE="$MARK_FILE"
export ZBUILD_STAGE_INPUTS="$STAGE_INPUTS_DRIVER"

load_template "$TEST_TEMP_DIR/template.yaml"
export ZBUILD_CURRENT_STAGE=build
build_stage_run "ignored" "$STATE_FILE"
EOF

bash "$DRIVER" >/dev/null 2>/dev/null || true

# ── (1) LLM edits captured by git: post-#608 they land in a pipeline commit;
#       pre-#608 they remained in the working tree. Either signal proves the
#       edits weren't lost to a stash dance — the #602 invariant.
numstat="$(cd "$REPO" && git diff HEAD --numstat 2>/dev/null || true)"
untracked="$(cd "$REPO" && git status --porcelain 2>/dev/null | grep -E '^\?\?' || true)"
last_author="$(cd "$REPO" && git log -1 --format='%an' 2>/dev/null || true)"
if [[ -n "$numstat" || -n "$untracked" || "$last_author" == "zbuild-pipeline" ]]; then
    assert_pass "LLM edits captured by git (working tree or pipeline commit, #602)"
else
    assert_fail "LLM edits captured by git (#602)" \
        "expected diff/untracked/pipeline-commit; got empty — likely stashed"
fi

# ── (2) New file present in working tree (proof: not hidden in stash) ──────
if [[ -f "$REPO/tests/fixtures/build-602-newfile.txt" ]]; then
    assert_pass "newfile exists in working tree (not stashed)"
else
    assert_fail "newfile exists in working tree (not stashed)" \
        "file missing — likely stashed and not popped"
fi

# ── (3) Zero new stashes created by the build run ──────────────────────────
POST_STASHES="$(cd "$REPO" && git stash list 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
assert_eq "no new stashes after build (#602)" "$PRE_STASHES" "$POST_STASHES"

# ── (4) diff.patch artifact non-empty ──────────────────────────────────────
DIFF_PATCH="$STATE_DIR/artifacts/diff.patch"
if [[ -s "$DIFF_PATCH" ]]; then
    assert_pass "diff.patch artifact non-empty"
else
    assert_fail "diff.patch artifact non-empty" "diff.patch missing or empty"
fi

# ── (5) build-summary.json has NO apply_check field (#602) ─────────────────
SUMMARY="$STATE_DIR/artifacts/build-summary.json"
if [[ -f "$SUMMARY" ]]; then
    has_apply_check="$(jq -r 'has("apply_check")' "$SUMMARY" 2>/dev/null || echo true)"
    assert_eq "build-summary.json has no apply_check field (#602)" "false" "$has_apply_check"
else
    assert_fail "build-summary.json present" "missing"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
