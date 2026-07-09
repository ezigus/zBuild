#!/usr/bin/env bash
# Tests: scripts/lib/impact-prefilter.sh — deterministic scope prefilter (#781).
#
# Pinned assertions (TDD red→green for #781):
#   S1: _impact_detect_shape_change — standard.yaml in plan → rc=0
#   S2: _impact_detect_shape_change — only plugin file in plan → rc=1
#   S3: _impact_detect_shape_change — empty plan → rc=1
#   S4: _impact_detect_shape_change — uses jq on steps[].files[] (not fictional plan.files[])
#
#   P1: _impact_parse_shape_counts — flow:7 entries → "7"
#   P2: _impact_parse_shape_counts — both flow + stages → unique counts
#   P3: _impact_parse_shape_counts — missing file → empty (no error)
#
#   G1: _impact_grep_numeric_candidates — 7 matches "expect_label build 7"
#   G2: _impact_grep_numeric_candidates — 7 does NOT match "sleep 7" / "port 7777"
#   G3: _impact_grep_numeric_candidates — excludes files in step_files_csv
#   G4: _impact_grep_numeric_candidates — zero matches → empty + rc=0 under set -e
#
#   O1: _impact_list_event_goldens — finds tests/golden/**/event-sequence.golden
#   O2: _impact_list_event_goldens — missing dir → empty + rc=0
#
#   X1: _impact_scope_prefilter — non-shape plan → "[]"
#   X2: _impact_scope_prefilter — #754-shape plan surfaces numeric + golden candidates
#   X3: _impact_scope_prefilter — produces valid JSON under set -euo pipefail with zero matches
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "impact prefilter — deterministic scope prefilter (#781)"
setup_test_env "impact-prefilter"

# Source the library under test.
# shellcheck source=../../scripts/lib/impact-prefilter.sh
source "$REPO_ROOT/scripts/lib/impact-prefilter.sh"

# ─── Build a synthetic repo root for isolated tests ─────────────────────────
FAKE_ROOT="$TEST_TEMP_DIR/fake-repo"
mkdir -p "$FAKE_ROOT/config/templates" "$FAKE_ROOT/tests/golden/full-pipeline" "$FAKE_ROOT/tests/golden/parity"

