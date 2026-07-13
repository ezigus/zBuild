#!/usr/bin/env bash
# Tests: DOC-D1 — deterministic gather(source) collector (#1439)
# Verifies doc_gather_plugin_bundle and doc_gather_mechanic_bundle functions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/doc-gather.sh
source "$REPO_ROOT/scripts/lib/doc-gather.sh"

print_test_header "doc-gather — deterministic source collector (DOC-D1 #1439)"
setup_test_env "doc-gather"

# ─── Fixture paths ────────────────────────────────────────────────────────────
FIXTURES="$REPO_ROOT/tests/unit/fixtures/doc-gather"
PLUGIN_FIXTURES="$FIXTURES"
MECHANICS_YAML="$FIXTURES/mechanics-fixture.yaml"

# Local wiki tree for tests that need an existing page
WIKI_ROOT="$TEST_TEMP_DIR/wiki"
mkdir -p "$WIKI_ROOT/plugins" "$WIKI_ROOT/mechanics"
cp "$FIXTURES/existing-page.md" "$WIKI_ROOT/plugins/doc-gather-full.md"
cat > "$WIKI_ROOT/mechanics/fixture-mechanic.md" << 'WIKIEOF'
# fixture-mechanic

Existing wiki page for the fixture-mechanic mechanic.
WIKIEOF

# ─── Helper: parse bundle key ─────────────────────────────────────────────────
_bundle_get() {
    local bundle="$1" key="$2"
    printf '%s\n' "$bundle" | grep "^${key}=" | head -1 | sed "s/^${key}=//"
}

# ─── SPEC-1: plugin-full returns all manifest fields + source + existing page ──
bundle="$(doc_gather_plugin_bundle "doc-gather-full" "$PLUGIN_FIXTURES" "$WIKI_ROOT")"

assert_eq "[SPEC-1] id field" \
    "doc-gather-full" "$(_bundle_get "$bundle" "id")"

assert_eq "[SPEC-1] kind field" \
    "agent" "$(_bundle_get "$bundle" "kind")"

assert_eq "[SPEC-1] version field" \
    "1.2.3" "$(_bundle_get "$bundle" "version")"

summary_val="$(_bundle_get "$bundle" "summary")"
assert_contains "[SPEC-1] summary non-empty" "$summary_val" "complete fixture"

usage_val="$(_bundle_get "$bundle" "usage")"
assert_contains "[SPEC-1] usage non-empty" "$usage_val" "real plugin"

assert_eq "[SPEC-1] tier_default field" \
    "T1" "$(_bundle_get "$bundle" "tier_default")"

source_b64="$(_bundle_get "$bundle" "source")"
source_decoded="$(printf '%s' "$source_b64" | base64 -d 2>/dev/null)"
assert_contains "[SPEC-1] source contains plugin guard" \
    "$source_decoded" "_ZBUILD_DOC_GATHER_FULL_LOADED"

wiki_b64="$(_bundle_get "$bundle" "wiki_page")"
wiki_decoded="$(printf '%s' "$wiki_b64" | base64 -d 2>/dev/null)"
assert_contains "[SPEC-1] wiki_page contains existing content" \
    "$wiki_decoded" "Existing wiki page"

# ─── SPEC-2: plugin-no-docs → empty summary/usage, non-empty source ───────────
bundle2="$(doc_gather_plugin_bundle "doc-gather-nodocs" "$PLUGIN_FIXTURES" "$WIKI_ROOT")"

assert_eq "[SPEC-2] no-docs kind field" \
    "tool" "$(_bundle_get "$bundle2" "kind")"

assert_eq "[SPEC-2] missing summary is empty" \
    "" "$(_bundle_get "$bundle2" "summary")"

assert_eq "[SPEC-2] missing usage is empty" \
    "" "$(_bundle_get "$bundle2" "usage")"

source2_b64="$(_bundle_get "$bundle2" "source")"
source2_decoded="$(printf '%s' "$source2_b64" | base64 -d 2>/dev/null)"
assert_contains "[SPEC-2] no-docs source non-empty" \
    "$source2_decoded" "nodocs_run"

# ─── SPEC-3: plugin-full with no wiki page → wiki_page is empty ───────────────
WIKI_NO_PAGE="$TEST_TEMP_DIR/wiki-no-page"
mkdir -p "$WIKI_NO_PAGE/plugins" "$WIKI_NO_PAGE/mechanics"
bundle3="$(doc_gather_plugin_bundle "doc-gather-full" "$PLUGIN_FIXTURES" "$WIKI_NO_PAGE")"

