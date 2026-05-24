#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pipeline-resume test — Validate workflow shell logic         ║
# ║  Tests stage detection, DETECTED building, next-stage computation,       ║
# ║  override precedence, fallback behavior, and merge deduplication.        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.6.1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Portable equivalent of grep -oP '^\s+\K[a-z_]+(?=: complete)'
# Works on both macOS (BSD grep) and Linux (GNU grep).
extract_completed_stages() {
    local file="$1"
    grep -E '^\s+[a-z_]+: complete' "$file" \
        | sed 's/^[[:space:]]*//' \
        | sed 's/: complete$//' \
        || true
}

# Build comma-separated DETECTED string from a newline-separated list.
build_detected() {
    local stages_nl="$1"
    printf '%s' "$stages_nl" | tr '\n' ',' | sed 's/,$//;s/^,//'
}

# Walk the canonical stage list and return the first stage not in completed set.
# Args: completed_csv canonical_list (space-separated)
next_stage_after() {
    local completed_csv="$1"
    shift
    local canonical=("$@")
    local result=""
    for stage in "${canonical[@]}"; do
        if ! printf '%s' "$completed_csv" | tr ',' '\n' | grep -qxF "$stage"; then
            result="$stage"
            break
        fi
    done
    echo "${result}"
}

CANONICAL_STAGES=(intake plan design build test review compound_quality pr merge deploy validate monitor)

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/work"
    for cmd in grep sed sort tr printf wc cat; do
        command -v "$cmd" &>/dev/null && ln -sf "$(command -v "$cmd")" "$TEST_TEMP_DIR/bin/$cmd" 2>/dev/null || true
    done
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
}

_test_cleanup_hook() { cleanup_test_env; }

# ─── Setup ────────────────────────────────────────────────────────────────────
setup_env

print_test_header "pipeline-resume shell logic tests (v${VERSION})"

# ─── 1. Stage detection regex — basic happy path ─────────────────────────────
echo -e "${BOLD}  1. Stage Detection Regex${RESET}"

STATE_FILE="$TEST_TEMP_DIR/work/pipeline-state-basic.md"
cat > "$STATE_FILE" <<'EOF'
---
issue: 42
branch: feature/test
---

## Pipeline State

stages:
  intake: complete
  plan: complete
  design: complete
  build: in_progress
  test: pending
  review: pending
EOF

STAGES_NL=$(extract_completed_stages "$STATE_FILE")
assert_contains "detects 'intake' as complete" "$STAGES_NL" "intake"
assert_contains "detects 'plan' as complete" "$STAGES_NL" "plan"
assert_contains "detects 'design' as complete" "$STAGES_NL" "design"

# Negative: in_progress and pending must not appear
if printf '%s' "$STAGES_NL" | grep -qxF "build"; then
    assert_fail "does not include in_progress stage (build)" "build appeared in completed list"
else
    assert_pass "does not include in_progress stage (build)"
fi

if printf '%s' "$STAGES_NL" | grep -qxF "test"; then
    assert_fail "does not include pending stage (test)" "test appeared in completed list"
else
    assert_pass "does not include pending stage (test)"
fi

# ─── 2. Stage detection — all stages complete ─────────────────────────────────
echo ""
echo -e "${BOLD}  2. Stage Detection — All Stages Complete${RESET}"

STATE_ALL="$TEST_TEMP_DIR/work/pipeline-state-all.md"
cat > "$STATE_ALL" <<'EOF'
---
issue: 99
---
stages:
  intake: complete
  plan: complete
  design: complete
  build: complete
  test: complete
  review: complete
  compound_quality: complete
  pr: complete
  merge: complete
  deploy: complete
  validate: complete
  monitor: complete
EOF

ALL_NL=$(extract_completed_stages "$STATE_ALL")
for stage in intake plan design build test review compound_quality pr merge deploy validate monitor; do
    if printf '%s' "$ALL_NL" | grep -qxF "$stage"; then
        assert_pass "all-complete: detects '$stage'"
    else
        assert_fail "all-complete: detects '$stage'" "'$stage' not found in output"
    fi
