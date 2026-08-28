#!/usr/bin/env bash
# Tests: per-assertion attribution on the negctl [change] path (#1969, ADR-036).
#
# Before #1969 a [change] SPEC was judged ONLY by its test file's exit code.
# One unrelated red assertion therefore condemned every SPEC bound to the file.
# That is what happened to issue #1836 in run 32886585375: a `grep -c || echo 0`
# typo reddened test-test.sh (1 of 78), and SPEC-1..SPEC-8 — each individually
# ✓ in the very same log — were all reported not_passing_at_head. The build
# agent spent its last route-back pass chasing eight failures that did not
# exist and the run died at 4h03m.
#
#   SPEC-1 [change]: a [change] SPEC whose own tagged assertions pass at HEAD is
#                    a valid control even when a sibling assertion reddens the
#                    file — the #1836 shape.
#   SPEC-2 [change]: a [change] SPEC whose OWN assertion fails at HEAD is still
#                    condemned not_passing_at_head (the safety half).
#   SPEC-3 [change]: a baseline exiting 126/127 with no tagged evidence for the
#                    SPEC is infrastructure, not a valid negative control.
#   SPEC-4 [change]: per-assertion evidence also detects a tautology — a SPEC
#                    whose own assertion already passes at the merge-base.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-negctl.sh
source "$REPO_ROOT/scripts/lib/acceptance-negctl.sh"

print_test_header "negctl [change] per-assertion attribution (#1969)"
setup_test_env "acceptance-negctl-change-attribution"

GIT="$(command -v git)"

# ═══════════════════════════════════════════════════════════════════════════════
# SPEC-1 — the #1836 shape: sibling red assertion must not condemn a green SPEC
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "1. a sibling's red assertion does not condemn a green SPEC (#1836)"

REPO_A="$(setup_git_temp_repo negctl-attr-a)"
(
    cd "$REPO_A"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '# change impl\n' > impl_a.sh

    # [SPEC-1] flips ✗→✓ across the merge-base (a genuine control).
    # The UNTAGGED assertion below always fails — it stands in for the SPEC-9
    # `grep -c … || echo 0` typo, which can never pass at either revision.
    cat > tests/attr-a-test.sh <<'SEOF'
#!/usr/bin/env bash
_failed=0
_root="$(git rev-parse --show-toplevel)"
if [[ -f "$_root/impl_a.sh" ]]; then
    printf '  \xe2\x9c\x93 [SPEC-1] impl_a.sh found\n'
else
    printf '  \xe2\x9c\x97 [SPEC-1] impl_a.sh missing\n'
    _failed=1
fi
# Untagged, permanently red — the typo's stand-in.
printf '  \xe2\x9c\x97 unrelated assertion that can never pass\n'
_failed=1
exit "$_failed"
SEOF
    chmod +x tests/attr-a-test.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: impl_a + tagged test with a red sibling"
)
DM_A="$REPO_A/design.md"
cat > "$DM_A" <<'EOF'
```acceptance
SPEC-1[change]: impl_a.sh present at HEAD
TESTFILES:
SPEC-1: tests/attr-a-test.sh
```
EOF
set +e; OUT_A="$(acceptance_negctl_check "$DM_A" "$REPO_A")"; RC_A=$?; set -e

assert_eq "[SPEC-1] a SPEC green at HEAD is a valid control despite a red sibling" \
    "NEGCTL PASS SPEC-1" "$(grep 'SPEC-1' <<<"$OUT_A")"
assert_eq "[SPEC-1] not_passing_at_head is NOT reported" \
    "" "$(grep 'not_passing_at_head' <<<"$OUT_A" || true)"
assert_eq "[SPEC-1] overall rc=0" "0" "$RC_A"

# ═══════════════════════════════════════════════════════════════════════════════
# SPEC-2 — safety half: a SPEC whose OWN assertion is red at HEAD still fails
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "2. a SPEC red at HEAD is still condemned"

REPO_B="$(setup_git_temp_repo negctl-attr-b)"
(
    cd "$REPO_B"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '# unrelated impl\n' > impl_b.sh
    # [SPEC-1]'s own assertion is ✗ at BOTH revisions — the implementation
    # genuinely does not satisfy it.
    cat > tests/attr-b-test.sh <<'SEOF'
#!/usr/bin/env bash
printf '  \xe2\x9c\x97 [SPEC-1] required_file.txt missing\n'
exit 1
SEOF
    chmod +x tests/attr-b-test.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: impl_b + a genuinely failing tagged test"
)
DM_B="$REPO_B/design.md"
cat > "$DM_B" <<'EOF'
```acceptance
SPEC-1[change]: required_file.txt present at HEAD
TESTFILES:
SPEC-1: tests/attr-b-test.sh
```
EOF
set +e; OUT_B="$(acceptance_negctl_check "$DM_B" "$REPO_B")"; RC_B=$?; set -e