assert_eq "[SPEC-3] absent wiki_page is empty string" \
    "" "$(_bundle_get "$bundle3" "wiki_page")"

# ─── SPEC-4: mechanic bundle returns name, summary, usage, defined_in, source, wiki ──
mech_bundle="$(doc_gather_mechanic_bundle "fixture-mechanic" "$MECHANICS_YAML" "$WIKI_ROOT")"

assert_eq "[SPEC-4] mechanic name field" \
    "fixture-mechanic" "$(_bundle_get "$mech_bundle" "name")"

mech_summary="$(_bundle_get "$mech_bundle" "summary")"
assert_contains "[SPEC-4] mechanic summary non-empty" \
    "$mech_summary" "fixture mechanic"

mech_usage="$(_bundle_get "$mech_bundle" "usage")"
assert_contains "[SPEC-4] mechanic usage non-empty" \
    "$mech_usage" "real mechanic"

mech_defined_in="$(_bundle_get "$mech_bundle" "defined_in")"
assert_contains "[SPEC-4] mechanic defined_in non-empty" \
    "$mech_defined_in" "mechanic-source.sh"

# Regression (#1444): a block-scalar field must NOT over-capture the sibling keys
# that follow it (summary swallowing usage/defined_in). Test the extractor directly
# — _bundle_get's head -1 hides the over-captured trailing lines.
raw_summary4="$(_dgather_mechanic_stanza "$MECHANICS_YAML" "fixture-mechanic" "summary")"
if grep -qE '(^|[^a-z])(usage|defined_in):' <<< "$raw_summary4"; then
    assert_fail "[SPEC-4] summary must not over-capture sibling keys" "got: $raw_summary4"
else
    assert_pass "[SPEC-4] summary does not over-capture usage/defined_in"
fi
raw_usage4="$(_dgather_mechanic_stanza "$MECHANICS_YAML" "fixture-mechanic" "usage")"
if grep -qE '(^|[^a-z])defined_in:' <<< "$raw_usage4"; then
    assert_fail "[SPEC-4] usage must not over-capture defined_in" "got: $raw_usage4"
else
    assert_pass "[SPEC-4] usage does not over-capture defined_in"
fi

mech_source_b64="$(_bundle_get "$mech_bundle" "source")"
mech_source_decoded="$(printf '%s' "$mech_source_b64" | base64 -d 2>/dev/null)"
assert_contains "[SPEC-4] mechanic source contains known content" \
    "$mech_source_decoded" "fixture_mechanic"

mech_wiki_b64="$(_bundle_get "$mech_bundle" "wiki_page")"
mech_wiki_decoded="$(printf '%s' "$mech_wiki_b64" | base64 -d 2>/dev/null)"
assert_contains "[SPEC-4] mechanic wiki_page present" \
    "$mech_wiki_decoded" "fixture-mechanic"

# ─── SPEC-5: mechanic-nodocs → empty summary/usage, source from defined_in ────
WIKI_NO_MECH="$TEST_TEMP_DIR/wiki-no-mech"
mkdir -p "$WIKI_NO_MECH/plugins" "$WIKI_NO_MECH/mechanics"
mech_bundle5="$(doc_gather_mechanic_bundle "fixture-mechanic-nodocs" "$MECHANICS_YAML" "$WIKI_NO_MECH")"

assert_eq "[SPEC-5] nodocs mechanic summary is empty" \
    "" "$(_bundle_get "$mech_bundle5" "summary")"

assert_eq "[SPEC-5] nodocs mechanic usage is empty" \
    "" "$(_bundle_get "$mech_bundle5" "usage")"

mech5_source_b64="$(_bundle_get "$mech_bundle5" "source")"
mech5_source_decoded="$(printf '%s' "$mech5_source_b64" | base64 -d 2>/dev/null)"
assert_contains "[SPEC-5] nodocs mechanic source non-empty (falls back to defined_in)" \
    "$mech5_source_decoded" "fixture_mechanic"

assert_eq "[SPEC-5] nodocs mechanic wiki_page is empty when absent" \
    "" "$(_bundle_get "$mech_bundle5" "wiki_page")"

