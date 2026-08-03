#!/usr/bin/env bash
# Tests: ADR-036 (#922) — Level-1 SPEC→assertion tag-presence coverage gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-coverage.sh
source "$REPO_ROOT/scripts/lib/acceptance-coverage.sh"

print_test_header "acceptance coverage — Level-1 SPEC tag-presence (#922)"
setup_test_env "acceptance-coverage"

ROOT="$TEST_TEMP_DIR"          # acts as repo_root for relative TESTFILES
mkdir -p "$ROOT/tests"

_design() {  # _design <acceptance-body>  → writes $ROOT/design.md, echoes path
    local body="$1"
    {
        printf '# Design\n\n## Decision\nd.\n\n```scope\nfoo.sh\n```\n\n'
        printf '```acceptance\n%s\n```\n' "$body"
    } > "$ROOT/design.md"
    printf '%s' "$ROOT/design.md"
}

# ── C1: all SPECs tagged → pass, no UNTAGGED output ───────────────────────────
printf 'assert_eq "[SPEC-1] foo" 1 1\n'  > "$ROOT/tests/a-test.sh"
printf 'assert_eq "[SPEC-2] bar" 1 1\n'  > "$ROOT/tests/b-test.sh"
dm="$(_design "SPEC-1: foo works
SPEC-2: bar works
TESTFILES:
tests/a-test.sh
tests/b-test.sh")"
set +e; out="$(acceptance_coverage_check "$dm" "$ROOT")"; rc=$?; set -e
assert_eq "C1: all-tagged → rc=0" "0" "$rc"
assert_eq "C1: no UNTAGGED lines" "" "$out"

# ── C2: one SPEC untagged → fail, names SPEC-2 ────────────────────────────────
printf 'assert_eq "[SPEC-1] foo" 1 1\n'  > "$ROOT/tests/a-test.sh"
printf 'assert_eq "unrelated label" 1 1\n' > "$ROOT/tests/b-test.sh"
dm="$(_design "SPEC-1: foo works
SPEC-2: bar works
TESTFILES:
tests/a-test.sh
tests/b-test.sh")"
set +e; out="$(acceptance_coverage_check "$dm" "$ROOT")"; rc=$?; set -e
assert_eq "C2: one untagged → rc=1" "1" "$rc"
assert_eq "C2: names the untagged spec" "UNTAGGED SPEC-2" "$out"

# ── C3: no acceptance block → no SPEC-n ids → no-op pass ──────────────────────
{ printf '# Design\n\n## Decision\nd.\n\n```scope\nfoo.sh\n```\n'; } > "$ROOT/design.md"
set +e; out="$(acceptance_coverage_check "$ROOT/design.md" "$ROOT")"; rc=$?; set -e
assert_eq "C3: no block → rc=0" "0" "$rc"
assert_eq "C3: no UNTAGGED lines" "" "$out"

# ── C4: SPECs declared but zero TESTFILES → every SPEC untagged ───────────────
dm="$(_design "SPEC-1: foo works
TESTFILES:")"
set +e; out="$(acceptance_coverage_check "$dm" "$ROOT")"; rc=$?; set -e
assert_eq "C4: SPEC with no TESTFILES → rc=1" "1" "$rc"
assert_eq "C4: names the untagged spec" "UNTAGGED SPEC-1" "$out"

# ── C5: TESTFILE listed but missing on disk → untagged ────────────────────────
rm -f "$ROOT/tests/missing-test.sh"
dm="$(_design "SPEC-1: foo works
TESTFILES:
tests/missing-test.sh")"
set +e; out="$(acceptance_coverage_check "$dm" "$ROOT")"; rc=$?; set -e
assert_eq "C5: missing TESTFILE on disk → rc=1" "1" "$rc"
assert_eq "C5: names the untagged spec" "UNTAGGED SPEC-1" "$out"

# ── C6: legacy bare 'SPEC:' lines carry no id → not gated (no-op pass) ─────────
dm="$(_design "SPEC: legacy untagged claim
TESTFILES:
tests/a-test.sh")"
set +e; out="$(acceptance_coverage_check "$dm" "$ROOT")"; rc=$?; set -e
assert_eq "C6: bare SPEC: (no id) → rc=0 (not gated)" "0" "$rc"

