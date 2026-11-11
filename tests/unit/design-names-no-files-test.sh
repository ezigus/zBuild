#!/usr/bin/env bash
# tests/unit/design-names-no-files-test.sh — design names no files (#2508,
# ADR-069 §11, ADR-070 §6).
#
# #1805 run 42556446368 ended on a file design's lists did not name: design
# guessed every test file (TESTFILES) and every file of the change (a scope
# block) before any code or test existed. Now it names none. Which file holds a
# SPEC's test is found from the SPEC's tag in the repository's test folders.
#
# N1 a design with no TESTFILES and no scope block passes design's checks
# N2 a SPEC's test file is the file in a test folder that holds its tag
# N3 a file outside the test folders that holds the tag is not its test
# N4 a file test-author has not committed yet is found too
# N5 a repository's own .zbuild/test-paths.txt decides the test folders
# N6 every SPEC's files, once: the union the gate and test-author read
# N7 an old design's TESTFILES list is not read, nor its lines taken for SPECs
# N8 design's prompt asks for no scope block and no TESTFILES
# N9 design's prompt asks it to write UNCLEAR lines and carry on with the assumption
# N10 a malformed UNCLEAR line is refused by design's checks
# N11 on an issue's branch, a SPEC's tests are only the test files the branch added
#     or changed: a file the default branch already had, holding the tag as
#     sample text, is not its test (#2517)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "design names no files; a SPEC's test is found by its tag (#2508)"
setup_test_env "design-names-no-files"
_test_cleanup_hook() { cleanup_test_env; }
assert_not_contains() {
    if grep -qF -- "$3" <<< "$2"; then assert_fail "$1" "output holds: $3"; else assert_pass "$1"; fi
}

# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
# shellcheck source=../../plugins/agent/design/lib/checks.sh
source "$REPO_ROOT/plugins/agent/design/lib/checks.sh"

ROOT="$TEST_TEMP_DIR/repo"
mkdir -p "$ROOT/tests/unit" "$ROOT/scripts" "$ROOT/docs"
git -C "$ROOT" init --quiet
git -C "$ROOT" config user.email t@example.com
git -C "$ROOT" config user.name t
ZBUILD_ISSUE="$(zb_test_issue)"
export ZBUILD_REPO_ROOT="$ROOT" ZBUILD_ISSUE
T1="$(acceptance_spec_tag DSWORK-1)"; T2="$(acceptance_spec_tag DSWORK-2)"
TO="[#$((ZBUILD_ISSUE + 1))/DSWORK-1]"

printf 'assert "%s works" 1 1\n' "$T1" > "$ROOT/tests/unit/work-test.sh"
printf 'assert "%s other" 1 1\n' "$T2" > "$ROOT/tests/unit/other-test.sh"
printf '# the tag %s quoted in a document\n' "$T1" > "$ROOT/docs/notes.md"
printf 'assert "%s another issue" 1 1\n' "$TO" > "$ROOT/tests/unit/issue78-test.sh"
: > "$ROOT/scripts/wire.sh"
git -C "$ROOT" add -A && git -C "$ROOT" commit --quiet -m base

DESIGN="$TEST_TEMP_DIR/design.md"
cat > "$DESIGN" <<'EOF'
# Design

## Decision
Do the thing.

```acceptance
DSWORK-1[code]: the thing works
  When: it runs
  Then: it is done
DSWORK-2[code]: the other thing works
  When: it runs again
  Then: it is done again
WIRING: scripts/wire.sh
```
EOF

# ── N1 ─────────────────────────────────────────────────────────────────────
_design_checks "$DESIGN" "$ROOT" ""
assert_eq "[N1] a design with no TESTFILES and no scope block passes design's checks" \
    "" "${_DESIGN_VIOLATIONS[*]-}"

# ── N2 / N3 ────────────────────────────────────────────────────────────────
assert_eq "[N2] DSWORK-1's test file is the test-folder file holding its tag" \
    "tests/unit/work-test.sh" "$(acceptance_list_testfiles_for_spec "$DESIGN" DSWORK-1)"
assert_not_contains "[N3] a document holding the tag is not a test file" \
    "$(acceptance_list_testfiles_for_spec "$DESIGN" DSWORK-1)" "docs/notes.md"
assert_not_contains "[N3] another issue's tag for the same id is not this SPEC's" \
    "$(acceptance_list_testfiles_for_spec "$DESIGN" DSWORK-1)" "issue78-test.sh"

# ── N4 ─────────────────────────────────────────────────────────────────────
printf 'assert "%s new" 1 1\n' "$T2" > "$ROOT/tests/unit/new-test.sh"
assert_contains "[N4] an uncommitted test file holding the tag is found" \
    "$(acceptance_list_testfiles_for_spec "$DESIGN" DSWORK-2)" "tests/unit/new-test.sh"

# ── N5 ─────────────────────────────────────────────────────────────────────
mkdir -p "$ROOT/.zbuild" "$ROOT/spec"
printf 'spec/*\n' > "$ROOT/.zbuild/test-paths.txt"
printf 'it "%s works"\n' "$T1" > "$ROOT/spec/work_spec.rb"
_n5="$(acceptance_list_testfiles_for_spec "$DESIGN" DSWORK-1)"
assert_eq "[N5] the repository's own test folders decide where a test is found" \
    "spec/work_spec.rb" "$_n5"
rm -rf "$ROOT/.zbuild" "$ROOT/spec"