# ─── SPEC-6: unknown plugin id → rc=1 with error message ──────────────────────
set +e
out6="$(doc_gather_plugin_bundle "no-such-plugin-id" "$PLUGIN_FIXTURES" "$WIKI_ROOT" 2>&1)"
rc6=$?
set -e
assert_eq "[SPEC-6] unknown plugin id returns rc=1" "1" "$rc6"
assert_contains "[SPEC-6] unknown plugin id prints error" "$out6" "not found"

# ─── SPEC-7: unknown mechanic name → rc=1 ────────────────────────────────────
set +e
out7="$(doc_gather_mechanic_bundle "no-such-mechanic" "$MECHANICS_YAML" "$WIKI_ROOT" 2>&1)"
rc7=$?
set -e
assert_eq "[SPEC-7] unknown mechanic name returns rc=1" "1" "$rc7"
assert_contains "[SPEC-7] unknown mechanic prints error" "$out7" "not found"

# ─── SPEC-8: doc_gather_plugin_ids lists all plugin ids under plugins_root ────
ids8="$(doc_gather_plugin_ids "$PLUGIN_FIXTURES")"
assert_contains "[SPEC-8] plugin ids includes doc-gather-full" \
    "$ids8" "doc-gather-full"
assert_contains "[SPEC-8] plugin ids includes doc-gather-nodocs" \
    "$ids8" "doc-gather-nodocs"

# ─── SPEC-9: doc_gather_mechanic_ids lists all mechanic names ─────────────────
mech_ids9="$(doc_gather_mechanic_ids "$MECHANICS_YAML")"
assert_contains "[SPEC-9] mechanic ids includes fixture-mechanic" \
    "$mech_ids9" "fixture-mechanic"
assert_contains "[SPEC-9] mechanic ids includes fixture-mechanic-nodocs" \
    "$mech_ids9" "fixture-mechanic-nodocs"

# ─── SPEC-10: bundle source field is valid base64 ─────────────────────────────
bundle10="$(doc_gather_plugin_bundle "doc-gather-full" "$PLUGIN_FIXTURES" "$WIKI_ROOT")"
src10_b64="$(_bundle_get "$bundle10" "source")"
set +e
decoded10="$(printf '%s' "$src10_b64" | base64 -d 2>/dev/null)"
b64rc=$?
set -e
assert_eq "[SPEC-10] source base64 decodes without error" "0" "$b64rc"
assert_gt "[SPEC-10] decoded source is non-empty" "${#decoded10}" "0"

# ─── SPEC-11: wiki_page field is valid base64 when page exists ────────────────
bundle11="$(doc_gather_plugin_bundle "doc-gather-full" "$PLUGIN_FIXTURES" "$WIKI_ROOT")"
wiki11_b64="$(_bundle_get "$bundle11" "wiki_page")"
set +e
decoded11="$(printf '%s' "$wiki11_b64" | base64 -d 2>/dev/null)"
b64rc11=$?
set -e
assert_eq "[SPEC-11] wiki_page base64 decodes without error" "0" "$b64rc11"
assert_gt "[SPEC-11] decoded wiki_page is non-empty" "${#decoded11}" "0"

# ─── SPEC-12: gather works on a REAL mechanic from the live config/mechanics.yaml.
#     Pick the FIRST entry dynamically so the assertion survives registry edits
#     (do NOT hardcode a mechanic name — the DOC-B live-coupling lesson). ─────────
first_mech12="$(doc_gather_mechanic_ids "$REPO_ROOT/config/mechanics.yaml" | head -1)"
assert_gt "[SPEC-12] live config/mechanics.yaml has at least one mechanic" \
    "${#first_mech12}" "0"
bundle12="$(doc_gather_mechanic_bundle "$first_mech12" \
    "$REPO_ROOT/config/mechanics.yaml" "$WIKI_ROOT")"
name12="$(_bundle_get "$bundle12" "name")"
def12="$(_bundle_get "$bundle12" "defined_in")"
assert_eq "[SPEC-12] live mechanic bundle name matches the requested mechanic" \
    "$first_mech12" "$name12"
assert_gt "[SPEC-12] live mechanic bundle has a non-empty defined_in" "${#def12}" "0"

# ─── SPEC-13: plugin bundle output contains all required keys ─────────────────
bundle13="$(doc_gather_plugin_bundle "doc-gather-full" "$PLUGIN_FIXTURES" "$WIKI_ROOT")"
for key13 in id name kind version summary usage tier_default source wiki_page; do
    assert_contains "[SPEC-13] bundle has key ${key13}" "$bundle13" "${key13}="
done

# ─── Teardown ─────────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }

print_test_results
