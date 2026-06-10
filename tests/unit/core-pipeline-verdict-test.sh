#!/usr/bin/env bash
# Tests: core/pipeline/verdict.sh — verdict-driven stage indicator resolver (#507).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/verdict — runner_read_stage_verdict (#507)"
setup_test_env "pipeline-verdict"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"

STATE_DIR="$TEST_TEMP_DIR/state"
ART_DIR="$STATE_DIR/artifacts"
mkdir -p "$ART_DIR"

_make_manifest() {
    # _make_manifest <dir> <id> <output_path> <output_id> [type=json]
    local dir="$1" id="$2" path="$3" out_id="${4:-out}" type="${5:-json}"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: $id
kind: tool
version: 0.0.1
hooks:
  run: ${id}_run
requires:
  core: [event-bus]
inputs: []
outputs:
  - id: $out_id
    path: $path
    type: $type
    required: true
    primary: true
EOF
}

# ─── Test: verdict_classify pure mapping ─────────────────────────────────────
print_test_section "verdict_classify table"
for pair in "pass:pass" "approve:pass" "request_changes:warn" \
            "incomplete:warn" \
            "fail:fail" "error:fail" "block:fail" "scope_violation:fail" \
            ":unknown" "weird:unknown"; do
    raw="${pair%%:*}"; want="${pair##*:}"
    got="$(verdict_classify "$raw")"
    assert_eq "verdict_classify($raw) -> $want" "$want" "$got"
done

# ─── Test: rc != 0 always wins ───────────────────────────────────────────────
print_test_section "rc != 0 overrides verdict"
m_dir="$TEST_TEMP_DIR/plugins/test"
_make_manifest "$m_dir" "test" "${ART_DIR}/test-results.json" "test_results"
printf '%s' '{"verdict":"pass"}' > "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$m_dir/manifest.yaml" "test" 1)"
assert_eq "rc=1 forces fail even when verdict=pass" "fail" "$got"

# ─── Test: test verdict pass / fail / error ──────────────────────────────────
print_test_section "test plugin verdict mapping"
printf '%s' '{"verdict":"pass"}' > "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$m_dir/manifest.yaml" "test" 0)"
assert_eq "test verdict=pass -> pass" "pass" "$got"

printf '%s' '{"verdict":"fail"}' > "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$m_dir/manifest.yaml" "test" 0)"
assert_eq "test verdict=fail -> fail" "fail" "$got"

printf '%s' '{"verdict":"error"}' > "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$m_dir/manifest.yaml" "test" 0)"
# #550: structural-failure raw verdicts pass through unclassified so the
# cycle blocked predicate can distinguish them from generic "fail".
assert_eq "test verdict=error -> error (pass-through #550)" "error" "$got"

printf '%s' '{"verdict":"corrupt_diff","reason":"diff_apply_failed"}' > "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$m_dir/manifest.yaml" "test" 0)"
assert_eq "test verdict=corrupt_diff -> corrupt_diff (pass-through #550)" "corrupt_diff" "$got"

# ─── Test: review verdicts ───────────────────────────────────────────────────
print_test_section "review plugin verdict mapping"
r_dir="$TEST_TEMP_DIR/plugins/review"
_make_manifest "$r_dir" "review" "${ART_DIR}/review.json" "review"
printf '%s' '{"verdict":"approve"}' > "$ART_DIR/review.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$r_dir/manifest.yaml" "review" 0)"
assert_eq "review verdict=approve -> pass" "pass" "$got"

printf '%s' '{"verdict":"request_changes"}' > "$ART_DIR/review.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$r_dir/manifest.yaml" "review" 0)"
assert_eq "review verdict=request_changes -> warn" "warn" "$got"

printf '%s' '{"verdict":"block"}' > "$ART_DIR/review.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$r_dir/manifest.yaml" "review" 0)"
# #550: block is a structural-failure class — passes through unclassified.
assert_eq "review verdict=block -> block (pass-through #550)" "block" "$got"

# ─── Test: build verdict via .scope_violation (legacy) and .verdict ──────────
print_test_section "build plugin verdict derivation"
b_dir="$TEST_TEMP_DIR/plugins/build"
_make_manifest "$b_dir" "build" "${ART_DIR}/build-summary.json" "build_summary"

printf '%s' '{"scope_violation":false}' > "$ART_DIR/build-summary.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$b_dir/manifest.yaml" "build" 0)"
assert_eq "build scope_violation=false -> pass" "pass" "$got"

printf '%s' '{"scope_violation":true}' > "$ART_DIR/build-summary.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$b_dir/manifest.yaml" "build" 0)"
assert_eq "build scope_violation=true -> fail" "fail" "$got"

