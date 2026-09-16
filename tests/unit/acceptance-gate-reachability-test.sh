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

# ── REACH-NOPATH-1/4: [SPEC-1]/[SPEC-4] WIRING target absent from this commit's diff ─
# #1686: a target not changed here cannot flip when reverted, so inert_wiring
# (build-fixable) is the wrong signal — design named an unrelated file.
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
assert_eq "[SPEC-1] target absent from diff → REACHABILITY FAIL wiring_not_on_path" \
    "REACHABILITY FAIL wiring_not_on_path .github/workflows/ci.yml" \
    "$(grep 'wiring_not_on_path\|ci.yml' <<<"$OUT_NP")"
assert_eq "[SPEC-4] wiring_not_on_path does NOT produce inert_wiring" \
    "" "$(grep 'inert_wiring' <<<"$OUT_NP")"

# ── REACH-NOPATH-5: [SPEC-5] genuine inert_wiring still fires when target IS in diff ─
# Guard: a target changed in this commit whose revert flips no testfile is the real
# green-but-inert case (#956) and must still route to build, not to design.
#
# KNOWN GAP (#1711): the #1664 shape — .github/workflows/test.yml WAS in PR #1680's
# diff (+9/-2) yet no shell testfile can load workflow YAML — also lands here, as
# inert_wiring. Statically it is indistinguishable from the fixture below: both are
# "a file in the diff that no test exercises". Separating them needs build to
# attempt a fix and fail, not a static rule. Tracked in #1711.
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

# ═══ #2109 — reachability says what actually happened ═══════════════════════
_mk_reach_repo() {  # <name> <testfile-body> [head-impl-body] → prints repo path
    local r; r="$(setup_git_temp_repo "$1")"
    (
        cd "$r"
        "$GIT" checkout -q -b feature
        mkdir -p tests
        printf '%s\n' "${3:-#!/usr/bin/env bash
my_feature() { return 0; }}" > impl.sh
        printf '%s\n' "$2" > tests/t-test.sh
        chmod +x impl.sh tests/t-test.sh
        "$GIT" add -A; "$GIT" commit -q -m "feat"
    ) >/dev/null 2>&1
    printf '%s' "$r"
}
_design1() { cat > "$1/design.md" <<'EOF'
```acceptance
SPEC-1[change]: my_feature exists
WIRING:
impl.sh
TESTFILES:
SPEC-1: tests/t-test.sh
```
EOF
}

# ── [#2109-B1] red at HEAD is not_passing_at_head, never inert_wiring ─────────
# The assertion needs my_feature_v2, which HEAD does not define: the file is red
# at HEAD, so no revert can flip it. That is a build defect, not inert wiring.
REPO_B1="$(_mk_reach_repo reach-b1 '#!/usr/bin/env bash
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"; [[ -f "$impl" ]] && source "$impl"
if declare -F my_feature_v2 >/dev/null; then echo "  ✓ [SPEC-1] my_feature exists"; exit 0; fi
echo "  ✗ [SPEC-1] my_feature exists"; exit 1')"
_design1 "$REPO_B1"
set +e; OUT_B1="$(acceptance_reachability_check "$REPO_B1/design.md" "$REPO_B1" 2>/dev/null)"; set -e
assert_eq "[#2109-B1] a TESTFILE red at HEAD → not_passing_at_head, naming the file" \
    "REACHABILITY FAIL not_passing_at_head impl.sh tests/t-test.sh" "$OUT_B1"
assert_eq "[#2109-B1] and never inert_wiring" "" "$(grep 'inert_wiring' <<<"$OUT_B1" || true)"

# ── [#2109-B2] reverted rc=127 with head rc=0 is harness, never PASS ──────────
# Under set -e the baseline dies calling a function only HEAD defines: the run
# never reached an assertion, so it is evidence of nothing.
REPO_B2="$(_mk_reach_repo reach-b2 '#!/usr/bin/env bash
set -e
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"; [[ -f "$impl" ]] && source "$impl"
my_feature
echo "  ✓ [SPEC-1] my_feature exists"')"
_design1 "$REPO_B2"
set +e; OUT_B2="$(acceptance_reachability_check "$REPO_B2/design.md" "$REPO_B2" 2>/dev/null)"; set -e
assert_eq "[#2109-B2] a reverted run that could not execute (127) is harness, not a flip" \
    "REACHABILITY ERROR harness:impl.sh tests/t-test.sh" "$OUT_B2"

# ── [#2109-B4] every declared TESTFILE absent on disk → no_testfiles ──────────
REPO_B4="$(_mk_reach_repo reach-b4 '#!/usr/bin/env bash
exit 0')"
cat > "$REPO_B4/design.md" <<'EOF'
```acceptance
SPEC-1[change]: my_feature exists
WIRING:
impl.sh
TESTFILES:
SPEC-1: tests/does-not-exist-test.sh
```
EOF
set +e; OUT_B4="$(acceptance_reachability_check "$REPO_B4/design.md" "$REPO_B4" 2>/dev/null)"; set -e
assert_eq "[#2109-B4] no declared TESTFILE on disk → no_testfiles, not inert_wiring" \
    "REACHABILITY FAIL no_testfiles impl.sh" "$OUT_B4"

# ── [#2109-B5] one unrelated untagged ✗ does not hide a tagged flip ───────────
# [SPEC-1] is ✓ at HEAD and ✗ reverted (a real flip); an untagged assertion is ✗
# in both. Per-file rc says "red at HEAD"; per-SPEC evidence says load-bearing.
REPO_B5="$(_mk_reach_repo reach-b5 '#!/usr/bin/env bash
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"; [[ -f "$impl" ]] && source "$impl"
if declare -F my_feature >/dev/null; then echo "  ✓ [SPEC-1] my_feature exists"; else echo "  ✗ [SPEC-1] my_feature exists"; fi
echo "  ✗ unrelated legacy assertion"
exit 1')"
_design1 "$REPO_B5"
set +e; OUT_B5="$(acceptance_reachability_check "$REPO_B5/design.md" "$REPO_B5" 2>/dev/null)"; set -e
assert_eq "[#2109-B5] a tagged ✓→✗ flip is PASS even when an untagged line is ✗ in both runs" \
    "REACHABILITY PASS impl.sh" "$OUT_B5"

cleanup_test_env
print_test_results
