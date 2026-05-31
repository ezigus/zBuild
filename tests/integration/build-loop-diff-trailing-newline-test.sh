#!/usr/bin/env bash
# Integration test (#530, subprocess-boundary): a real build_stage_run that
# produces a heredoc-trailing-newline diff via the canonical capture path
# must yield a diff.patch that BOTH `git apply --check` (forward, against a
# stashed-clean tree) AND `git apply --check -R` (reverse) accept.
#
# This is the test that mirrors the #294 dogfood failure: the LLM's edits
# went through `git diff HEAD` → bash `$()` capture → `printf '%s'` write,
# and the trailing newline was stripped, producing "corrupt patch at line N"
# in the downstream test stage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #530: diff.patch trailing-newline (subprocess)"
setup_test_env "build-530-trailing-nl"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-530-$$"
export ZBUILD_ISSUE="530"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# ─── Fixture repo: file with a heredoc whose final byte (before \n) is EOF ──
REPO="$(setup_git_temp_repo build530repo)"
[[ -d "$REPO" ]] || { echo "setup_git_temp_repo failed" >&2; exit 1; }
mkdir -p "$REPO/tests/fixtures"
(
    cd "$REPO"
    cat > tests/fixtures/heredoc.sh <<'SEED'
#!/usr/bin/env bash
emit() {
    cat <<'EOF'
seed-line
EOF
}
SEED
    git add tests/fixtures/heredoc.sh
    git commit -q -m "seed heredoc fixture"
) >/dev/null

STATE_DIR="$TEST_TEMP_DIR/state-build"
mkdir -p "$STATE_DIR/artifacts"
cat > "$STATE_DIR/artifacts/plan.json" <<'EOF'
{
  "schema_version": 1,
  "goal": "Append a line below heredoc to reproduce #530 trailing-newline bug",
  "files": ["tests/fixtures/heredoc.sh"],
  "steps": [
    {"id": "s1", "description": "extend heredoc.sh",
     "files": ["tests/fixtures/heredoc.sh"], "estimated_lines": 4}
  ]
}
EOF
cat > "$STATE_DIR/scope-manifest.md" <<'EOF'
+ tests/
EOF
STATE_FILE="$STATE_DIR/state.json"
printf '{"issue":530,"branch":"feat/530"}' > "$STATE_FILE"

# ─── Mock claude: appends 4 lines below heredoc, terminating in \n ───────────
MARK_FILE="$TEST_TEMP_DIR/llm-call.mark"
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
mark="${MARK_FILE:-/tmp/mark}"
n=$(wc -l < "$mark" 2>/dev/null | tr -d ' ' || echo 0)
n=$(( n + 1 ))
echo "MARK_iter_${n}" >> "$mark"
# Append a new function below the heredoc. File MUST end in \n.
cat >> "$PWD/tests/fixtures/heredoc.sh" <<'NEW'

added_fn() {
    echo added
}
NEW
jq -n --arg r $'edits applied\nLOOP_COMPLETE' \
    '{result:$r, usage:{input_tokens:1, output_tokens:1}}'
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
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
      destinations: [file, stdout]
      tail_lines: 5
YAML

DRIVER="$TEST_TEMP_DIR/driver.sh"
cat > "$DRIVER" <<EOF
set -uo pipefail
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

load_template "$TEST_TEMP_DIR/template.yaml"
export ZBUILD_CURRENT_STAGE=build
build_stage_init >/dev/null 2>&1 || true
set +e
build_stage_run "ignored" "$STATE_FILE"
_brc=\$?
set -e
echo "DRIVER_RC=\$_brc"
exit 0
EOF

DRIVER_OUT="$TEST_TEMP_DIR/driver.out"
set +e
bash "$DRIVER" >"$DRIVER_OUT" 2>&1
_real_driver_rc=$?
set -e
echo "EXTERNAL_DRIVER_RC=$_real_driver_rc" >> "$DRIVER_OUT"

DIFF="$STATE_DIR/artifacts/diff.patch"
SUMMARY="$STATE_DIR/artifacts/build-summary.json"

# ─── (1) diff.patch exists & non-empty ───────────────────────────────────────
if [[ -s "$DIFF" ]]; then
    assert_pass "diff.patch written and non-empty"
else
    assert_fail "diff.patch non-empty" \
        "missing or empty: $DIFF; driver tail: $(tail -30 "$DRIVER_OUT" 2>/dev/null)"
    cleanup_test_env
    print_test_results
    exit 1
fi

# ─── (2) diff.patch ends in a newline ────────────────────────────────────────
last_byte="$(tail -c1 "$DIFF" | od -An -tx1 | tr -d ' ')"
if [[ "$last_byte" == "0a" ]]; then
    assert_pass "diff.patch ends in \\n (no #530 truncation)"
else
    assert_fail "diff.patch ends in \\n" "last byte=0x$last_byte"
fi

# ─── (3) forward `git apply --check` against stashed-clean tree succeeds ─────
(
    cd "$REPO"
    git stash push -u -q -m "t7-forward-check" 2>/dev/null || true
    if git apply --check "$DIFF" 2>err.log; then
        echo "FORWARD_OK"
    else
        echo "FORWARD_FAIL: $(cat err.log)"
    fi
    git stash pop -q 2>/dev/null || true
) > "$TEST_TEMP_DIR/fwd.out"

if grep -q '^FORWARD_OK' "$TEST_TEMP_DIR/fwd.out"; then
    assert_pass "forward git apply --check succeeds (downstream test stage will work)"
else
    assert_fail "forward git apply --check succeeds" "$(cat "$TEST_TEMP_DIR/fwd.out")"
fi

# ─── (4) build verdict=pass (gate accepted the well-formed patch) ────────────
if [[ -s "$SUMMARY" ]]; then
    verdict="$(jq -r '.verdict' "$SUMMARY" 2>/dev/null || echo '')"
    assert_eq "build verdict=pass" "pass" "$verdict"
    fwd="$(jq -r '.apply_check.forward_ok' "$SUMMARY" 2>/dev/null || echo '')"
    rev="$(jq -r '.apply_check.reverse_ok' "$SUMMARY" 2>/dev/null || echo '')"
    assert_eq "apply_check.forward_ok=true" "true" "$fwd"
    assert_eq "apply_check.reverse_ok=true" "true" "$rev"
else
    assert_fail "build-summary.json exists" "missing"
fi

# ─── (5) driver returned rc=0 (clean diff path) ──────────────────────────────
ext_rc="$(grep -oE 'EXTERNAL_DRIVER_RC=[0-9]+' "$DRIVER_OUT" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
assert_eq "driver rc=0 on clean diff" "0" "${ext_rc:-missing}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
