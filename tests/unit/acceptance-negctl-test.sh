#!/usr/bin/env bash
# Tests: ADR-036 (#922) — Level-2 baseline negative-control.
# Builds a temp git repo whose default branch (main) is the baseline (no impl)
# and whose HEAD (feature) adds the implementation + [SPEC-n]-tagged tests, then
# asserts acceptance_negctl_check distinguishes load-bearing from tautological.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-negctl.sh
source "$REPO_ROOT/scripts/lib/acceptance-negctl.sh"

print_test_header "acceptance negctl — Level-2 baseline negative control (#922)"
setup_test_env "acceptance-negctl"

GIT="$(command -v git)"
REPO="$(setup_git_temp_repo negctl-repo)"   # main @ seed (baseline state)

# ── Build the feature HEAD: impl + 4 tagged tests ─────────────────────────────
(
    cd "$REPO"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    # implementation present only at HEAD
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh

    # SPEC-1 — load-bearing: requires impl.sh (absent at baseline → fails there)
    cat > tests/nc-a-test.sh <<'EOF'
#!/usr/bin/env bash
# [SPEC-1] feature is implemented
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
[[ -f "$impl" ]] || exit 1
# shellcheck disable=SC1090
source "$impl"; my_feature
EOF

    # SPEC-2 — tautological: passes regardless of impl
    cat > tests/nc-b-test.sh <<'EOF'
#!/usr/bin/env bash
# [SPEC-2] something is fine
exit 0
EOF

    # SPEC-3 — broken stub: fails at baseline AND head (never passes)
    cat > tests/nc-c-test.sh <<'EOF'
#!/usr/bin/env bash
# [SPEC-3] not yet implemented
exit 1
EOF

    # SPEC-4 — #844-class tautology: reads an uninitialized assoc-array key and
    # compares to its own default; true at baseline AND head (inert).
    cat > tests/nc-d-test.sh <<'EOF'
#!/usr/bin/env bash
# [SPEC-4] cross-run state persists
declare -A _CYCLE_TIMEOUT_RUN_CROSS=()
val="${_CYCLE_TIMEOUT_RUN_CROSS[build-test/build]:-0}"
[[ "$val" == "0" ]] && exit 0 || exit 1
EOF

    chmod +x tests/*.sh impl.sh
    "$GIT" add -A
    "$GIT" commit -q -m "feat: impl + tagged tests"
)

# design.md naming the 4 SPECs + their TESTFILES
DM="$REPO/design.md"
cat > "$DM" <<'EOF'
# Design
```scope
impl.sh
```
```acceptance
SPEC-1: feature is implemented
SPEC-2: something is fine
SPEC-3: not yet implemented
SPEC-4: cross-run state persists
TESTFILES:
tests/nc-a-test.sh
tests/nc-b-test.sh
tests/nc-c-test.sh
tests/nc-d-test.sh
```
EOF

set +e
OUT="$(acceptance_negctl_check "$DM" "$REPO")"; RC=$?
set -e

# ── Assertions ────────────────────────────────────────────────────────────────
assert_eq "NC-A: load-bearing SPEC-1 → PASS" \
    "NEGCTL PASS SPEC-1" "$(grep 'SPEC-1' <<<"$OUT")"
assert_eq "NC-B: tautological SPEC-2 → FAIL tautology" \
    "NEGCTL FAIL SPEC-2 tautology" "$(grep 'SPEC-2' <<<"$OUT")"
assert_eq "NC-C: broken stub SPEC-3 → FAIL not_passing_at_head" \
    "NEGCTL FAIL SPEC-3 not_passing_at_head" "$(grep 'SPEC-3' <<<"$OUT")"
assert_eq "NC-D: #844-class tautology SPEC-4 → FAIL tautology" \
    "NEGCTL FAIL SPEC-4 tautology" "$(grep 'SPEC-4' <<<"$OUT")"
assert_eq "overall rc=1 (≥1 spec failed the control)" "1" "$RC"

# ── NC-E: no_impl_delta when merge-base == HEAD (commit on main, no branch) ────
REPO2="$(setup_git_temp_repo negctl-repo2)"
(
    cd "$REPO2"
    mkdir -p tests
    printf '#!/usr/bin/env bash\n# [SPEC-1] x\nexit 0\n' > tests/x-test.sh
    "$GIT" add -A; "$GIT" commit -q -m "on main"
)
DM2="$REPO2/design.md"
printf '```acceptance\nSPEC-1: x\nTESTFILES:\ntests/x-test.sh\n```\n' > "$DM2"
set +e; OUT2="$(acceptance_negctl_check "$DM2" "$REPO2")"; RC2=$?; set -e
assert_eq "NC-E: merge-base==HEAD → SKIP no_impl_delta" "NEGCTL SKIP no_impl_delta" "$OUT2"
assert_eq "NC-E: skip is not a failure (rc=0)" "0" "$RC2"

# ── NC-F: guard-classified SPEC gets NEGCTL SKIP guard_spec ──────────────────
# Build a repo with a guard SPEC whose test is tautological (always passes).
# negctl must SKIP it (not report tautology), so overall rc=0.
REPO3="$(setup_git_temp_repo negctl-repo3)"
(
    cd "$REPO3"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    # Production file alongside the test — ensures no_prod_delta does not fire so
    # the guard_spec classification is reached and exercised.
    printf '# guard fixture\n' > guard_impl.sh
    printf '#!/usr/bin/env bash\n# [SPEC-1] guard: always passes\nexit 0\n' > tests/guard-test.sh
    chmod +x tests/guard-test.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: guard spec"
)
DM3="$REPO3/design.md"
cat > "$DM3" <<'EOF'
```acceptance
SPEC-1[guard]: invariant that must not regress
TESTFILES:
tests/guard-test.sh
```
EOF

set +e
OUT3="$(acceptance_negctl_check "$DM3" "$REPO3")"; RC3=$?
set -e
assert_eq "NC-F: guard SPEC → NEGCTL SKIP guard_spec" \
    "NEGCTL SKIP guard_spec SPEC-1" "$(grep 'SPEC-1' <<<"$OUT3")"
assert_eq "NC-F: guard skip yields overall rc=0" "0" "$RC3"

# ── NC-G: a test that outlives ZBUILD_NEGCTL_TIMEOUT → INFRA, not a violation ──
# (ADR-036 #1188) A timeout on either run must classify as negctl_error:timeout,
# NEVER as not_passing_at_head — and it must not spuriously satisfy the control.
if command -v timeout >/dev/null 2>&1; then
    REPO4="$(setup_git_temp_repo negctl-repo4)"
    (
        cd "$REPO4"
        "$GIT" checkout -q -b feature
        mkdir -p tests
        printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
        # A tagged test that sleeps well past a tiny timeout.
        printf '#!/usr/bin/env bash\n# [SPEC-1] slow feature\nsleep 30\n' > tests/slow-test.sh
        chmod +x tests/slow-test.sh impl.sh
        "$GIT" add -A; "$GIT" commit -q -m "feat: slow tagged test"
    )
    DM4="$REPO4/design.md"
    cat > "$DM4" <<'EOF'
```acceptance
SPEC-1: slow feature
TESTFILES:
tests/slow-test.sh
```
EOF
    set +e
    OUT4="$(ZBUILD_NEGCTL_TIMEOUT=1 acceptance_negctl_check "$DM4" "$REPO4")"; RC4=$?
    set -e
    assert_eq "NC-G: timeout → NEGCTL ERROR timeout:SPEC-1 (infra, not not_passing_at_head)" \
        "NEGCTL ERROR timeout:SPEC-1" "$(grep 'SPEC-1' <<<"$OUT4")"
    assert_eq "NC-G: timeout is not classified not_passing_at_head" \
        "" "$(grep 'not_passing_at_head' <<<"$OUT4")"
    assert_eq "NC-G: timeout yields overall rc=1 (gate records it)" "1" "$RC4"

    # ── NC-H: with ZBUILD_NEGCTL_ARTIFACT_DIR set, a diagnostic log is captured ──
    LOGDIR="$TEST_TEMP_DIR/negctl-logs"
    set +e
    ZBUILD_NEGCTL_TIMEOUT=1 ZBUILD_NEGCTL_ARTIFACT_DIR="$LOGDIR" \
        acceptance_negctl_check "$DM4" "$REPO4" >/dev/null 2>&1
    set -e
    [[ -f "$LOGDIR/negctl-SPEC-1.log" ]] \
        && assert_pass "NC-H: negctl-SPEC-1.log artifact written for diagnosis" \
        || assert_fail "NC-H: expected negctl-SPEC-1.log artifact" "missing"
else
    assert_pass "NC-G: skipped (no 'timeout' binary available)"
fi

# ── NC-I: ZBUILD_ACCEPTANCE_RUN_CMD seam — non-bash runner (python3) ──────────
# [SPEC-1] load-bearing python3 spec → NEGCTL PASS with python3 runner
# [SPEC-2] tautological python3 spec → NEGCTL FAIL tautology (not not_passing_at_head)
if command -v python3 >/dev/null 2>&1; then
    REPO5="$(setup_git_temp_repo negctl-repo5)"
    (
        cd "$REPO5"
        "$GIT" checkout -q -b feature
        mkdir -p tests
        # implementation present only at HEAD (python-flavor fixture)
        printf '#!/usr/bin/env bash\nmy_py_feature() { return 0; }\n' > impl_py.sh

        # SPEC-1 fixture — load-bearing: checks impl_py.sh exists; Python syntax
        # fails under bash so the old hardcoded-bash runner can't execute it.
        cat > tests/py-lb-test.py <<'PYEOF'
#!/usr/bin/env python3
# [SPEC-1] load-bearing python spec
import os, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.exit(0 if os.path.exists(os.path.join(root, 'impl_py.sh')) else 1)
PYEOF

        # SPEC-2 fixture — tautological: always exits 0; Python syntax fails under bash.
        cat > tests/py-taut-test.py <<'PYEOF'
#!/usr/bin/env python3
# [SPEC-2] tautological python spec
import sys
sys.exit(0)
PYEOF

        chmod +x tests/py-lb-test.py tests/py-taut-test.py impl_py.sh
        "$GIT" add -A
        "$GIT" commit -q -m "feat: python testfile fixtures"
    )

    DM5="$REPO5/design.md"
    cat > "$DM5" <<'EOF'
```acceptance
SPEC-1: load-bearing python spec
SPEC-2: tautological python spec
TESTFILES:
tests/py-lb-test.py
tests/py-taut-test.py
```
EOF

    set +e
    OUT5="$(ZBUILD_ACCEPTANCE_RUN_CMD='python3 {files}' acceptance_negctl_check "$DM5" "$REPO5")"
    RC5=$?
    set -e

    assert_eq "[SPEC-1] non-bash runner: load-bearing py spec → NEGCTL PASS SPEC-1" \
        "NEGCTL PASS SPEC-1" "$(grep 'SPEC-1' <<<"$OUT5")"
    assert_eq "[SPEC-2] non-bash runner: tautological py spec → NEGCTL FAIL SPEC-2 tautology" \
        "NEGCTL FAIL SPEC-2 tautology" "$(grep 'SPEC-2' <<<"$OUT5")"
else
    assert_pass "[SPEC-1] skipped — python3 not available in this environment"
    assert_pass "[SPEC-2] skipped — python3 not available in this environment"
fi

# ── NC-J: _acceptance_build_run_cmd unit-level tests ──────────────────────────
# [SPEC-3] no {files} token in template → returns 1 (misconfiguration guard)
set +e
_acceptance_build_run_cmd "bash" "/tmp/test.sh" >/dev/null 2>&1
_rc_nofiles=$?
set -e
assert_eq "[SPEC-3] _acceptance_build_run_cmd with no {files} token → returns 1" \
    "1" "$_rc_nofiles"

# [SPEC-4] bash {files} template → produces correct NUL-separated runner tokens
_cmd_out=()
while IFS= read -r -d '' _tok; do _cmd_out+=("$_tok"); done \
    < <(_acceptance_build_run_cmd "bash {files}" "/tmp/test.sh")
assert_eq "[SPEC-4] _acceptance_build_run_cmd: first token is interpreter" \
    "bash" "${_cmd_out[0]:-}"
assert_eq "[SPEC-4] _acceptance_build_run_cmd: second token is testfile path" \
    "/tmp/test.sh" "${_cmd_out[1]:-}"

# ── NC-K: [SPEC-1][SPEC-2] test-only diff → NEGCTL SKIP no_prod_delta ────────────
# The feature branch adds only a file under tests/ (no production code). At
# baseline (before the fix), negctl would spin up a worktree and emit
# NEGCTL FAIL tautology; with the fix it emits NEGCTL SKIP no_prod_delta, rc=0.
REPO_K="$(setup_git_temp_repo negctl-repo-k)"
(
    cd "$REPO_K"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    # Only a test file in the diff — no production code changed.
    cat > tests/nc-k-test.sh <<'EOF'
#!/usr/bin/env bash
# [SPEC-1] test-only change
exit 0
EOF
    chmod +x tests/nc-k-test.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: test-only change"
)
DM_K="$REPO_K/design.md"
cat > "$DM_K" <<'EOF'
```acceptance
SPEC-1: test-only change
TESTFILES:
tests/nc-k-test.sh
```
EOF
set +e; OUT_K="$(acceptance_negctl_check "$DM_K" "$REPO_K")"; RC_K=$?; set -e
assert_eq "[SPEC-1] test-only diff → NEGCTL SKIP no_prod_delta" \
    "NEGCTL SKIP no_prod_delta" "$OUT_K"
assert_eq "[SPEC-2] test-only diff skip yields rc=0" "0" "$RC_K"

# ── NC-L: [SPEC-3] mixed diff (test + prod file) → full negctl runs, no skip ─────
# When at least one changed path is outside tests/, no_prod_delta must NOT fire.
REPO_L="$(setup_git_temp_repo negctl-repo-l)"
(
    cd "$REPO_L"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    # production file present only at HEAD (load-bearing)
    printf '#!/usr/bin/env bash\nmy_l_feature() { return 0; }\n' > impl_l.sh
    cat > tests/nc-l-test.sh <<'EOF'
#!/usr/bin/env bash
# [SPEC-1] load-bearing: impl_l.sh must exist
impl="$(cd "$(dirname "$0")/.." && pwd)/impl_l.sh"
[[ -f "$impl" ]] || exit 1
# shellcheck disable=SC1090
source "$impl"; my_l_feature
EOF
    chmod +x tests/nc-l-test.sh impl_l.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: impl + test (mixed diff)"
)
DM_L="$REPO_L/design.md"
cat > "$DM_L" <<'EOF'
```acceptance
SPEC-1: load-bearing test for impl_l
TESTFILES:
tests/nc-l-test.sh
```
EOF
set +e; OUT_L="$(acceptance_negctl_check "$DM_L" "$REPO_L")"; RC_L=$?; set -e
assert_eq "[SPEC-3] mixed diff does NOT emit no_prod_delta skip" \
    "" "$(grep 'no_prod_delta' <<<"$OUT_L")"
assert_eq "[SPEC-3] mixed diff runs full negctl → NEGCTL PASS SPEC-1" \
    "NEGCTL PASS SPEC-1" "$(grep 'SPEC-1' <<<"$OUT_L")"

# ── NC-M: [SPEC-1][SPEC-2] per-SPEC binding restricts candidate testfiles ─────────
# When per-SPEC binding is declared, negctl uses only the SPEC's own bound files.
# SPEC-1 is bound to a load-bearing file; SPEC-2 is bound to a tautological file.
# SPEC-2 must NOT be able to "ride" SPEC-1's passing control.
REPO_M="$(setup_git_temp_repo negctl-repo-m)"
(
    cd "$REPO_M"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '#!/usr/bin/env bash\nmy_m_feature() { return 0; }\n' > impl_m.sh

    # SPEC-1 file: load-bearing — fails at baseline (impl_m.sh absent), passes at HEAD
    cat > tests/nc-m-lb-test.sh <<'EOF'
#!/usr/bin/env bash
# [SPEC-1] per-SPEC load-bearing
impl="$(cd "$(dirname "$0")/.." && pwd)/impl_m.sh"
[[ -f "$impl" ]] || exit 1
# shellcheck disable=SC1090
source "$impl"; my_m_feature
EOF

    # SPEC-2 file: tautological — always exits 0 regardless of impl_m.sh
    cat > tests/nc-m-taut-test.sh <<'EOF'
#!/usr/bin/env bash
# [SPEC-2] per-SPEC tautological
exit 0
EOF

    chmod +x tests/nc-m-lb-test.sh tests/nc-m-taut-test.sh impl_m.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: per-SPEC negctl fixture"
)
DM_M="$REPO_M/design.md"
cat > "$DM_M" <<'EOF'
```acceptance
SPEC-1[change]: per-SPEC load-bearing
SPEC-2[change]: per-SPEC tautological
TESTFILES:
SPEC-1: tests/nc-m-lb-test.sh
SPEC-2: tests/nc-m-taut-test.sh
```
EOF

set +e; OUT_M="$(acceptance_negctl_check "$DM_M" "$REPO_M")"; RC_M=$?; set -e
assert_eq "[SPEC-1] NC-M: per-SPEC bound load-bearing file → NEGCTL PASS SPEC-1" \
    "NEGCTL PASS SPEC-1" "$(grep 'SPEC-1' <<<"$OUT_M")"
assert_eq "[SPEC-2] NC-M: per-SPEC bound tautological file → NEGCTL FAIL SPEC-2 tautology" \
    "NEGCTL FAIL SPEC-2 tautology" "$(grep 'SPEC-2' <<<"$OUT_M")"
# SPEC-2 must NOT ride SPEC-1's passing control (sibling isolation)
assert_eq "[SPEC-2] NC-M: SPEC-2 does not emit PASS via sibling's binding" \
    "0" "$(grep -c 'NEGCTL PASS SPEC-2' <<<"$OUT_M" || true)"

cleanup_test_env
print_test_results  # exits with $FAIL
