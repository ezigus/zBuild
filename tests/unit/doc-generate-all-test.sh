#!/usr/bin/env bash
set -euo pipefail
# tests/unit/doc-generate-all-test.sh — DOC-D3: doc_generate_all batch orchestration (#1441)
# Covers: [SPEC-17]..[SPEC-21]: all-plugins iteration, all-mechanics iteration,
# NO_CHANGE short-circuit, partial-failure propagation, CLI --all dispatch.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "doc-generate-all — batch orchestration (DOC-D3 #1441)"
setup_test_env "doc-generate-all"

# ─── Fixture paths ────────────────────────────────────────────────────────
# Fixture root has 2 plugins (doc-gather-full, doc-gather-nodocs) and
# mechanics-fixture.yaml has 2 mechanics (fixture-mechanic, fixture-mechanic-nodocs).
FIXTURES="$REPO_ROOT/tests/unit/fixtures/doc-gather"
PLUGIN_FIXTURES="$FIXTURES"
MECHANICS_YAML="$FIXTURES/mechanics-fixture.yaml"
TEMPLATE="$REPO_ROOT/docs/templates/doc-page.md"

WIKI_ROOT="$TEST_TEMP_DIR/wiki"
mkdir -p "$WIKI_ROOT/plugins" "$WIKI_ROOT/mechanics"

# ─── Call-count tracking (file-based so subshell counts propagate) ────────
_CALL_COUNT_FILE="$TEST_TEMP_DIR/call-count.txt"
_FAIL_ON_CALL_FILE="$TEST_TEMP_DIR/fail-on-call.txt"
echo 0 > "$_CALL_COUNT_FILE"
echo 0 > "$_FAIL_ON_CALL_FILE"

_MOCK_ROUTE_RESPONSE="# generated-page

## How to use

.

## Reference

.

## Advanced

_Newcomers can skip this section._
"

# route_to_model_cli is called inside command-substitution subshells by
# _doc_generate_page. File-based counter survives across those subshell forks.
route_to_model_cli() {
    local call_num fail_on
    call_num=$(cat "$_CALL_COUNT_FILE" 2>/dev/null || echo 0)
    fail_on=$(cat "$_FAIL_ON_CALL_FILE" 2>/dev/null || echo 0)
    call_num=$((call_num + 1))
    echo "$call_num" > "$_CALL_COUNT_FILE"
    if [[ "$fail_on" -gt 0 && "$call_num" -eq "$fail_on" ]]; then
        return 1
    fi
    printf '%s' "${_MOCK_ROUTE_RESPONSE}"
    return 0
}

# shellcheck source=../../scripts/lib/doc-generate.sh
source "$REPO_ROOT/scripts/lib/doc-generate.sh"

# ─── Helper: reset wiki tree and counters ─────────────────────────────────
_reset_all() {
    rm -rf "$WIKI_ROOT"
    mkdir -p "$WIKI_ROOT/plugins" "$WIKI_ROOT/mechanics"
    echo 0 > "$_CALL_COUNT_FILE"
    echo 0 > "$_FAIL_ON_CALL_FILE"
}

# ─── SPEC-17: doc_generate_all iterates every plugin id and writes a page ─
_reset_all
_MOCK_ROUTE_RESPONSE="# generated-plugin-page

## How to use

.

## Reference

.

## Advanced

_Newcomers can skip this section._
"
doc_generate_all "$PLUGIN_FIXTURES" "$MECHANICS_YAML" "$WIKI_ROOT" "$TEMPLATE"

assert_file_exists "[SPEC-17] plugin page written for doc-gather-full" \
    "$WIKI_ROOT/plugins/doc-gather-full.md"
assert_file_exists "[SPEC-17] plugin page written for doc-gather-nodocs" \
    "$WIKI_ROOT/plugins/doc-gather-nodocs.md"

# ─── SPEC-18: doc_generate_all iterates every mechanic name and writes a page
_reset_all
_MOCK_ROUTE_RESPONSE="# generated-mechanic-page

## How to use

.

## Reference

.

## Advanced

_Newcomers can skip this section._
"
doc_generate_all "$PLUGIN_FIXTURES" "$MECHANICS_YAML" "$WIKI_ROOT" "$TEMPLATE"

assert_file_exists "[SPEC-18] mechanic page written for fixture-mechanic" \
    "$WIKI_ROOT/mechanics/fixture-mechanic.md"
assert_file_exists "[SPEC-18] mechanic page written for fixture-mechanic-nodocs" \
    "$WIKI_ROOT/mechanics/fixture-mechanic-nodocs.md"

