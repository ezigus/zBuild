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

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-498-$$"
export ZBUILD_ISSUE="498"
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
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
mark="${MARK_FILE:-/tmp/mark}"
n=$(wc -l < "$mark" 2>/dev/null | tr -d ' ' || echo 0)
n=$(( n + 1 ))
echo "MARK_iter_${n}" >> "$mark"
# Edit in-scope fixture file each iteration so numstat has content.
mkdir -p "$PWD/tests/fixtures"
printf 'iter-%d\n' "$n" >> "$PWD/tests/fixtures/build-test-498.txt"
if [[ "$n" -ge 2 ]]; then
    jq -n --arg r $'done\nLOOP_COMPLETE' \
        '{result:$r, usage:{input_tokens:7, output_tokens:4}}'
else
    jq -n --arg r "progress ${n}" \
        '{result:$r, usage:{input_tokens:7, output_tokens:4}}'
fi
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
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
printf '{"issue":498,"branch":"feat/498"}' > "$STATE_FILE"

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

load_template "$TEST_TEMP_DIR/template.yaml"
export ZBUILD_CURRENT_STAGE=build
build_stage_init >/dev/null 2>&1 || true
build_stage_run "ignored" "$STATE_FILE"
EOF

ZBUILD_STAGE_IO_FD=3 bash "$DRIVER" >/dev/null 2>/dev/null 3>"$BANNER" || true

banner="$(cat "$BANNER" 2>/dev/null || echo '')"

# ─── (1) Per-iteration [llm] banners preserved (#482 unchanged) ───────────
in_llm="$(printf '%s\n' "$banner" | grep -cE '══ build \[llm\] seq=.* input ══' || true)"
out_llm="$(printf '%s\n' "$banner" | grep -cE '══ build \[llm\] seq=.* output ' || true)"
assert_eq "2 [llm] input banners (one per iter)"  "2" "$in_llm"
assert_eq "2 [llm] output banners (one per iter)" "2" "$out_llm"

# ─── (2) Exactly ONE [computed] banner (input + output pair) ──────────────
in_computed="$(printf '%s\n' "$banner" | grep -cE '══ build \[computed\] seq=.* input ══' || true)"
out_computed="$(printf '%s\n' "$banner" | grep -cE '══ build \[computed\] seq=.* output ' || true)"
assert_eq "1 [computed] input banner"  "1" "$in_computed"
assert_eq "1 [computed] output banner" "1" "$out_computed"

# ─── (3) [computed] banner appears AFTER all [llm] banners (#491 ordering) ─
last_llm_line="$(printf '%s\n' "$banner" | grep -nE '══ build \[llm\]' | tail -1 | cut -d: -f1)"
first_computed_line="$(printf '%s\n' "$banner" | grep -nE '══ build \[computed\]' | head -1 | cut -d: -f1)"
if [[ -n "$last_llm_line" && -n "$first_computed_line" \
      && "$last_llm_line" -lt "$first_computed_line" ]]; then
    assert_pass "[computed] banner emitted AFTER all [llm] banners"
else
    assert_fail "[computed] banner ordering" \
        "last_llm=$last_llm_line first_computed=$first_computed_line"
fi

# ─── (4) [computed] banner contains numstat literal + changed file ────────
assert_contains "[computed] banner input shows numstat literal" \
    "$banner" "git diff HEAD --numstat"
assert_contains "[computed] banner output shows the changed file" \
    "$banner" "build-test-498.txt"
assert_contains "[computed] banner output shows total footer" \
    "$banner" "total: 1 files,"

# ─── (5) Numstat byte-matches `git diff HEAD --numstat` (consistency) ─────
real_numstat="$(git -C "$REPO" diff HEAD --numstat 2>/dev/null || true)"
# The banner shows the formatted body; extract +A -R path lines and compare
# files names against the real numstat output.
if [[ -n "$real_numstat" ]]; then
    real_file="$(printf '%s\n' "$real_numstat" | head -1 | awk '{print $3}')"
    if printf '%s\n' "$banner" | grep -q "$real_file"; then
        assert_pass "banner numstat references real changed file ($real_file)"
    else
        assert_fail "banner missing real numstat file" "expected $real_file in banner"
    fi
fi

# ─── (6) Exactly 1 stage.io.captured event with kind=computed ─────────────
captured_computed="$(jq -c --arg t "stage.io.captured" \
    'select(.type==$t and .data.stage=="build" and .data.kind=="computed")' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "1 stage.io.captured event with kind=computed" "1" "$captured_computed"

# ─── (7) No discrepancy event (numstat showed > 0 files changed) ──────────
disc_count="$(jq -c --arg t "build.discrepancy.detected" \
    'select(.type==$t)' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "no build.discrepancy.detected event (real edits present)" "0" "$disc_count"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
