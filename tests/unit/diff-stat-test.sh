#!/usr/bin/env bash
# Unit: scripts/lib/diff-stat.sh — _zbuild_diff_stat (Wave 16-B, #699)
#
# Drives the helper with synthetic patches and asserts the formatted summary
# block: header has total file count + total +/- ; per-file rows list path +
# counts; paths are bare (no redaction wrappers); empty patch is non-crashing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "unit: diff-stat _zbuild_diff_stat (#699)"

# shellcheck source=../../scripts/lib/diff-stat.sh
source "$REPO_ROOT/scripts/lib/diff-stat.sh"

setup_test_env "diff-stat"

# ─── 1. Three-file patch with mixed add/del counts ───────────────────────────
print_test_section "1. multi-file unified patch"

PATCH1="$TEST_TEMP_DIR/p1.patch"
cat > "$PATCH1" <<'EOF'
diff --git a/core/foo.sh b/core/foo.sh
--- a/core/foo.sh
+++ b/core/foo.sh
@@ -1,2 +1,5 @@
 line1
+added1
+added2
+added3
 line2
diff --git a/core/bar.sh b/core/bar.sh
--- a/core/bar.sh
+++ b/core/bar.sh
@@ -1,3 +1,2 @@
 keep
-removed
 keep2
diff --git a/tests/new.sh b/tests/new.sh
new file mode 100644
--- /dev/null
+++ b/tests/new.sh
@@ -0,0 +1,4 @@
+#!/usr/bin/env bash
+echo a
+echo b
+echo c
EOF

out1="$(_zbuild_diff_stat "$PATCH1")"

assert_contains "header has total file count (3)" "$out1" "3 total"
assert_contains "header has total adds (+3+0+4 = +7)" "$out1" "+7"
assert_contains "header has total dels (-0-1-0 = -1)" "$out1" "-1"
assert_contains "first file listed" "$out1" "core/foo.sh"
assert_contains "second file listed" "$out1" "core/bar.sh"
assert_contains "new file listed" "$out1" "tests/new.sh"
assert_contains "foo per-file adds" "$out1" "+3"
assert_contains "bar per-file dels" "$out1" "-1"

# Paths must be bare — no redaction tag wrappers.
if grep -qF '<out-of-scope-context>' <<< "$out1"; then
    assert_fail "paths are bare (no wrappers)" "found <out-of-scope-context>"
else
    assert_pass "paths are bare (no wrappers)"
fi

# ─── 2. Empty / missing patch → header line only ─────────────────────────────
print_test_section "2. empty and missing patches"

empty_patch="$TEST_TEMP_DIR/empty.patch"
: > "$empty_patch"
out_empty="$(_zbuild_diff_stat "$empty_patch")"
assert_contains "empty patch → 0 total header" "$out_empty" "0 total"

out_missing="$(_zbuild_diff_stat "$TEST_TEMP_DIR/does-not-exist.patch")"
assert_contains "missing patch → 0 total header (no crash)" "$out_missing" "0 total"

# No args → no crash, 0 total
out_noarg="$(_zbuild_diff_stat)"
assert_contains "no arg → 0 total header (no crash)" "$out_noarg" "0 total"

# ─── 3. Header format exactly matches the spec ───────────────────────────────
print_test_section "3. header format"

header_line="$(printf '%s\n' "$out1" | head -n 1)"
# Expected shape: "## Changed files (N total, +A -D)"
if [[ "$header_line" =~ ^##\ Changed\ files\ \(3\ total,\ \+7\ -1\)$ ]]; then
    assert_pass "header exact format"
else
    assert_fail "header exact format" "got: $header_line"
fi

cleanup_test_env
print_test_results
