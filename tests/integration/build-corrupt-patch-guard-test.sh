#!/usr/bin/env bash
# Integration test (#509): build plugin's corrupt-patch guard fires fail-CLOSED
# when the post-loop diff.patch fails `git apply --check`.
#
# Reproducer for the suspected #1 root cause: `git add -N` on an empty file
# yields a zero-line stat entry that git apply --check rejects.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #509: corrupt-patch guard subprocess-boundary"
setup_test_env "build-corrupt-patch"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-509-$$"
export ZBUILD_ISSUE="509"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

REPO="$(setup_git_temp_repo build509repo)"
[[ -d "$REPO" ]] || { echo "setup_git_temp_repo failed" >&2; exit 1; }
mkdir -p "$REPO/tests/fixtures"
( cd "$REPO" \
    && echo "seed" > tests/fixtures/seed.txt \
    && git add tests/fixtures/seed.txt \
    && git commit -q -m "seed" ) >/dev/null

STATE_DIR="$TEST_TEMP_DIR/state-build"
mkdir -p "$STATE_DIR/artifacts"
cat > "$STATE_DIR/artifacts/plan.json" <<'EOF'
{
  "schema_version": 1,
  "goal": "Trigger corrupt-patch reproducer",
  "files": ["tests/fixtures/binary509.bin"],
  "steps": [
    {"id": "s1", "description": "drop binary file",
     "files": ["tests/fixtures/binary509.bin"], "estimated_lines": 0}
  ]
}
EOF
cat > "$STATE_DIR/scope-manifest.md" <<'EOF'
+ tests/
EOF
STATE_FILE="$STATE_DIR/state.json"
printf '{"issue":509,"branch":"feat/509"}' > "$STATE_FILE"

# ── Reproducer: mock claude writes a new binary file. ────────────────────────
# `git add -N` on a new binary file makes `git diff HEAD` emit a "Binary
# files differ" stub WITHOUT a full index line — git apply --check then
# rejects the patch ("cannot apply binary patch without full index line").
# This is the same family of corruption #509 fires on (zero-stat new files,
# binary stubs, etc). Our gate must catch it and set verdict=corrupt_diff
# fail-CLOSED.
MARK_FILE="$TEST_TEMP_DIR/llm-call.mark"
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
mark="${MARK_FILE:-/tmp/mark}"
n=$(wc -l < "$mark" 2>/dev/null | tr -d ' ' || echo 0)
n=$(( n + 1 ))
echo "MARK_iter_${n}" >> "$mark"
mkdir -p "$PWD/tests/fixtures"
# Write a small binary blob (NUL bytes etc) so `git add -N` produces a diff
# that git apply --check rejects for missing full index line.
printf '\x00\x01\x02binary\x00\xff\xfe' > "$PWD/tests/fixtures/binary509.bin"
jq -n --arg r $'done\nLOOP_COMPLETE' \
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

SUMMARY="$STATE_DIR/artifacts/build-summary.json"
DIFF="$STATE_DIR/artifacts/diff.patch"

# ─── (1) build-summary.json exists and is well-formed ─────────────────────
if [[ -s "$SUMMARY" ]] && jq empty "$SUMMARY" >/dev/null 2>&1; then
    assert_pass "build-summary.json written and valid JSON"
else
    assert_fail "build-summary.json written and valid JSON" \
        "missing/invalid: $(head -c 200 "$SUMMARY" 2>/dev/null)"
fi

# ─── (2) schema_version still 3 (additive) ────────────────────────────────
sv="$(jq -r '.schema_version' "$SUMMARY" 2>/dev/null || echo '')"
assert_eq "schema_version unchanged at 3" "3" "$sv"

# ─── (3) New .apply_check.* fields present ────────────────────────────────
ok="$(jq -r '.apply_check.ok' "$SUMMARY" 2>/dev/null || echo 'null')"
reason="$(jq -r '.apply_check.reason // ""' "$SUMMARY" 2>/dev/null || echo '')"
if [[ "$ok" == "false" ]]; then
    assert_pass "apply_check.ok=false (gate detected corruption)"
else
    assert_fail "apply_check.ok=false" "got ok='$ok', reason='$reason', summary=$(head -c 300 "$SUMMARY")"
fi
if [[ -n "$reason" && "$reason" != "null" ]]; then
    assert_pass "apply_check.reason populated ($reason)"
else
    assert_fail "apply_check.reason populated" "got: '$reason'"
fi

# ─── (4) verdict=corrupt_diff ─────────────────────────────────────────────
verdict="$(jq -r '.verdict' "$SUMMARY" 2>/dev/null || echo '')"
assert_eq "verdict=corrupt_diff" "corrupt_diff" "$verdict"

# ─── (5) build.apply_check.failed event emitted ───────────────────────────
assert_event_emitted "build.apply_check.failed event emitted" \
    "$ZBUILD_EVENTS_JSONL" "build.apply_check.failed"

# ─── (6) diff.patch written even when corrupt (triage) ────────────────────
if [[ -e "$DIFF" ]]; then
    assert_pass "diff.patch written for triage even on failure"
else
    assert_fail "diff.patch written for triage" "missing $DIFF"
fi

# ─── (7) Driver returned non-zero (rc=1, fail-closed) ─────────────────────
# Prefer the EXTERNAL rc (`bash $DRIVER` exit code) — that's the real
# subprocess-boundary signal. Fall back to the DRIVER_RC line written
# inside the driver itself.
ext_rc="$(grep -oE 'EXTERNAL_DRIVER_RC=[0-9]+' "$DRIVER_OUT" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
inner_rc="$(grep -oE 'DRIVER_RC=[0-9]+' "$DRIVER_OUT" 2>/dev/null | grep -v EXTERNAL | tail -1 | cut -d= -f2 || true)"
drc="${ext_rc:-${inner_rc:-missing}}"
if [[ "$drc" != "0" && -n "$drc" && "$drc" != "missing" ]]; then
    assert_pass "build_stage_run returned rc!=0 (fail-closed): $drc"
else
    assert_fail "build_stage_run returned rc!=0 (fail-closed)" \
        "got drc='$drc' (ext='$ext_rc' inner='$inner_rc'); driver tail: $(tail -20 "$DRIVER_OUT" 2>/dev/null)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
