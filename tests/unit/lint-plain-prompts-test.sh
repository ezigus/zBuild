#!/usr/bin/env bash
# tests/unit/lint-plain-prompts-test.sh — model-facing text speaks plainly (#2269).
#
# Why: engine-internal words leaked into the text sent to models and were read
# in their everyday sense. #2032 run 37066151065: design listed an event-name
# list as "WIRING" (the engine meant "the existing file whose code calls the new
# behaviour"); the gate fed back "WIRING … inert — reverting it breaks no
# TESTFILE", and test-author satisfied the measure with a test that greps the
# file. The rules (ADR-067): never name an internal check in model-facing text;
# no maintainer notes (ADR/issue numbers, legacy paths) or repo internals.
#
# The lint reads the text a model receives: heredoc bodies in the files listed in
# config/model-facing-sources.txt, and whole prompt .md files listed there.
#
# P1 [change] a heredoc naming an internal check (NEGCTL, REACHABILITY, inert,
#             tautolog…) fails, naming file:line and the word
# P2 [change] an ADR number or a `_TPL_` internal in a prompt fails
# P3 [guard]  shell code and comments OUTSIDE heredocs are not prompt text
# P4 [guard]  a parser key (WIRING:, TESTFILES:, LOOP_COMPLETE) is allowed
# P5 [guard]  a file listed in the sources list that does not exist fails
# P6 [change] the real tree passes
# P7 [change] a variable NAME is not prompt text — only its value reaches a
#             model (`$inert`, `${_TPL_STAGES[@]}` in a printf line)
# P8 [change] a comment ends a `\` continuation: the line after it is code, not
#             the summary call's text
# P9 [code]   the retired [guard] tag in a heredoc fails: a model reading it
#             would offer it back, and the design-gate refuses it (#2304,
#             ADR-069 §8)
# P10 [code]  a heredoc telling a stage to skip part of its own job fails —
#             "is proven by the pipeline itself … never judge it here" told
#             two stages to leave what the issue required unchecked (#2308,
#             ADR-067 §8)
# P11 [code]  so does an answer form that calls a finding "not yours to"
#             change, and a "keep every other entry" re-prompt
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "model-facing text speaks plainly (#2269)"
setup_test_env "lint-plain-prompts"

LINT="$REPO_ROOT/scripts/lib/lint-plain-prompts.sh"
R="$TEST_TEMP_DIR/repo"; mkdir -p "$R/config" "$R/plugins/x"
_src() { printf '%s\n' "$@" > "$R/config/model-facing-sources.txt"; }
_lint() { out="$(bash "$LINT" "$R" 2>&1)"; rc=$?; }

# shellcheck disable=SC2016  # literal fixture text
printf '%s\n' '_p() {' 'cat <<EOF' 'Fix the NEGCTL failure first.' 'EOF' '}' > "$R/plugins/x/a.sh"
_src plugins/x/a.sh; _lint
assert_eq "[P1] a heredoc naming an internal check fails" "1" "$rc"
assert_contains "[P1] it names the file and line" "$out" "plugins/x/a.sh:3"
assert_contains "[P1] it names the word" "$out" "NEGCTL"

printf '%s\n' 'cat <<'"'"'EOF'"'" 'See ADR-036 for the tagging rule.' 'EOF' > "$R/plugins/x/b.sh"
_src plugins/x/b.sh; _lint
assert_eq "[P2] an ADR number in a prompt fails" "1" "$rc"

# shellcheck disable=SC2016  # literal fixture text
printf '%s\n' '# NEGCTL and ADR-036 in a comment are for maintainers' 'x="$_TPL_STAGES"' \
    'cat <<EOF' 'Name the file that calls the new code.' 'EOF' > "$R/plugins/x/c.sh"
_src plugins/x/c.sh; _lint
assert_eq "[P3] code and comments outside heredocs are not prompt text" "0" "$rc"

printf '%s\n' 'cat <<EOF' 'WIRING: <file>   (which existing file calls the new code?)' \
    'TESTFILES:' 'Emit LOOP_COMPLETE when done.' 'EOF' > "$R/plugins/x/d.sh"
_src plugins/x/d.sh; _lint
assert_eq "[P4] parser keys are allowed" "0" "$rc"

_src plugins/x/gone.sh; _lint
assert_eq "[P5] a listed file that does not exist fails" "1" "$rc"

# shellcheck disable=SC2016  # literal fixture text
printf '%s\n' '[[ -n "$inert" ]] && clauses+=("$(_ids "$inert") was put back")' > "$R/plugins/x/e.sh"
# shellcheck disable=SC2016  # literal fixture text
printf '%s\n' 'printf "%s\n" "${_TPL_STAGES[@]}"' > "$R/plugins/x/f.sh"
printf '%s\n' 'plugins/x/e.sh' 'plugins/x/f.sh printf' > "$R/config/model-facing-sources.txt"; _lint
assert_eq "[P7] variable names are not prompt text" "0" "$rc"

# shellcheck disable=SC2016,SC1003  # literal fixture text
printf '%s\n' 'stage_summary_write "$f" x pass "the check ran" \' '# NEGCTL: why the next line exists' \
    'mode=NEGCTL' > "$R/plugins/x/g.sh"
_src plugins/x/g.sh; _lint
assert_eq "[P8] a comment ends a continuation; the next line is code" "0" "$rc"
[[ $rc -eq 0 ]] || printf '%s\n' "$out"

printf '%s\n' 'cat <<EOF' 'If the code already does it, tag it [guard].' 'EOF' > "$R/plugins/x/h.sh"
_src plugins/x/h.sh; _lint
assert_eq "[P9] a heredoc offering the retired [guard] tag fails" "1" "$rc"
assert_contains "[P9] it names the file and line" "$out" "plugins/x/h.sh:2"

printf '%s\n' 'cat <<EOF' 'How it is verified is proven by the pipeline itself; never judge it here.' 'EOF' > "$R/plugins/x/i.sh"
_src plugins/x/i.sh; _lint
assert_eq "[P10] a heredoc telling a stage to skip part of its job fails" "1" "$rc"
assert_contains "[P10] it names the file and line" "$out" "plugins/x/i.sh:2"
assert_contains "[P10] it says what is wrong" "$out" "skip part of its own job"

printf '%s\n' 'cat <<EOF' '  nothing to do — <why it is not yours to change>' 'EOF' > "$R/plugins/x/j.sh"
_src plugins/x/j.sh; _lint
assert_eq "[P11] an answer form calling a finding 'not yours to' change fails" "1" "$rc"
printf '%s\n' 'cat <<EOF' 'Fix that one. Keep every other scope and acceptance entry.' 'EOF' > "$R/plugins/x/k.sh"
_src plugins/x/k.sh; _lint
assert_eq "[P11] a re-prompt to keep every other entry fails" "1" "$rc"
printf '%s\n' 'cat <<EOF' 'Judge the behaviour the issue requires; the later check judges how it is tested.' 'EOF' > "$R/plugins/x/l.sh"
_src plugins/x/l.sh; _lint
assert_eq "[P11] saying what the stage owns is allowed" "0" "$rc"

bash "$LINT" "$REPO_ROOT" > "$TEST_TEMP_DIR/real.out" 2>&1; rc=$?
assert_eq "[P6] the real tree passes" "0" "$rc"
[[ $rc -eq 0 ]] || tail -15 "$TEST_TEMP_DIR/real.out"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
