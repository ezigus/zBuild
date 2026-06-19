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

cleanup_test_env
print_test_results  # exits with $FAIL
