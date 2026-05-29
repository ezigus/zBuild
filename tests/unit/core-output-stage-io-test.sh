#!/usr/bin/env bash
# Tests: core/output/stage-io.sh — capture_stage_io chokepoint (ADR-015 v1, issue #438)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAGE_IO_SH="$REPO_ROOT/core/output/stage-io.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/output/stage-io — capture_stage_io chokepoint (ADR-015 v1)"
setup_test_env "stage-io"

# Sandbox event-bus and state dir into TEST_TEMP_DIR
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="test-run-stage-io"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# shellcheck disable=SC1090
source "$STAGE_IO_SH"

# ─── Mock template_stage_io_dests — controlled destination list ──────────────
# Default: file. Override per test by reassigning _MOCK_DESTS.
_MOCK_DESTS="file"
template_stage_io_dests() {
    local _stage="$1"
    [[ -z "$_MOCK_DESTS" ]] && return 0
    printf '%s\n' "$_MOCK_DESTS" | tr ',' '\n'
}

# ─── T1: zero args → rc=2 ────────────────────────────────────────────────────
set +e
err="$(capture_stage_io 2>&1)"
rc=$?
set -e
assert_eq "T1 zero args returns rc=2" "2" "$rc"
assert_contains_regex "T1 stderr mentions usage/required" "$err" "usage|required"

# ─── T2: missing --stage → rc=2 ──────────────────────────────────────────────
set +e
capture_stage_io --kind llm --input "i" --output "o" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T2 missing --stage returns rc=2" "2" "$rc"

# ─── T3: missing --kind → rc=2 ───────────────────────────────────────────────
set +e
capture_stage_io --stage plan --input "i" --output "o" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T3 missing --kind returns rc=2" "2" "$rc"

# ─── T4: unknown --kind=foo → rc=2 ───────────────────────────────────────────
set +e
capture_stage_io --stage plan --kind foo --input "i" --output "o" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T4 unknown --kind returns rc=2" "2" "$rc"

# ─── T5: malformed --metadata → rc=2 ─────────────────────────────────────────
set +e
capture_stage_io --stage plan --kind llm --input "i" --output "o" --metadata "no_equals_sign" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T5 malformed --metadata returns rc=2" "2" "$rc"

# ─── T6: empty destinations → rc=0, no file written ──────────────────────────
_MOCK_DESTS=""
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
set +e
capture_stage_io --stage plan --kind llm --input "i" --output "o" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T6 empty destinations returns rc=0" "0" "$rc"
assert_file_not_exists "T6 no artifact written" "$ZBUILD_STATE_DIR/artifacts/stage-io/plan-1.json"

# ─── T7: file destination writes valid record ────────────────────────────────
_MOCK_DESTS="file"
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
set +e
capture_stage_io --stage plan --kind llm --input "test input" --output "test output" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T7 file destination returns rc=0" "0" "$rc"
assert_file_exists "T7 artifact file exists" "$ZBUILD_STATE_DIR/artifacts/stage-io/plan-1.json"
t7_json="$(cat "$ZBUILD_STATE_DIR/artifacts/stage-io/plan-1.json" 2>/dev/null || echo '{}')"
assert_json_key "T7 schema_version == 1" "$t7_json" ".schema_version" "1"
assert_json_key "T7 kind == llm" "$t7_json" ".kind" "llm"
assert_json_key "T7 stage == plan" "$t7_json" ".stage" "plan"
assert_json_key "T7 run_id matches env" "$t7_json" ".run_id" "test-run-stage-io"
assert_json_key "T7 input present" "$t7_json" ".input" "test input"
assert_json_key "T7 output present" "$t7_json" ".output" "test output"
assert_json_key "T7 seq == 1" "$t7_json" ".seq" "1"
# ts is non-empty
t7_ts="$(printf '%s' "$t7_json" | jq -r '.ts' 2>/dev/null)"
assert_contains_regex "T7 ts is ISO-8601 UTC" "$t7_ts" "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"

# ─── T8: seq increments ──────────────────────────────────────────────────────
capture_stage_io --stage plan --kind llm --input "i2" --output "o2" >/dev/null 2>&1
assert_file_exists "T8 plan-2.json exists" "$ZBUILD_STATE_DIR/artifacts/stage-io/plan-2.json"
t8_json="$(cat "$ZBUILD_STATE_DIR/artifacts/stage-io/plan-2.json" 2>/dev/null || echo '{}')"
assert_json_key "T8 seq == 2" "$t8_json" ".seq" "2"

# ─── T9: metadata k=v propagation ────────────────────────────────────────────
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
capture_stage_io --stage plan --kind llm --input "i" --output "o" \
    --metadata "tier=T2" --metadata "model_id=mymodel" >/dev/null 2>&1
t9_json="$(cat "$ZBUILD_STATE_DIR/artifacts/stage-io/plan-1.json")"
assert_json_key "T9 metadata.tier == T2" "$t9_json" ".metadata.tier" "T2"
assert_json_key "T9 metadata.model_id == mymodel" "$t9_json" ".metadata.model_id" "mymodel"