assert_contains "[SPEC-2] a SPEC whose own assertion is red at HEAD fails" \
    "$OUT_B" "NEGCTL FAIL SPEC-1 not_passing_at_head"
assert_eq "[SPEC-2] overall rc=1" "1" "$RC_B"

# ═══════════════════════════════════════════════════════════════════════════════
# SPEC-3 — a 127 baseline with no tagged evidence is infra, not a control
# ═══════════════════════════════════════════════════════════════════════════════
# #1836 hit this too: SPEC-8's assertion called a function the change
# introduces, so under `set -e` the baseline aborted rc=127 BEFORE printing any
# [SPEC-8] line. The change path checked only _negctl_is_timeout_rc, so "the
# runner could not execute this" was silently accepted as "the test reddened".
print_test_section "3. a 126/127 baseline without tagged evidence is infrastructure"

REPO_C="$(setup_git_temp_repo negctl-attr-c)"
(
    cd "$REPO_C"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    # The helper exists only at HEAD; at the merge-base the call is a
    # command-not-found (127) that aborts before any [SPEC-1] line is printed.
    printf '#!/usr/bin/env bash\n_attr_c_helper() { printf ok; }\n' > impl_c.sh
    cat > tests/attr-c-test.sh <<'SEOF'
#!/usr/bin/env bash
set -euo pipefail
_root="$(git rev-parse --show-toplevel)"
# shellcheck disable=SC1090
[[ -f "$_root/impl_c.sh" ]] && source "$_root/impl_c.sh"
_v="$(_attr_c_helper)"
printf '  \xe2\x9c\x93 [SPEC-1] helper returned %s\n' "$_v"
SEOF
    chmod +x tests/attr-c-test.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: impl_c + a test that cannot parse-run at baseline"
)
DM_C="$REPO_C/design.md"
cat > "$DM_C" <<'EOF'
```acceptance
SPEC-1[change]: _attr_c_helper exists at HEAD
TESTFILES:
SPEC-1: tests/attr-c-test.sh
```
EOF
set +e; OUT_C="$(acceptance_negctl_check "$DM_C" "$REPO_C")"; RC_C=$?; set -e

assert_contains "[SPEC-3] a 127 baseline with no tagged evidence → harness error" \
    "$OUT_C" "NEGCTL ERROR harness:SPEC-1"
assert_eq "[SPEC-3] it is NOT reported as a passing control" \
    "" "$(grep 'NEGCTL PASS SPEC-1' <<<"$OUT_C" || true)"
assert_eq "[SPEC-3] it is NOT reported as a tautology" \
    "" "$(grep 'tautology' <<<"$OUT_C" || true)"

# ═══════════════════════════════════════════════════════════════════════════════
# SPEC-4 — a SPEC already green at the merge-base is still a tautology
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "4. per-assertion evidence still detects a tautology"

REPO_D="$(setup_git_temp_repo negctl-attr-d)"
(
    cd "$REPO_D"
    printf '# present at baseline too\n' > anchor_d.sh
    "$GIT" add anchor_d.sh; "$GIT" commit -q -m "baseline: anchor"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '# unrelated impl\n' > impl_d.sh
    # ✓ at BOTH revisions — asserts nothing about the change.
    cat > tests/attr-d-test.sh <<'SEOF'
#!/usr/bin/env bash
_root="$(git rev-parse --show-toplevel)"
if [[ -f "$_root/anchor_d.sh" ]]; then
    printf '  \xe2\x9c\x93 [SPEC-1] anchor_d.sh found\n'; exit 0
fi
printf '  \xe2\x9c\x97 [SPEC-1] anchor_d.sh missing\n'; exit 1
SEOF
    chmod +x tests/attr-d-test.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: impl_d + a tautological tagged test"
)
DM_D="$REPO_D/design.md"
cat > "$DM_D" <<'EOF'
```acceptance
SPEC-1[change]: anchor_d.sh present at HEAD
TESTFILES:
SPEC-1: tests/attr-d-test.sh
```
EOF
set +e; OUT_D="$(acceptance_negctl_check "$DM_D" "$REPO_D")"; RC_D=$?; set -e

assert_contains "[SPEC-4] a SPEC green at the merge-base is a tautology" \
    "$OUT_D" "NEGCTL FAIL SPEC-1 tautology"
assert_eq "[SPEC-4] overall rc=1" "1" "$RC_D"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
