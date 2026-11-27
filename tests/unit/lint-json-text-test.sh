#!/usr/bin/env bash
# Tests: scripts/lib/lint-json-text.sh — a JSON string is written or read by
# the shell only in scripts/lib/json-text.sh.
#
# K1 [change] a hand-written JSON escape fails, naming the file and line: a
#             \u00XX built by printf, a quote escaped for JSON by replacement,
#             a quote read back by replacement, the string-body regex
# K2 [change] what passes: json-text.sh itself, a test file, a comment, a line
#             marked `# json-text-ok: <reason>` (a mark needs its reason)
# K3 [change] npm run lint runs it
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "lint-json-text — one JSON string writer and reader"
setup_test_env "lint-json-text"
_test_cleanup_hook() { cleanup_test_env; }
LINT="$REPO_ROOT/scripts/lib/lint-json-text.sh"

# _lint <file under root> <line> — the lint over a fresh tree holding one file
# with that line; `rc=<rc>` then its output.
_lint() {
    local root; root="$(mktemp -d "$TEST_TEMP_DIR/root.XXXXXX")" || { printf 'no temp folder\n' >&2; exit 1; }
    mkdir -p "$root/${1%/*}"
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$root/$1"
    local out rc=0
    out="$(bash "$LINT" "$root" 2>&1)" || rc=$?
    printf 'rc=%s\n%s\n' "$rc" "$out"
}
_rc() { local o; o="$(_lint "$@")"; printf '%s' "${o%%$'\n'*}"; }
L=scripts/lib/x.sh

print_test_section "K1: a hand-written JSON escape fails"
_k1="$(_lint "$L" "    printf -v e '\\u%04x' \"\$i\"")"
assert_eq "[K1] a backslash-u00XX escape built by printf fails" "rc=1" "${_k1%%$'\n'*}"
assert_contains "[K1] ...naming the file and line" "$_k1" "scripts/lib/x.sh:2"
assert_contains "[K1] ...and what to use" "$_k1" "zb_json_str_v"
assert_eq "[K1] a quote escaped by replacement" "rc=1" "$(_rc core/y.sh '    s="${s//\"/\\\"}"')"
assert_eq "[K1] a quote read back by replacement" "rc=1" "$(_rc plugins/agent/p/lib/z.sh '    s="${s//\\\"/\"}"')"
assert_eq "[K1] the string-body regex" "rc=1" "$(_rc "$L" "    local re='\"(([^\"\\\\]|\\\\.)*)\"'")"

print_test_section "K2: what passes"
assert_eq "[K2] json-text.sh itself" "rc=0" "$(_rc scripts/lib/json-text.sh '    s="${s//\"/\\\"}"')"
assert_eq "[K2] a test file" "rc=0" "$(_rc tests/unit/a-test.sh '    s="${s//\"/\\\"}"')"
assert_eq "[K2] a plugin's test file" "rc=0" "$(_rc plugins/agent/p/tests/a-test.sh '    s="${s//\"/\\\"}"')"
assert_eq "[K2] a comment" "rc=0" "$(_rc "$L" '# we used to write s="${s//\"/\\\"}" here')"
assert_eq "[K2] a line marked with its reason" "rc=0" "$(_rc "$L" '    s="${s//\"/\\\"}"   # json-text-ok: a shell double-quoted word, not JSON')"
assert_eq "[K2] a mark with no reason fails" "rc=1" "$(_rc "$L" '    s="${s//\"/\\\"}"   # json-text-ok:')"
assert_eq "[K2] a tree with none" "rc=0" "$(_rc "$L" '    zb_json_str_v s "$t"')"

print_test_section "#2640: a tab-separated read fails"
assert_eq "[#2640/SPEC-4] a jq @tsv read fails" "rc=1" "$(_rc "$L" "    IFS=\$'\\t' read -r a b < <(jq -r '[.a, .b] | @tsv' f)")"
assert_contains "[#2640/SPEC-4] ...saying what to use" "$(_lint "$L" "    x=\"\$(jq -r '[.a] | @tsv' f)\"")" "read it NUL-separated"
assert_eq "[#2640/SPEC-4] ...in a plugin too" "rc=1" "$(_rc plugins/tool/g/plugin.sh "    jq -r '[.a,.b]|@tsv' f")"
assert_eq "[#2640/SPEC-4] a comment naming it passes" "rc=0" "$(_rc "$L" '# not @tsv: it doubles a backslash')"

print_test_section "K3: npm run lint runs it"
assert_contains "[K3] package.json's lint" "$(jq -r '.scripts.lint' "$REPO_ROOT/package.json")" "bash scripts/lib/lint-json-text.sh"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