printf '%s' '{"verdict":"pass","scope_violation":false}' > "$ART_DIR/build-summary.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$b_dir/manifest.yaml" "build" 0)"
assert_eq "build .verdict=pass -> pass" "pass" "$got"

# #550: build corrupt_diff also passes through (structural-failure class).
printf '%s' '{"verdict":"corrupt_diff","scope_violation":false}' > "$ART_DIR/build-summary.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$b_dir/manifest.yaml" "build" 0)"
assert_eq "build .verdict=corrupt_diff -> corrupt_diff (pass-through #550)" "corrupt_diff" "$got"

printf '%s' '{"verdict":"error"}' > "$ART_DIR/build-summary.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$b_dir/manifest.yaml" "build" 0)"
assert_eq "build .verdict=error -> error (pass-through #550)" "error" "$got"

# ─── Test: plan (no .verdict field) falls back to pass when present ──────────
print_test_section "plan plugin no .verdict field -> pass"
p_dir="$TEST_TEMP_DIR/plugins/plan"
_make_manifest "$p_dir" "plan" "${ART_DIR}/plan.json" "plan"
printf '%s' '{"steps":[]}' > "$ART_DIR/plan.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$p_dir/manifest.yaml" "plan" 0)"
assert_eq "plan present, no .verdict -> pass" "pass" "$got"

# ─── Test: missing artifact -> warn + stage.verdict.missing event ────────────
print_test_section "missing primary artifact emits stage.verdict.missing"
: > "$ZBUILD_EVENTS_JSONL"
rm -f "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$m_dir/manifest.yaml" "test" 0)"
assert_eq "missing artifact -> warn" "warn" "$got"
miss_count=$(grep -c '"stage.verdict.missing"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
[[ "$miss_count" -ge 1 ]] \
    && assert_pass "stage.verdict.missing emitted on absent artifact" \
    || assert_fail "stage.verdict.missing emitted on absent artifact" "got $miss_count"

# ─── Test: malformed JSON -> warn + event ────────────────────────────────────
print_test_section "malformed JSON primary -> warn"
: > "$ZBUILD_EVENTS_JSONL"
printf '%s' 'not-json{{{' > "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$m_dir/manifest.yaml" "test" 0)"
assert_eq "malformed JSON -> warn" "warn" "$got"
malformed_count=$(grep -c '"stage.verdict.missing"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
[[ "$malformed_count" -ge 1 ]] \
    && assert_pass "stage.verdict.missing emitted on malformed JSON" \
    || assert_fail "stage.verdict.missing emitted on malformed JSON" "got $malformed_count"

# ─── Test: non-JSON primary (e.g. pr-url.txt) -> presence = pass ─────────────
print_test_section "non-JSON primary path -> presence = pass"
pr_dir="$TEST_TEMP_DIR/plugins/pr"
_make_manifest "$pr_dir" "pr" "${ART_DIR}/pr-url.txt" "pr_url" "pr-url.txt"
printf 'https://example/pr/1\n' > "$ART_DIR/pr-url.txt"
got="$(runner_read_stage_verdict "$STATE_DIR" "$pr_dir/manifest.yaml" "pr" 0)"
assert_eq "non-JSON primary present -> pass" "pass" "$got"

# ─── Test: no manifest -> unknown (contract-bypass display path) ─────────────
print_test_section "no manifest -> unknown"
got="$(runner_read_stage_verdict "$STATE_DIR" "" "ghost" 0)"
assert_eq "absent manifest -> unknown" "unknown" "$got"

# ─── Test: manifest without primary -> pass (rc-fallback) ────────────────────
print_test_section "manifest without primary -> pass on rc=0"
np_dir="$TEST_TEMP_DIR/plugins/noprim"
mkdir -p "$np_dir"
cat > "$np_dir/manifest.yaml" <<'EOF'
id: noprim
name: noprim
kind: tool
version: 0.0.1
hooks:
  run: noprim_run
requires:
  core: [event-bus]
inputs: []
outputs:
  - id: foo
    path: /tmp/foo
    type: x
    required: true
EOF
got="$(runner_read_stage_verdict "$STATE_DIR" "$np_dir/manifest.yaml" "noprim" 0)"
assert_eq "no primary declared, rc=0 -> pass" "pass" "$got"

# ─── Test: verdict_glyph + verdict_color non-empty ───────────────────────────
print_test_section "glyph + color tables"
assert_eq "glyph pass" "✓" "$(verdict_glyph pass)"
assert_eq "glyph warn" "⚠" "$(verdict_glyph warn)"
assert_eq "glyph fail" "✗" "$(verdict_glyph fail)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
