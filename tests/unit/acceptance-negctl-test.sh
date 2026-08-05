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
assert_eq "[SPEC-2] NC-E: merge-base==HEAD → per-SPEC SKIP no_impl_delta" \
    "NEGCTL SKIP SPEC-1 no_impl_delta" "$(grep 'SPEC-1' <<<"$OUT2")"
assert_eq "[SPEC-2] NC-E: skip is not a failure (rc=0)" "0" "$RC2"

# ── NC-F: [SPEC-1][SPEC-4] guard-classified SPEC passing at baseline → NEGCTL PASS ─
# Build a repo with a guard SPEC whose test always passes at baseline.
# negctl must run the baseline check and emit PASS (not SKIP), rc=0.
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
assert_eq "[SPEC-1] NC-F: guard SPEC passing at baseline → NEGCTL PASS guard_spec" \
    "NEGCTL PASS SPEC-1 guard_spec" "$(grep 'SPEC-1' <<<"$OUT3")"
assert_eq "NC-F: guard PASS yields overall rc=0" "0" "$RC3"
assert_eq "[SPEC-4] NC-F: NEGCTL SKIP guard_spec is no longer emitted" \
    "" "$(grep 'SKIP guard_spec' <<<"$OUT3")"
# #1684's enrichment keys off "NEGCTL <verdict> <SPEC-n>"; the guard tokens must
# occupy that shape or guard SPECs silently lose their design/asserts readout.
assert_contains_regex "[SPEC-6] NC-F: guard PASS line puts the SPEC id where enrichment finds it" \
    "$(grep 'SPEC-1' <<<"$OUT3")" '^NEGCTL (PASS|FAIL|SKIP) SPEC-[0-9]+'

# ── NC-F2: [SPEC-2] guard SPEC failing at baseline → NEGCTL FAIL guard_spec regressed ─
# When the guard invariant is already broken at the merge-base (test exits 1),
# negctl must emit FAIL with reason=regressed and rc=1.
REPO3b="$(setup_git_temp_repo negctl-repo3b)"
(
    cd "$REPO3b"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '# guard fixture\n' > guard_impl.sh
    # This guard test exits 1 — simulates an invariant already broken at baseline.
    printf '#!/usr/bin/env bash\n# [SPEC-1] guard: invariant broken\nexit 1\n' > tests/guard-fail-test.sh
    chmod +x tests/guard-fail-test.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: guard spec with broken invariant"
)
DM3b="$REPO3b/design.md"
cat > "$DM3b" <<'EOF'
```acceptance
SPEC-1[guard]: invariant that must not regress
TESTFILES:
tests/guard-fail-test.sh
```
EOF

set +e
OUT3b="$(acceptance_negctl_check "$DM3b" "$REPO3b")"; RC3b=$?
set -e
assert_eq "[SPEC-2] NC-F2: guard SPEC fails at baseline → NEGCTL FAIL guard_regressed" \
    "NEGCTL FAIL SPEC-1 guard_regressed" "$(grep 'SPEC-1' <<<"$OUT3b")"
assert_eq "[SPEC-2] NC-F2: guard FAIL guard_regressed yields rc=1" "1" "$RC3b"

# ── NC-F3: [SPEC-3] guard SPEC timeout → NEGCTL ERROR timeout (advisory) ─────────
# A timeout on the guard baseline run must be advisory (same as change-SPEC path),
# not a false guard_regressed violation.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    REPO3c="$(setup_git_temp_repo negctl-repo3c)"
    (
        cd "$REPO3c"
        "$GIT" checkout -q -b feature
        mkdir -p tests
        printf '# guard fixture\n' > guard_impl.sh
        printf '#!/usr/bin/env bash\n# [SPEC-1] guard: slow\nsleep 30\n' > tests/guard-slow-test.sh
        chmod +x tests/guard-slow-test.sh
        "$GIT" add -A; "$GIT" commit -q -m "feat: guard spec that times out"
    )
    DM3c="$REPO3c/design.md"
    cat > "$DM3c" <<'EOF'
```acceptance
SPEC-1[guard]: invariant that must not regress
TESTFILES:
tests/guard-slow-test.sh
```
EOF
    set +e
    OUT3c="$(ZBUILD_NEGCTL_TIMEOUT=1 acceptance_negctl_check "$DM3c" "$REPO3c")"; RC3c=$?
    set -e
    assert_eq "[SPEC-3] NC-F3: guard SPEC timeout → NEGCTL ERROR timeout:SPEC-1" \
        "NEGCTL ERROR timeout:SPEC-1" "$(grep 'SPEC-1' <<<"$OUT3c")"
    assert_eq "[SPEC-3] NC-F3: guard timeout is not guard_regressed" \
        "" "$(grep 'guard_regressed' <<<"$OUT3c")"
