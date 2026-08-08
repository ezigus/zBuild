#!/usr/bin/env bash
# tests/unit/deferred-tracker-rotate-sections-test.sh — rotate_update_sections
# no longer aborts on a body with zero prior update sections (#1751).
#
#   SPEC-1 [change]: a zero-section body does not abort the run
#   SPEC-2 [guard] : a body under max_keep is left intact
#   SPEC-3 [guard] : a body over max_keep drops oldest-first, retains max_keep
#
# `grep -c` prints "0" AND exits 1 on no-match, so the old
# `count="$(grep -c … || echo 0)"` yielded "0\n0" and the following
# `(( count <= max_keep ))` died with a syntax error — fatal under `set -e`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "deferred-tracker — rotate_update_sections (#1751)"
setup_test_env "deferred-tracker-rotate-sections"

TRACKER="$REPO_ROOT/scripts/deferred-tracker.sh"

# The script guards its entrypoint with [[ ${BASH_SOURCE[0]} == $0 ]], so
# sourcing gives us rotate_update_sections without running main.
# shellcheck source=/dev/null
source "$TRACKER"

# ─── SPEC-1: zero-section body must not abort ────────────────────────────────
print_test_section "1. zero-section body: no abort"

# Source-level guard on the antipattern itself. `|| true` here, deliberately —
# using `|| echo 0` would reintroduce the very bug under test.
bad_pattern_count="$(/usr/bin/grep -cE '\$\(.*grep[[:space:]]+-[a-zA-Z]*c[a-zA-Z]*[[:space:]].*\|\|[[:space:]]*echo' "$TRACKER" 2>/dev/null || true)"
bad_pattern_count="${bad_pattern_count//[^0-9]/}"
assert_eq "[SPEC-1] rotate_update_sections has no grep || echo antipattern" \
    "0" "${bad_pattern_count:-0}"

ZERO_BODY="$TEST_TEMP_DIR/zero-section.md"
cat > "$ZERO_BODY" <<'EOF'
# Deferred candidates

- [ ] PR #1 — `separate issue`
EOF
ZERO_BEFORE="$(cat "$ZERO_BODY")"

# Subshell isolation is load-bearing: at the merge-base the arithmetic aborts,
# and `set -e` would take this whole test file down with it — which would also
# rob SPEC-2/SPEC-3 of their baseline run.
rc=0
( rotate_update_sections "$ZERO_BODY" ) >/dev/null 2>&1 || rc=$?
assert_eq "[SPEC-1] rotate_update_sections exits cleanly on zero-section body" "0" "$rc"
assert_eq "[SPEC-1] body preserved unchanged on zero-section call" \
    "$ZERO_BEFORE" "$(cat "$ZERO_BODY")"

# ─── SPEC-2: body under max_keep is untouched ────────────────────────────────
print_test_section "2. single-section body: intact when under limit"

ONE_BODY="$TEST_TEMP_DIR/one-section.md"
cat > "$ONE_BODY" <<'EOF'
# Deferred candidates

## Update — 2026-08-01
- [ ] PR #10 — `follow-up`
EOF

rc=0
( UPDATE_SECTION_RETAIN=10 rotate_update_sections "$ONE_BODY" ) >/dev/null 2>&1 || rc=$?
ONE_AFTER="$(cat "$ONE_BODY")"
assert_contains "[SPEC-2] single-section body still has the update header" \
    "$ONE_AFTER" "## Update — 2026-08-01"
assert_contains "[SPEC-2] single-section body content preserved" \
    "$ONE_AFTER" "PR #10"

# ─── SPEC-3: over-limit body drops oldest first ──────────────────────────────
print_test_section "3. over-max body: oldest sections dropped"

MANY_BODY="$TEST_TEMP_DIR/many-sections.md"
{
    echo "# Deferred candidates"
    echo ""
    for n in 1 2 3 4 5; do
        echo "## Update — 2026-08-0${n}"
        echo "- [ ] PR #${n}0 — \`section ${n} marker\`"
        echo ""
    done
} > "$MANY_BODY"

