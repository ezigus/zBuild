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

# ─── T11: stdout destination renders content (#440) ──────────────────────────
_MOCK_DESTS="stdout"
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
set +e
out11="$(capture_stage_io --stage plan --kind llm --input "i" --output "o" 2>&1)"
rc=$?
set -e
assert_eq "T11 stdout dest rc=0" "0" "$rc"
assert_contains "T11 stdout dest emits stage-io header" "$out11" "stage-io: plan"

# ─── T12: gh_comment destination silent skip when ZBUILD_ISSUE unset ─────────
_MOCK_DESTS="gh_comment"
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
unset ZBUILD_ISSUE 2>/dev/null || true
set +e
out12="$(capture_stage_io --stage plan --kind llm --input "i" --output "o" 2>&1)"
rc=$?
set -e
assert_eq "T12 gh_comment dest rc=0 (silent skip)" "0" "$rc"

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

# ═══════════════════════════════════════════════════════════════════════════
# ADR-015 v3 (#440): _stage_io_to_stdout + _stage_io_to_gh_comment renderers
# ═══════════════════════════════════════════════════════════════════════════

# Helper: build a record JSON for direct renderer testing
_t440_make_record() {
    local stage="$1" kind="$2" input="$3" output="$4"
    local exit_code="${5:-}" duration_ms="${6:-}" metadata_json="${7:-{\}}"
    jq -n \
        --arg stage "$stage" --arg kind "$kind" \
        --arg input "$input" --arg output "$output" \
        --arg exit_code "$exit_code" --arg duration_ms "$duration_ms" \
        --argjson metadata "$metadata_json" \
        '{
            schema_version: 1, run_id: "t440", stage: $stage, kind: $kind, seq: 1,
            input: $input, output: $output,
            exit_code: (if $exit_code == "" then null else ($exit_code|tonumber) end),
            duration_ms: (if $duration_ms == "" then null else ($duration_ms|tonumber) end),
            metadata: $metadata, ts: "2026-05-29T00:00:00Z"
        }'
}

# Stub template_stage_io_tail_lines + template_stage_io_redact so the renderers
# don't depend on template state. Tests override these per case.
_MOCK_TAIL=""
_MOCK_REDACT=""
template_stage_io_tail_lines() { printf '%s' "$_MOCK_TAIL"; }
template_stage_io_redact() { printf '%s' "$_MOCK_REDACT"; }

# ─── T35: stdout llm renders banner with header ──────────────────────────────
_MOCK_TAIL=""
rec35="$(_t440_make_record plan llm "prompt text" "response text" "" "2400")"
out35="$(_stage_io_to_stdout "$rec35" 2>/dev/null)"
assert_contains_regex "T35 stdout llm has header line" "$out35" "stage-io: plan \[llm\]"
assert_contains "T35 stdout llm has seq=1" "$out35" "seq=1"
assert_contains "T35 stdout llm has duration 2.4s" "$out35" "2.4s"
assert_contains "T35 stdout llm has input section" "$out35" "── input ──"
assert_contains "T35 stdout llm has output section" "$out35" "── output ──"
assert_contains "T35 stdout llm has footer" "$out35" "end stage-io: plan"

# ─── T36: stdout command shows $ <input> and exit line ───────────────────────
rec36="$(_t440_make_record build command "ls -la" "file1\nfile2" "0" "100")"
out36="$(_stage_io_to_stdout "$rec36" 2>/dev/null)"
assert_contains "T36 stdout command has \$ prefix" "$out36" '$ ls -la'
assert_contains "T36 stdout command has exit line" "$out36" "── exit: 0 ──"

# ─── T37: stdout computed shows in:/out: ─────────────────────────────────────
rec37="$(_t440_make_record intake computed "src/file.txt" "dst/file.txt" "" "")"
out37="$(_stage_io_to_stdout "$rec37" 2>/dev/null)"
assert_contains "T37 stdout computed has in:" "$out37" "in: src/file.txt"
assert_contains "T37 stdout computed has out:" "$out37" "out: dst/file.txt"

# ─── T38: stdout tail_lines default 40 when template returns empty ───────────
# Generate 50-line output; expect last 40 to appear, first 10 missing
_MOCK_TAIL=""
fifty_lines=""
for i in $(seq 1 50); do fifty_lines+="line${i}\n"; done
# Use printf to expand the \n into real newlines
fifty_lines="$(printf '%b' "$fifty_lines")"
rec38="$(_t440_make_record plan llm "in" "$fifty_lines" "" "100")"
out38="$(_stage_io_to_stdout "$rec38" 2>/dev/null)"
assert_contains "T38 stdout llm tail contains line50" "$out38" "line50"
assert_contains "T38 stdout llm tail contains line11" "$out38" "line11"
if grep -qx "line10" <<< "$out38"; then
    assert_fail "T38 stdout llm tail excludes line10" "line10 unexpectedly present"
