#!/usr/bin/env bash
# Tests: crash and resume — SIGKILL a pipeline mid-run, verify state, then resume
# E2E: invokes real scripts/zbuild with PATH-shadowed externals
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ZBUILD_CLI="$REPO_ROOT/scripts/zbuild"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "crash-resume — SIGKILL mid-run then zbuild pipeline resume (E2E)"
setup_test_env "e2e-crash-resume"

export ZBUILD_TEST_TMP="$TEST_TEMP_DIR"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
mkdir -p "$ZBUILD_STATE_DIR" "$TEST_TEMP_DIR/events"

mock_claude
mock_gh
mock_git

_test_cleanup_hook() { cleanup_test_env; }

# ─── Build plugins: intake sleeps 15s (slow enough to be killed), rest fast ───
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$PLUGINS_ROOT/agent/intake" "$PLUGINS_ROOT/agent/security-lens" "$PLUGINS_ROOT/tool/output"

cat > "$PLUGINS_ROOT/agent/intake/manifest.yaml" <<'YAML'
id: intake
name: Slow Intake
kind: agent
version: 0.0.1
hooks:
  run: intake_run
requires:
  core:
    - redaction
YAML
cat > "$PLUGINS_ROOT/agent/intake/plugin.sh" <<'EOF'
intake_run() { sleep 15; return 0; }
EOF

cat > "$PLUGINS_ROOT/agent/security-lens/manifest.yaml" <<'YAML'
id: security-lens
name: Fast SL
kind: agent
version: 0.0.1
hooks:
  run: security_lens_run
requires:
  core:
    - redaction
YAML
cat > "$PLUGINS_ROOT/agent/security-lens/plugin.sh" <<'EOF'
security_lens_run() { return 0; }
EOF

cat > "$PLUGINS_ROOT/tool/output/manifest.yaml" <<'YAML'
id: output
name: Fast Output
kind: tool
version: 0.0.1
hooks:
  run: output_run
YAML
cat > "$PLUGINS_ROOT/tool/output/plugin.sh" <<'EOF'
output_run() { return 0; }
EOF

export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"

# ADR-047 §5 (#1282): the runner's resolvability preflight rejects at LOAD any
# template leaf with no plugin. This harness registers exactly intake +
# security-lens + output, so it must drive a template whose flow is those three
# leaves — the shipped `simple` template needs ~14 plugins and would abort at load
# (previously it "worked" only because the old canonical fence never checked plugin
# presence; the run crashed mid-flight at the first missing leaf, after intake had
# already written state). Install the matching minimal fixture as a per-repo
# overlay and run the CLI from that repo so `--template` resolves it.
OVERLAY_REPO="$(setup_git_temp_repo crash-resume-overlay)"
install_template_overlay "$OVERLAY_REPO" crash-resume-minimal

