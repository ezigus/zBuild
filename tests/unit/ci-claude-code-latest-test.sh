#!/usr/bin/env bash
# tests/unit/ci-claude-code-latest-test.sh — CI installs the latest Claude Code
# (#2639, ADR-003 provider amendment).
#
# The router asks the CLI for a family name (sonnet, opus, haiku), and the CLI
# decides which model that name means. A CI install fixed at one version fixed
# the model with it: 2.1.183 read `sonnet` as Sonnet 4.6, two Sonnet versions
# behind, though ADR-003 says the family name gives every run the latest model.
# What ran each call is known from the run's own events instead (model.outcome's
# cli_version and model_used — tests/unit/router-provider-modules-test.sh).
#
# [#2639/SPEC-1] every workflow that installs Claude Code installs it unpinned
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "CI installs the latest Claude Code (#2639)"

_installs="" _pinned=""
for _wf in "$REPO_ROOT"/.github/workflows/*.yml; do
    while IFS= read -r _l; do
        [[ "$_l" =~ npm[[:space:]]+(install|i)[[:space:]].*@anthropic-ai/claude-code ]] || continue
        _installs+="${_wf##*/}: $_l"$'\n'
        [[ "$_l" =~ @anthropic-ai/claude-code@ ]] && _pinned+="${_wf##*/}: $_l"$'\n'
    done < "$_wf"
done

assert_contains "[#2639/SPEC-1] the pipeline workflow installs Claude Code" "$_installs" "zbuild-pipeline.yml"
assert_contains "[#2639/SPEC-1] the live lens check installs Claude Code" "$_installs" "lens-live-check.yml"
assert_eq "[#2639/SPEC-1] no workflow fixes Claude Code's version" "" "$_pinned"

print_test_results
exit $((FAIL > 0))