else
    assert_pass "T38 stdout llm tail excludes line10 (default 40)"
fi

# ─── T39: stdout tail_lines custom (5) honored ───────────────────────────────
_MOCK_TAIL="5"
rec39="$(_t440_make_record plan llm "in" "$fifty_lines" "" "100")"
out39="$(_stage_io_to_stdout "$rec39" 2>/dev/null)"
assert_contains "T39 stdout tail 5 contains line50" "$out39" "line50"
assert_contains "T39 stdout tail 5 contains line46" "$out39" "line46"
if grep -qx "line45" <<< "$out39"; then
    assert_fail "T39 stdout tail 5 excludes line45" "line45 unexpectedly present"
else
    assert_pass "T39 stdout tail 5 excludes line45"
fi
_MOCK_TAIL=""

# ─── T40: stdout llm with metadata.error → FAIL ──────────────────────────────
rec40="$(_t440_make_record plan llm "in" "out" "" "100" '{"error":"timeout"}')"
out40="$(_stage_io_to_stdout "$rec40" 2>/dev/null)"
assert_contains "T40 stdout llm with error shows FAIL" "$out40" "FAIL"

# ─── T41: stdout command exit_code 0 vs 1 → OK vs FAIL ───────────────────────
rec41a="$(_t440_make_record build command "true" "" "0" "10")"
out41a="$(_stage_io_to_stdout "$rec41a" 2>/dev/null)"
assert_contains "T41a stdout command exit 0 → OK" "$out41a" " OK "
rec41b="$(_t440_make_record build command "false" "" "1" "10")"
out41b="$(_stage_io_to_stdout "$rec41b" 2>/dev/null)"
assert_contains "T41b stdout command exit 1 → FAIL" "$out41b" " FAIL "

# ─── T42: gh_comment no-op when ZBUILD_ISSUE unset ───────────────────────────
unset ZBUILD_ISSUE 2>/dev/null || true
rec42="$(_t440_make_record plan llm "i" "o" "" "100")"
# Use a gh shim that records calls
ghdir="$TEST_TEMP_DIR/gh-t42"; mkdir -p "$ghdir"
cat > "$ghdir/gh" <<EOF
#!/usr/bin/env bash
echo "GH_CALLED \$@" >> "$ghdir/calls.log"
exit 0
EOF
chmod +x "$ghdir/gh"
saved_path="$PATH"; PATH="$ghdir:$PATH"
_stage_io_to_gh_comment "$rec42" >/dev/null 2>&1
PATH="$saved_path"
if [[ -s "$ghdir/calls.log" ]]; then
    assert_fail "T42 gh not called when ZBUILD_ISSUE unset" "calls.log non-empty"
else
    assert_pass "T42 gh not called when ZBUILD_ISSUE unset"
fi

# ─── T43: gh_comment no-op when ZBUILD_OUTPUT_GH_COMMENT=0 ───────────────────
export ZBUILD_ISSUE="123"
export ZBUILD_OUTPUT_GH_COMMENT="0"
ghdir="$TEST_TEMP_DIR/gh-t43"; mkdir -p "$ghdir"
cat > "$ghdir/gh" <<EOF
#!/usr/bin/env bash
echo "GH_CALLED" >> "$ghdir/calls.log"
exit 0
EOF
chmod +x "$ghdir/gh"
saved_path="$PATH"; PATH="$ghdir:$PATH"
_stage_io_to_gh_comment "$rec42" >/dev/null 2>&1
PATH="$saved_path"
if [[ -s "$ghdir/calls.log" ]]; then
    assert_fail "T43 gh not called when ZBUILD_OUTPUT_GH_COMMENT=0" "calls.log non-empty"
else
    assert_pass "T43 gh not called when ZBUILD_OUTPUT_GH_COMMENT=0"
fi
unset ZBUILD_OUTPUT_GH_COMMENT

# ─── T44: gh_comment builds <details>/<summary>/fenced shape ─────────────────
export ZBUILD_ISSUE="123"
rec44="$(_t440_make_record plan llm "prompt body" "response body" "" "2400")"
ghdir="$TEST_TEMP_DIR/gh-t44"; mkdir -p "$ghdir"
cat > "$ghdir/gh" <<EOF
#!/usr/bin/env bash
# Capture --body argument
shift  # 'issue'
shift  # 'comment'
shift  # issue number
while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--body" ]]; then
        printf '%s' "\$2" > "$ghdir/body.txt"
        shift 2
        continue
    fi
    shift
