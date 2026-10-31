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
# C1 [change] the pipeline step has its own time limit, at least 20 minutes
#             under GitHub's 360, so the steps after it have time to save
# C2 [change] the status comment's ceiling is that limit, not GitHub's
# C3 [guard]  the steps that save the work run whatever the pipeline did
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
_limit="$(sed -n 's/^        timeout-minutes:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<< "$_run_step" | head -n1)"
assert_eq "[C1] the pipeline step has its own time limit" "yes" "$([[ -n "$_limit" ]] && echo yes || echo no)"
assert_eq "[C1] ...at least 20 minutes under GitHub's 360" "yes" \
    "$([[ "$_limit" =~ ^[0-9]+$ ]] && (( _limit <= 340 )) && echo yes || echo no)"

_ceiling="$(sed -n 's/^      ZBUILD_STATUS_CEILING_MIN:[[:space:]]*"\{0,1\}\([0-9][0-9]*\)"\{0,1\}.*/\1/p' "$WF" | head -n1)"
assert_eq "[C2] the status comment's ceiling is the pipeline step's limit" "${_limit:-unset}" "${_ceiling:-unset}"

for _s in "Push work branch (preserve work on pass OR fail)" "Upload pipeline artifacts"; do
    assert_contains "[C3] '$_s' runs whatever the pipeline did" "$(_step "$_s")" "if: always()"
done

print_test_results
exit $((FAIL > 0))