# ── C7 (#1255): a [guard] SPEC is EXEMPT from the tag-coverage requirement ────
# Mirrors the acceptance-gate's negctl guard exemption: guards are invariants,
# not new behavior, so they need not have a [SPEC-n]-tagged test.
printf 'assert_eq "unrelated label" 1 1\n' > "$ROOT/tests/g-test.sh"
dm="$(_design "SPEC-1[guard]: an invariant that must not break
TESTFILES:
tests/g-test.sh")"
set +e; out="$(acceptance_coverage_check "$dm" "$ROOT")"; rc=$?; set -e
assert_eq "C7: guard-only, no tagged test → rc=0 (exempt)" "0" "$rc"
assert_eq "C7: no UNTAGGED lines for a guard SPEC" "" "$out"

# ── C8 (#1255 regression guard): a [change] SPEC still REQUIRES a tagged test ─
dm="$(_design "SPEC-1[change]: new behavior
TESTFILES:
tests/g-test.sh")"
set +e; out="$(acceptance_coverage_check "$dm" "$ROOT")"; rc=$?; set -e
assert_eq "C8: [change] with no tagged test → rc=1 (no regression)" "1" "$rc"
assert_eq "C8: names the untagged change spec" "UNTAGGED SPEC-1" "$out"

# ── C9 (#1255): mixed design — guard exempt, change still gated ───────────────
printf 'assert_eq "[SPEC-2] tagged" 1 1\n' > "$ROOT/tests/c-test.sh"
dm="$(_design "SPEC-1[guard]: an invariant
SPEC-2[change]: new behavior with a tagged test
SPEC-3[change]: new behavior WITHOUT a tagged test
TESTFILES:
tests/c-test.sh")"
set +e; out="$(acceptance_coverage_check "$dm" "$ROOT")"; rc=$?; set -e
assert_eq "C9: mixed → rc=1 (only the untagged change flagged)" "1" "$rc"
assert_eq "C9: flags only SPEC-3, not the guard SPEC-1" "UNTAGGED SPEC-3" "$out"

# ── C10: [SPEC-2] acceptance_find_assertion_label — label found in testfile ────
printf '#!/usr/bin/env bash\n# [SPEC-1] the feature works correctly\nassert_eq "ok" 1 1\n' \
    > "$ROOT/tests/labeled-test.sh"
set +e
c10_label="$(acceptance_find_assertion_label "$ROOT" "SPEC-1" "tests/labeled-test.sh")"
set -e
assert_eq "[SPEC-2] C10: label extracted from testfile" \
    "# [SPEC-1] the feature works correctly" "$c10_label"

# ── C11: [SPEC-2] acceptance_find_assertion_label — empty when tag absent ──────
printf '#!/usr/bin/env bash\n# no tag here\nassert_eq "ok" 1 1\n' \
    > "$ROOT/tests/untagged-test.sh"
set +e
c11_label="$(acceptance_find_assertion_label "$ROOT" "SPEC-1" "tests/untagged-test.sh")"
c11_rc=$?
set -e
assert_eq "[SPEC-2] C11: no tag returns 0" "0" "$c11_rc"
assert_eq "[SPEC-2] C11: no tag returns empty string" "" "$c11_label"

# ── C12: [SPEC-2] acceptance_find_assertion_label — truncates at 60 chars ──────
# Create a testfile whose [SPEC-1] line is 61 characters:
# "# [SPEC-1] " (11) + "abcdefghijklmnopqrstuvwxyz " (27) + "ABCDEFGHIJKLMNOPQRSTUVW" (23) = 61
printf '#!/usr/bin/env bash\n# [SPEC-1] abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVW\nassert_eq "ok" 1 1\n' \
    > "$ROOT/tests/long-label-test.sh"
set +e
c12_label="$(acceptance_find_assertion_label "$ROOT" "SPEC-1" "tests/long-label-test.sh")"
set -e
c12_len="$(printf '%s' "$c12_label" | wc -c | tr -d ' ')"
assert_eq "[SPEC-2] C12: long label truncated (len <= 63 bytes: 60 chars + 3-byte ellipsis)" \
    "1" "$(( c12_len <= 63 ? 1 : 0 ))"
assert_contains "[SPEC-2] C12: truncated label ends with ellipsis" "$c12_label" "…"

# ── C13: [SPEC-2] acceptance_find_assertion_label — first match wins across files
printf '#!/usr/bin/env bash\n# [SPEC-1] first file match\n' > "$ROOT/tests/first-test.sh"
printf '#!/usr/bin/env bash\n# [SPEC-1] second file match\n' > "$ROOT/tests/second-test.sh"
set +e
c13_label="$(acceptance_find_assertion_label "$ROOT" "SPEC-1" \
    "tests/first-test.sh" "tests/second-test.sh")"
set -e
assert_eq "[SPEC-2] C13: first file match returned" "# [SPEC-1] first file match" "$c13_label"

cleanup_test_env
print_test_results  # exits with $FAIL
