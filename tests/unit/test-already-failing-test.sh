#!/usr/bin/env bash
# tests/unit/test-already-failing-test.sh — a test that already fails on the
# starting code does not send the round back (#2591, ADR-054 §6a).
#
# #2532 runs 45017980554 (C7) and 45102665787 (RG9): a test outside the change
# failed every round, no stage could fix it, and the cycle ran out of rounds.
#
# AF1 [change] a failing test file the branch did not change, that fails on the
#              starting code too, is "already failing": the stage passes, the
#              file is listed in data.already_failing, it is no finding, and it
#              is not in the red set
# AF2 [guard]  a file that fails only with the change is still a failure, with
#              its finding, even beside one that was already failing
# AF3 [guard]  a test file the branch changed is never checked on the starting
#              code: its failure stands
# AF4 [change] an already-failing file stays visible: the open items name it,
#              though its result passed
# AF5 [change] a narrowed run whose only failure is excused is confirmed by the
#              full suite: a file the change broke elsewhere still fails it
# AF6 [change] a file is excused only when every check failing with the change
#              failed on the starting code too: a new failing check in the same
#              file stands
# AF7 [change] the starting code is set up like the copy tested — the files git
#              ignores are there — so a test does not fail there for want of them
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a test already failing before the change does not send the round back (#2591)"
setup_test_env "test-already-failing"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"
# shellcheck source=../../plugins/tool/test/plugin.sh
source "$REPO_ROOT/plugins/tool/test/plugin.sh"
# shellcheck source=../../scripts/lib/run-open-items.sh
source "$REPO_ROOT/scripts/lib/run-open-items.sh"

_g() { git -C "$R" -c user.name=t -c user.email=t@t "$@"; }
# A repo on main: lib.sh, a test that already fails (old), one that reads lib
# (ok), and a runner that, like zbuild's, runs every file or the --files given.
_repo() {
    R="$TEST_TEMP_DIR/$1"; rm -rf "$R"; mkdir -p "$R/tests/unit" "$R/scripts"
    printf 'ok=1\n' > "$R/lib.sh"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$R/tests/unit/old-test.sh"
    printf '#!/usr/bin/env bash\nsource lib.sh; [[ "$ok" == 1 ]]\n' > "$R/tests/unit/ok-test.sh"
    cat > "$R/scripts/run-tests.sh" <<'RUN'
#!/usr/bin/env bash
files=(); if [[ "${1:-}" == "--files" ]]; then shift; files=("$@"); else files=(tests/unit/*.sh); fi
p=0; for f in "${files[@]}"; do if bash "$f"; then p=$((p + 1)); else printf 'unit: FAIL %s/%s\n' "$PWD" "$f"; fi; done
printf 'unit: %d/%d passed\n' "$p" "${#files[@]}"; (( p == ${#files[@]} ))
RUN
    git init -q -b main "$R"; _g add -A; _g commit -q -m base; _g checkout -q -b work
}
_run() {
    A="$TEST_TEMP_DIR/art-$1"; rm -rf "$A"; mkdir -p "$A"; : > "$A/diff.patch"
    ( unset ZBUILD_TEST_CHANGED_FILES ZBUILD_TEST_CMD_TARGETED
      [[ -n "${RED:-}" ]] && export ZBUILD_TEST_RED_SET="$RED" || unset ZBUILD_TEST_RED_SET
      _test_run_inner "$A/diff.patch" "$R" "$A/test-results.json" "bash scripts/run-tests.sh" >/dev/null 2>&1 ) || true
}
_j() { jq -r "$1" "$A/test-results.json" 2>/dev/null; }

print_test_section "AF1: already failing on the starting code"
_repo r1; printf '# a change\n' > "$R/README.md"; _g add -A; _g commit -q -m change
_run 1
assert_eq "[AF1] setup: the suite ran: one file passed" "1" "$(_j '.data.passed')"
assert_eq "[AF1] the failed count is what still fails" "0" "$(_j '.data.failed')"
assert_eq "[AF1] the stage passes: the failure is not this change's" "pass" "$(_j '.outcome')"
assert_eq "[AF1] ...the file is listed as already failing" "tests/unit/old-test.sh" "$(_j '.data.already_failing // [] | join(",")')"
assert_eq "[AF1] ...it is no finding" "0" "$(_j '.data.findings | length')"
assert_eq "[AF1] ...and not in the red set" "no" "$(jq -e 'index("tests/unit/old-test.sh")' "$A/test-red-set.json" >/dev/null 2>&1 && echo yes || echo no)"

print_test_section "AF2: a failure the change made stands"
_repo r2; printf 'ok=0\n' > "$R/lib.sh"; _g add -A; _g commit -q -m break
_run 2
assert_eq "[AF2] the stage fails" "fail" "$(_j '.outcome')"
assert_contains "[AF2] ...on the file the change broke" "$(_j '[.data.findings[].text] | join("\n")')" "tests/unit/ok-test.sh"
_f2="$(_j '[.data.findings[].text] | join("\n")')"
if [[ "$_f2" == *old-test.sh* ]]; then assert_fail "[AF2] ...not on the one already failing" "$_f2"; else assert_pass "[AF2] ...not on the one already failing"; fi
assert_eq "[AF2] ...which is listed as already failing" "tests/unit/old-test.sh" "$(_j '.data.already_failing // [] | join(",")')"

print_test_section "AF3: a test file the branch changed is not excused"
_repo r3; printf '#!/usr/bin/env bash\n# changed\nexit 1\n' > "$R/tests/unit/old-test.sh"; _g add -A; _g commit -q -m edit
_run 3
assert_eq "[AF3] the stage fails" "fail" "$(_j '.outcome')"
assert_eq "[AF3] ...nothing is excused" "" "$(_j '.data.already_failing // [] | join(",")')"

print_test_section "AF4: open items name an already-failing file"
_repo r4; printf '# a change\n' > "$R/README.md"; _g add -A; _g commit -q -m change
_run 4
SD="$TEST_TEMP_DIR/sd4"; mkdir -p "$SD/artifacts"; cp "$A/test-results.json" "$SD/artifacts/"
assert_contains "[AF4] the open items name it" "$(open_items_json "$SD")" "tests/unit/old-test.sh"
assert_contains "[AF4] ...as failing before this change" "$(open_items_json "$SD")" "already fails before this change"

print_test_section "AF5: a narrowed run is confirmed by the full suite"
_repo r5; printf 'ok=0\n' > "$R/lib.sh"; _g add -A; _g commit -q -m break
RED="$TEST_TEMP_DIR/red5.json"; printf '["tests/unit/old-test.sh"]\n' > "$RED"
_run 5; RED=""
assert_eq "[AF5] the stage fails: the full suite found the broken file" "fail" "$(_j '.outcome')"
assert_eq "[AF5] ...after the narrowed run" "targeted+full" "$(_j '.data.run_mode')"
assert_contains "[AF5] ...on the file the change broke" "$(_j '[.data.findings[].text] | join("\n")')" "tests/unit/ok-test.sh"

print_test_section "AF6: a new failing check in an already-failing file stands"
_repo r6
printf '#!/usr/bin/env bash\nsource lib.sh\necho "  ✗ old check"\n[[ "$ok" == 1 ]] || echo "  ✗ new check"\nexit 1\n' > "$R/tests/unit/old-test.sh"
_g add -A; _g commit -q --amend -m base; _g branch -f main HEAD
printf 'ok=0\n' > "$R/lib.sh"; rm -f "$R/tests/unit/ok-test.sh"; _g add -A; _g commit -q -m break
_run 6
assert_eq "[AF6] the stage fails" "fail" "$(_j '.outcome')"
assert_eq "[AF6] ...nothing is excused" "" "$(_j '.data.already_failing // [] | join(",")')"

print_test_section "AF7: the starting code has the files git ignores"
_repo r7
printf 'deps/\n' > "$R/.gitignore"; mkdir -p "$R/deps"; : > "$R/deps/x"
printf '#!/usr/bin/env bash\nsource lib.sh; [[ -f deps/x && "$ok" == 1 ]]\n' > "$R/tests/unit/ok-test.sh"
_g add -A; _g commit -q --amend -m base; _g branch -f main HEAD
printf 'ok=0\n' > "$R/lib.sh"; _g add -A; _g commit -q -m break
_run 7
assert_eq "[AF7] the stage fails on the file the change broke" "fail" "$(_j '.outcome')"
_a7="$(_j '.data.already_failing // [] | join(",")')"
if [[ "$_a7" == *ok-test.sh* ]]; then assert_fail "[AF7] ...which is not excused" "$_a7"; else assert_pass "[AF7] ...which is not excused"; fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
