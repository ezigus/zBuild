#!/usr/bin/env bash
# tests/unit/ci-stop-before-github-test.sh — a CI run stops before GitHub's
# 360-minute job limit, so its log, events and files are saved (ADR-064,
# amended 2026-10-31).
#
# Why: #1754's run (41138244027) was killed at GitHub's limit. A killed job
# keeps no log, its upload steps never run, and nothing after the last
# snapshot was saved — round 2's build was lost, and the status comment could
# not say how the run ended.
#
# C1 [change] zbuild stops itself well before that: it is sent the stop signal
#             its interrupted path handles (TERM) at its own limit, and given at
#             least 10 minutes to save before it can be killed
# C2 [change] the step's own limit is a backstop after that, at least 20
#             minutes under GitHub's 360, so the steps after it have time to save
# C3 [change] the status comment's ceiling is when zbuild stops, not GitHub's
# C4 [guard]  the steps that save the work run whatever the pipeline did
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "a CI run stops before GitHub's job limit (ADR-064)"

WF="$REPO_ROOT/.github/workflows/zbuild-pipeline.yml"
# _step <name> — the lines of one step, from its `- name:` to the next.
_step() { awk -v n="      - name: $1" '$0 == n { on = 1; print; next } on && /^      - name: / { exit } on { print }' "$WF"; }

_run_step="$(_step "Run pipeline")"
_line="$(grep -m1 -E 'exec .*timeout ' <<< "$_run_step")"
_stop="$(sed -nE 's/.*timeout (--signal=TERM )?(--kill-after=[0-9]+m )?([0-9]+)m .*/\3/p' <<< "$_line")"
_grace="$(sed -nE 's/.*--kill-after=([0-9]+)m .*/\1/p' <<< "$_line")"
assert_contains "[C1] zbuild runs under its own time limit" "$_line" "zbuild\" pipeline start"
assert_contains "[C1] ...which sends it TERM, the signal its interrupted path saves on" "$_line" "--signal=TERM"
assert_eq "[C1] ...with at least 10 minutes to save before it can be killed" "yes" \
    "$([[ "$_grace" =~ ^[0-9]+$ ]] && (( _grace >= 10 )) && echo yes || echo no)"

_limit="$(grep -m1 -E '^        timeout-minutes:' <<< "$_run_step" | sed -n 's/^        timeout-minutes:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
assert_eq "[C2] the step's own limit comes after zbuild's stop and its time to save" "yes" \
    "$([[ "$_limit" =~ ^[0-9]+$ && "$_stop" =~ ^[0-9]+$ && "$_grace" =~ ^[0-9]+$ ]] && (( _stop + _grace <= _limit )) && echo yes || echo no)"
assert_eq "[C2] ...at least 20 minutes under GitHub's 360" "yes" \
    "$([[ "$_limit" =~ ^[0-9]+$ ]] && (( _limit <= 340 )) && echo yes || echo no)"

_ceiling="$(grep -m1 -E '^      ZBUILD_STATUS_CEILING_MIN:' "$WF" | sed -n 's/^      ZBUILD_STATUS_CEILING_MIN:[[:space:]]*"\{0,1\}\([0-9][0-9]*\)"\{0,1\}.*/\1/p')"
assert_eq "[C3] the status comment's ceiling is when zbuild stops" "${_stop:-unset}" "${_ceiling:-unset}"

for _s in "Push work branch (preserve work on pass OR fail)" "Upload pipeline artifacts"; do
    assert_contains "[C4] '$_s' runs whatever the pipeline did" "$(_step "$_s")" "if: always()"
done

print_test_results
exit $((FAIL > 0))
