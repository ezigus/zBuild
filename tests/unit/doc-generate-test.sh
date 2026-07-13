#!/usr/bin/env bash
# tests/unit/doc-generate-test.sh — DOC-D2: LLM page generator unit tests (#1440)
# Covers: doc_generate_plugin, doc_generate_mechanic, doc_generate_page, zbuild CLI dispatch.
# All route_to_model calls are intercepted via a mock function — no live LLM calls.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "doc-generate — LLM page generator (DOC-D2 #1440)"
setup_test_env "doc-generate"

# ─── Fixture paths ────────────────────────────────────────────────────────────
FIXTURES="$REPO_ROOT/tests/unit/fixtures/doc-gather"
PLUGIN_FIXTURES="$FIXTURES"
MECHANICS_YAML="$FIXTURES/mechanics-fixture.yaml"
TEMPLATE="$REPO_ROOT/docs/templates/doc-page.md"

WIKI_ROOT="$TEST_TEMP_DIR/wiki"
mkdir -p "$WIKI_ROOT/plugins" "$WIKI_ROOT/mechanics"

# ─── LLM mock ────────────────────────────────────────────────────────────────
# Define route_to_model BEFORE sourcing doc-generate.sh so the lazy-load guard
# (_doc_generate_ensure_router) sees it and skips loading the real router stack.
_MOCK_ROUTE_RESPONSE="# placeholder"
_ROUTE_CALL_COUNT=0

route_to_model() {
    _ROUTE_CALL_COUNT=$((_ROUTE_CALL_COUNT + 1))
    printf '%s' "${_MOCK_ROUTE_RESPONSE}"
    return 0
}

# shellcheck source=../../scripts/lib/doc-generate.sh
source "$REPO_ROOT/scripts/lib/doc-generate.sh"

# ─── Helper: reset wiki tree and call counter ─────────────────────────────────
_reset_wiki() {
    rm -rf "$WIKI_ROOT"
    mkdir -p "$WIKI_ROOT/plugins" "$WIKI_ROOT/mechanics"
    _ROUTE_CALL_COUNT=0
}

# ─── SPEC-1: plugin page write — file written, contains expected H1 ──────────
_reset_wiki
_MOCK_ROUTE_RESPONSE="# doc-gather-full

A complete plugin wiki page.

## How to use

Source and call.

## Reference

Kind: agent

## Advanced

_Newcomers can skip this section._
"
doc_generate_plugin "doc-gather-full" "$PLUGIN_FIXTURES" "$WIKI_ROOT" "" "$TEMPLATE"

plugin_page="$WIKI_ROOT/plugins/doc-gather-full.md"
assert_file_exists "[SPEC-1] plugin wiki page written" "$plugin_page"
page_content="$(<"$plugin_page")"
assert_contains "[SPEC-1] plugin page contains expected H1" "$page_content" "# doc-gather-full"

# ─── SPEC-2: mechanic page write — file written, contains expected H1 ────────
_reset_wiki
_MOCK_ROUTE_RESPONSE="# fixture-mechanic

A test mechanic wiki page.

## How to use

Use the mechanic.

## Reference

Defined in: tests/unit/fixtures/doc-gather/mechanic-source.sh

## Advanced

_Newcomers can skip this section._
"
doc_generate_mechanic "fixture-mechanic" "$MECHANICS_YAML" "$WIKI_ROOT" "" "$TEMPLATE"

mechanic_page="$WIKI_ROOT/mechanics/fixture-mechanic.md"
assert_file_exists "[SPEC-2] mechanic wiki page written" "$mechanic_page"
mech_content="$(<"$mechanic_page")"
assert_contains "[SPEC-2] mechanic page contains expected H1" "$mech_content" "# fixture-mechanic"

# ─── SPEC-3: NO_CHANGE path — wiki file NOT written ──────────────────────────
_reset_wiki
_MOCK_ROUTE_RESPONSE="NO_CHANGE"

doc_generate_plugin "doc-gather-full" "$PLUGIN_FIXTURES" "$WIKI_ROOT" "" "$TEMPLATE"

assert_file_not_exists "[SPEC-3] wiki page NOT written when model returns NO_CHANGE" \
    "$WIKI_ROOT/plugins/doc-gather-full.md"

# ─── SPEC-4: hash sidecar written in both write and NO_CHANGE cases ──────────
# SPEC-4a: hash sidecar written after normal page write
_reset_wiki
_MOCK_ROUTE_RESPONSE="# doc-gather-full

Content.

## How to use

Use.

## Reference

Ref.

## Advanced

_Newcomers can skip this section._
"
doc_generate_plugin "doc-gather-full" "$PLUGIN_FIXTURES" "$WIKI_ROOT" "" "$TEMPLATE"
assert_file_exists "[SPEC-4] hash sidecar written after page write" \
    "$WIKI_ROOT/plugins/doc-gather-full.md.hash"

# SPEC-4b: hash sidecar also written on NO_CHANGE path
_reset_wiki
_MOCK_ROUTE_RESPONSE="NO_CHANGE"
doc_generate_plugin "doc-gather-full" "$PLUGIN_FIXTURES" "$WIKI_ROOT" "" "$TEMPLATE"
assert_file_exists "[SPEC-4] hash sidecar written even when NO_CHANGE returned" \
    "$WIKI_ROOT/plugins/doc-gather-full.md.hash"

# ─── SPEC-5: hash sidecar is valid 64-char hex SHA-256 ──────────────────────
_reset_wiki
_MOCK_ROUTE_RESPONSE="# doc-gather-full

Hash test content.

## How to use

.

## Reference

.

## Advanced