# ─── Test 1: Start pipeline and SIGKILL after state-file appears ──────────────
# Originally a fixed `sleep 1` then SIGKILL. Post-Wave-19 (template-resolver,
# two-channel verdict, recursive seq-prefix) the runner startup occasionally
# crosses 1s on GHA's slower runners, so SIGKILL arrives BEFORE the state
# file is written → flake on #727 CI. Poll for the state file's appearance so
# the test races against state-write, not absolute wall clock. The poll BREAKS
# the instant `status` is written (~1.7s locally), then kills — the cap is only a
# fail-safe upper bound. #1587: raised 5s → 12s because in the dogfood test stage
# crash-resume runs inside the full parallel suite on a slower GHA runner, where
# startup can exceed 5s under peak load (measured: NO code latency regression,
# just a too-tight margin). 12s stays below intake's 15s sleep so the kill still
# lands mid-run. NOTE: the status assertion below (Test 3) is a MID-RUN PROXY, not
# a crash-safety invariant — an empty status just means the kill landed before the
# run really started (nothing to resume); the real invariants are the valid-JSON /
# .bak / resume checks, which do not depend on this timing.
( cd "$OVERLAY_REPO" && \
  ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
  ZBUILD_STATE_DIR="$ZBUILD_STATE_DIR" \
  ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events" \
  ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl" \
  ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db" \
      bash "$ZBUILD_CLI" pipeline start --goal "test crash resume" --template crash-resume-minimal 2>/dev/null ) &
pipeline_pid=$!
# Wait up to 12s (#1587) for state file to appear AND contain a status field
# (intake writes status BEFORE entering the long 15s sleep). Without the status
# check, the file can exist but be empty when SIGKILL arrives, causing the
# Test 3 status assertion to fail with an empty value. Breaks early the instant
# status appears; the 12s cap is a fail-safe for slow/loaded CI runners.
for _i in $(seq 1 24); do
    if [[ -f "$STATE_FILE" ]]; then
        _st="$(jq -r '.status // empty' "$STATE_FILE" 2>/dev/null || true)"
        [[ -n "$_st" ]] && break
    fi
    sleep 0.5
done
kill -9 "$pipeline_pid" 2>/dev/null || true
wait "$pipeline_pid" 2>/dev/null || true

if [[ -f "$STATE_FILE" ]]; then
    assert_pass "state file exists after SIGKILL"
else
    assert_fail "state file exists after SIGKILL" "expected $STATE_FILE"
fi

# ─── Test 2: Assert state file is valid JSON (not corrupt) ────────────────────
if [[ -f "$STATE_FILE" ]]; then
    if jq empty "$STATE_FILE" 2>/dev/null; then
        assert_pass "state file is valid JSON after SIGKILL"
    else
        assert_fail "state file is valid JSON after SIGKILL" "jq parse failed on $STATE_FILE"
    fi
else
    # File absent — already failed above; skip this check
    assert_fail "state file is valid JSON after SIGKILL" "state file absent"
fi

# ─── Test 2b (#909): if a .bak rotation exists, it must be valid JSON ──────────
# .bak is the corruption-recovery source; atomic_write rotates it via
# atomic_replace (temp+rename) so a SIGKILL can never leave a torn backup.
if [[ -f "${STATE_FILE}.bak" ]]; then
    if jq empty "${STATE_FILE}.bak" 2>/dev/null; then
        assert_pass ".bak is valid JSON after SIGKILL (recovery path intact)"
    else
        assert_fail ".bak is valid JSON after SIGKILL" "jq parse failed on ${STATE_FILE}.bak"
    fi
fi

# ─── Test 3: State status is interrupted (not complete or corrupt) ────────────
if [[ -f "$STATE_FILE" ]]; then
    status="$(jq -r '.status // empty' "$STATE_FILE" 2>/dev/null || true)"
    if [[ "$status" == "interrupted" ]]; then
        assert_pass "pipeline status=interrupted after SIGKILL"
    else
        # SIGKILL can arrive before state is written; accept in_progress too.
        # The key requirement is that it is NOT "complete" and not empty/corrupt.
        if [[ -z "$status" || "$status" == "complete" ]]; then
            assert_fail "pipeline status is not 'complete' or empty after SIGKILL" \
                "got status='$status'"
        else
            assert_pass "pipeline status is not 'complete' after SIGKILL (got '$status')"
        fi
    fi
else
    assert_fail "pipeline status check — state file absent"
fi

# ─── Test 4: zbuild pipeline resume on the interrupted state — non-crash ───────
# Replace intake with a fast no-op so resume completes quickly
cat > "$PLUGINS_ROOT/agent/intake/plugin.sh" <<'EOF'
intake_run() { return 0; }
EOF

# Force status to interrupted so resume is allowed
if [[ -f "$STATE_FILE" ]]; then
    jq '.status = "interrupted"' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi

set +e
out="$(ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
       ZBUILD_STATE_DIR="$ZBUILD_STATE_DIR" \
       ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events" \
       ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl" \
       ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db" \
       bash "$ZBUILD_CLI" pipeline resume 2>&1)"
rc=$?
set -e

# rc > 128 means crash/signal; we allow 0 or any non-signal non-crash exit
if [[ "$rc" -gt 128 ]]; then
    assert_fail "zbuild pipeline resume does not crash (rc=$rc — signal/crash detected)" \
        "output: $out"
else
    assert_pass "zbuild pipeline resume exits without crash (rc=$rc)"
fi

cleanup_test_env
print_test_results
