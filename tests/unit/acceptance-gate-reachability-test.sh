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
    printf '#!/usr/bin/env bash\n# sigkill-rc fixture\nexit 137\n' > tests/sigkill-test.sh
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

# ── REACH-NOPATH-1/4: [SPEC-1]/[SPEC-4] WIRING target not in changed_files ───────
# Before this change, a WIRING target absent from the diff caused a worktree run
# whose testfile could never flip (target == baseline == HEAD), producing
# REACHABILITY FAIL inert_wiring — a misleading signal that blamed the test suite
# for a design error. After this change the distinct wiring_not_on_path class fires
# and inert_wiring is absent.
GIT_NP="$(command -v git)"
REPO_NP="$(setup_git_temp_repo reach-repo-nopath)"
(
    cd "$REPO_NP"
    "$GIT_NP" checkout -q -b feature
    mkdir -p .github/workflows tests
    # Commit only impl.sh — ci.yml is NOT in this commit's diff.
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
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
assert_eq "[SPEC-1] WIRING target not in diff → REACHABILITY FAIL wiring_not_on_path" \
    "REACHABILITY FAIL wiring_not_on_path .github/workflows/ci.yml" \
    "$(grep 'wiring_not_on_path\|ci.yml' <<<"$OUT_NP")"
assert_eq "[SPEC-4] wiring_not_on_path does NOT produce inert_wiring" \
    "" "$(grep 'inert_wiring' <<<"$OUT_NP")"

# ── REACH-NOPATH-5: [SPEC-5] genuine inert_wiring still fires when target IS in diff ─
# Guard: when the WIRING target IS in the diff (file changed in this commit) but
# the testfile never flips, the existing inert_wiring class must still fire — not
# wiring_not_on_path. This ensures the new pre-check does not suppress the
# load-bearing reachability signal for actual wiring changes.
REPO_INERT="$(setup_git_temp_repo reach-repo-inert)"
(
    cd "$REPO_INERT"
    "$GIT_NP" checkout -q -b feature
    mkdir -p .github/workflows tests
    # Commit BOTH impl.sh AND .github/workflows/ci.yml — ci.yml IS in the diff.
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
    printf 'on: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps: []\n' \
        > .github/workflows/ci.yml
    printf '#!/usr/bin/env bash\n# testfile always passes — never flips\nexit 0\n' \
        > tests/inert-test.sh
    chmod +x impl.sh tests/inert-test.sh
    "$GIT_NP" add impl.sh .github/workflows/ci.yml tests/inert-test.sh
    "$GIT_NP" commit -q -m "feat: impl + ci.yml changed (wiring IS in diff)"
) >/dev/null 2>&1
cat > "$REPO_INERT/design.md" <<'EOF'
```acceptance
SPEC-1[change]: inert-wiring guard fixture
WIRING:
.github/workflows/ci.yml
TESTFILES:
tests/inert-test.sh
```
EOF
set +e; OUT_INERT="$(acceptance_reachability_check "$REPO_INERT/design.md" "$REPO_INERT" 2>/dev/null)"; set -e
assert_eq "[SPEC-5] target IS in diff but no flip → REACHABILITY FAIL inert_wiring (not wiring_not_on_path)" \
    "REACHABILITY FAIL inert_wiring .github/workflows/ci.yml" \
    "$(grep 'inert_wiring\|ci.yml' <<<"$OUT_INERT")"
assert_eq "[SPEC-5] wiring_not_on_path must NOT fire when target is in diff" \
    "" "$(grep 'wiring_not_on_path' <<<"$OUT_INERT")"

cleanup_test_env
print_test_results
