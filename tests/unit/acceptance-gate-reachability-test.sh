#!/usr/bin/env bash
# Tests: _reachability_is_timeout_rc rc=137 classification (#1660).
# [SPEC-3] rc=137 (SIGKILL) is classified as an infrastructure timeout in the
# reachability gate, matching the negctl gate behaviour added in the same change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-reachability.sh
source "$REPO_ROOT/scripts/lib/acceptance-reachability.sh"

print_test_header "acceptance reachability — rc=137 timeout classification (#1660)"
setup_test_env "acceptance-reachability-kill"

# ── REACH-KILL-1: [SPEC-3] rc=137 (SIGKILL) classified as infra timeout ───────
# Before this change, _reachability_is_timeout_rc did not recognise rc=137. A
# process killed by SIGKILL (-k kill-after or OOM) would not be flagged as a
# timeout, leaving the flip-detection verdict wrong.
set +e; _reachability_is_timeout_rc 137; _rc_137=$?; set -e
assert_eq "[SPEC-3] _reachability_is_timeout_rc 137 → true (SIGKILL = infra timeout)" \
    "0" "$_rc_137"

# Guard: existing timeout codes must still be recognised (invariant).
set +e; _reachability_is_timeout_rc 124; _rc_124=$?; set -e
assert_eq "REACH-GUARD: _reachability_is_timeout_rc 124 → true" "0" "$_rc_124"
set +e; _reachability_is_timeout_rc 143; _rc_143=$?; set -e
assert_eq "REACH-GUARD: _reachability_is_timeout_rc 143 → true" "0" "$_rc_143"
set +e; _reachability_is_timeout_rc 1; _rc_1=$?; set -e
assert_eq "REACH-GUARD: _reachability_is_timeout_rc 1 → false" "1" "$_rc_1"

# ── REACH-KILL-2: [SPEC-3] rc=137 end-to-end through acceptance_reachability_check
# REACH-KILL-1 proves the classifier; this proves it is actually CALLED on the
# real path. A TESTFILE that exits 137 runs identically reverted and at HEAD, so
# without the classifier the run reads as "no flip" → REACHABILITY FAIL
# inert_wiring: a correct change condemned by an infrastructure kill. With it,
# the unknown verdict surfaces as ERROR timeout (infra, non-terminal per #1188).
GIT="$(command -v git)"
REPO_K="$(setup_git_temp_repo reach-repo-137)"
(
    cd "$REPO_K"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
    # References impl.sh (as a real TESTFILE for that WIRING target would) so the
    # fixture exercises the timeout path, not #1686's not-referenced pre-check.
    printf '#!/usr/bin/env bash\n# sigkill-rc fixture for impl.sh\nexit 137\n' > tests/sigkill-test.sh
    chmod +x tests/sigkill-test.sh impl.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: rc=137 fixture"
) >/dev/null 2>&1
cat > "$REPO_K/design.md" <<'EOF'
```acceptance
SPEC-1[change]: sigkill-rc fixture
WIRING:
impl.sh
TESTFILES:
tests/sigkill-test.sh
```
EOF
set +e; OUT_K="$(acceptance_reachability_check "$REPO_K/design.md" "$REPO_K" 2>/dev/null)"; set -e
assert_eq "[SPEC-3] rc=137 TESTFILE → REACHABILITY ERROR timeout:impl.sh" \
    "REACHABILITY ERROR timeout:impl.sh" "$(grep 'impl.sh' <<<"$OUT_K")"
assert_eq "[SPEC-3] rc=137 TESTFILE is not condemned as inert_wiring" \
    "" "$(grep 'inert_wiring' <<<"$OUT_K")"

# ── REACH-NOPATH-1/4: [SPEC-1]/[SPEC-4] no TESTFILE references the WIRING target ──
# #1686: a target no declared TESTFILE even mentions cannot be load-bearing —
# reverting it flips nothing, so inert_wiring (build-fixable) is the wrong signal.
GIT_NP="$(command -v git)"
REPO_NP="$(setup_git_temp_repo reach-repo-nopath)"
(
    cd "$REPO_NP"
    "$GIT_NP" checkout -q -b feature
    mkdir -p .github/workflows tests
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
    # Testfile never mentions ci.yml — nothing can load it.
    printf '#!/usr/bin/env bash\n# testfile always passes\nexit 0\n' > tests/nopath-test.sh
    chmod +x impl.sh tests/nopath-test.sh
    "$GIT_NP" add impl.sh tests/nopath-test.sh
    "$GIT_NP" commit -q -m "feat: impl only, no ci.yml change"
) >/dev/null 2>&1
cat > "$REPO_NP/design.md" <<'EOF'
```acceptance
SPEC-1[change]: wiring-not-on-path fixture
WIRING:
.github/workflows/ci.yml
TESTFILES:
tests/nopath-test.sh
```
EOF
set +e; OUT_NP="$(acceptance_reachability_check "$REPO_NP/design.md" "$REPO_NP" 2>/dev/null)"; set -e
assert_eq "[SPEC-1] no TESTFILE references the target → REACHABILITY FAIL wiring_not_on_path" \
    "REACHABILITY FAIL wiring_not_on_path .github/workflows/ci.yml" \
    "$(grep 'wiring_not_on_path\|ci.yml' <<<"$OUT_NP")"