# ─── SPEC-19: per-source NO_CHANGE is honoured ────────────────────────────
# When model returns NO_CHANGE for every source: pages must NOT be written,
# but the hash sidecar MUST be recorded (short-circuit path in _doc_generate_page).
_reset_all
_MOCK_ROUTE_RESPONSE="NO_CHANGE"
doc_generate_all "$PLUGIN_FIXTURES" "$MECHANICS_YAML" "$WIKI_ROOT" "$TEMPLATE"

assert_file_not_exists "[SPEC-19] plugin page NOT written when NO_CHANGE returned" \
    "$WIKI_ROOT/plugins/doc-gather-full.md"
assert_file_exists "[SPEC-19] plugin hash sidecar recorded despite NO_CHANGE" \
    "$WIKI_ROOT/plugins/doc-gather-full.md.hash"
assert_file_not_exists "[SPEC-19] mechanic page NOT written when NO_CHANGE returned" \
    "$WIKI_ROOT/mechanics/fixture-mechanic.md"
assert_file_exists "[SPEC-19] mechanic hash sidecar recorded despite NO_CHANGE" \
    "$WIKI_ROOT/mechanics/fixture-mechanic.md.hash"

# ─── SPEC-20: per-source failure → non-zero return; remaining sources processed
# Fixture has 2 plugins then 2 mechanics = 4 model calls. Fail on call 1
# (first plugin). The other 3 sources must still be attempted and succeed.
_reset_all
_MOCK_ROUTE_RESPONSE="# generated-page

## How to use

.

## Reference

.

## Advanced

_Newcomers can skip this section._
"
echo 1 > "$_FAIL_ON_CALL_FILE"

all_rc=0
doc_generate_all "$PLUGIN_FIXTURES" "$MECHANICS_YAML" "$WIKI_ROOT" "$TEMPLATE" 2>/dev/null \
    || all_rc=$?

assert_eq "[SPEC-20] doc_generate_all returns non-zero when a source fails" \
    "1" "$all_rc"
# Second plugin (call 2) must still have been processed successfully.
assert_file_exists "[SPEC-20] second plugin page written despite first plugin failing" \
    "$WIKI_ROOT/plugins/doc-gather-nodocs.md"
# Mechanics (calls 3-4) must still have been processed.
assert_file_exists "[SPEC-20] mechanic page written despite preceding plugin failure" \
    "$WIKI_ROOT/mechanics/fixture-mechanic.md"

# ─── SPEC-21: zbuild docs generate --all exits 0; generator called for ≥2 sources
# Run the CLI in a subprocess with a stubbed route_to_model_cli that writes
# each call number to a shared file. Verify exit 0 and call count ≥ 2.
_reset_all
_CLI_CALL_COUNT_FILE="$TEST_TEMP_DIR/cli-call-count.txt"
echo 0 > "$_CLI_CALL_COUNT_FILE"
export _CLI_CALL_COUNT_FILE
export ZBUILD_WIKI_ROOT="$WIKI_ROOT"

route_to_model_cli() {
    local n
    n=$(cat "$_CLI_CALL_COUNT_FILE" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$_CLI_CALL_COUNT_FILE"
    printf '%s' "# cli-all-page

## How to use

.

## Reference

.

## Advanced

_Newcomers can skip this section._
"
    return 0
}
export -f route_to_model_cli

cli_rc=0
bash "$REPO_ROOT/scripts/zbuild" docs generate --all 2>/dev/null || cli_rc=$?

assert_eq "[SPEC-21] zbuild docs generate --all exits 0" "0" "$cli_rc"

_cli_final_count=$(cat "$_CLI_CALL_COUNT_FILE" 2>/dev/null || echo 0)
_cli_multi=0
[[ "$_cli_final_count" -ge 2 ]] && _cli_multi=1
assert_eq "[SPEC-21] generator called for multiple sources (>=2) under --all" \
    "1" "$_cli_multi"

unset ZBUILD_WIKI_ROOT _CLI_CALL_COUNT_FILE

# ─── SPEC-22: doc_generate_all fails closed when no sources are discovered ────
# A wrong/empty root must not silently return success (#1441 review) — the old
# process-substitution discarded the enumerator rc and returned 0 for 0 sources.
EMPTY_ROOT="$TEST_TEMP_DIR/empty-plugins"; mkdir -p "$EMPTY_ROOT"
EMPTY_MECH="$TEST_TEMP_DIR/empty-mechanics.yaml"; printf 'mechanics:\n' > "$EMPTY_MECH"
_empty_rc=0
doc_generate_all "$EMPTY_ROOT" "$EMPTY_MECH" "$WIKI_ROOT" "$TEMPLATE" 2>/dev/null || _empty_rc=$?
_empty_bad=0; [[ "$_empty_rc" -ne 0 ]] && _empty_bad=1
assert_eq "[SPEC-22] doc_generate_all fails closed when 0 sources discovered" "1" "$_empty_bad"

# ─── Cleanup ──────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }

print_test_results