done

# ─── 3. Stage detection — no completed stages ─────────────────────────────────
echo ""
echo -e "${BOLD}  3. Stage Detection — No Completed Stages${RESET}"

STATE_NONE="$TEST_TEMP_DIR/work/pipeline-state-none.md"
cat > "$STATE_NONE" <<'EOF'
---
issue: 7
---
stages:
  intake: in_progress
  plan: pending
  build: pending
EOF

NONE_NL=$(extract_completed_stages "$STATE_NONE")
if [[ -z "${NONE_NL// }" ]]; then
    assert_pass "no-complete state: extraction returns empty"
else
    assert_fail "no-complete state: extraction returns empty" "got: $NONE_NL"
fi

# ─── 4. DETECTED variable building from newline list ─────────────────────────
echo ""
echo -e "${BOLD}  4. DETECTED Variable Building${RESET}"

# Three stages
DETECTED=$(build_detected "$(printf 'intake\nplan\ndesign\n')")
assert_eq "three stages produce correct CSV" "intake,plan,design" "$DETECTED"

# One stage — no trailing comma
DETECTED_ONE=$(build_detected "$(printf 'intake\n')")
assert_eq "single stage: no trailing comma" "intake" "$DETECTED_ONE"

# Two stages
DETECTED_TWO=$(build_detected "$(printf 'build\ntest\n')")
assert_eq "two stages produce correct CSV" "build,test" "$DETECTED_TWO"

# No leading or trailing commas when input has no trailing newline anomaly
DETECTED_NOTRIM=$(build_detected "$(printf 'plan\ndesign')")
assert_eq "no trailing comma without trailing newline" "plan,design" "$DETECTED_NOTRIM"

# ─── 5. Next-stage computation ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  5. Next-Stage Computation${RESET}"

# After intake+plan+design completed, next should be build
NEXT=$(next_stage_after "intake,plan,design" "${CANONICAL_STAGES[@]}")
assert_eq "next stage after intake,plan,design is build" "build" "$NEXT"

# After nothing completed, next should be intake
NEXT_FIRST=$(next_stage_after "" "${CANONICAL_STAGES[@]}")
assert_eq "next stage when nothing complete is intake" "intake" "$NEXT_FIRST"

# After all stages except monitor, next should be monitor
ALL_BUT_MONITOR="intake,plan,design,build,test,review,compound_quality,pr,merge,deploy,validate"
NEXT_LAST=$(next_stage_after "$ALL_BUT_MONITOR" "${CANONICAL_STAGES[@]}")
assert_eq "next stage when all but monitor complete is monitor" "monitor" "$NEXT_LAST"

# After all stages complete, next should be empty (pipeline done)
ALL_DONE="intake,plan,design,build,test,review,compound_quality,pr,merge,deploy,validate,monitor"
NEXT_DONE=$(next_stage_after "$ALL_DONE" "${CANONICAL_STAGES[@]}")
assert_eq "next stage when all complete is empty" "" "$NEXT_DONE"

# ─── 6. Override precedence ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  6. Override Precedence${RESET}"

# Simulate the workflow logic:
#   if OVERRIDE_STAGES non-empty → DETECTED=OVERRIDE_STAGES, SOURCE="manual override"
#   else → DETECTED=<computed>, SOURCE=<something else>

compute_detected_with_override() {
    local OVERRIDE_STAGES="$1"
    local COMPUTED_STAGES="$2"
    local DETECTED SOURCE
    if [[ -n "$OVERRIDE_STAGES" ]]; then
        DETECTED="$OVERRIDE_STAGES"
        SOURCE="manual override"
    else
        DETECTED="$COMPUTED_STAGES"
        SOURCE="pipeline state"
    fi
    echo "DETECTED=$DETECTED SOURCE=$SOURCE"
}

OUT=$(compute_detected_with_override "build,test" "intake,plan")
assert_contains "override set: DETECTED uses override value" "$OUT" "DETECTED=build,test"
assert_contains "override set: SOURCE is 'manual override'" "$OUT" "SOURCE=manual override"