_Newcomers can skip this section._
"
doc_generate_plugin "doc-gather-full" "$PLUGIN_FIXTURES" "$WIKI_ROOT" "" "$TEMPLATE"
hash_val="$(<"$WIKI_ROOT/plugins/doc-gather-full.md.hash")"
hash_val="${hash_val%%[[:space:]]*}"   # trim trailing whitespace/newline

hex_ok=0
if [[ "${#hash_val}" -eq 64 ]] && printf '%s' "$hash_val" | grep -qE '^[0-9a-f]{64}$'; then
    hex_ok=1
fi
assert_eq "[SPEC-5] hash sidecar is a valid 64-char hex SHA-256" "1" "$hex_ok"

# ─── SPEC-6: zbuild CLI dispatch reaches doc_generate_page and exits 0 ───────
# Run zbuild docs generate via subprocess with route_to_model exported as a mock.
# ZBUILD_WIKI_ROOT redirects output to the temp dir so the real docs/ is untouched.
export ZBUILD_WIKI_ROOT="$WIKI_ROOT"
_CLI_MOCK_RESPONSE="# plan

Plan plugin wiki page.

## How to use

Start a plan.

## Reference

Kind: agent

## Advanced

_Newcomers can skip this section._
"
# Export a mock route_to_model for the child process; child bash inherits it.
route_to_model() {
    printf '%s' "${_CLI_MOCK_RESPONSE:-# Default Page}"
    return 0
}
export -f route_to_model

cli_rc=0
bash "$REPO_ROOT/scripts/zbuild" docs generate plugin:plan >/dev/null 2>&1 || cli_rc=$?
assert_eq "[SPEC-6] zbuild docs generate plugin exits 0" "0" "$cli_rc"

unset ZBUILD_WIKI_ROOT
# Restore in-process route_to_model
route_to_model() {
    _ROUTE_CALL_COUNT=$((_ROUTE_CALL_COUNT + 1))
    printf '%s' "${_MOCK_ROUTE_RESPONSE}"
    return 0
}

# ─── SPEC-7: unknown source prefix returns rc=1 with error message ────────────
_reset_wiki
unknown_rc=0
unknown_err=""
unknown_err="$(doc_generate_page "stage:foo" 2>&1)" || unknown_rc=$?
assert_eq "[SPEC-7] unknown prefix returns rc=1" "1" "$unknown_rc"
assert_contains "[SPEC-7] error message mentions unknown prefix" "$unknown_err" "stage"

# ─── SPEC-8: source spec without colon (invalid format) returns rc=1 ──────────
_reset_wiki
nocomp_rc=0
nocomp_err=""
nocomp_err="$(doc_generate_page "pluginfoo" 2>&1)" || nocomp_rc=$?
assert_eq "[SPEC-8] spec without colon returns rc=1" "1" "$nocomp_rc"
assert_contains "[SPEC-8] error message mentions invalid spec" "$nocomp_err" "invalid source spec"

# ─── SPEC-9: plugin output path is wiki_root/plugins/<id>.md ────────────────
_reset_wiki
_MOCK_ROUTE_RESPONSE="# doc-gather-full

Canonical path test.

## How to use

.

## Reference

.

## Advanced

_Newcomers can skip this section._
"
doc_generate_plugin "doc-gather-full" "$PLUGIN_FIXTURES" "$WIKI_ROOT" "" "$TEMPLATE"
assert_file_exists "[SPEC-9] plugin page at wiki_root/plugins/<id>.md" \
    "$WIKI_ROOT/plugins/doc-gather-full.md"

# ─── SPEC-10: mechanic output path is wiki_root/mechanics/<name>.md ──────────
_reset_wiki
_MOCK_ROUTE_RESPONSE="# fixture-mechanic

Canonical path test.

## How to use

.

## Reference

.

## Advanced

_Newcomers can skip this section._
"
doc_generate_mechanic "fixture-mechanic" "$MECHANICS_YAML" "$WIKI_ROOT" "" "$TEMPLATE"
assert_file_exists "[SPEC-10] mechanic page at wiki_root/mechanics/<name>.md" \
    "$WIKI_ROOT/mechanics/fixture-mechanic.md"

# ─── SPEC-11: pre-call hash short-circuit — when sidecar matches, LLM not called
# Strategy: write page with content A, then change the mock to content B.
# If second call short-circuits (hash match), page stays at content A.
_reset_wiki
_MOCK_ROUTE_RESPONSE="# doc-gather-full

Short circuit ORIGINAL content.

## How to use

.

## Reference

.

## Advanced

_Newcomers can skip this section._
"
# First call: writes page and sidecar.
doc_generate_plugin "doc-gather-full" "$PLUGIN_FIXTURES" "$WIKI_ROOT" "" "$TEMPLATE"
first_content="$(<"$WIKI_ROOT/plugins/doc-gather-full.md")"
assert_contains "[SPEC-11] first call wrote page with original content" \
    "$first_content" "Short circuit ORIGINAL content"

# Change mock to a different response. Without short-circuit, second call would overwrite.
_MOCK_ROUTE_RESPONSE="# doc-gather-full

SHORT CIRCUIT CHANGED - should not appear if short-circuit works.

## How to use

.

## Reference

.

## Advanced

_Newcomers can skip this section._
"
# Second call with identical bundle: hash matches sidecar → return 0 immediately.
doc_generate_plugin "doc-gather-full" "$PLUGIN_FIXTURES" "$WIKI_ROOT" "" "$TEMPLATE"
second_content="$(<"$WIKI_ROOT/plugins/doc-gather-full.md")"

assert_eq "[SPEC-11] second call short-circuits: page content unchanged when hash matches" \
    "$first_content" "$second_content"

# ─── Cleanup ─────────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }

print_test_results
