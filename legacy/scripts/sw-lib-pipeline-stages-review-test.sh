#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright detect_plan_drift — Unit tests for cross-stage drift detector ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: detect_plan_drift Tests"

setup_test_env "sw-lib-pipeline-stages-review-test"
_test_cleanup_hook() { cleanup_test_env; }

# Ensure jq works
[[ -x /usr/bin/jq ]] && cp -f /usr/bin/jq "$TEST_TEMP_DIR/bin/jq" 2>/dev/null || true

# ─── Setup a real git repo with main + feature branch ─────────────────────
PROJ="$TEST_TEMP_DIR/project"
mkdir -p "$PROJ/src" "$PROJ/tests" "$PROJ/.claude/pipeline-artifacts"
ARTIFACTS_DIR="$PROJ/.claude/pipeline-artifacts"
BASE_BRANCH="main"
export BASE_BRANCH

# Initialize main with a baseline commit (nothing changed yet)
(
    cd "$PROJ"
    git init -q -b main 2>/dev/null || (git init -q && git checkout -q -b main 2>/dev/null) || git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    touch README.md
    git add -A
    git commit -q -m "init"
)

# Create feature branch to simulate pipeline work
(
    cd "$PROJ"
    git checkout -q -b feat/test-drift 2>/dev/null || true
)

# ─── Source dependencies ───────────────────────────────────────────────────
emit_event() { :; }
warn() { echo "WARN: $*" >&2; }
info() { echo "INFO: $*" >&2; }

source "$SCRIPT_DIR/lib/helpers.sh"
_PIPELINE_STAGES_REVIEW_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-stages-review.sh"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: happy path — one planned file not modified"
# ═══════════════════════════════════════════════════════════════════════════════

# Plan lists 2 files; only one will be committed on the feature branch
cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Implementation Plan

## Files to Modify

- `src/auth.js` — Add JWT validation logic
- `src/config.js` — Update configuration defaults

## Task Checklist
- [ ] Implement auth
PLAN

# Commit only auth.js on the feature branch (config.js is unmodified)
(
    cd "$PROJ"
    echo "// auth" > src/auth.js
    git add src/auth.js
    git commit -q -m "feat: add auth"
)

result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
assert_contains "Drift warning for untouched planned file" "$result" "[DRIFT-WARNING] Planned file not modified: src/config.js"
if echo "$result" | grep -q "src/auth.js"; then
    assert_fail "No false positive for modified file" "src/auth.js appeared in drift warnings"
else
    assert_pass "No false positive for modified planned file"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: no drift — all planned files modified"
# ═══════════════════════════════════════════════════════════════════════════════

# Commit the second planned file too
(
    cd "$PROJ"
    echo "// config" > src/config.js
    git add src/config.js
    git commit -q -m "feat: add config"
)

result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
if [[ -z "$result" ]]; then
    assert_pass "No drift warnings when all planned files modified"
else
    assert_fail "Should have no drift warnings" "$result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: fail-open — plan.md missing"
# ═══════════════════════════════════════════════════════════════════════════════

rm -f "$ARTIFACTS_DIR/plan.md"
result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
if [[ -z "$result" ]]; then
    assert_pass "No warnings when plan.md missing (fail-open)"
else
    assert_fail "Should return empty when plan.md missing" "$result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: fail-open — no Files to Modify section"
# ═══════════════════════════════════════════════════════════════════════════════

cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Implementation Plan

## Problem Analysis
Just a description, no files section here.

## Task Checklist
- [ ] Do something
PLAN

result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
if [[ -z "$result" ]]; then
    assert_pass "No warnings when no Files to Modify section (fail-open)"
else
    assert_fail "Should return empty when section missing" "$result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: fail-open — invalid project_root (git fails)"
# ═══════════════════════════════════════════════════════════════════════════════

cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Plan

## Files to Modify

- `src/auth.js` — something

## Notes
done
PLAN