else
    assert_pass "[SPEC-3] NC-F3: skipped — no timeout binary available"
fi

# ── NC-F4: [SPEC-3] guard baseline that ERRORS (never reached an assertion) ──────
# The #1670 hazard: a guard whose test depends on something this change adds
# cannot run at the merge-base. That rc says nothing about the invariant, so it
# must be advisory (NEGCTL ERROR harness:) — never a guard_regressed violation,
# which would make the guard unlandable.
#
# Two independent shapes, because they fail through different mechanisms:
#   (a) the baseline copy does not PARSE  → caught by the bash -n preflight
#   (b) the runner cannot execute it (127) → caught by the rc class
REPO3d="$(setup_git_temp_repo negctl-repo3d)"
(
    cd "$REPO3d"
    "$GIT" checkout -q -b feature
    mkdir -p tests scripts/lib
    printf '# guard fixture\n' > guard_impl.sh
    # Calls a helper this change introduces — absent at the merge-base → rc=127.
    printf '#!/usr/bin/env bash\nset -euo pipefail\n# [SPEC-1] guard: invariant\nhelper_added_by_this_change\n' \
        > tests/guard-harness-test.sh
    chmod +x tests/guard-harness-test.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: guard spec needing a new helper"
)
DM3d="$REPO3d/design.md"
cat > "$DM3d" <<'EOF'
```acceptance
SPEC-1[guard]: invariant that must not regress
TESTFILES:
tests/guard-harness-test.sh
```
EOF
set +e
OUT3d="$(acceptance_negctl_check "$DM3d" "$REPO3d")"; RC3d=$?
set -e
assert_eq "[SPEC-3] NC-F4a: guard baseline rc=127 → NEGCTL ERROR harness:SPEC-1" \
    "NEGCTL ERROR harness:SPEC-1" "$(grep 'SPEC-1' <<<"$OUT3d")"
assert_eq "[SPEC-3] NC-F4a: a harness error is NOT a guard_regressed violation" \
    "" "$(grep 'guard_regressed' <<<"$OUT3d")"
# rc=1 matches the timeout path (NC-G): the LIBRARY reports "I could not form an
# opinion". Non-blocking is the plugin's job, via disposition=advisory (S6c) —
# the two layers are pinned separately so neither can drift silently.
assert_eq "[SPEC-3] NC-F4a: harness error yields rc=1, as the timeout path does" "1" "$RC3d"

REPO3f="$(setup_git_temp_repo negctl-repo3f)"
(
    cd "$REPO3f"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '# guard fixture\n' > guard_impl.sh
    # Unparseable at baseline: the overlay copies this HEAD file into a worktree
    # where the `fi` it depends on has no matching `if`.
    printf '#!/usr/bin/env bash\n# [SPEC-1] guard: invariant\nif [[ 1 -eq 1 ]]; then\n  :\n' \
        > tests/guard-syntax-test.sh
    chmod +x tests/guard-syntax-test.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: guard spec that does not parse"
)
DM3f="$REPO3f/design.md"
cat > "$DM3f" <<'EOF'
```acceptance
SPEC-1[guard]: invariant that must not regress
TESTFILES:
tests/guard-syntax-test.sh
```
EOF
set +e
OUT3f="$(acceptance_negctl_check "$DM3f" "$REPO3f")"; RC3f=$?
set -e
assert_eq "[SPEC-3] NC-F4b: unparseable guard baseline → NEGCTL ERROR harness:SPEC-1" \
    "NEGCTL ERROR harness:SPEC-1" "$(grep 'SPEC-1' <<<"$OUT3f")"
assert_eq "[SPEC-3] NC-F4b: harness error yields rc=1, as the timeout path does" "1" "$RC3f"

