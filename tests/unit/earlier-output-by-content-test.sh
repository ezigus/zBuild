#!/usr/bin/env bash
# tests/unit/earlier-output-by-content-test.sh — a stage finds earlier work by
# what it contains, never by which stage made it (#2364, ADR-055 §1, ADR-067 §8).
#
# Why: stages don't know about each other. Every stage is handed every earlier
# stage's latest output (the engine's index); a stage that needs one of them
# picks it by its content — an acceptance block, a plan's work items, the issue
# text — never by another stage's output name or file name.
#
# C1 [change] earlier_output_with_text finds the output whose content matches,
#             whatever it is called
# C2 [change] earlier_output_with_json finds the JSON output a jq test is true of
# C3 [guard]  nothing matches: empty, rc 1
# C4 [change] with no index, the artifacts and state directories are searched
# C5 [change] intake's result carries the issue text (data.issue_text) — the real
#             intake stage run on a mocked issue
# C6 [change] no plugin's code names another stage's output (the lint passes)
# C7 [change] a deploy result is found by whether it says anything was deployed
# C8 [change] an empty issue text is not an issue text (rc 1)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "a stage finds earlier work by content (#2364)"
setup_test_env "earlier-output-by-content"
# shellcheck source=../../scripts/lib/earlier-output.sh
source "$REPO_ROOT/scripts/lib/earlier-output.sh"

D="$TEST_TEMP_DIR/out"; mkdir -p "$D"
printf '# notes\nnothing here\n' > "$D/zz-notes.md"
printf '# D\n```acceptance\nSPEC-1[code]: x\n```\n' > "$D/whatever-name.md"
printf '{"steps":[{"id":"s1"}],"goal":"g"}\n' > "$D/a1.json"
printf '{"result_contract":3,"outcome":"pass","reason":"x"}\n' > "$D/a2.json"
jq -n --arg a "$D/zz-notes.md" --arg b "$D/whatever-name.md" --arg c "$D/a1.json" --arg e "$D/a2.json" \
    '{schema_version:2, stage:"x", inputs:{one:$a, two:[$b], three:$c, four:$e}}' > "$TEST_TEMP_DIR/idx.json"
export ZBUILD_STAGE_INPUTS="$TEST_TEMP_DIR/idx.json"

# ── C1 / C2 / C3 ─────────────────────────────────────────────────────────────
assert_eq "[C1] the output holding an acceptance block is found by content" "$D/whatever-name.md" \
    "$(earlier_output_with_text '^```acceptance')"
assert_eq "[C2] the JSON output with work items is found by content" "$D/a1.json" \
    "$(earlier_output_with_json '(.steps | type) == "array"')"
earlier_output_with_text '^NOTHING-MATCHES' >/dev/null; _rc=$?
assert_eq "[C3] nothing matches: rc 1" "1" "$_rc"
assert_eq "[C3] ...and nothing printed" "" "$(earlier_output_with_json '.nope == 1')"

# ── C4 ───────────────────────────────────────────────────────────────────────
unset ZBUILD_STAGE_INPUTS
S="$TEST_TEMP_DIR/state"; mkdir -p "$S/artifacts"
printf '{"requirements":[{"id":"R-1","text":"t"}]}\n' > "$S/artifacts/r.json"
printf '+ ./\n' > "$S/scope.md"
export ZBUILD_STATE_DIR="$S"
assert_eq "[C4] with no index, the artifacts directory is searched" "$S/artifacts/r.json" \
    "$(earlier_output_with_json '(.requirements | type) == "array"')"
assert_eq "[C4] ...and the state directory" "$S/scope.md" "$(earlier_output_with_text '^\+ .*/$')"

# ── C7 ───────────────────────────────────────────────────────────────────────
# A deploy result is known by what it says: whether anything was deployed —
# true or false, a deploy that deployed nothing included.
R="$TEST_TEMP_DIR/rel"; mkdir -p "$R"
printf '{"result_contract":3,"outcome":"pass","reason":"x","data":{"pr_url":"u"}}\n' > "$R/a-other.json"
printf '{"result_contract":3,"outcome":"pass","reason":"gate not pass","data":{"deployed":false}}\n' > "$R/b-deploy.json"
assert_eq "[C7] a deploy result that deployed nothing is found" "$R/b-deploy.json" \
    "$(ZBUILD_STAGE_INPUTS="" ZBUILD_STATE_DIR="" ZBUILD_ARTIFACT_DIR="" earlier_deploy_result "$R")"
