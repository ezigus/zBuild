#!/usr/bin/env bash
# Tests: render_diff_md — built-in diff renderer (#470)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/golden.sh
source "$REPO_ROOT/scripts/lib/golden.sh"

print_test_header "render_diff_md (#470)"
setup_test_env "render-diff"

# shellcheck source=../../scripts/lib/artifact-render.sh
source "$REPO_ROOT/scripts/lib/artifact-render.sh"

# ─── D1: multi-file diff → golden ────────────────────────────────────────────
input="$(cat "$REPO_ROOT/tests/fixtures/render/diff-multifile.patch")"
out="$(render_diff_md "$input")"
set +e
assert_golden "render-diff.md" "$out"
gold_rc=$?
set -e
if [[ $gold_rc -eq 0 ]]; then
    assert_pass "D1 multi-file diff matches render-diff.md.golden"
else
    assert_fail "D1 multi-file diff matches render-diff.md.golden" "rc=$gold_rc"
fi

# ─── D2: empty input → "_no changes_" ────────────────────────────────────────
out="$(render_diff_md "")"
assert_eq "D2 empty diff placeholder" "_no changes_" "$out"
out="$(render_diff_md $'\n\n')"
assert_eq "D2 whitespace-only diff placeholder" "_no changes_" "$out"

# ─── D3: no diff --git header → fenced raw passthrough ───────────────────────
out="$(render_diff_md "this is not a diff")"
assert_contains "D3 raw passthrough body" "$out" "this is not a diff"
assert_contains_regex "D3 raw passthrough has fence" "$out" '^\`\`\`'

# ─── D4: single file modify → ## heading + ```diff fence ─────────────────────
d='diff --git a/x.sh b/x.sh
--- a/x.sh
+++ b/x.sh
@@ -1,1 +1,1 @@
-a
+b'
out="$(render_diff_md "$d")"
assert_contains "D4 modify heading" "$out" '## a/x.sh'
assert_contains_regex "D4 modify fence" "$out" '\`\`\`diff'

# ─── D5: new file → "(new)" suffix ───────────────────────────────────────────
d='diff --git a/n.sh b/n.sh
new file mode 100644
--- /dev/null
+++ b/n.sh
@@ -0,0 +1,1 @@
+x'
out="$(render_diff_md "$d")"
assert_contains "D5 new file heading" "$out" '## a/n.sh (new)'

# ─── D6: deleted file → "(deleted)" suffix ───────────────────────────────────
d='diff --git a/g.sh b/g.sh
deleted file mode 100644
--- a/g.sh
+++ /dev/null
@@ -1,1 +0,0 @@
-x'
out="$(render_diff_md "$d")"
assert_contains "D6 deleted heading" "$out" '## a/g.sh (deleted)'

# ─── D7: rename → "a/x → a/y" heading ────────────────────────────────────────
d='diff --git a/old.sh b/new.sh
similarity index 100%
rename from old.sh
rename to new.sh'
out="$(render_diff_md "$d")"
assert_contains "D7 rename heading uses unicode arrow" "$out" '## a/old.sh → a/new.sh'

# ─── D8: binary diff → placeholder, no fence ─────────────────────────────────
d='diff --git a/img.png b/img.png
index abc..def 100644
Binary files a/img.png and b/img.png differ'
out="$(render_diff_md "$d")"
assert_contains "D8 binary heading" "$out" '## a/img.png'
assert_contains "D8 binary placeholder" "$out" '_binary changes_'
if grep -qE '\`\`\`diff' <<< "$out"; then
    assert_fail "D8 no diff fence for binary" "fence emitted"
else
    assert_pass "D8 no diff fence for binary"
fi

# ─── D9: diff body containing ``` escalates fence to 4 backticks ─────────────
d='diff --git a/README.md b/README.md
--- a/README.md
+++ b/README.md
@@ -1,1 +1,2 @@
 # Title
+```new code```'
out="$(render_diff_md "$d")"
# Body contains ``` → outer fence must be ````.
assert_contains_regex "D9 4-backtick fence escalation" "$out" '\`\`\`\`diff'
# Inner ``` content preserved.
assert_contains "D9 inner backticks preserved" "$out" '+```new code```'

# ─── D10: drive the renderer without $() capture for accurate coverage ──────
_d10_tmp="$TEST_TEMP_DIR/d10.out"
render_diff_md "$input" > "$_d10_tmp"
assert_contains "D10 in-shell diff render works" "$(cat "$_d10_tmp")" "## a/scripts/foo.sh"
render_diff_md "" > "$_d10_tmp"
assert_contains "D10 empty no-changes" "$(cat "$_d10_tmp")" "_no changes_"
render_diff_md "not a diff" > "$_d10_tmp"
assert_contains "D10 raw passthrough" "$(cat "$_d10_tmp")" "not a diff"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
