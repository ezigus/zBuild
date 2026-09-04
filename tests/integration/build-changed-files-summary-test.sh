#!/usr/bin/env bash
# Integration test (#498): build plugin emits a stage-level [computed]
# summary banner via `git diff HEAD --numstat` AFTER route_to_model_loop
# completes. Per-iteration [llm] banners (#482) MUST remain unchanged and
# MUST precede the new [computed] banner in fd-3 output order (#491
# ordering contract).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #498: changed-files numstat summary banner (kind=computed)"
setup_test_env "build-changed-files-summary"

# #1921 follow-up: reserved test identity — the QUOTED assignment form.
# These were real issue numbers used as run identity.
_ZB_ID="$(zb_test_issue)"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-498-$$"
export ZBUILD_ISSUE="$_ZB_ID"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

# Scope-override token so the per-iter redaction.applied stub satisfies C6.
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# ── Build a real git repo so `git diff HEAD --numstat` returns real output ─
REPO="$(setup_git_temp_repo build498repo)"
[[ -d "$REPO" ]] || { echo "setup_git_temp_repo failed" >&2; exit 1; }
mkdir -p "$REPO/tests/fixtures"
( cd "$REPO" \
    && echo "seed-fixture" > tests/fixtures/seed.txt \
    && git add tests/fixtures/seed.txt \
    && git commit -q -m "fixture-seed" ) >/dev/null

# ── Mock claude: 2 iters then DONE; edits a fixture each iteration ────────
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
# Edit in-scope fixture file each iteration so numstat has content.
mkdir -p "\$PWD/tests/fixtures"
printf 'iter-%d\n' "\$n" >> "\$PWD/tests/fixtures/build-test-498.txt"
if [[ "\$n" -ge 2 ]]; then
    jq -n --arg r \$'done\nLOOP_COMPLETE' \
        '{result:\$r, usage:{input_tokens:7, output_tokens:4}}'
else
    jq -n --arg r "progress \${n}" \
        '{result:\$r, usage:{input_tokens:7, output_tokens:4}}'
fi
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

# ── Template with stdout destination so banners emit on fd 3 ──────────────
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
      tail_lines: 80
YAML

# ── plan.json with in-scope file declared ─────────────────────────────────
STATE_DIR="$TEST_TEMP_DIR/state-build"
mkdir -p "$STATE_DIR/artifacts"
cat > "$STATE_DIR/artifacts/plan.json" <<'EOF'
{
  "schema_version": 1,
  "goal": "Add test fixture for #498",
  "files": ["tests/fixtures/build-test-498.txt"],
  "steps": [
    {"id": "step-1", "description": "create fixture",
     "files": ["tests/fixtures/build-test-498.txt"], "estimated_lines": 2}
  ]
}
EOF
# Scope manifest with the fixture dir in scope.
cat > "$STATE_DIR/scope-manifest.md" <<'EOF'
+ tests/
+ plugins/
+ core/
EOF
# State file (passed positionally as $2 to build_stage_run).
STATE_FILE="$STATE_DIR/state.json"
printf '{"issue":$_ZB_ID,"branch":"feat/498"}' > "$STATE_FILE"

STAGE_INPUTS_DRIVER="$TEST_TEMP_DIR/stage-inputs-driver.json"
jq -n \
    --arg sm "$STATE_DIR/scope-manifest.md" \
    --arg pl "$STATE_DIR/artifacts/plan.json" \
    '{"schema_version":1,"stage":"build","inputs":{"scope_manifest":$sm,"plan":$pl}}' \
    > "$STAGE_INPUTS_DRIVER"

# ── Subprocess driver: real build_stage_run with fd 3 capture ─────────────
DRIVER="$TEST_TEMP_DIR/driver.sh"
BANNER="$TEST_TEMP_DIR/banner-fd3.txt"

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

ZBUILD_STAGE_IO_FD=3 bash "$DRIVER" >/dev/null 2>/dev/null 3>"$BANNER" || true

banner="$(cat "$BANNER" 2>/dev/null || echo '')"

# ─── (1) Per-iteration [llm] banners preserved (#482 unchanged) ───────────
in_llm="$(printf '%s\n' "$banner" | grep -cE '══ build \[llm\] seq=.* input ══' || true)"
out_llm="$(printf '%s\n' "$banner" | grep -cE '══ build \[llm\] seq=.* output ' || true)"
assert_eq "2 [llm] input banners (one per iter)"  "2" "$in_llm"
assert_eq "2 [llm] output banners (one per iter)" "2" "$out_llm"

# ─── (2) ZERO [computed] banners (#587: kill duplicate post-loop banner) ──
in_computed="$(printf '%s\n' "$banner" | grep -cE '══ build \[computed\] seq=.* input ══' || true)"
out_computed="$(printf '%s\n' "$banner" | grep -cE '══ build \[computed\] seq=.* output ' || true)"
assert_eq "0 [computed] input banners (#587)"  "0" "$in_computed"
assert_eq "0 [computed] output banners (#587)" "0" "$out_computed"

# ─── (3) No discrepancy event for happy-path (numstat showed > 0 files) ───
disc_count="$(jq -c --arg t "build.discrepancy.detected" \
    'select(.type==$t)' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "no build.discrepancy.detected event (real edits present)" "0" "$disc_count"

# ─── (4) No empty-after-done-sentinel event either (happy-path) ───────────
empty_count="$(jq -c --arg t "build.diff.empty_after_done_sentinel" \
    'select(.type==$t)' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "no build.diff.empty_after_done_sentinel event (#587, real edits)" "0" "$empty_count"

# ─── (5) Zero stage.io.captured events with kind=computed (#587) ──────────
captured_computed="$(jq -c --arg t "stage.io.captured" \
    'select(.type==$t and .data.stage=="build" and .data.kind=="computed")' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0 stage.io.captured events with kind=computed (#587)" "0" "$captured_computed"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