rm -f "$R/b-deploy.json"
assert_eq "[C7] a result that does not say whether anything was deployed is not one" "" \
    "$(ZBUILD_STAGE_INPUTS="" ZBUILD_STATE_DIR="" ZBUILD_ARTIFACT_DIR="" earlier_deploy_result "$R")"

# ── C5 ───────────────────────────────────────────────────────────────────────
# Run the real intake stage on a (mocked) issue and read its result.
_c5="$( unset ZBUILD_STAGE_INPUTS ZBUILD_STATE_DIR
    # shellcheck source=../../plugins/agent/intake/tests/intake-test-lib.sh
    source "$REPO_ROOT/plugins/agent/intake/tests/intake-test-lib.sh" >/dev/null 2>&1
    _set_gh_mock "C5 title" "C5-ISSUE-BODY-MARKER the body as written" 0
    unset ZBUILD_GOAL; export ZBUILD_ISSUE="$_ZB_ID"
    intake_run intake "$STATE_FILE" >/dev/null 2>&1
    earlier_issue_text "$ARTIFACT_DIR" 2>/dev/null )"
assert_contains "[C5] intake's result carries the issue text, found by what it is" "$_c5" "C5-ISSUE-BODY-MARKER"

# C8: an issue text that is empty is no issue text (rc 1, nothing printed).
E="$TEST_TEMP_DIR/empty-issue"; mkdir -p "$E"
printf '{"result_contract":3,"outcome":"pass","reason":"x","data":{"issue_text":""}}\n' > "$E/r.json"
ZBUILD_STAGE_INPUTS="" ZBUILD_STATE_DIR="" ZBUILD_ARTIFACT_DIR="" earlier_issue_text "$E" >/dev/null; _rc8=$?
# ── C9 (#2472: one grep for all the outputs) ─────────────────────────────────
E="$TEST_TEMP_DIR/c9"; mkdir -p "$E"
printf 'first\nfile 1 took 2s\n' > "$E/b-later.txt"
printf 'file 3 took 1s\n' > "$E/a-first.txt"
printf '{"x":"file 9 took 1s"}\n' > "$E/c.json"
: > "$E/d-empty.txt"
printf 'file 7 took 1s\n' > "$E/e-last.txt"
jq -n --arg a "$E/c.json" --arg b "$E/d-empty.txt" --arg c "$E/b-later.txt" --arg d "$E/a-first.txt" --arg e "$E/e-last.txt" --arg m "$E/missing.txt" \
    '{inputs:{one:$a, two:[$b, $m], three:$c, four:$d, five:$e}}' > "$TEST_TEMP_DIR/idx9.json"
_c9() { ZBUILD_STAGE_INPUTS="$TEST_TEMP_DIR/idx9.json" earlier_output_with_text "$@"; }
assert_eq "[C9] several hold the text: the first in the index, not the first by name" "$E/b-later.txt" "$(_c9 '^file [0-9]+ ')"
assert_eq "[C9] a JSON output is never a text match, an empty or missing one is skipped" "$E/a-first.txt" "$(_c9 '^file 3 ')"
assert_eq "[C9] a pattern starting with a dash is a pattern" "" "$(_c9 '-x')"
head -c 4096 /dev/urandom > "$E/0.bin"
jq -n --arg z "$E/0.bin" --arg d "$E/a-first.txt" '{inputs:{zero:$z, four:$d}}' > "$TEST_TEMP_DIR/idx9b.json"
assert_eq "[C9] a binary output before the match does not stop the search" "$E/a-first.txt" \
    "$(ZBUILD_STAGE_INPUTS="$TEST_TEMP_DIR/idx9b.json" earlier_output_with_text '^file 3 ')"

assert_eq "[C8] an empty issue text is not found: rc 1" "1" "$_rc8"

# ── C6 ───────────────────────────────────────────────────────────────────────
_out="$(bash "$REPO_ROOT/scripts/lib/lint-stage-output-names.sh" 2>&1)"; _rc=$?
assert_eq "[C6] no plugin names another stage's output" "0" "$_rc"
[[ $_rc -eq 0 ]] || printf '%s\n' "$_out" | head -20 >&2

cleanup_test_env
print_test_results
exit $((FAIL > 0))