# Synthetic shape-change-paths.txt mirroring real one.
cat > "$FAKE_ROOT/config/shape-change-paths.txt" <<'PATHS'
# test fixture
config/templates/*.yaml
core/pipeline/template.sh
core/pipeline/runner.sh
config/event-schema.json
PATHS

# Synthetic standard.yaml with flow:7 entries.
cat > "$FAKE_ROOT/config/templates/simple.yaml" <<'YAML'
flow:
  - intake
  - plan
  - design_impact_cycle
  - build_review_cycle
  - extra1
  - extra2
  - extra3

intake:
  gate: auto
YAML

# Synthetic tests/ with target hits + adversarial negatives.
mkdir -p "$FAKE_ROOT/tests/integration" "$FAKE_ROOT/tests/unit"
cat > "$FAKE_ROOT/tests/integration/runner-test.sh" <<'T'
#!/usr/bin/env bash
# pipeline has 7 stages
assert_eq "expect_label build 7" "$got" "7"
T
cat > "$FAKE_ROOT/tests/unit/adversarial-test.sh" <<'T'
#!/usr/bin/env bash
sleep 7
port=7777
retries=7
# 7 things to do
T
cat > "$FAKE_ROOT/tests/integration/cardinal-test.sh" <<'T'
#!/usr/bin/env bash
# flow stage cardinal at 7
expect_label_stage 7
T

# Synthetic golden snapshots.
echo "intake.start" > "$FAKE_ROOT/tests/golden/full-pipeline/event-sequence.golden"
echo "intake.start" > "$FAKE_ROOT/tests/golden/parity/event-sequence.golden"

# ─── S: detect_shape_change ──────────────────────────────────────────────────
PLAN_SHAPE='{"steps":[{"id":"s1","files":["config/templates/simple.yaml"]}]}'
PLAN_NONSHAPE='{"steps":[{"id":"s1","files":["plugins/agent/foo/plugin.sh"]}]}'
PLAN_EMPTY='{"steps":[]}'

set +e
_impact_detect_shape_change "$PLAN_SHAPE" "$FAKE_ROOT"; rc=$?; set -e
assert_eq "S1: shape plan → rc=0" "0" "$rc"

set +e
_impact_detect_shape_change "$PLAN_NONSHAPE" "$FAKE_ROOT"; rc=$?; set -e
assert_eq "S2: non-shape plan → rc=1" "1" "$rc"

set +e
_impact_detect_shape_change "$PLAN_EMPTY" "$FAKE_ROOT"; rc=$?; set -e
assert_eq "S3: empty plan → rc=1" "1" "$rc"

# S4: plan with fictional plan.files[] (not real schema) must not match.
PLAN_FICTIONAL='{"files":["config/templates/simple.yaml"]}'
set +e
_impact_detect_shape_change "$PLAN_FICTIONAL" "$FAKE_ROOT"; rc=$?; set -e
assert_eq "S4: fictional plan.files[] → rc=1 (uses steps[].files[] only)" "1" "$rc"

# ─── P: parse_shape_counts ───────────────────────────────────────────────────
out="$(_impact_parse_shape_counts "$FAKE_ROOT/config/templates/simple.yaml")"
assert_eq "P1: flow:7 entries → '7'" "7" "$out"

# Dual-shape: both flow and stages declared.
cat > "$FAKE_ROOT/config/templates/dual.yaml" <<'YAML'
flow:
  - a
  - b
  - c
stages:
  - x
  - y
YAML
out="$(_impact_parse_shape_counts "$FAKE_ROOT/config/templates/dual.yaml" | sort | tr '\n' ',')"
assert_eq "P2: dual-shape flow+stages → 2,3" "2,3," "$out"

out="$(_impact_parse_shape_counts "$FAKE_ROOT/does-not-exist.yaml")"
assert_eq "P3: missing file → empty" "" "$out"

# ─── G: grep_numeric_candidates ──────────────────────────────────────────────
out="$(_impact_grep_numeric_candidates "7" "$FAKE_ROOT/tests" "")"
case "$out" in
    *"runner-test.sh"*)
        assert_pass "G1: 7 matches 'pipeline has 7 stages' in runner-test.sh" ;;
    *)
        assert_fail "G1: 7 should match runner-test.sh; got: $out" ;;
esac
case "$out" in
    *"adversarial-test.sh"*)
        assert_fail "G2: 7 should NOT match adversarial fixture (sleep/port/retries)" ;;
    *)
        assert_pass "G2: 7 does NOT match adversarial fixture" ;;
esac

# G3: excluded via step_files_csv.
out="$(_impact_grep_numeric_candidates "7" "$FAKE_ROOT/tests" "tests/integration/runner-test.sh")"
case "$out" in
    *"runner-test.sh"*)
        assert_fail "G3: runner-test.sh should be excluded via step_files_csv" ;;
    *)
        assert_pass "G3: step_files_csv excludes named file" ;;
esac

# G4: zero matches under set -euo pipefail (no exit 1).
set +e
out="$(_impact_grep_numeric_candidates "99999" "$FAKE_ROOT/tests" ""; echo "RC=$?")"
set -e
case "$out" in
    *"RC=0"*) assert_pass "G4: zero-match grep returns rc=0 under set -e" ;;
    *) assert_fail "G4: zero-match should rc=0; got: $out" ;;
esac

# ─── O: list_event_goldens ───────────────────────────────────────────────────
out="$(_impact_list_event_goldens "$FAKE_ROOT/tests" | sort | tr '\n' ',')"
assert_eq "O1: enumerates both goldens" \
    "tests/golden/full-pipeline/event-sequence.golden,tests/golden/parity/event-sequence.golden," \
    "$out"

set +e
out="$(_impact_list_event_goldens "$FAKE_ROOT/does-not-exist"; echo "RC=$?")"
set -e
case "$out" in
    *"RC=0"*) assert_pass "O2: missing tests root → rc=0 (no error)" ;;
    *) assert_fail "O2: missing root should rc=0; got: $out" ;;
esac

# ─── X: scope_prefilter orchestrator ────────────────────────────────────────
out="$(_impact_scope_prefilter "$PLAN_NONSHAPE" "$FAKE_ROOT")"
assert_eq "X1: non-shape plan → empty JSON array" "[]" "$out"

PLAN_754='{"steps":[{"id":"step-1","files":["config/templates/simple.yaml","plugins/agent/design/plugin.sh"]}]}'
out="$(_impact_scope_prefilter "$PLAN_754" "$FAKE_ROOT")"
# Should be valid JSON array.
echo "$out" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1
case "$?" in
    0) assert_pass "X2: #754-shape produces non-empty JSON array" ;;
    *) assert_fail "X2: expected non-empty JSON array; got: $out" ;;
esac
# Must contain at least one shape-change-golden source entry.
case "$out" in
    *'"source": "shape-change-golden"'*|*'"source":"shape-change-golden"'*)
        assert_pass "X2: includes shape-change-golden source entry" ;;
    *)
        assert_fail "X2: missing shape-change-golden source entry: $out" ;;
esac
# Must reference both event-sequence goldens.
case "$out" in
    *"full-pipeline/event-sequence.golden"*)
        assert_pass "X2: forced gap names full-pipeline golden" ;;
    *)
        assert_fail "X2: missing full-pipeline golden in output" ;;
esac

# X3: prefilter must produce valid JSON under set -euo pipefail.
set +e
out="$(_impact_scope_prefilter "$PLAN_NONSHAPE" "$FAKE_ROOT"; echo "RC=$?")"
set -e
case "$out" in
    *"RC=0"*) assert_pass "X3: non-shape orchestrator returns rc=0 under set -e" ;;
    *) assert_fail "X3: orchestrator should rc=0; got: $out" ;;
esac

cleanup_test_env
print_test_results
exit $((FAIL > 0))
