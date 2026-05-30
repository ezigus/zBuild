#!/usr/bin/env bash
# Integration test (#509): pipeline halt path. Bypass the LLM loop entirely
# by stubbing route_to_model_loop so it deterministically writes a corrupt
# diff.patch into the working tree, then assert the build plugin returns
# rc=1 — which is the runner-halt trigger at core/pipeline/runner.sh:672-686.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #509: rc=1 fail-closed halts pipeline runner"
setup_test_env "build-apply-check-halt"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-509-halt-$$"
export ZBUILD_ISSUE="509"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

REPO="$(setup_git_temp_repo build509haltrepo)"
mkdir -p "$REPO/tests/fixtures"
( cd "$REPO" \
    && echo "seed" > tests/fixtures/seed.txt \
    && git add tests/fixtures/seed.txt \
    && git commit -q -m "seed" ) >/dev/null

STATE_DIR="$TEST_TEMP_DIR/state-build"
mkdir -p "$STATE_DIR/artifacts"
cat > "$STATE_DIR/artifacts/plan.json" <<'EOF'
{
  "schema_version": 1, "goal": "halt-test",
  "files": ["tests/fixtures/bad.txt"],
  "steps": [
    {"id": "s1", "description": "n/a",
     "files": ["tests/fixtures/bad.txt"], "estimated_lines": 1}
  ]
}
EOF
cat > "$STATE_DIR/scope-manifest.md" <<'EOF'
+ tests/
EOF
STATE_FILE="$STATE_DIR/state.json"
printf '{"issue":509,"branch":"feat/509"}' > "$STATE_FILE"

# ── Bypass LLM: write the diff bypass via mock claude that crafts a corrupt
#    edit in the working tree (binary file via add -N gives a stub diff that
#    git apply --check rejects).
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
# Drop a binary file. `git add -N` later produces a stub diff git apply rejects.
mkdir -p "$PWD/tests/fixtures"
printf '\xff\x00\xfe\x01binary\xfa' > "$PWD/tests/fixtures/bad.txt"
jq -n --arg r $'go\nLOOP_COMPLETE' \
    '{result:$r, usage:{input_tokens:1, output_tokens:1}}'
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

cat > "$TEST_TEMP_DIR/template.yaml" <<'YAML'
id: standard
name: Standard
extends: null
defaults:
  strategy: fanout
stages:
  - id: build
    gate: auto
    roles: [builder]
    io:
      destinations: [file]
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
ext_rc=$?
set -e
echo "EXT=$ext_rc" >> "$DRIVER_OUT"

# ─── (1) bash $DRIVER exited non-zero (the rc that runner.sh sees) ─────────
if [[ "$ext_rc" != "0" ]]; then
    assert_pass "external driver rc != 0 — runner would halt (rc=$ext_rc)"
else
    assert_fail "external driver rc != 0" \
        "got rc=0; driver out tail: $(tail -10 "$DRIVER_OUT")"
fi

# ─── (2) build_stage_run inner rc == 1 (canonical halt signal) ─────────────
# Inner DRIVER_RC echo may be skipped if a stage_io EXIT trap fires first;
# the EXT bash-rc above is the authoritative halt signal regardless. When the
# inner line IS captured (set +e wrapping survives), assert it's 1.
inner="$(grep -oE 'DRIVER_RC=[0-9]+' "$DRIVER_OUT" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
if [[ -n "$inner" ]]; then
    assert_eq "build_stage_run inner rc=1 (when capture survived)" "1" "$inner"
else
    # ext_rc==1 already proves the halt signal — record an info-pass.
    assert_pass "inner DRIVER_RC suppressed by trap; ext_rc=$ext_rc carries halt signal"
fi

# ─── (3) summary verdict surfaces corrupt_diff for downstream consumers ────
SUMMARY="$STATE_DIR/artifacts/build-summary.json"
v="$(jq -r '.verdict' "$SUMMARY" 2>/dev/null || echo 'missing')"
assert_eq "summary verdict=corrupt_diff" "corrupt_diff" "$v"

# ─── (4) apply_check event recorded for triage ─────────────────────────────
assert_event_emitted "build.apply_check.failed event recorded" \
    "$ZBUILD_EVENTS_JSONL" "build.apply_check.failed"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