result=$(detect_plan_drift "$ARTIFACTS_DIR" "/nonexistent/path/xyz/no/git" 2>/dev/null)
if [[ -z "$result" ]]; then
    assert_pass "No warnings when git fails (fail-open)"
else
    assert_fail "Should return empty when git fails" "$result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: fail-open — BASE_BRANCH absent (no false positives)"
# ═══════════════════════════════════════════════════════════════════════════════

# When the configured base branch doesn't exist, git diff --name-only <base>..HEAD fails.
# Falling back to git diff --name-only HEAD returns empty on a clean working tree,
# which would make every planned file appear drifted (false positive). Correct behaviour
# is fail-open: return no warnings when the base branch is absent.

cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Plan

## Files to Modify

- `src/auth.js` — something

## Notes
done
PLAN

_saved_base="${BASE_BRANCH:-main}"
BASE_BRANCH="nonexistent-branch-xyz-987"
export BASE_BRANCH
result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
BASE_BRANCH="$_saved_base"
export BASE_BRANCH

if [[ -z "$result" ]]; then
    assert_pass "No false-positive drift warnings when BASE_BRANCH branch is absent"
else
    assert_fail "Should return empty when BASE_BRANCH branch is absent (fail-open)" "$result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: multiple planned files, partial drift"
# ═══════════════════════════════════════════════════════════════════════════════

cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Plan

## Files to Modify

- `src/auth.js` — already modified (committed earlier)
- `src/config.js` — already modified (committed earlier)
- `src/missing-feature.js` — not implemented yet
- `tests/missing-feature.test.js` — test not written

## Notes
done
PLAN

result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
assert_contains "Drift warning for first missing file" "$result" "src/missing-feature.js"
assert_contains "Drift warning for second missing file" "$result" "tests/missing-feature.test.js"

missing_count=$(echo "$result" | grep -c '\[DRIFT-WARNING\]' || true)
if [[ "${missing_count:-0}" -eq 2 ]]; then
    assert_pass "Exactly 2 drift warnings for 2 unmodified planned files"
else
    assert_fail "Expected 2 drift warnings" "got ${missing_count:-0}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: case-insensitive section header"
# ═══════════════════════════════════════════════════════════════════════════════

cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Implementation Plan

## files to modify

- `src/missing-ci.js` — CI fix

## Notes
done
PLAN

result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
assert_contains "Drift warning with lowercase section header" "$result" "src/missing-ci.js"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: backtick-quoted Makefile (no . or /)"
# ═══════════════════════════════════════════════════════════════════════════════

cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Plan

## Files to Modify

- `Makefile` — update build targets

## Notes
done
PLAN

result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
assert_contains "Drift warning for backtick-quoted Makefile" "$result" "Makefile"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: whole-line match — no false positive for substring"
# ═══════════════════════════════════════════════════════════════════════════════

# Commit only src/widget.js.backup — which is a substring superset of src/widget.js.
# With grep -qF (substring match), "src/widget.js" would match "src/widget.js.backup"
# and produce a false negative (no drift warning). With grep -qxF it correctly detects drift.
(
    cd "$PROJ"
    echo "// backup" > src/widget.js.backup
    git add src/widget.js.backup
    git commit -q -m "chore: add widget backup"
)

cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Plan

## Files to Modify

- `src/widget.js` — planned file (only .backup was committed)

## Notes
done
PLAN

result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
assert_contains "Whole-line match: src/widget.js not matched by src/widget.js.backup" "$result" "src/widget.js"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: fail-open — empty artifacts_dir"
# ═══════════════════════════════════════════════════════════════════════════════

result=$(detect_plan_drift "" "$PROJ" 2>/dev/null)
if [[ -z "$result" ]]; then
    assert_pass "No warnings when artifacts_dir is empty (fail-open)"
else
    assert_fail "Should return empty when artifacts_dir is empty" "$result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: multiple backtick items per line — first file extracted"
# ═══════════════════════════════════════════════════════════════════════════════

# A bullet with two backtick-quoted tokens on the same line.
# The first (`src/first.js`) is the planned file; `utils/second.js` is incidental context.
# Only src/first.js should be checked; utils/second.js should not generate a warning.
cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Plan