# ── NC-F6: [SPEC-7] untagged [guard] SPEC → SKIP, not FAIL (#1255 contract) ──────
# #1255 exempts [guard] SPECs from the design-gate's tag-coverage rule, so a
# guard with no tagged assertion is legal input. Failing it here would deadlock:
# design-gate admits the design and this gate halts the cycle over it.
REPO3g="$(setup_git_temp_repo negctl-repo3g)"
(
    cd "$REPO3g"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '# prod change\n' > guard_impl.sh
    # Carries [SPEC-1] only — SPEC-2 (the guard) is deliberately untagged.
    printf '#!/usr/bin/env bash\n# [SPEC-1] change: new behavior\ngrep -q "prod change" "$(git rev-parse --show-toplevel)/guard_impl.sh"\n' \
        > tests/mixed-test.sh
    chmod +x tests/mixed-test.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: change spec plus an untagged guard"
)
DM3g="$REPO3g/design.md"
cat > "$DM3g" <<'EOF'
```acceptance
SPEC-1[change]: new behavior lands
SPEC-2[guard]: the invariant nobody wrote an assertion for
TESTFILES:
tests/mixed-test.sh
```
EOF
set +e
OUT3g="$(acceptance_negctl_check "$DM3g" "$REPO3g")"; RC3g=$?
set -e
assert_eq "[SPEC-7] NC-F6: untagged guard SPEC → NEGCTL SKIP guard_untested" \
    "NEGCTL SKIP SPEC-2 guard_untested" "$(grep 'SPEC-2' <<<"$OUT3g")"
assert_eq "[SPEC-7] NC-F6: an untagged guard does not fail the gate" "0" "$RC3g"
assert_eq "[SPEC-7] NC-F6: the [change] SPEC alongside it still gets a real control" \
    "NEGCTL PASS SPEC-1" "$(grep 'SPEC-1' <<<"$OUT3g")"

# ── NC-F5: [SPEC-5] guard SPEC with per-SPEC binding → NEGCTL PASS guard_spec ────
# When per-SPEC binding is declared for a guard SPEC, negctl must use only that
# bound file and still run the inverted baseline check correctly.
REPO3e="$(setup_git_temp_repo negctl-repo3e)"
(
    cd "$REPO3e"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '# guard fixture\n' > guard_impl.sh
    printf '#!/usr/bin/env bash\n# [SPEC-1] guard: bound always passes\nexit 0\n' > tests/guard-bound-test.sh
    chmod +x tests/guard-bound-test.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: guard spec with per-SPEC binding"
)
DM3e="$REPO3e/design.md"
cat > "$DM3e" <<'EOF'
```acceptance
SPEC-1[guard]: invariant that must not regress
TESTFILES:
SPEC-1: tests/guard-bound-test.sh
```
EOF

set +e
OUT3e="$(acceptance_negctl_check "$DM3e" "$REPO3e")"; RC3e=$?
set -e
assert_eq "[SPEC-5] NC-F5: guard SPEC with per-SPEC binding → NEGCTL PASS guard_spec" \
    "NEGCTL PASS SPEC-1 guard_spec" "$(grep 'SPEC-1' <<<"$OUT3e")"
assert_eq "[SPEC-5] NC-F5: bound guard SPEC yields rc=0" "0" "$RC3e"

# ── NC-F7: [SPEC-8] the #1658 shape — a guard asserting the OPPOSITE of its SPEC ──
# The defect this whole check exists for. Design declared "cleanup WITHOUT
# --worktrees does not reclaim worktrees"; build implemented the inverse and
# tagged an assertion agreeing with its own implementation. The assertion is
# true only at HEAD, so it reddens at the merge-base — which is exactly what
# disqualifies it as a guard.
REPO3h="$(setup_git_temp_repo negctl-repo3h)"
(
    cd "$REPO3h"
    # Baseline (merge-base): worktrees are NOT part of the default set.
    printf 'default_all="branches state stashes tmpdirs"\n' > cleanup_impl.sh
    "$GIT" add -A; "$GIT" commit -q -m "baseline: worktrees are not reclaimable"
    # HEAD folds worktree reclamation in — the inversion of what the SPEC claims.
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf 'default_all="branches state stashes tmpdirs worktrees"\n' > cleanup_impl.sh
    printf '#!/usr/bin/env bash\nset -euo pipefail\n# [SPEC-1] guard: default-all includes worktrees\ngrep -q "worktrees" "$(git rev-parse --show-toplevel)/cleanup_impl.sh"\n' \
        > tests/inverted-guard-test.sh
    chmod +x tests/inverted-guard-test.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: fold worktrees into default-all"
)
DM3h="$REPO3h/design.md"
cat > "$DM3h" <<'EOF'
```acceptance
SPEC-1[guard]: cleanup without --worktrees does NOT reclaim worktrees
TESTFILES:
tests/inverted-guard-test.sh
```
EOF
set +e
OUT3h="$(acceptance_negctl_check "$DM3h" "$REPO3h")"; RC3h=$?
set -e
assert_eq "[SPEC-8] NC-F7: an inverted guard assertion reddens at the merge-base" \
    "NEGCTL FAIL SPEC-1 guard_regressed" "$(grep 'SPEC-1' <<<"$OUT3h")"
