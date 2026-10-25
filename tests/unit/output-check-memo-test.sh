#!/usr/bin/env bash
# tests/unit/output-check-memo-test.sh — an output is checked for damage once,
# and again only when it changes (ADR-055 §9 #1894, amended; ADR-065 §5).
#
# Every stage's start re-checked every earlier output with a jq: 456 jq in one
# three-run pipeline test, nearly all of them on files nobody had touched. A
# file that passes leaves a mark made BEFORE its check; a later check that finds
# the mark strictly newer than the file starts nothing. A write after the mark
# leaves the file no older than it, so it is checked again.
#
# M1 [change] a JSON output that passed is not parsed again while unchanged
# M2 [guard]  broken in place straight after it passed (no pause) — caught
# M3 [guard]  replaced by a broken file moved into place — caught
# M4 [guard]  a damaged file leaves no mark: caught each time, passes once fixed
# M5 [guard]  without a mark dir every call checks, as before
# M6 [guard]  an empty file is damaged, mark or not
# M7 [change] the index a stage gets: built twice over unchanged outputs, the
#             second build checks none of them again, and lists the same files
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"

print_test_header "output damage check: once per change (ADR-055 §9)"
setup_test_env "output-check-memo"

CALLS="$TEST_TEMP_DIR/calls"
jq() { printf 'jq\n' >> "$CALLS"; command jq "$@"; }
jqs() { local c; c="$(grep -c '^jq$' "$CALLS" 2>/dev/null)"; printf '%s' "${c:-0}"; }
MARKS="$TEST_TEMP_DIR/state/runtime/form-ok"
D="$TEST_TEMP_DIR/out"; mkdir -p "$D" "$TEST_TEMP_DIR/state/runtime"
dmg() { _inputs_damaged "$@" && printf damaged || printf ok; }

print_test_section "M1: unchanged"
F="$D/a.json"; printf '{"x":1}\n' > "$F"
: > "$CALLS"
_r1="$(dmg "$F" a "$MARKS")"; _n1="$(jqs)"
_r2="$(dmg "$F" a "$MARKS")"; _r3="$(dmg "$F" a "$MARKS")"
assert_eq "[M1] it passes each time" "ok ok ok" "$_r1 $_r2 $_r3"
assert_eq "[M1] one jq for the first check, none after" "1 1" "$_n1 $(jqs)"

print_test_section "M2: broken in place at once"
F="$D/b.json"; printf '{"x":1}\n' > "$F"
_r1="$(dmg "$F" b "$MARKS")"; printf '{"x":' > "$F"
assert_eq "[M2] passed, then broken straight after: caught" "ok damaged" "$_r1 $(dmg "$F" b "$MARKS")"

print_test_section "M3: replaced"
F="$D/c.json"; printf '{"x":1}\n' > "$F"
_r1="$(dmg "$F" c "$MARKS")"
printf '[1,' > "$D/c.new"; mv -f "$D/c.new" "$F"
assert_eq "[M3] a broken file moved over it: caught" "ok damaged" "$_r1 $(dmg "$F" c "$MARKS")"

print_test_section "M4: damaged stays checked"
F="$D/d.json"; printf 'nope' > "$F"
: > "$CALLS"
_r1="$(dmg "$F" d "$MARKS")"; _r2="$(dmg "$F" d "$MARKS")"
assert_eq "[M4] damaged both times, checked both times" "damaged damaged 2" "$_r1 $_r2 $(jqs)"
printf '{}\n' > "$F"; _r3="$(dmg "$F" d "$MARKS")"; printf '{' > "$F"
assert_eq "[M4] fixed it passes; broken again it is caught" "ok damaged" "$_r3 $(dmg "$F" d "$MARKS")"

print_test_section "M5: no mark dir"
F="$D/e.json"; printf '{}\n' > "$F"
: > "$CALLS"
dmg "$F" e >/dev/null; dmg "$F" e >/dev/null
assert_eq "[M5] two checks, two jq" "2" "$(jqs)"

print_test_section "M6: empty"
F="$D/f.json"; printf '{}\n' > "$F"
_r1="$(dmg "$F" f "$MARKS")"; : > "$F"
assert_eq "[M6] passed, then emptied: damaged" "ok damaged" "$_r1 $(dmg "$F" f "$MARKS")"

print_test_section "M7: the index, built twice"
SD="$TEST_TEMP_DIR/state"; PR="$TEST_TEMP_DIR/plugins"; mkdir -p "$PR" "$SD/artifacts"
printf '{"p":1}\n' > "$SD/artifacts/plan.json"; printf '{"d":1}\n' > "$SD/artifacts/design.json"
printf '# notes\n' > "$SD/artifacts/notes.md"
_TPL_STAGES=(plan design)
_seed() {
    _IR_INDEX_KEY="${PR}|${SD}|plan design "
    _IR_PATHS=([plan_out]="$SD/artifacts/plan.json" [design_out]="$SD/artifacts/design.json" [notes]="$SD/artifacts/notes.md")
    _IR_FORMAT=([plan_out]=json [design_out]=json [notes]=markdown)
    _IR_PRODUCER=([plan_out]=plan [design_out]=design [notes]=plan); _IR_ISMAP=()
}
_seed; _idx1="$(_inputs_resolve_stage design "$PR" "$SD")"; _j1="$(command jq -cS .inputs "$_idx1" 2>/dev/null)"
_seed; : > "$CALLS"
_idx2="$(_inputs_resolve_stage design "$PR" "$SD")"; _j2="$(command jq -cS .inputs "$_idx2" 2>/dev/null)"
assert_eq "[M7] the second build parses only for writing the index (no checks)" "1" "$(jqs)"
assert_eq "[M7] …and lists the same three outputs" "$_j1" "$_j2"
assert_contains "[M7] …the JSON ones among them" "$_j2" "plan.json"
unset -f jq

cleanup_test_env
print_test_results
exit $((FAIL > 0))
