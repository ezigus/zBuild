#!/usr/bin/env bash
# tests/unit/vision-admission-gate-test.sh — admission gate enforcement (ADR-049 §Phase-1.1, #1360).
#
# Covers:
#   SPEC-1  valid vision passes load+validate (rc=0)
#   SPEC-2  missing vision → load_vision_doc rc=1; absence message names three
#           search paths and contains 'zbuild vision init' hint
#   SPEC-3  malformed vision (missing ## Intent) → validate_vision_doc rc=1;
#           diagnostic names the missing section
#   SPEC-4  over-length vision → validate_vision_doc rc=1; diagnostic contains
#           overage count and '--condense' hint
#   SPEC-5  over-length diagnostic contains body word count
#   SPEC-6  over-length diagnostic reports correct overage (count − 300)
#   SPEC-7  runner exits rc=2 on missing vision when ZBUILD_VISION_GATE=enforce
#   SPEC-8  runner exits rc=2 on malformed vision when ZBUILD_VISION_GATE=enforce
#   SPEC-9  runner proceeds (rc≠2 gate-related) when ZBUILD_VISION_GATE=off
#   SPEC-10 validate_vision_doc over-length message contains 'Run: zbuild vision init --condense'
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/vision.sh
source "$REPO_ROOT/scripts/lib/vision.sh"

print_test_header "scripts/lib/vision.sh — admission gate enforcement (ADR-049 #1360)"
setup_test_env "vision-admission-gate"

# #1921 follow-up: reserved test identity (zb_test_issue). These were real
# issue numbers; a run keyed to one writes fabricated prior work onto that
# issue's state branch. Only identity positions and the strings DERIVED from
# them are swept — a bare number elsewhere is not an identity.
_ZB_ID="$(zb_test_issue)"

# ── Fixture helpers ───────────────────────────────────────────────────────────

make_valid_doc() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'EOF'
## Intent

This project gives teams a reliable way to ship software consistently.
Templates encode the delivery process once; every run reproduces it exactly.

## Principles

- Consistency through repetition — same template, same way every time.
- Flexible by composition — behavior is plugin-delivered and template-composed.
- Safety is non-negotiable — all model-bound text passes through one chokepoint.
EOF
}

make_no_intent_doc() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'EOF'
## Principles

- Consistency through repetition.
- Flexible by composition.
EOF
}

make_over_limit_doc() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    {
        printf '## Intent\n\n'
        python3 -c "print(' '.join(['word'] * 310))" 2>/dev/null \
            || printf 'word word word word word word word word word word\n%.0s' {1..31}
        printf '\n\n## Principles\n\n- principle one.\n'
    } > "$path"
}

# ── SPEC-1: valid vision passes load+validate ─────────────────────────────────
VALID_DOC="$TEST_TEMP_DIR/valid-repo/docs/VISION.md"
make_valid_doc "$VALID_DOC"

# load_vision_doc
rc=0
resolved="$(load_vision_doc "$TEST_TEMP_DIR/valid-repo" 2>&1)" || rc=$?
assert_eq "[SPEC-1] valid vision: load_vision_doc rc=0" "0" "$rc"

# validate_vision_doc
rc=0
validate_vision_doc "$VALID_DOC" >/dev/null 2>&1 || rc=$?
assert_eq "[SPEC-1] valid vision: validate_vision_doc rc=0" "0" "$rc"

# ── SPEC-2: missing vision → rc=1 + search path hint + init hint ─────────────
EMPTY_REPO="$TEST_TEMP_DIR/empty-repo"
mkdir -p "$EMPTY_REPO"

rc=0
load_vision_doc "$EMPTY_REPO" >/dev/null 2>&1 || rc=$?
assert_eq "[SPEC-2] missing vision: load_vision_doc rc=1" "1" "$rc"

# The absence message comes from the caller — runner.sh; test that the three
# search-path strings are named in what the runner emits (see SPEC-7/SPEC-8).
# Here we assert directly on load_vision_doc contract: rc=1 means absent.
# Additional human-readable hint checking is done at the runner layer (SPEC-7).
assert_eq "[SPEC-2] missing vision: rc=1 signals absence" "1" "$rc"

# Verify the three canonical paths are known to the library
assert_contains "[SPEC-2] search path 1: .zbuild/vision.md" \
    "${_VISION_SEARCH_PATHS[0]}" ".zbuild/vision.md"
assert_contains "[SPEC-2] search path 2: docs/VISION.md" \
    "${_VISION_SEARCH_PATHS[1]}" "docs/VISION.md"
assert_contains "[SPEC-2] search path 3: VISION.md" \
    "${_VISION_SEARCH_PATHS[2]}" "VISION.md"

# ── SPEC-3: doc missing ## Intent now passes validation (word-cap only) ───────
NO_INTENT="$TEST_TEMP_DIR/no-intent/vision.md"
make_no_intent_doc "$NO_INTENT"

rc=0
diag="$(validate_vision_doc "$NO_INTENT" 2>&1)" || rc=$?
assert_eq "[SPEC-3] doc missing ## Intent now passes validation (rc=0)" "0" "$rc"

# ── SPEC-4: over-length vision → rc=1 + overage count + --condense hint ──────
OVER_LIMIT="$TEST_TEMP_DIR/over-limit/vision.md"
make_over_limit_doc "$OVER_LIMIT"

rc=0
diag="$(validate_vision_doc "$OVER_LIMIT" 2>&1)" || rc=$?
assert_eq "[SPEC-4] over-length vision: rc=1" "1" "$rc"
assert_contains "[SPEC-4] over-length diagnostic contains '--condense'" "$diag" "--condense"