assert_eq "[SPEC-8] NC-F7: the inverted guard fails the gate (rc=1)" "1" "$RC3h"

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
assert_eq "[SPEC-3] test-only diff → NEGCTL SKIP SPEC-1 no_prod_delta" \
    "NEGCTL SKIP SPEC-1 no_prod_delta" "$(grep 'SPEC-1' <<<"$OUT_K")"
assert_eq "[SPEC-3] test-only diff skip yields rc=0" "0" "$RC_K"

# ── NC-K2: [SPEC-3] multi-SPEC test-only diff → one SKIP line per declared SPEC ──
REPO_K2="$(setup_git_temp_repo negctl-repo-k2)"
(
    cd "$REPO_K2"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    cat > tests/nc-k2a-test.sh <<'EOF'
#!/usr/bin/env bash
# [SPEC-1] test-only spec one
exit 0
EOF
    cat > tests/nc-k2b-test.sh <<'EOF'
#!/usr/bin/env bash
# [SPEC-2] test-only spec two
exit 0
EOF
    chmod +x tests/nc-k2a-test.sh tests/nc-k2b-test.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: test-only two-SPEC change"
)
DM_K2="$REPO_K2/design.md"
cat > "$DM_K2" <<'EOF'
```acceptance
SPEC-1: test-only spec one
SPEC-2: test-only spec two
TESTFILES:
tests/nc-k2a-test.sh
tests/nc-k2b-test.sh
```
EOF
set +e; OUT_K2="$(acceptance_negctl_check "$DM_K2" "$REPO_K2")"; RC_K2=$?; set -e
# `grep -c` prints 0 AND exits 1 on no-match, so `|| echo 0` would emit "0\n0"
# and make the mismatch message unreadable on the failure this asserts.
assert_eq "[SPEC-3] NC-K2: two-SPEC no_prod_delta → exactly two SKIP lines" \
    "2" "$(grep -c 'NEGCTL SKIP' <<<"$OUT_K2" || true)"
assert_eq "[SPEC-3] NC-K2: SPEC-1 SKIP line present" \
    "NEGCTL SKIP SPEC-1 no_prod_delta" "$(grep 'SPEC-1' <<<"$OUT_K2")"
assert_eq "[SPEC-3] NC-K2: SPEC-2 SKIP line present" \
    "NEGCTL SKIP SPEC-2 no_prod_delta" "$(grep 'SPEC-2' <<<"$OUT_K2")"
assert_eq "[SPEC-3] NC-K2: rc=0 (no_prod_delta is not a failure)" "0" "$RC_K2"

# ── NC-K3: [SPEC-2] unreadable SPEC roster still emits a whole-run SKIP line ─────
# Per-SPEC emission must not be able to turn "we verified nothing, and here is
# the roster" into silence — an empty section reads identically to the check
# never having run. With no design.md the roster is unavailable, so the
# pre-#1715 bare line is the required fallback, not zero lines.
REPO_K3="$(setup_git_temp_repo negctl-repo-k3)"
set +e
OUT_K3="$(acceptance_negctl_check "$REPO_K3/nonexistent-design.md" "$REPO_K3")"; RC_K3=$?
set -e
assert_eq "[SPEC-2] NC-K3: unreadable roster → bare no_impl_delta fallback line" \
    "NEGCTL SKIP no_impl_delta" "$OUT_K3"
assert_eq "[SPEC-2] NC-K3: fallback is not a failure (rc=0)" "0" "$RC_K3"

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

    # SPEC-1's bound file: load-bearing — fails at baseline (impl_m.sh absent),
    # passes at HEAD. It deliberately ALSO carries a [SPEC-2] tag: that is the
    # sibling-riding VECTOR this issue fixes. Under the OLD tag-scan negctl,
    # SPEC-2 matches this file, sees it flip, and wrongly reports PASS SPEC-2.
    # Per-SPEC binding restricts SPEC-2 to its own tautological file. Without
    # the dual tag the fixture cannot discriminate old from new (both attribute
    # correctly), leaving the negctl wiring inert.
    cat > tests/nc-m-lb-test.sh <<'EOF'