assert_eq "[SPEC-4] wiring_not_on_path does NOT produce inert_wiring" \
    "" "$(grep 'inert_wiring' <<<"$OUT_NP")"

# ── REACH-NOPATH-6: [SPEC-1] the #1664 shape — target IS in the diff, still unloadable ─
# THE regression this issue exists for. PR #1680 changed .github/workflows/test.yml
# (+9/-2), so the target WAS in the diff; no shell testfile can load workflow YAML.
# A diff-membership predicate misses this exact case and re-emits inert_wiring.
REPO_1664="$(setup_git_temp_repo reach-repo-1664)"
(
    cd "$REPO_1664"
    "$GIT_NP" checkout -q -b feature
    mkdir -p .github/workflows docs tests
    printf 'jobs:\n  test:\n    steps:\n      - run: npm test\n' > .github/workflows/test.yml
    printf '#!/usr/bin/env bash\n# honest test — does not read the workflow yaml\nexit 0\n' \
        > tests/run-tests-parallel-test.sh
    chmod +x tests/run-tests-parallel-test.sh
    "$GIT_NP" add -A; "$GIT_NP" commit -q -m base
    # Feature commit: the workflow IS modified, exactly as in PR #1680.
    printf 'jobs:\n  test:\n    steps:\n      - run: npm test\n      - run: echo cap\n' \
        > .github/workflows/test.yml
    printf '# ADR-053 test flake policy\n' > docs/ADR-053.md
    "$GIT_NP" add -A; "$GIT_NP" commit -q -m "policy ADR + CI config"
) >/dev/null 2>&1
cat > "$REPO_1664/design.md" <<'EOF'
```acceptance
SPEC-1[change]: ADR-053 policy documented and CI caps the serial-pin list
WIRING:
.github/workflows/test.yml
TESTFILES:
tests/run-tests-parallel-test.sh
```
EOF
set +e; OUT_1664="$(acceptance_reachability_check "$REPO_1664/design.md" "$REPO_1664" 2>/dev/null)"; set -e
assert_eq "[SPEC-1] #1664 shape (target IN diff, unloadable) → wiring_not_on_path" \
    "REACHABILITY FAIL wiring_not_on_path .github/workflows/test.yml" \
    "$(grep 'wiring_not_on_path\|test.yml' <<<"$OUT_1664")"
assert_eq "[SPEC-4] #1664 shape must NOT be condemned as inert_wiring" \
    "" "$(grep 'inert_wiring' <<<"$OUT_1664")"

# ── REACH-NOPATH-5: [SPEC-5] genuine inert_wiring still fires ───────────────────
# Guard: the TESTFILE DOES reference the target (so it is loadable) but never flips
# when the target is reverted. That is the real green-but-inert case #956 built the
# gate for, and it must still route to build — not wiring_not_on_path.
REPO_INERT="$(setup_git_temp_repo reach-repo-inert)"
(
    cd "$REPO_INERT"
    "$GIT_NP" checkout -q -b feature
    mkdir -p tests
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
    # Testfile NAMES impl.sh (loadable) but its assertion never flips.
    printf '#!/usr/bin/env bash\n# references impl.sh but never asserts on it\nexit 0\n' \
        > tests/inert-test.sh
    chmod +x impl.sh tests/inert-test.sh
    "$GIT_NP" add impl.sh tests/inert-test.sh
    "$GIT_NP" commit -q -m "feat: impl + testfile that references it but never flips"
) >/dev/null 2>&1
cat > "$REPO_INERT/design.md" <<'EOF'
```acceptance
SPEC-1[change]: inert-wiring guard fixture
WIRING:
impl.sh
TESTFILES:
tests/inert-test.sh
```
EOF
set +e; OUT_INERT="$(acceptance_reachability_check "$REPO_INERT/design.md" "$REPO_INERT" 2>/dev/null)"; set -e
assert_eq "[SPEC-5] referenced target that never flips → REACHABILITY FAIL inert_wiring" \
    "REACHABILITY FAIL inert_wiring impl.sh" \
    "$(grep 'inert_wiring\|impl.sh' <<<"$OUT_INERT")"
assert_eq "[SPEC-5] wiring_not_on_path must NOT fire when a TESTFILE references the target" \
    "" "$(grep 'wiring_not_on_path' <<<"$OUT_INERT")"

cleanup_test_env
print_test_results
