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

# _cc_scan <workflows dir> — sets _installs (each workflow that installs Claude
# Code, its install line with any `\` continuation joined) and _pinned (each one
# that names a version: `@anthropic-ai/claude-code@…` on any line, so a version
# on a continued line or in any step is found).
_cc_scan() {
    local _wf _body _l
    _installs="" _pinned=""
    shopt -s nullglob
    for _wf in "$1"/*.yml "$1"/*.yaml; do
        _body="$(cat "$_wf")"
        _body="${_body//$'\\\n'/ }"
        while IFS= read -r _l; do
            [[ "$_l" =~ npm[[:space:]]+(install|i|add)[[:space:]].*@anthropic-ai/claude-code ]] \
                && _installs+="${_wf##*/}: $_l"$'\n'
            [[ "$_l" =~ @anthropic-ai/claude-code@ ]] && _pinned+="${_wf##*/}: $_l"$'\n'
        done <<< "$_body"
    done
    shopt -u nullglob
}

print_test_section "the scan finds a version however it is written"
_WF="$(mktemp -d "${TMPDIR:-/tmp}/ci-claude-code.XXXXXX")" || exit 1
printf '      - run: npm install -g \\\n          @anthropic-ai/claude-code@2.1.183\n' > "${_WF:?}/split.yaml"
printf '      - run: npm install -g @anthropic-ai/claude-code\n' > "${_WF:?}/plain.yml"
_cc_scan "$_WF"
assert_contains "[#2639/SPEC-1] a .yaml workflow is read, its install joined across a continued line" "$_installs" "split.yaml"
assert_contains "[#2639/SPEC-1] …and its version found on the continued line" "$_pinned" "split.yaml"
_no_plain=yes; grep -q "plain.yml" <<< "$_pinned" && _no_plain=no
assert_eq "[#2639/SPEC-1] an install with no version is not a pin" "yes" "$_no_plain"
rm -rf "${_WF:?}"

print_test_section "the repository's workflows"
_cc_scan "$REPO_ROOT/.github/workflows"
assert_contains "[#2639/SPEC-1] the pipeline workflow installs Claude Code" "$_installs" "zbuild-pipeline.yml"
assert_contains "[#2639/SPEC-1] the live lens check installs Claude Code" "$_installs" "lens-live-check.yml"
assert_eq "[#2639/SPEC-1] no workflow fixes Claude Code's version" "" "$_pinned"

print_test_results
exit $((FAIL > 0))