OUT_NO_OVERRIDE=$(compute_detected_with_override "" "intake,plan")
assert_contains "no override: DETECTED uses computed value" "$OUT_NO_OVERRIDE" "DETECTED=intake,plan"
assert_contains "no override: SOURCE is not 'manual override'" "$OUT_NO_OVERRIDE" "SOURCE=pipeline state"

# Empty string override must NOT activate override path
OUT_EMPTY=$(compute_detected_with_override "" "design,build")
assert_contains "empty override string: computed value used" "$OUT_EMPTY" "DETECTED=design,build"

# ─── 7. Fallback behavior — BRANCH_STAGES vs COMMENT_STAGES ──────────────────
echo ""
echo -e "${BOLD}  7. Fallback Behavior${RESET}"

# Simulate:
#   if BRANCH_STAGES non-empty → use BRANCH_STAGES
#   elif COMMENT_STAGES non-empty → use COMMENT_STAGES
#   else → DETECTED="" SOURCE="no completed stages found"

resolve_stages() {
    local BRANCH_STAGES="$1"
    local COMMENT_STAGES="$2"
    local DETECTED SOURCE
    if [[ -n "$BRANCH_STAGES" ]]; then
        DETECTED="$BRANCH_STAGES"
        SOURCE="branch state"
    elif [[ -n "$COMMENT_STAGES" ]]; then
        DETECTED="$COMMENT_STAGES"
        SOURCE="issue comments"
    else
        DETECTED=""
        SOURCE="no completed stages found"
    fi
    echo "DETECTED=${DETECTED} SOURCE=${SOURCE}"
}

RES=$(resolve_stages "intake,plan" "intake")
assert_contains "branch stages present: uses branch stages" "$RES" "DETECTED=intake,plan"
assert_contains "branch stages present: SOURCE is branch" "$RES" "SOURCE=branch state"

RES2=$(resolve_stages "" "intake,plan")
assert_contains "no branch stages: falls back to comment stages" "$RES2" "DETECTED=intake,plan"
assert_contains "no branch stages: SOURCE is comments" "$RES2" "SOURCE=issue comments"

RES3=$(resolve_stages "" "")
assert_contains "both empty: DETECTED is empty" "$RES3" "DETECTED= SOURCE="
assert_contains "both empty: SOURCE is no completed stages" "$RES3" "no completed stages found"

# ─── 8. Merge deduplication for auto-retry ────────────────────────────────────
echo ""
echo -e "${BOLD}  8. Merge Deduplication (auto-retry)${RESET}"

# Simulate:
#   printf '%s\n%s\n' "$RAW_STAGES" "$BRANCH_STAGES" | sort -u | grep -v '^$'

# merge_stages mirrors production line 220 of shipwright-auto-retry.yml exactly:
#   printf '%s\n%s\n' "$RAW_STAGES" "$BRANCH_STAGES" | sort -u | grep -v '^$' || true
# Both inputs must be newline-separated (as they are in the real workflow).
merge_stages() {
    local RAW_STAGES="$1"
    local BRANCH_STAGES="$2"
    printf '%s\n%s\n' "$RAW_STAGES" "$BRANCH_STAGES" \
        | sort -u \
        | grep -v '^$' \
        || true
}

# Overlapping entries — no duplicates in result (newline-separated inputs)
MERGED=$(merge_stages "$(printf 'intake\nplan\ndesign\n')" "$(printf 'intake\nplan\n')")
INTAKE_COUNT=$(printf '%s' "$MERGED" | grep -cxF "intake" || true)
assert_eq "merge: 'intake' appears exactly once" "1" "$INTAKE_COUNT"

PLAN_COUNT=$(printf '%s' "$MERGED" | grep -cxF "plan" || true)
assert_eq "merge: 'plan' appears exactly once" "1" "$PLAN_COUNT"

DESIGN_COUNT=$(printf '%s' "$MERGED" | grep -cxF "design" || true)
assert_eq "merge: 'design' included from RAW_STAGES only" "1" "$DESIGN_COUNT"