done
exit 0
EOF
chmod +x "$ghdir/gh"
saved_path="$PATH"; PATH="$ghdir:$PATH"
# No manifest → pass-through redaction
_stage_io_to_gh_comment "$rec44" >/dev/null 2>&1
PATH="$saved_path"
body44="$(cat "$ghdir/body.txt" 2>/dev/null || echo '')"
assert_contains "T44 gh body contains <details>" "$body44" "<details>"
assert_contains "T44 gh body contains </details>" "$body44" "</details>"
assert_contains "T44 gh body contains summary OK plan llm 2.4s" "$body44" "<summary>OK stage: plan (llm, 2.4s)</summary>"
# Two fenced blocks: ```... ``` for input and output sections (stdout rendering nested)
fence_count="$(grep -c '^```' <<< "$body44" || true)"
if [[ "$fence_count" -ge 2 ]]; then
    assert_pass "T44 gh body has at least 2 fence markers"
else
    assert_fail "T44 gh body has at least 2 fence markers" "got: $fence_count"
fi

# ─── T45: body cap: 65_000-char output → ≤ 60_000 + truncated marker ─────────
# Use head -c / tr (portable) for the big payload; `printf 'X%.0s' $(seq …)`
# is not portable because the inline argv expansion can exceed Linux ARG_MAX.
# Payload sized to just-over-cap (65k > 60k) to keep CI tracing overhead bounded.
big_size=65000
big_output="$(head -c "$big_size" /dev/zero | tr '\0' 'X')"
rec45="$(_t440_make_record plan llm "short input" "$big_output" "" "100")"
ghdir="$TEST_TEMP_DIR/gh-t45"; mkdir -p "$ghdir"
cat > "$ghdir/gh" <<EOF
#!/usr/bin/env bash
shift; shift; shift
while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--body" ]]; then
        printf '%s' "\$2" > "$ghdir/body.txt"
        shift 2; continue
    fi
    shift