# ─── T10: stage.io.captured event emitted ────────────────────────────────────
: > "$ZBUILD_EVENTS_JSONL"
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
capture_stage_io --stage plan --kind llm --input "i" --output "o" >/dev/null 2>&1
assert_event_emitted "T10 stage.io.captured event emitted" "$ZBUILD_EVENTS_JSONL" "stage.io.captured"
t10_evt="$(jq -c --arg t "stage.io.captured" 'select(.type==$t)' "$ZBUILD_EVENTS_JSONL" | head -1)"
# payload is flattened — check that key fields appear in event JSON
assert_contains "T10 event has stage" "$t10_evt" "plan"
assert_contains "T10 event has kind=llm" "$t10_evt" "llm"
assert_contains "T10 event has artifact_path" "$t10_evt" "plan-1.json"

# ─── T11: stdout destination stub ────────────────────────────────────────────
_MOCK_DESTS="stdout"
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
set +e
out11="$(capture_stage_io --stage plan --kind llm --input "i" --output "o" 2>&1)"
rc=$?
set -e
assert_eq "T11 stdout dest rc=0" "0" "$rc"
assert_contains "T11 stdout dest logs deferred to #440" "$out11" "deferred to #440"

# ─── T12: gh_comment destination stub ────────────────────────────────────────
_MOCK_DESTS="gh_comment"
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
set +e
out12="$(capture_stage_io --stage plan --kind llm --input "i" --output "o" 2>&1)"
rc=$?
set -e
assert_eq "T12 gh_comment dest rc=0" "0" "$rc"
assert_contains "T12 gh_comment dest logs deferred to #440" "$out12" "deferred to #440"

# ─── T31: stdout-only dest writes NO file under state/artifacts/stage-io ─────
# Proves the stub path doesn't accidentally write artifacts.
_MOCK_DESTS="stdout"
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
set +e
capture_stage_io --stage plan --kind llm --input "i" --output "o" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T31 stdout-only dest rc=0" "0" "$rc"
assert_file_not_exists "T31 no file artifact written for stdout-only" "$ZBUILD_STATE_DIR/artifacts/stage-io/plan-1.json"
# Also ensure no stray files in the dir
t31_count=0
if [[ -d "$ZBUILD_STATE_DIR/artifacts/stage-io" ]]; then
    # shellcheck disable=SC2012
    t31_count=$(ls -1 "$ZBUILD_STATE_DIR/artifacts/stage-io" 2>/dev/null | wc -l | tr -d ' ')
fi
assert_eq "T31 stage-io dir empty after stdout-only capture" "0" "$t31_count"

# ─── T32: empty-string --input and --output succeed (sentinel fix) ───────────
_MOCK_DESTS="file"
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
set +e
capture_stage_io --stage plan --kind llm --input "" --output "" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T32 empty --input/--output returns rc=0" "0" "$rc"
assert_file_exists "T32 artifact file exists for empty in/out" "$ZBUILD_STATE_DIR/artifacts/stage-io/plan-1.json"
t32_json="$(cat "$ZBUILD_STATE_DIR/artifacts/stage-io/plan-1.json" 2>/dev/null || echo '{}')"
assert_json_key "T32 .input == \"\"" "$t32_json" ".input" ""
assert_json_key "T32 .output == \"\"" "$t32_json" ".output" ""

# ─── T33: schema-invalid path — force jq -e validator to fail via PATH override
# We mock `jq` so that the validator (`jq -e 'has(...)'`) returns non-zero,
# while the earlier --arg jq calls in record assembly still succeed (we shim
# only the `jq -e` invocation).
_MOCK_DESTS="file"
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
: > "$ZBUILD_EVENTS_JSONL"
t33_shim_dir="$TEST_TEMP_DIR/t33-shim"
mkdir -p "$t33_shim_dir"
_real_jq="$(command -v jq)"
cat > "$t33_shim_dir/jq" <<EOF
#!/usr/bin/env bash
# Force the validation \`jq -e ...\` to fail (rc=1) so we exercise schema_invalid.
# Pass everything else through to the real jq.
for a in "\$@"; do
    if [[ "\$a" == "-e" ]]; then
        exit 1
    fi
done
exec "$_real_jq" "\$@"
EOF
chmod +x "$t33_shim_dir/jq"
_saved_path="$PATH"
PATH="$t33_shim_dir:$PATH"
set +e
capture_stage_io --stage plan --kind llm --input "i" --output "o" >/dev/null 2>&1
rc=$?
set -e
PATH="$_saved_path"
assert_eq "T33 schema-invalid validator returns rc=2" "2" "$rc"
assert_event_emitted "T33 stage.io.error event emitted on schema-invalid" "$ZBUILD_EVENTS_JSONL" "stage.io.error"

# ─── T34: missing --input only (not both) → rc=2, stderr mentions "input" ────
set +e
err34="$(capture_stage_io --stage plan --kind llm --output "o" 2>&1 1>/dev/null)"
rc=$?
set -e
assert_eq "T34 missing --input only returns rc=2" "2" "$rc"
assert_contains "T34 stderr mentions input" "$err34" "input"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