#!/usr/bin/env bash
# [SPEC-1] per-SPEC load-bearing
# [SPEC-2] sibling-riding vector: the old tag-scan would match this file for SPEC-2
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

# ── NC-N: #1567 — _negctl_run scrubs inherited ZBUILD_STAGE_IO_* render steering ─
# The pipeline sets ZBUILD_STAGE_IO_SEQ_LABEL ("5.1.1") / ZBUILD_STAGE_IO_PERSONA
# on the acceptance-gate stage. If they leak into the sandbox, a bound TESTFILE
# that asserts a fresh banner (seq=1) fails at HEAD for the wrong reason —
# a false not_passing_at_head. The probe passes (rc 0) only when the sandbox
# has scrubbed the whole family; if the scrub regressed, rc becomes 1 here.
probe_n="$TEST_TEMP_DIR/sio-scrub-probe-test.sh"
cat > "$probe_n" <<'PROBE'
#!/usr/bin/env bash
leaked=0
for _v in "${!ZBUILD_STAGE_IO_@}"; do leaked=1; done
[[ "$leaked" -eq 0 ]]
PROBE
chmod +x "$probe_n"
export ZBUILD_STAGE_IO_SEQ_LABEL="5.1.1" ZBUILD_STAGE_IO_PERSONA="product-owner" ZBUILD_STAGE_IO_FD=3
RC_N=0; _negctl_run "$probe_n" "$TEST_TEMP_DIR" || RC_N=$?
unset ZBUILD_STAGE_IO_SEQ_LABEL ZBUILD_STAGE_IO_PERSONA ZBUILD_STAGE_IO_FD
assert_eq "NC-N: _negctl_run scrubs inherited ZBUILD_STAGE_IO_* (probe sees none → rc 0)" \
    "0" "$RC_N"

# ── NC-O: [SPEC-1] rc=137 (SIGKILL) is classified as an infra timeout ────────
# Before this change, _negctl_is_timeout_rc did not recognise rc=137. A process
# killed by SIGKILL after a -k kill-after sequence (or an OOM kill) would have
# been misclassified as not_passing_at_head instead of an infrastructure timeout.
set +e; _negctl_is_timeout_rc 137; _rc_137=$?; set -e
assert_eq "[SPEC-1] _negctl_is_timeout_rc 137 → true (SIGKILL = infra timeout)" \
    "0" "$_rc_137"

# ── NC-P: [SPEC-2] _negctl_run SIGTERM-ignoring TESTFILE is escalated to SIGKILL
# The loop traps SIGTERM (ignores it) and runs 30 sleep-1 iterations.
# At HEAD  (-k 2, timeout 1): SIGTERM at 1s ignored; SIGKILL at 3s → rc=137.
# At baseline (no -k, timeout 1): SIGTERM ignored; bash loops to completion (≈30s)
# and exits 0 — assertion "137" vs "0" fails at baseline, proves the wiring.
# The guard must mirror what _acceptance_timeout_prefix actually resolves —
# gtimeout OR timeout. Checking only `timeout` would silently drop this coverage
# on a macOS coreutils host, which is exactly where the bound is exercised.
if command -v gtimeout >/dev/null 2>&1 || command -v timeout >/dev/null 2>&1; then
    _trap_sh="$TEST_TEMP_DIR/trap-sigterm-loop.sh"
    cat > "$_trap_sh" <<'TEOF'
#!/usr/bin/env bash
trap "" SIGTERM
for _i in {1..30}; do sleep 1 || true; done
TEOF
    chmod +x "$_trap_sh"
    _rc_spec2=0
    ZBUILD_NEGCTL_TIMEOUT=1 ZBUILD_NEGCTL_KILL_GRACE=2 \
        _negctl_run "$_trap_sh" "$TEST_TEMP_DIR" 2>/dev/null || _rc_spec2=$?
    assert_eq "[SPEC-2] _negctl_run SIGTERM-ignoring TESTFILE escalated to SIGKILL (rc=137)" \
        "137" "$_rc_spec2"
else
    assert_pass "[SPEC-2] skipped — neither gtimeout nor timeout available"
fi

# ── NC-P2: the kill grace is operator-tunable, not a hardcoded literal ────────
# _acceptance_timeout_prefix is the single place both acceptance gates build
# their bound, so assert the built argv directly — no process needs to be run.
ZBUILD_NEGCTL_KILL_GRACE=7 _acceptance_timeout_prefix 33
_TOUT_JOINED="${_ACCEPTANCE_TOUT[*]}"
if [[ "${_ACCEPTANCE_TIMEOUT_KILL_OK:-}" == "yes" ]]; then
    assert_eq "NC-P2: ZBUILD_NEGCTL_KILL_GRACE feeds -k in the built bound" \
        "-k 7 33" "${_TOUT_JOINED#* }"
