#!/usr/bin/env bash
# Tests: branch_numstat helper (#567) — fail-OPEN diff summary for the
# test_assessment LLM input. Returns one line "files=N add=A del=D" or
# "unknown" when no usable ref/repo is available.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "branch_numstat helper (#567)"
setup_test_env "branch-numstat"

# Function must exist
if declare -F branch_numstat >/dev/null 2>&1; then
    assert_pass "branch_numstat function is defined"
else
    assert_fail "branch_numstat function is defined" "not declared"
    print_test_results
    exit 1
fi

# ─── V1: non-git directory → unknown, rc=0 ────────────────────────────────────
mkdir -p "$TEST_TEMP_DIR/nogit"
(
    cd "$TEST_TEMP_DIR/nogit"
    out="$(branch_numstat)"
    rc=$?
    [[ $rc -eq 0 ]] || { echo "rc=$rc" >&2; exit 1; }
    [[ "$out" == *"unknown"* ]] || { echo "out=$out" >&2; exit 1; }
)
if [[ $? -eq 0 ]]; then
    assert_pass "V1 non-git dir → unknown rc=0"
else
    assert_fail "V1 non-git dir → unknown rc=0" "branch_numstat misbehaved"
fi

# ─── V2: fresh repo with 2 commits on a branch → triplet ──────────────────────
mkdir -p "$TEST_TEMP_DIR/repo"
(
    cd "$TEST_TEMP_DIR/repo"
    git init -q -b main
    git config user.email a@b
    git config user.name a
    echo "one" > a.txt
    git add a.txt
    git commit -q -m c1
    git checkout -q -b feature
    echo "two" > b.txt
    echo "three" >> a.txt
    git add a.txt b.txt
    git commit -q -m c2
    out="$(branch_numstat)"
    [[ "$out" =~ files=[0-9]+ ]] || { echo "BAD: $out" >&2; exit 1; }
    [[ "$out" =~ add=[0-9]+ ]]   || { echo "BAD: $out" >&2; exit 1; }
    [[ "$out" =~ del=[0-9]+ ]]   || { echo "BAD: $out" >&2; exit 1; }
)
if [[ $? -eq 0 ]]; then
    assert_pass "V2 feature branch → files=/add=/del= triplet"
else
    assert_fail "V2 feature branch → files=/add=/del= triplet" "missing fields"
fi

# ─── V3: on main (no diff vs main) → files=0 ─────────────────────────────────
(
    cd "$TEST_TEMP_DIR/repo"
    git checkout -q main
    out="$(branch_numstat)"
    # Either files=0 OR unknown is acceptable — both are well-formed
    if [[ "$out" == *"files=0"* || "$out" == *"unknown"* ]]; then
        exit 0
    fi
    echo "BAD: $out" >&2; exit 1
)
if [[ $? -eq 0 ]]; then
    assert_pass "V3 on main → files=0 or unknown"
else
    assert_fail "V3 on main → files=0 or unknown" "unexpected output"
fi

# ─── V4: detached HEAD → still rc=0, well-formed ──────────────────────────────
(
    cd "$TEST_TEMP_DIR/repo"
    sha="$(git rev-parse HEAD)"
    git checkout -q "$sha" 2>/dev/null
    out="$(branch_numstat)"
    rc=$?
    [[ $rc -eq 0 ]] || { echo "rc=$rc" >&2; exit 1; }
    [[ -n "$out" ]] || { echo "empty" >&2; exit 1; }
)
if [[ $? -eq 0 ]]; then
    assert_pass "V4 detached HEAD → rc=0 with non-empty output"
else
    assert_fail "V4 detached HEAD → rc=0 with non-empty output" "fail"
fi

# ─── V5: repo with no main/master AND no upstream → falls back gracefully ────
mkdir -p "$TEST_TEMP_DIR/oddrepo"
(
    cd "$TEST_TEMP_DIR/oddrepo"
    git init -q -b weirdbranch
    git config user.email a@b
    git config user.name a
    echo x > x.txt
    git add x.txt
    git commit -q -m c1
    out="$(branch_numstat)"
    rc=$?
    [[ $rc -eq 0 ]] || { echo "rc=$rc" >&2; exit 1; }
    # Acceptable: triplet OR unknown
    [[ "$out" =~ files= || "$out" == *"unknown"* ]] || { echo "BAD: $out" >&2; exit 1; }
)
if [[ $? -eq 0 ]]; then
    assert_pass "V5 no main/master → falls back to HEAD~ or unknown"
else
    assert_fail "V5 no main/master → falls back to HEAD~ or unknown" "fail"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
