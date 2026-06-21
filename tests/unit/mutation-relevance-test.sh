#!/usr/bin/env bash
# Tests: scripts/run-mutation.sh — patch-vs-test relevance gate (#309)
# Verifies _check_mutation_relevance refuses mutation docs whose
# Expected failing test has no path/content link to the mutated file.
set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_REPO_ROOT="$(cd "$TEST_SCRIPT_DIR/../.." && pwd)"
# Aliases for the test-helpers harness which expects these names.
# shellcheck disable=SC2034  # SCRIPT_DIR is consumed by sourced helpers
SCRIPT_DIR="$TEST_SCRIPT_DIR"
REPO_ROOT="$TEST_REPO_ROOT"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "mutation harness relevance gate (#309)"

setup_test_env "mutation-relevance"

# Extract just the helpers from run-mutation.sh into a sub-script we can
# source. The full script has `set -euo pipefail` + a main loop with EXIT
# trap; we don't want that side-effect-on-source. We work around by sourcing
# only up to the main-loop sentinel.
HARNESS="$REPO_ROOT/scripts/run-mutation.sh"
HARNESS_SUB="$TEST_TEMP_DIR/harness-fns.sh"
# Strip the harness's top-level trap install lines — without that strip the
# source would install a trap that clobbers test-helpers.sh's cleanup_test_env
# hook (#322 review L32). The relevance helpers are the only part of
# run-mutation.sh we need here. The _restore_patches rule is retained for
# resilience (it now matches nothing — #992 replaced it with _mut_teardown).
awk '
    /^# ─── Main loop ───/ { exit }
    /^trap .*_restore_patches/ { next }
    /^trap .*_mut_teardown/ { next }
    { print }
' "$HARNESS" > "$HARNESS_SUB"

# Save the test-harness EXIT trap so we can restore it after sourcing, even
# though the awk strip above already removes the run-mutation trap install.
_PRIOR_EXIT_TRAP="$(trap -p EXIT)"

# shellcheck disable=SC1090
source "$HARNESS_SUB"

# Defensive: re-establish the prior EXIT trap in case the harness installs
# anything via other paths (e.g. via sourced helpers we don't strip).
if [[ -n "$_PRIOR_EXIT_TRAP" ]]; then
    eval "$_PRIOR_EXIT_TRAP"
fi

# The sub-script computes REPO_ROOT relative to its OWN location (the temp
# file). Override using the saved TEST_REPO_ROOT so _check_mutation_relevance
# resolves test paths against the real repo.
REPO_ROOT="$TEST_REPO_ROOT"

# ─── Test 1: real existing mutation docs are RELATED ─────────────────────────
print_test_section "1. existing mutation docs pass the relevance check"
for doc in "$REPO_ROOT"/tests/mutation/*.md; do
    set +e
    _check_mutation_relevance "$doc"
    rc=$?
    set -e
    name="$(basename "$doc")"
    if [[ $rc -eq 0 ]]; then
        assert_pass "$name: file ↔ test linkage detected"
    else
        assert_fail "$name: file ↔ test linkage detected" "rc=$rc"
    fi
done

# ─── Test 2: cross-module mismatch is REJECTED ────────────────────────────────
print_test_section "2. mismatched file/test paths are refused"
BAD_DOC="$TEST_TEMP_DIR/bad-mutation.md"
cat > "$BAD_DOC" <<'EOF'
## File
`core/router/route.sh`

## Mutation
Hypothetical mutation that swaps `return 1` to `return 0` in route.sh.

## Patch
```bash
true
```

## Expected failing test
`tests/unit/core-redaction-test.sh` — points at the WRONG module to verify (#309 catches this).

## Result
This mutation must be caught.

## Test
```bash
bash tests/unit/core-redaction-test.sh
```
EOF

set +e
_check_mutation_relevance "$BAD_DOC"
rc=$?
set -e
assert_eq "cross-module mismatch (router vs redaction test) refused" "1" "$rc"

# ─── Test 3: missing test file is REJECTED with rc=2 ─────────────────────────
print_test_section "3. missing test file refused with rc=2"
NOFILE_DOC="$TEST_TEMP_DIR/no-file-mutation.md"
cat > "$NOFILE_DOC" <<'EOF'
## File
`core/router/route.sh`

## Mutation
Whatever.

## Patch
```bash
true
```

## Expected failing test
`tests/unit/does-not-exist-test.sh`

## Result
N/A

## Test
```bash
true
```
EOF
set +e
_check_mutation_relevance "$NOFILE_DOC"
rc=$?
set -e
assert_eq "missing test file refused (rc=2)" "2" "$rc"

# ─── Test 4: same-module match is accepted (sanity) ──────────────────────────
print_test_section "4. correctly paired module/test passes"
GOOD_DOC="$TEST_TEMP_DIR/good-mutation.md"
cat > "$GOOD_DOC" <<'EOF'
## File
`core/router/route.sh`

## Mutation
N/A

## Patch
```bash
true
```

## Expected failing test
`tests/integration/core-router-route-test.sh` — directly exercises route.sh.

## Result
Caught.

## Test
```bash
true
```
EOF
set +e
_check_mutation_relevance "$GOOD_DOC"
rc=$?
set -e
assert_eq "correctly paired (router file ↔ router test) accepted" "0" "$rc"

cleanup_test_env
# print_test_results already exits with the failure count; the trailing
# `exit` was unreachable dead code (#322 review L152).
print_test_results