# ── N6 ─────────────────────────────────────────────────────────────────────
assert_eq "[N6] every SPEC's test files, each once, sorted" \
    "tests/unit/new-test.sh tests/unit/other-test.sh tests/unit/work-test.sh" \
    "$(acceptance_list_testfiles "$DESIGN" | tr '\n' ' ' | sed 's/ $//')"

# ── N7 ─────────────────────────────────────────────────────────────────────
OLD="$TEST_TEMP_DIR/old-design.md"
cat > "$OLD" <<'EOF'
```acceptance
DSWORK-1[code]: the thing works
  When: it runs
  Then: it is done
TESTFILES:
DSWORK-1: tests/unit/listed-test.sh
WIRING: none
```
EOF
printf 'assert "untagged" 1 1\n' > "$ROOT/tests/unit/listed-test.sh"
assert_eq "[N7] an old design's TESTFILES list is not read" \
    "tests/unit/work-test.sh" "$(acceptance_list_testfiles_for_spec "$OLD" DSWORK-1)"
assert_eq "[N7] its binding line is not read as a SPEC" \
    "DSWORK-1" "$(acceptance_list_spec_ids "$OLD")"

# ── N8 / N9: design's prompt ───────────────────────────────────────────────
(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh"
    _route_resolve_max_turns() { printf '9'; }
    _route_resolve_timeout()   { printf '60'; }
    route_to_model() { return 0; }
    apply_scope_redaction() { cp "$1" "$2"; }
    atomic_write() { cat - > "$1"; }
    art="$TEST_TEMP_DIR/state/artifacts"; mkdir -p "$art"
    printf 'scope: all\n' > "$TEST_TEMP_DIR/state/scope-manifest.md"
    export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/state/events.jsonl" ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/state"
    _design_stage_run_inner "$TEST_TEMP_DIR/state/scope-manifest.md" "$art/design.md" "$art" >/dev/null 2>&1 || true
)
PROMPT="$(cat "$TEST_TEMP_DIR/state/artifacts/design-prompt.txt" 2>/dev/null || true)"
assert_contains "fixture: design's prompt was written" "$PROMPT" "acceptance"
assert_not_contains "[N8] design is not asked for a scope block" "$PROMPT" '```scope'
assert_not_contains "[N8] design is not asked for TESTFILES" "$PROMPT" "TESTFILES"
assert_contains "[N9] design is told how to mark a requirement it does not understand" \
    "$PROMPT" "UNCLEAR: <id> | <the question> | <what you assumed>"
assert_contains "[N9] and to carry on with what it assumed" "$PROMPT" "carry on with that assumption"

# ── N10 ────────────────────────────────────────────────────────────────────
BAD="$TEST_TEMP_DIR/bad-design.md"
{ cat "$DESIGN"; printf '\nUNCLEAR: R-1 does --from-stage need --resume?\n'; } > "$BAD"
_design_checks "$BAD" "$ROOT" ""
assert_contains "[N10] a malformed UNCLEAR line is refused" "${_DESIGN_VIOLATIONS[*]-}" "UNCLEAR_MALFORMED"
_n10=""; for v in "${_DESIGN_VIOLATIONS[@]}"; do _n10+="$(_dck_plain "$v")"; done
assert_contains "[N10] and design is told the form" "$_n10" "UNCLEAR: <id> | <the question> | <what you assumed>"
GOOD="$TEST_TEMP_DIR/good-design.md"
{ cat "$DESIGN"; printf '\nUNCLEAR: R-1 | does --from-stage need --resume? | it works on its own\n'; } > "$GOOD"
_design_checks "$GOOD" "$ROOT" ""
assert_eq "[N10] a well-formed UNCLEAR line passes" "" "${_DESIGN_VIOLATIONS[*]-}"

# ── N11 ────────────────────────────────────────────────────────────────────
# On #1805 run 42817975218 an engine test holding [#1805/DSFSTG-1] as sample text
# was run as DSFSTG-1's test. work-test.sh is on the default branch; the branch
# adds its own test and changes other-test.sh.
git -C "$ROOT" add -A >/dev/null 2>&1; git -C "$ROOT" commit --quiet -m "base 2" >/dev/null 2>&1
git -C "$ROOT" checkout --quiet -b issue-work
printf 'assert "%s on the branch" 1 1\n' "$T1" > "$ROOT/tests/unit/branch-test.sh"
git -C "$ROOT" add -A && git -C "$ROOT" commit --quiet -m work
printf 'assert "%s changed, not committed" 1 1\n' "$T2" >> "$ROOT/tests/unit/other-test.sh"
assert_eq "[N11] on a branch, a SPEC's test is the file the branch added, not one the default branch had" \
    "tests/unit/branch-test.sh" "$(acceptance_list_testfiles_for_spec "$DESIGN" DSWORK-1)"
assert_contains "[N11] ...and a file the branch changed (not yet committed) counts" \
    "$(acceptance_list_testfiles_for_spec "$DESIGN" DSWORK-2)" "tests/unit/other-test.sh"
assert_not_contains "[N11] ...but an untouched file of the default branch does not" \
    "$(acceptance_list_testfiles_for_spec "$DESIGN" DSWORK-1)" "tests/unit/work-test.sh"
# A branch with no base in common with the default branch (as in a shallow
# clone) has no branch work to tell apart: every test file counts.
git -C "$ROOT" checkout --quiet --orphan lone && git -C "$ROOT" commit --quiet -am lone
assert_contains "[N11] with no common base, every test file counts" \
    "$(acceptance_list_testfiles_for_spec "$DESIGN" DSWORK-1)" "tests/unit/work-test.sh"

print_test_results
exit $((FAIL > 0))
