#!/usr/bin/env bash
# tests/unit/test-folders-test.sh — every test and test helper of this
# repository lives under its test folders (ADR-069 §10, amendment #2510).
#
# The test folders decide who may do what: test-author owns them, build may not
# change them, a SPEC's tests are found by searching them. A test or a helper
# outside them escapes all three. scripts/lib/lint-test-helper-place.sh finds a
# script outside the test folders that tests source and no production code
# sources or runs: a test helper beside production code.
#
# F1 [code] a helper beside production code, sourced only by a test, is refused by name
# F2 [code] a library production code sources, and a script production code runs, are not test helpers
# F7 [code] a script production code loads by a computed name (a folder and a
#           variable: providers/$p.sh) is not a test helper
# F3 [code] a helper inside the repository's own test folders passes; a mention in a comment is not a use
# F4 [code] the real tree has no test helper outside its test folders
# F5 [code] this repository's test folders are read from its own .zbuild/test-paths.txt
# F6 [code] every *-test.sh file of this repository is inside those folders
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/test-paths.sh
source "$REPO_ROOT/scripts/lib/test-paths.sh"

print_test_header "every test and test helper lives under the test folders (ADR-069 §10, #2510)"
setup_test_env "test-folders"

LINT="$REPO_ROOT/scripts/lib/lint-test-helper-place.sh"
assert_file_exists "[setup] the lint exists" "$LINT"

# A fake repository: its own test folders (tests/, qa/), production code that
# sources one library and runs one script, and tests that source all of them.
R="$TEST_TEMP_DIR/repo"
mkdir -p "$R/.zbuild" "$R/scripts/lib" "$R/tests/unit" "$R/tests/lib" "$R/qa/lib"
printf 'tests/*\nqa/*\n' > "$R/.zbuild/test-paths.txt"
printf '#!/usr/bin/env bash\nh() { :; }\n' > "$R/scripts/lib/beside-code.sh"
printf '#!/usr/bin/env bash\nl() { :; }\n' > "$R/scripts/lib/real-lib.sh"
printf '#!/usr/bin/env bash\necho tool\n' > "$R/scripts/tool.sh"
mkdir -p "$R/scripts/providers"
printf '#!/usr/bin/env bash\nprovider_x() { :; }\n' > "$R/scripts/providers/xprov.sh"
printf '#!/usr/bin/env bash\nt() { :; }\n' > "$R/tests/lib/in-tests.sh"
printf '#!/usr/bin/env bash\nq() { :; }\n' > "$R/qa/lib/in-qa.sh"
cat > "$R/scripts/main.sh" <<'EOF'
#!/usr/bin/env bash
source "$ROOT/scripts/lib/real-lib.sh"
# a comment is not a use: source "$ROOT/scripts/lib/beside-code.sh"
bash "$ROOT/scripts/tool.sh"
source "$ROOT/scripts/providers/$name.sh"
EOF
cat > "$R/tests/unit/a-test.sh" <<'EOF'
#!/usr/bin/env bash
source "$ROOT/scripts/lib/beside-code.sh"
source "$ROOT/scripts/lib/real-lib.sh"
. "$ROOT/scripts/tool.sh"
source "$ROOT/tests/lib/in-tests.sh"
source "$ROOT/qa/lib/in-qa.sh"
source "$ROOT/scripts/providers/xprov.sh"
EOF
git -C "$R" init -q
git -C "$R" add -A

_rc=0; _out="$(bash "$LINT" "$R" 2>&1)" || _rc=$?
assert_eq "[F1] a helper beside production code, sourced only by tests, is refused" "1" "$_rc"
assert_contains "[F1] ...naming the file" "$_out" "scripts/lib/beside-code.sh"
assert_contains "[F1] ...in plain words, naming the test folders" "$_out" "is sourced only by tests"
assert_contains "[F1] ...and the folders it belongs in" "$_out" "qa/*"
assert_eq "[F2] a library production code sources is not a test helper" \
    "0" "$(grep -c 'real-lib.sh' <<< "$_out")"
assert_eq "[F2] a script production code runs is not a test helper" \
    "0" "$(grep -c 'scripts/tool.sh' <<< "$_out")"
assert_eq "[F7] a script production code loads by a computed name is not a test helper" \
    "0" "$(grep -c 'xprov.sh' <<< "$_out")"
assert_eq "[F3] a helper in tests/ passes" "0" "$(grep -c 'in-tests.sh' <<< "$_out")"
assert_eq "[F3] a helper in the repository's own qa/ folder passes" \
    "0" "$(grep -c 'in-qa.sh' <<< "$_out")"

rm "$R/scripts/lib/beside-code.sh"
sed -i.bak '/beside-code/d' "$R/tests/unit/a-test.sh" && rm -f "$R/tests/unit/a-test.sh.bak"
_rc=0; bash "$LINT" "$R" >/dev/null 2>&1 || _rc=$?
assert_eq "[F3] with the helper gone, the fake repository is clean" "0" "$_rc"

_rc=0; _out="$(bash "$LINT" "$REPO_ROOT" 2>&1)" || _rc=$?
assert_eq "[F4] the real tree has no test helper outside its test folders" "0" "$_rc"
[[ "$_rc" -eq 0 ]] || printf '%s\n' "$_out" >&2
assert_contains "[F4] npm run lint runs it" \
    "$(jq -r '.scripts.lint' "$REPO_ROOT/package.json")" "bash scripts/lib/lint-test-helper-place.sh"

assert_file_exists "[F5] this repository declares its test folders" "$REPO_ROOT/.zbuild/test-paths.txt"
# Without the engine's default list, so the globs can only come from this file.
_globs="$(_ZBUILD_TEST_PATHS_DEFAULT="$TEST_TEMP_DIR/no-default.txt"; unset _ZBUILD_ROOT
    _g=""; zb_test_path_globs_v _g "$REPO_ROOT"; printf '%s' "$_g")"
assert_eq "[F5] the list is not empty" "1" "$([[ -n "$_globs" ]] && echo 1)"
assert_eq "[F5] they are read from .zbuild/test-paths.txt" \
    "$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$REPO_ROOT/.zbuild/test-paths.txt" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')" \
    "$_globs"

_outside=""
while IFS= read -r _f; do
    zb_is_test_path "$_f" "$REPO_ROOT" || _outside+="$_f "
done < <(git -C "$REPO_ROOT" ls-files --cached --others --exclude-standard -- '*-test.sh' ':!legacy-DoNotUse')
assert_eq "[F6] every *-test.sh file is inside the test folders" "" "$_outside"

print_test_results
