#!/usr/bin/env bash
# tests/unit/problem-list-join-test.sh — a check's list of problems reaches the
# model as written (#2598 R4, ADR-072 §3).
#
# #2532 run 45231040380: the red-team lens quoted `… macos ;;\n' > …`. Its
# check joined the problems with `;` and then put a space after every `;` —
# inside the quote too — so the re-ask showed it `; ;`. Eight checks did this.
#
# J1 [change] the shared join puts "; " between problems and leaves each one
#             exactly as written (`;;`, `a;b`)
# J2 [change] no check joins its problems by rewriting every `;`
# J3 [change] a lens's re-ask shows a quote's `;;` as the lens wrote it
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a check's problems reach the model as written (#2598)"
setup_test_env "problem-list-join"
# shellcheck source=../../scripts/lib/judge-quotes.sh
source "$REPO_ROOT/scripts/lib/judge-quotes.sh"

print_test_section "J1: the shared join"
_items=("finding 3's quote is not in a.sh: macos ;;" "a;b holds" "plain")
_out=""; judge_problems_join_v _out _items
assert_eq "[J1] each problem as written, \"; \" between" "finding 3's quote is not in a.sh: macos ;;; a;b holds; plain" "$_out"
_one=("only ;; one"); judge_problems_join_v _out _one
assert_eq "[J1] one problem is itself" "only ;; one" "$_out"
_none=(); judge_problems_join_v _out _none
assert_eq "[J1] no problems is empty" "" "$_out"

print_test_section "J2: no check rewrites every ;"
_hits="$(/usr/bin/grep -rnF '//;/; }' "$REPO_ROOT/core" "$REPO_ROOT/scripts" "$REPO_ROOT/plugins" --include='*.sh' 2>/dev/null || true)"
assert_eq "[J2] no '\${x//;/; }' anywhere in the engine" "" "$_hits"

print_test_section "J3: a lens's problem keeps a quote's ;;"
# shellcheck source=../../plugins/agent/review-lens/plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh" 2>/dev/null
R="$TEST_TEMP_DIR/repo"; mkdir -p "$R"; printf 'case x in a) : ;; esac\n' > "$R/a.sh"
_rep=$'SCORE: 4\nFINDING\nseverity: low\ncategory: logic\nfix: code\nintroduced: yes\nquote: a.sh | case y in b) : ;; esac\nmessage: m\ntrigger: t\naccepted if: a'
_j=""; _p=""; _rl_reply_problem "$_rep" _j _p
_q=""; _rl_quote_problem_v _q "$_j" "" "$R" ""
assert_contains "[J3] the re-ask shows the quote's ;; as written" "$_q" "b) : ;; esac"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