# ── SPEC-5: over-length diagnostic contains body word count ──────────────────
# Extract the reported word count from the diagnostic (format: "word count N exceeds")
_reported_wc=""
if [[ "$diag" =~ word\ count\ ([0-9]+)\ exceeds ]]; then
    _reported_wc="${BASH_REMATCH[1]}"
fi
if [[ -n "$_reported_wc" && "$_reported_wc" -gt 300 ]]; then
    assert_pass "[SPEC-5] over-length diagnostic contains body word count (got $_reported_wc)"
else
    assert_fail "[SPEC-5] over-length diagnostic must contain a word count > 300" \
        "parsed: '$_reported_wc' from: $diag"
fi

# ── SPEC-6: over-length diagnostic reports correct overage (count − 300) ─────
if [[ -n "$_reported_wc" ]]; then
    _expected_overage=$(( _reported_wc - 300 ))
    assert_contains "[SPEC-6] over-length diagnostic reports correct overage ($_expected_overage)" \
        "$diag" "$_expected_overage"
else
    assert_fail "[SPEC-6] cannot verify overage without parsed word count" ""
fi

# ── SPEC-10: over-length message contains 'Run: zbuild vision init --condense' ─
assert_contains "[SPEC-10] over-length message contains actionable hint" \
    "$diag" "Run: zbuild vision init --condense"

# ── SPEC-7: runner exits rc=2 on missing vision (enforce mode) ───────────────
# We test runner.sh subprocess behavior in a minimal overlay repo.
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# Set up a minimal overlay repo without a vision doc.
GATE_REPO="$(setup_git_temp_repo gate-test-repo)"
install_template_overlay "$GATE_REPO" runner-state-dir-minimal

# Stub plugins so the runner doesn't fail on missing plugins before the vision gate
GATE_PLUGINS="$TEST_TEMP_DIR/gate-plugins"
mock_plugin_factory "intake" "agent" 0 >/dev/null
mock_plugin_factory "build"  "agent" 0 >/dev/null

mkdir -p "$TEST_TEMP_DIR/gate-events"
rc=0
gate_out="$(
    cd "$GATE_REPO"
    ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/plugins" \
    ZBUILD_STATE_DIR="$TEST_TEMP_DIR/gate-state" \
    ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/gate-events" \
    ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/gate-events/events.jsonl" \
    ZBUILD_EVENTS_DB="/dev/null" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=enforce \
    bash "$RUNNER" --template runner-state-dir-minimal --issue "$_ZB_ID" 2>&1
)" || rc=$?
assert_eq "[SPEC-7] runner rc=2 on missing vision (enforce)" "2" "$rc"
assert_contains "[SPEC-7] runner names search paths in message" "$gate_out" ".zbuild/vision.md"
assert_contains "[SPEC-7] runner includes zbuild vision init hint" "$gate_out" "zbuild vision init"

# ── SPEC-8: runner exits rc=2 on malformed vision (enforce mode) ─────────────
MALFORMED_REPO="$(setup_git_temp_repo malformed-vision-repo)"
install_template_overlay "$MALFORMED_REPO" runner-state-dir-minimal
# Place an over-word-count vision doc (fails new word-cap-only validator);
# reuse the SPEC-4 fixture helper instead of a second python3 subprocess.
mkdir -p "$MALFORMED_REPO/docs"
make_over_limit_doc "$MALFORMED_REPO/docs/VISION.md"

mkdir -p "$TEST_TEMP_DIR/malformed-events"
rc=0
malformed_out="$(
    cd "$MALFORMED_REPO"
    ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/plugins" \
    ZBUILD_STATE_DIR="$TEST_TEMP_DIR/malformed-state" \
    ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/malformed-events" \
    ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/malformed-events/events.jsonl" \
    ZBUILD_EVENTS_DB="/dev/null" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=enforce \
    bash "$RUNNER" --template runner-state-dir-minimal --issue "$_ZB_ID" 2>&1
)" || rc=$?
assert_eq "[SPEC-8] runner rc=2 on malformed vision (enforce)" "2" "$rc"
assert_contains "[SPEC-8] runner message references --condense" "$malformed_out" "--condense"

# ── SPEC-9: runner proceeds when ZBUILD_VISION_GATE=off ──────────────────────
VALID_GATE_REPO="$(setup_git_temp_repo valid-gate-repo)"
install_template_overlay "$VALID_GATE_REPO" runner-state-dir-minimal

mkdir -p "$TEST_TEMP_DIR/gate-off-events"
rc=0
gate_off_out="$(
    cd "$VALID_GATE_REPO"
    ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/plugins" \
    ZBUILD_STATE_DIR="$TEST_TEMP_DIR/gate-off-state" \
    ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/gate-off-events" \
    ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/gate-off-events/events.jsonl" \
    ZBUILD_EVENTS_DB="/dev/null" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_VISION_GATE=off \
    bash "$RUNNER" --template runner-state-dir-minimal --issue "$_ZB_ID" 2>&1
)" || rc=$?
# rc=0 means the pipeline ran (and possibly succeeded); rc=2 would mean the gate fired.
# We assert rc is NOT 2 (gate did not fire on missing vision when off).
if [[ "$rc" -eq 2 ]]; then
    assert_fail "[SPEC-9] ZBUILD_VISION_GATE=off must not return rc=2 for missing vision" \
        "got rc=2, output: ${gate_off_out:0:200}"
else
    assert_pass "[SPEC-9] ZBUILD_VISION_GATE=off: runner proceeds past vision gate (rc=$rc)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