else
    assert_pass "NC-P2: skipped — host timeout does not support -k"
fi

# ── NC-P3: a `timeout` without -k support degrades instead of failing every run
# A timeout binary lacking -k exits 125 on the unknown flag. 125 is not a
# timeout rc, so every bounded run would fall through to the ordinary control
# comparison and be reported as tautology/not_passing_at_head — silently
# condemning correct changes. The probe must catch that and drop back to the
# plain TERM-only bound.
_FAKE_BIN="$TEST_TEMP_DIR/fakebin"
mkdir -p "$_FAKE_BIN"
# Shadow BOTH names: the helper resolves gtimeout first, so stubbing only
# `timeout` would leave a coreutils host running the real gtimeout.
cat > "$_FAKE_BIN/gtimeout" <<'FEOF'
#!/usr/bin/env bash
[[ "$1" == "-k" ]] && { echo "timeout: invalid option -- 'k'" >&2; exit 125; }
exit 0
FEOF
chmod +x "$_FAKE_BIN/gtimeout"
cp "$_FAKE_BIN/gtimeout" "$_FAKE_BIN/timeout"
(
    PATH="$_FAKE_BIN:$PATH"
    unset _ACCEPTANCE_TIMEOUT_KILL_OK
    _acceptance_timeout_prefix 33
    # Only the flags matter here; the binary name varies by host.
    _joined="${_ACCEPTANCE_TOUT[*]}"
    printf '%s\n' "${_joined#* }" > "$TEST_TEMP_DIR/nok.out"
)
assert_eq "NC-P3: timeout without -k support → TERM-only bound, no -k in argv" \
    "33" "$(cat "$TEST_TEMP_DIR/nok.out")"

# ── NC-Q: [SPEC-4] a TESTFILE that exits rc=137 → NEGCTL ERROR timeout, not
# not_passing_at_head (end-to-end through acceptance_negctl_check) ─────────────
# Simulates a process killed by SIGKILL (-k kill-after or OOM).
# At baseline (137 unrecognised): rc_base=137 unrecognised → not_passing_at_head.
# At HEAD   (137 in classifier): both runs classified as timeout → ERROR timeout.
REPO_Q="$(setup_git_temp_repo negctl-repo-q)"
(
    cd "$REPO_Q"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
    printf '#!/usr/bin/env bash\n# [SPEC-1] sigkill-rc fixture\nexit 137\n' > tests/sigkill-test.sh
    chmod +x tests/sigkill-test.sh impl.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: rc=137 fixture"
)
DM_Q="$REPO_Q/design.md"
cat > "$DM_Q" <<'EOF'
```acceptance
SPEC-1: sigkill-rc fixture
TESTFILES:
tests/sigkill-test.sh
```
EOF
set +e; OUT_Q="$(acceptance_negctl_check "$DM_Q" "$REPO_Q")"; RC_Q=$?; set -e
assert_eq "[SPEC-4] rc=137 TESTFILE → NEGCTL ERROR timeout:SPEC-1 (not not_passing_at_head)" \
    "NEGCTL ERROR timeout:SPEC-1" "$(grep 'SPEC-1' <<<"$OUT_Q")"
assert_eq "[SPEC-4] rc=137 TESTFILE does not emit not_passing_at_head" \
    "" "$(grep 'not_passing_at_head' <<<"$OUT_Q")"

# ── NC-R: [SPEC-2] run-tests.sh also wires -k for SIGKILL escalation ─────────
# The same SIGTERM-ignoring defect can hang run-tests.sh per-file timeouts.
# Structural: the _rt_tout assignment in scripts/run-tests.sh must carry -k.
# In the reachability worktree, REPO_ROOT → worktree; run-tests.sh at baseline
# has no -k → grep returns 0 ≠ 1 → test flips → reachability gate passes.
# (Behavioural proof of the same wiring lives in run-tests-timeout-report-test.sh.)
assert_eq "[SPEC-2] run-tests.sh _rt_tout wires -k for SIGKILL escalation" "1" \
    "$(grep -cF '"-k" "$_RT_KILL_GRACE"' "$REPO_ROOT/scripts/run-tests.sh")"

cleanup_test_env
print_test_results  # exits with $FAIL