# Disjoint sets — all entries present
MERGED2=$(merge_stages "$(printf 'intake\nplan\n')" "$(printf 'design\nbuild\n')")
for s in intake plan design build; do
    if printf '%s' "$MERGED2" | grep -qxF "$s"; then
        assert_pass "merge disjoint: '$s' present in result"
    else
        assert_fail "merge disjoint: '$s' present in result" "'$s' missing from: $MERGED2"
    fi
done

# Empty RAW_STAGES — result equals BRANCH_STAGES
MERGED3=$(merge_stages "" "$(printf 'intake\nplan\n')")
if printf '%s' "$MERGED3" | grep -qxF "intake"; then
    assert_pass "merge: empty RAW uses BRANCH_STAGES (intake)"
else
    assert_fail "merge: empty RAW uses BRANCH_STAGES (intake)" "got: $MERGED3"
fi
if printf '%s' "$MERGED3" | grep -qxF "plan"; then
    assert_pass "merge: empty RAW uses BRANCH_STAGES (plan)"
else
    assert_fail "merge: empty RAW uses BRANCH_STAGES (plan)" "got: $MERGED3"
fi

# Both empty — result is empty
MERGED4=$(merge_stages "" "")
if [[ -z "$MERGED4" ]]; then
    assert_pass "merge: both empty yields empty result"
else
    assert_fail "merge: both empty yields empty result" "got: $MERGED4"
fi

# ─── 9. State file format — YAML front-matter is ignored ─────────────────────
echo ""
echo -e "${BOLD}  9. YAML Front-matter Is Not Misidentified as Stages${RESET}"

STATE_FRONTMATTER="$TEST_TEMP_DIR/work/pipeline-state-frontmatter.md"
cat > "$STATE_FRONTMATTER" <<'EOF'
---
issue: 12
branch: main
completed: true
label: complete
---

## Notes
Some note that says complete in prose.

stages:
  intake: complete
  plan: pending
EOF

FM_NL=$(extract_completed_stages "$STATE_FRONTMATTER")

# Should find intake
if printf '%s' "$FM_NL" | grep -qxF "intake"; then
    assert_pass "front-matter: intake stage detected correctly"
else
    assert_fail "front-matter: intake stage detected correctly" "intake missing from: $FM_NL"
fi

# Should NOT misidentify top-level YAML keys like 'label: complete' (not indented)
if printf '%s' "$FM_NL" | grep -qxF "label"; then
    assert_fail "front-matter: top-level 'label: complete' not mistaken for a stage" "label appeared in stages"
else
    assert_pass "front-matter: top-level 'label: complete' not mistaken for a stage"
fi

# Should NOT pick up plan (pending)
if printf '%s' "$FM_NL" | grep -qxF "plan"; then
    assert_fail "front-matter: 'plan: pending' not treated as complete" "plan appeared in stages"
else
    assert_pass "front-matter: 'plan: pending' not treated as complete"
fi

# ─── 10. Underscored stage names handled correctly ───────────────────────────
echo ""
echo -e "${BOLD}  10. Underscored Stage Names${RESET}"

STATE_UNDER="$TEST_TEMP_DIR/work/pipeline-state-underscore.md"
cat > "$STATE_UNDER" <<'EOF'
stages:
  compound_quality: complete
  pr: complete
EOF

UNDER_NL=$(extract_completed_stages "$STATE_UNDER")
if printf '%s' "$UNDER_NL" | grep -qxF "compound_quality"; then
    assert_pass "underscore stage 'compound_quality' detected"
else
    assert_fail "underscore stage 'compound_quality' detected" "got: $UNDER_NL"
fi

if printf '%s' "$UNDER_NL" | grep -qxF "pr"; then
    assert_pass "short stage 'pr' detected"
else
    assert_fail "short stage 'pr' detected" "got: $UNDER_NL"
fi

# Verify build_detected handles underscore stage names in CSV
UNDER_CSV=$(build_detected "$(printf 'compound_quality\npr\n')")
assert_eq "underscore stage preserved in CSV" "compound_quality,pr" "$UNDER_CSV"

# ─── Results ──────────────────────────────────────────────────────────────────
echo ""
print_test_results