done
exit 0
EOF
chmod +x "$ghdir/gh"
saved_path="$PATH"; PATH="$ghdir:$PATH"
_stage_io_to_gh_comment "$rec45" >/dev/null 2>&1
PATH="$saved_path"
body45="$(cat "$ghdir/body.txt" 2>/dev/null || echo '')"
body45_size=${#body45}
if [[ "$body45_size" -le 60000 ]]; then
    assert_pass "T45 body cap ≤ 60000 (got $body45_size)"
else
    assert_fail "T45 body cap ≤ 60000" "got: $body45_size"
fi
assert_contains "T45 truncated marker present" "$body45" "[truncated"
assert_contains "T45 truncated mentions ${big_size} bytes" "$body45" "${big_size}-byte"
assert_contains "T45 truncated mentions artifact path" "$body45" "artifacts/stage-io/plan-1.json"

# ─── T46: redaction applied via scope manifest ───────────────────────────────
mkdir -p "$ZBUILD_STATE_DIR"
cat > "$ZBUILD_STATE_DIR/scope-manifest.md" <<'EOF'
+ core/
EOF
rec46="$(_t440_make_record plan llm "prompt" "see secrets/api.key for details" "" "100")"
ghdir="$TEST_TEMP_DIR/gh-t46"; mkdir -p "$ghdir"
cat > "$ghdir/gh" <<EOF
#!/usr/bin/env bash
shift; shift; shift
while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--body" ]]; then printf '%s' "\$2" > "$ghdir/body.txt"; shift 2; continue; fi
    shift
done
exit 0
EOF
chmod +x "$ghdir/gh"
saved_path="$PATH"; PATH="$ghdir:$PATH"
_stage_io_to_gh_comment "$rec46" >/dev/null 2>&1
PATH="$saved_path"
body46="$(cat "$ghdir/body.txt" 2>/dev/null || echo '')"
assert_contains "T46 body has out-of-scope-context wrapper" "$body46" "<out-of-scope-context>"

# ─── T47: redact: false opt-out for command kind ─────────────────────────────
_MOCK_REDACT="false"
rec47="$(_t440_make_record build command "grep -r secrets/api.key /etc" "found secrets/api.key" "0" "100")"
ghdir="$TEST_TEMP_DIR/gh-t47"; mkdir -p "$ghdir"
cat > "$ghdir/gh" <<EOF
#!/usr/bin/env bash
shift; shift; shift
while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--body" ]]; then printf '%s' "\$2" > "$ghdir/body.txt"; shift 2; continue; fi
    shift
done
exit 0
EOF
chmod +x "$ghdir/gh"
saved_path="$PATH"; PATH="$ghdir:$PATH"
_stage_io_to_gh_comment "$rec47" >/dev/null 2>&1
PATH="$saved_path"
body47="$(cat "$ghdir/body.txt" 2>/dev/null || echo '')"
if grep -qF '<out-of-scope-context>' <<< "$body47"; then
    assert_fail "T47 command redact:false → no redaction" "out-of-scope-context wrapper unexpectedly present"
else
    assert_pass "T47 command redact:false → no redaction wrapper"
fi
assert_contains "T47 command redact:false body has unredacted token" "$body47" "secrets/api.key"
_MOCK_REDACT=""

# ─── T48: LLM kind ignores redact:false (always redacted) ────────────────────
_MOCK_REDACT="false"
rec48="$(_t440_make_record plan llm "prompt" "see secrets/api.key here" "" "100")"
ghdir="$TEST_TEMP_DIR/gh-t48"; mkdir -p "$ghdir"
cat > "$ghdir/gh" <<EOF
#!/usr/bin/env bash
shift; shift; shift
while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--body" ]]; then printf '%s' "\$2" > "$ghdir/body.txt"; shift 2; continue; fi
    shift
done
exit 0
EOF
chmod +x "$ghdir/gh"
saved_path="$PATH"; PATH="$ghdir:$PATH"
_stage_io_to_gh_comment "$rec48" >/dev/null 2>&1
PATH="$saved_path"
body48="$(cat "$ghdir/body.txt" 2>/dev/null || echo '')"
assert_contains "T48 LLM ignores redact:false (still redacted)" "$body48" "<out-of-scope-context>"
_MOCK_REDACT=""

# ─── T49: redaction failure → drop comment + emit error event ────────────────
# Save the real function via declare -f, install a failing mock, restore later.
: > "$ZBUILD_EVENTS_JSONL"
_orig_apply_scope_redaction="$(declare -f apply_scope_redaction)"
apply_scope_redaction() { return 1; }
rec49="$(_t440_make_record plan llm "p" "o" "" "100")"
ghdir="$TEST_TEMP_DIR/gh-t49"; mkdir -p "$ghdir"
cat > "$ghdir/gh" <<EOF
#!/usr/bin/env bash
echo "GH_CALLED" >> "$ghdir/calls.log"
exit 0
EOF
chmod +x "$ghdir/gh"
saved_path="$PATH"; PATH="$ghdir:$PATH"
set +e
_stage_io_to_gh_comment "$rec49" >/dev/null 2>&1
rc49=$?
set -e
PATH="$saved_path"
assert_eq "T49 redaction failure returns 0" "0" "$rc49"
if [[ -s "$ghdir/calls.log" ]]; then
    assert_fail "T49 comment dropped on redaction failure" "gh was called"
else
    assert_pass "T49 comment dropped on redaction failure"
fi
assert_event_emitted "T49 stage.io.error redaction_failed emitted" "$ZBUILD_EVENTS_JSONL" "stage.io.error"
t49_evt="$(jq -c --arg t "stage.io.error" 'select(.type==$t)' "$ZBUILD_EVENTS_JSONL" | head -1)"
assert_contains "T49 event has redaction_failed reason" "$t49_evt" "redaction_failed"
# Restore real apply_scope_redaction from the saved declare -f snapshot.
unset -f apply_scope_redaction
eval "$_orig_apply_scope_redaction"
unset _orig_apply_scope_redaction

# ─── T50: gh post failure → emit error event, return 0 ──────────────────────
: > "$ZBUILD_EVENTS_JSONL"
rec50="$(_t440_make_record plan llm "p" "o" "" "100")"
ghdir="$TEST_TEMP_DIR/gh-t50"; mkdir -p "$ghdir"
cat > "$ghdir/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$ghdir/gh"
saved_path="$PATH"; PATH="$ghdir:$PATH"
set +e
_stage_io_to_gh_comment "$rec50" >/dev/null 2>&1
rc50=$?
set -e
PATH="$saved_path"
assert_eq "T50 gh failure returns 0" "0" "$rc50"
assert_event_emitted "T50 stage.io.error gh_comment_post_failed emitted" "$ZBUILD_EVENTS_JSONL" "stage.io.error"
t50_evt="$(jq -c --arg t "stage.io.error" 'select(.type==$t)' "$ZBUILD_EVENTS_JSONL" | head -1)"
assert_contains "T50 event has gh_comment_post_failed reason" "$t50_evt" "gh_comment_post_failed"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
