#!/usr/bin/env bash
# tests/unit/file-mode-kept-on-replace-test.sh — a file the engine rewrites
# keeps its permission bits (#2225 §1).
#
# Why: #2219, #2221 and #2223 each flipped test files 100755 → 100644. The
# stale-tag step rewrote every declared testfile as `awk … > f.tmp && mv f.tmp f`
# (plugins/agent/test-author/plugin.sh) and atomic_write has the same temp+mv
# shape: the new file gets default permissions, so an executable loses its bit.
#
# P1 [change] atomic_write over an executable file keeps it executable
# P2 [change] the stale-tag step keeps a testfile executable (and still rewrites it)
# P3 [guard]  a NEW file from atomic_write is not made executable
# P4 [change] replace_keep_mode puts a file in place with the target's mode
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"

print_test_header "a rewritten file keeps its permission bits (#2225 §1)"
setup_test_env "file-mode-kept"
_ID="$(zb_test_issue)"

_is_exec() { [[ -x "$1" ]] && printf 'exec' || printf 'not-exec'; }

print_test_section "P1/P3: atomic_write"
F1="$TEST_TEMP_DIR/run.sh"; printf '#!/usr/bin/env bash\necho old\n' > "$F1"; chmod 755 "$F1"
printf '#!/usr/bin/env bash\necho new\n' | atomic_write "$F1" >/dev/null 2>&1
assert_contains "[P1] atomic_write replaced the content" "$(cat "$F1")" "echo new"
assert_eq "[P1] ...and the file is still executable" "exec" "$(_is_exec "$F1")"
F3="$TEST_TEMP_DIR/new.json"
printf '{}\n' | atomic_write "$F3" >/dev/null 2>&1
assert_eq "[P3] a new file is not made executable" "not-exec" "$(_is_exec "$F3")"

print_test_section "P2: the stale-tag step"
REPO="$TEST_TEMP_DIR/repo"; mkdir -p "$REPO/tests"
DESIGN="$TEST_TEMP_DIR/design.md"
cat > "$DESIGN" <<'EOF'
```acceptance
SPEC-1[change]: kept
TESTFILES:
tests/t-test.sh
```
EOF
printf '#!/usr/bin/env bash\n# [#%s/SPEC-1] kept\n# [#%s/SPEC-9] stale\n' "$_ID" "$_ID" > "$REPO/tests/t-test.sh"
chmod 755 "$REPO/tests/t-test.sh"
_ta_emit() { :; }
# shellcheck disable=SC1090
source <(sed -n '/^_ta_drop_stale_tags()/,/^}/p' "$REPO_ROOT/plugins/agent/test-author/plugin.sh")
ZBUILD_ISSUE="$_ID" _ta_drop_stale_tags "$DESIGN" "$REPO" >/dev/null 2>&1 || true
if grep -qF "SPEC-9]" "$REPO/tests/t-test.sh"; then
    assert_fail "[P2] fixture: the stale tag was dropped" "it is still there"
else
    assert_pass "[P2] fixture: the stale tag was dropped"
fi
assert_eq "[P2] the testfile is still executable" "exec" "$(_is_exec "$REPO/tests/t-test.sh")"
if compgen -G "$REPO/tests/t-test.sh.*" >/dev/null; then
    assert_fail "[P2] no temp or backup file is left in the repo" "$(ls "$REPO/tests")"
else
    assert_pass "[P2] no temp or backup file is left in the repo"
fi

print_test_section "P4: replace_keep_mode"
T4="$TEST_TEMP_DIR/target.sh"; printf 'old\n' > "$T4"; chmod 750 "$T4"
S4="$TEST_TEMP_DIR/src.tmp"; printf 'new\n' > "$S4"; chmod 600 "$S4"
if declare -F replace_keep_mode >/dev/null 2>&1; then
    replace_keep_mode "$S4" "$T4"
    assert_eq "[P4] the content is the new file's" "new" "$(cat "$T4")"
    _m="$(stat -f '%Lp' "$T4" 2>/dev/null || stat -c '%a' "$T4" 2>/dev/null)"
    assert_eq "[P4] the mode is the target's (750)" "750" "$_m"
else
    assert_fail "[P4] replace_keep_mode exists in helpers.sh" "not defined"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
