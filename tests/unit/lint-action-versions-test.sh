#!/usr/bin/env bash
# tests/unit/lint-action-versions-test.sh — action-version drift guard (#1459).
#
# Verifies scripts/lib/lint-action-versions.sh:
#   SPEC-1: same action at two different major versions → rc=1, names the action
#   SPEC-2: all actions at a single consistent major version → rc=0
#   SPEC-3: exits 0 against the real .github/workflows/ tree (no current drift)
#   SPEC-4: package.json wires lint-action-versions.sh into npm run lint
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/lib/lint-action-versions.sh — action-version drift guard (#1459)"
setup_test_env "lint-action-versions"

CHECKER="$REPO_ROOT/scripts/lib/lint-action-versions.sh"

# Build a minimal fixture workflow tree two levels up from where the checker
# will be copied, so _REPO_ROOT resolution inside the script reaches our temp
# tree rather than the real repo.
build_fixture_repo() {
    local root="$1"
    mkdir -p "$root/scripts/lib" "$root/.github/workflows"
    cp "$CHECKER" "$root/scripts/lib/lint-action-versions.sh"
}

# --- SPEC-1: version drift → rc=1, names the drifting action -----------------
FX_DRIFT="$TEST_TEMP_DIR/drift"
build_fixture_repo "$FX_DRIFT"
cat > "$FX_DRIFT/.github/workflows/a.yml" <<'EOF'
jobs:
  build:
    steps:
      - uses: actions/checkout@v3
EOF
cat > "$FX_DRIFT/.github/workflows/b.yml" <<'EOF'
jobs:
  deploy:
    steps:
      - uses: actions/checkout@v7
EOF
rc=0
out="$(bash "$FX_DRIFT/scripts/lib/lint-action-versions.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-1] version drift exits 1" "1" "$rc"
assert_contains "[SPEC-1] diagnostic names the drifting action" "$out" "actions/checkout"

# --- SPEC-2: no drift → rc=0 -------------------------------------------------
FX_CLEAN="$TEST_TEMP_DIR/clean"
build_fixture_repo "$FX_CLEAN"
cat > "$FX_CLEAN/.github/workflows/a.yml" <<'EOF'
jobs:
  build:
    steps:
      - uses: actions/checkout@v7
      - uses: actions/upload-artifact@v4
EOF
cat > "$FX_CLEAN/.github/workflows/b.yml" <<'EOF'
jobs:
  deploy:
    steps:
      - uses: actions/checkout@v7
      - uses: actions/upload-artifact@v4
EOF
rc=0
out="$(bash "$FX_CLEAN/scripts/lib/lint-action-versions.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-2] no drift exits 0" "0" "$rc"

# --- Extra: SHA-pinned refs compared as-is (unexercised by SPEC-1..4) --------
# Addresses a review finding: the SHA branch (_major="$_ref" verbatim, script
# line ~67) had no test coverage. Two different SHA pins of the same action
# must be flagged as drift; the identical SHA in two files must not.
FX_SHA_DRIFT="$TEST_TEMP_DIR/sha-drift"
build_fixture_repo "$FX_SHA_DRIFT"
cat > "$FX_SHA_DRIFT/.github/workflows/a.yml" <<'EOF'
jobs:
  build:
    steps:
      - uses: actions/checkout@a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2
EOF
cat > "$FX_SHA_DRIFT/.github/workflows/b.yml" <<'EOF'
jobs:
  deploy:
    steps:
      - uses: actions/checkout@f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5
EOF
rc=0
out="$(bash "$FX_SHA_DRIFT/scripts/lib/lint-action-versions.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-1] two different SHA pins of the same action → rc=1" "1" "$rc"
assert_contains "[SPEC-1] diagnostic names the SHA-drifting action" "$out" "actions/checkout"

FX_SHA_CLEAN="$TEST_TEMP_DIR/sha-clean"
build_fixture_repo "$FX_SHA_CLEAN"
cat > "$FX_SHA_CLEAN/.github/workflows/a.yml" <<'EOF'
jobs:
  build:
    steps:
      - uses: actions/checkout@a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2
EOF
cat > "$FX_SHA_CLEAN/.github/workflows/b.yml" <<'EOF'
jobs:
  deploy:
    steps:
      - uses: actions/checkout@a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2
EOF
rc=0
out="$(bash "$FX_SHA_CLEAN/scripts/lib/lint-action-versions.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-2] identical SHA pin of the same action in two files → rc=0" "0" "$rc"

# --- SPEC-3: real repo has no current drift (guard) --------------------------
rc=0
out="$(bash "$CHECKER" 2>&1)" || rc=$?
assert_eq "[SPEC-3] real .github/workflows/ has no version drift (rc=0)" "0" "$rc"

# --- SPEC-4: package.json wires the checker into npm run lint ----------------
pkg_lint="$(jq -r '.scripts.lint // ""' "$REPO_ROOT/package.json")"
assert_contains "[SPEC-4] package.json wires lint-action-versions.sh" \
    "$pkg_lint" "lint-action-versions.sh"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