## Files to Modify

- `src/first.js` — primary change, also affects `utils/second.js`

## Notes
done
PLAN

result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
assert_contains "Drift warning for first backtick-quoted file" "$result" "src/first.js"
if echo "$result" | grep -q "utils/second.js"; then
    assert_fail "No drift warning for incidental second backtick item" "utils/second.js appeared in warnings"
else
    assert_pass "No spurious drift warning for incidental second backtick item"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: root file with extension (setup.py, config.toml)"
# ═══════════════════════════════════════════════════════════════════════════════

# Files at repo root with extensions (no slash) should be checked for drift.
cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Plan

## Files to Modify

- `setup.py` — update package metadata
- `config.toml` — add new section

## Notes
done
PLAN

result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
assert_contains "Drift warning for setup.py (root file with extension)" "$result" "setup.py"
assert_contains "Drift warning for config.toml (root file with extension)" "$result" "config.toml"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: ./-prefixed paths normalised to match git output"
# ═══════════════════════════════════════════════════════════════════════════════

# Authors sometimes write - `./src/auth.js` in plan.md.
# git diff --name-only never emits the ./ prefix, so we must strip it before comparing.
cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Plan

## Files to Modify

- `./src/auth.js` — main auth module (already committed as src/auth.js)
- `./tests/auth.test.js` — unit tests (not yet committed)

## Notes
done
PLAN

# src/auth.js is already committed on the feature branch (from earlier tests).
# tests/auth.test.js has NOT been committed, so it should trigger drift.
result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
assert_contains "Drift warning for ./tests/auth.test.js after ./ strip" "$result" "tests/auth.test.js"
if echo "$result" | grep -q "src/auth.js"; then
    assert_fail "No false positive for ./src/auth.js when src/auth.js is changed" \
        "drift warning emitted for a file that was actually modified"
else
    assert_pass "No false positive for ./src/auth.js when src/auth.js is changed"
fi

# Now commit tests/auth.test.js — no drift warnings expected
(
    cd "$PROJ"
    echo "// auth tests" > tests/auth.test.js
    git add tests/auth.test.js
    git commit -q -m "test: add auth tests"
)
result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
if [[ -z "$result" ]]; then
    assert_pass "No drift when both ./-prefixed planned files are modified"
else
    assert_fail "No drift when both ./-prefixed planned files are modified" \
        "unexpected warnings: $result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: Files to Modify section present but empty (no bullets)"
# ═══════════════════════════════════════════════════════════════════════════════

# A plan.md where the "## Files to Modify" section exists but contains no
# bullet items (e.g., author added the heading but didn't list files yet).
# Expect: no drift warnings — nothing to check.
cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Plan

## Files to Modify

(no files listed yet)

## Notes
done
PLAN

result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
if [[ -z "$result" ]]; then
    assert_pass "No drift warnings when Files to Modify section has no bullet items"
else
    assert_fail "Should return empty when no bullet items in section" "$result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: h3 heading (### Files to Modify)"
# ═══════════════════════════════════════════════════════════════════════════════

# Some plan authors use h3 headings; the parser should handle this.
cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Plan

## Overview

Some context.

### Files to Modify

- `src/h3-test.js` — feature file (not committed)

## Notes
done
PLAN

result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
assert_contains "Drift warning with h3 section header" "$result" "src/h3-test.js"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: case-insensitive path match (plan Auth.js vs git auth.js)"
# ═══════════════════════════════════════════════════════════════════════════════

# Simulate macOS/Windows where git may return lowercase path but plan uses mixed-case.
# Commit auth.js (lowercase); plan lists Auth.js (different case).
# On case-insensitive filesystems these refer to the same file — should NOT drift.
(
    cd "$PROJ"
    echo "// auth v2" > src/CaseTestAuth.js
    git add src/CaseTestAuth.js
    git commit -q -m "feat: add CaseTestAuth (lowercase from git)"
)

cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Plan

## Files to Modify

- `src/casetestauth.js` — same file, different case in plan

## Notes
done
PLAN

# Plan has src/casetestauth.js (lowercase); git committed src/CaseTestAuth.js (mixed).
# grep -qixF matches case-insensitively, so no drift warning should be emitted.
if ! result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null); then
    assert_fail "Case-insensitive path comparison: function should not error"
elif [[ "$result" == *"src/casetestauth.js"* ]] || [[ "$result" == *"src/CaseTestAuth.js"* ]]; then
    assert_fail "Case-insensitive path comparison: should not flag case-only path differences as drift"
else
    assert_pass "Case-insensitive path comparison: ignores case-only path differences"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: h3 subsection within Files to Modify does not truncate"
# ═══════════════════════════════════════════════════════════════════════════════

# An h3 (###) heading inside the section must not cause early exit —
# files listed after the subsection heading must still be detected as drifted.
cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Plan

## Files to Modify

### Core Files

- `src/core.js` — core feature file (not committed)

### Test Files

- `src/core.test.js` — test file (not committed)

## Notes
done
PLAN

result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
assert_contains "h3 subsection: core file drift detected" "$result" "src/core.js"
assert_contains "h3 subsection: test file after subsection heading detected" "$result" "src/core.test.js"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_plan_drift: heading with trailing colon (## Files to Modify:)"
# ═══════════════════════════════════════════════════════════════════════════════

# Some plan authors add a trailing colon; the parser should handle this.
cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Plan

## Files to Modify:

- `src/colon-test.js` — feature file (not committed)

## Notes
done
PLAN

result=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)
assert_contains "Drift warning with trailing-colon section header" "$result" "src/colon-test.js"

# ═══════════════════════════════════════════════════════════════════════════════
# Integration Test 1: drift warnings appear in review prompt when files unmodified
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Integration: drift warnings embedded in review prompt when files unmodified"

# Plan lists a file NOT committed on the feature branch — drift expected
cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Plan

## Files to Modify

- `src/auth.js` — modified (committed earlier)
- `src/unmodified-integration.js` — NOT committed (drift expected)

## Notes
done
PLAN

_drift=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)

# Simulate the review-prompt drift section assembly (mirrors stage_review() lines 288-296)
_review_prompt=""
if [[ -n "$_drift" ]]; then
    _review_prompt="## Cross-Stage Drift Detected
The following files were planned but not modified by the build:
${_drift}
Reviewer: Verify whether these files were intentionally skipped or represent incomplete implementation."
fi

assert_contains "Drift warning in assembled review prompt" "$_review_prompt" \
    "[DRIFT-WARNING] Planned file not modified: src/unmodified-integration.js"
assert_contains "Drift section heading in review prompt" "$_review_prompt" \
    "## Cross-Stage Drift Detected"
if echo "$_review_prompt" | grep -q "src/auth.js"; then
    assert_fail "No false positive for committed file in review prompt" \
        "src/auth.js appeared in drift section"
else
    assert_pass "No false positive: committed file absent from drift section"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Integration Test 2: no drift warnings in review prompt when all planned files modified
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Integration: no drift warnings in review prompt when all planned files modified"

# Plan lists only files that ARE committed on the feature branch
cat > "$ARTIFACTS_DIR/plan.md" <<'PLAN'
# Plan

## Files to Modify

- `src/auth.js` — committed earlier (no drift expected)
- `src/config.js` — committed earlier (no drift expected)

## Notes
done
PLAN

_drift=$(detect_plan_drift "$ARTIFACTS_DIR" "$PROJ" 2>/dev/null)

_review_prompt=""
if [[ -n "$_drift" ]]; then
    _review_prompt="## Cross-Stage Drift Detected
${_drift}"
fi

if [[ -z "$_review_prompt" ]]; then
    assert_pass "Review prompt contains no drift section when all planned files modified"
else
    assert_fail "Review prompt should have no drift section when all planned files modified" \
        "$_review_prompt"
fi

print_test_results