rc=0
( UPDATE_SECTION_RETAIN=3 rotate_update_sections "$MANY_BODY" ) >/dev/null 2>&1 || rc=$?
MANY_AFTER="$(cat "$MANY_BODY")"

_hits_1="$(/usr/bin/grep -cF 'section 1 marker' "$MANY_BODY" 2>/dev/null || true)"
assert_eq "[SPEC-3] oldest section 1 was dropped" "0" "${_hits_1//[^0-9]/}"
_hits_2="$(/usr/bin/grep -cF 'section 2 marker' "$MANY_BODY" 2>/dev/null || true)"
assert_eq "[SPEC-3] oldest section 2 was dropped" "0" "${_hits_2//[^0-9]/}"
assert_contains "[SPEC-3] section 3 retained" "$MANY_AFTER" "section 3 marker"
assert_contains "[SPEC-3] section 4 retained" "$MANY_AFTER" "section 4 marker"
assert_contains "[SPEC-3] section 5 retained" "$MANY_AFTER" "section 5 marker"

# ─── SPEC-3: the shape format_update_section actually emits ──────────────────
print_test_section "4. production body shape: separators stay well-formed"

# format_update_section (deferred-tracker.sh:238) prefixes every section with
# a blank-line-padded '---'. A fixture of bare headers would not exercise the
# awk's `/^---$/ && suppress` arm at all, so rotation on a REAL body shape is
# asserted here: each retained section keeps exactly one separator, and no
# orphan separator is left where a dropped section used to be.
SEP_BODY="$TEST_TEMP_DIR/sep-sections.md"
{
    echo "# Deferred candidates"
    echo ""
    echo "...initial content..."
    for n in 1 2 3; do
        printf '\n\n---\n\n'
        echo "## Update — 2026-08-0${n}"
        echo "- [ ] PR #${n}0 — \`sep section ${n}\`"
    done
} > "$SEP_BODY"

rc=0
( UPDATE_SECTION_RETAIN=2 rotate_update_sections "$SEP_BODY" ) >/dev/null 2>&1 || rc=$?
SEP_AFTER="$(cat "$SEP_BODY")"

_sep_hits="$(/usr/bin/grep -cF 'sep section 1' "$SEP_BODY" 2>/dev/null || true)"
assert_eq "[SPEC-3] production-shape body drops the oldest section" "0" "${_sep_hits//[^0-9]/}"
assert_contains "[SPEC-3] production-shape body retains section 2" "$SEP_AFTER" "sep section 2"
assert_contains "[SPEC-3] production-shape body retains section 3" "$SEP_AFTER" "sep section 3"
# A separator COUNT is not discriminative — dropping a section removes one
# header and one '---' either way, so the count is 2 whether or not placement
# is correct. Assert placement instead, two ways:
#
# (a) structural: every '---' is followed by a '## Update — ' header. An orphan
#     separator (one left behind where a dropped section used to be) is exactly
#     a '---' that no longer leads a section, so this arm is what would redden.
_orphans="$(awk '
    /^---$/ { if (pending) orphan++; pending = 1; next }
    /^[[:space:]]*$/ { next }
    { if (pending && $0 !~ /^## Update — /) orphan++; pending = 0 }
    END { if (pending) orphan++; print orphan + 0 }
' "$SEP_BODY")"
assert_eq "[SPEC-3] every '---' still leads an update section (no orphan)" "0" "$_orphans"

# (b) exact: the rotated body must be byte-identical to a body that only ever
#     contained the retained sections, built through the same format. This is
#     the strongest available statement that rotation preserves the shape
#     format_update_section emits.
SEP_EXPECTED="$TEST_TEMP_DIR/sep-expected.md"
{
    echo "# Deferred candidates"
    echo ""
    echo "...initial content..."
    for n in 2 3; do
        printf '\n\n---\n\n'
        echo "## Update — 2026-08-0${n}"
        echo "- [ ] PR #${n}0 — \`sep section ${n}\`"
    done
} > "$SEP_EXPECTED"
assert_eq "[SPEC-3] rotated body is byte-identical to a natively-built body" \
    "$(cat "$SEP_EXPECTED")" "$SEP_AFTER"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
