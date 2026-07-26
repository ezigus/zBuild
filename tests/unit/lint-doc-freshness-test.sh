#!/usr/bin/env bash
# tests/unit/lint-doc-freshness-test.sh — DOC-E freshness + coverage + DOC-STYLE gate (#1418).
#
# Verifies scripts/lib/lint-doc-freshness.sh:
#   SPEC-1: missing plugin page → rc=1, output names the plugin id
#   SPEC-2: missing mechanic page → rc=1, output names the mechanic
#   SPEC-3: plugin page without newcomer opening → rc=1 (conformance)
#   SPEC-4: mechanic page without newcomer opening → rc=1 (conformance)
#   SPEC-5: plugin page with embedded hash not matching manifest → rc=1 (freshness)
#   SPEC-6: mechanic page with embedded hash not matching defined_in → rc=1 (freshness)
#   SPEC-7: orphan plugin page (no backing manifest) → rc=1
#   SPEC-8: all-green fixture → rc=0; real repo gate → rc=0; package.json wired
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/lib/lint-doc-freshness.sh — doc coverage + conformance + freshness (#1418)"
setup_test_env "lint-doc-freshness"

CHECKER="$REPO_ROOT/scripts/lib/lint-doc-freshness.sh"

# Copy the checker into $root/scripts/lib/ — it derives _REPO_ROOT two dirs up.
build_fixture_repo() {
    local root="$1"
    mkdir -p \
        "$root/scripts/lib" \
        "$root/config" \
        "$root/docs/wiki/plugins" \
        "$root/docs/wiki/mechanics"
    cp "$CHECKER" "$root/scripts/lib/lint-doc-freshness.sh"
}

# Write a minimal conforming mechanics.yaml with one entry.
write_mechanics_yaml() {
    local root="$1" name="${2:-mymechanic}" defined_in="${3:-scripts/lib/lint-doc-freshness.sh}"
    cat > "$root/config/mechanics.yaml" <<EOF
mechanics:
  - name: $name
    summary: A test mechanic used in fixture.
    defined_in: $defined_in
EOF
}

# Write a conforming mechanic wiki page (prose opening, no hash footer).
write_mechanic_page() {
    local root="$1" name="${2:-mymechanic}"
    cat > "$root/docs/wiki/mechanics/$name.md" <<EOF
# $name

The $name mechanic handles core processing in the pipeline and lets you configure its behavior.

## Details
EOF
}

# Write a minimal plugin manifest with the given id.
write_plugin_manifest() {
    local root="$1" id="$2" kind="${3:-tool}"
    mkdir -p "$root/plugins/$kind/$id"
    cat > "$root/plugins/$kind/$id/manifest.yaml" <<EOF
id: $id
name: My $id Plugin
kind: $kind
version: 0.1.0
description: |
  Test plugin manifest for $id.
EOF
}

# Write a conforming plugin wiki page (prose opening, no hash footer).
write_plugin_page() {
    local root="$1" id="$2"
    cat > "$root/docs/wiki/plugins/$id.md" <<EOF
# $id

The $id plugin provides the core functionality for the $id stage of the pipeline.

## Details
EOF
}

# ─── SPEC-1: missing plugin page → rc=1, output names the plugin id ──────────
print_test_section "SPEC-1: missing plugin page"
FX="$TEST_TEMP_DIR/spec1"
build_fixture_repo "$FX"
write_mechanics_yaml "$FX"
write_mechanic_page "$FX"
write_plugin_manifest "$FX" "myplugin"
# intentionally do NOT create docs/wiki/plugins/myplugin.md

rc=0
out="$(bash "$FX/scripts/lib/lint-doc-freshness.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-1] missing plugin page → rc=1" "1" "$rc"
assert_contains "[SPEC-1] output names the missing plugin id" "$out" "myplugin"

# ─── SPEC-2: missing mechanic page → rc=1, output names the mechanic ─────────
print_test_section "SPEC-2: missing mechanic page"
FX="$TEST_TEMP_DIR/spec2"
build_fixture_repo "$FX"
write_mechanics_yaml "$FX" "mymechanic"
# intentionally do NOT create docs/wiki/mechanics/mymechanic.md
write_plugin_manifest "$FX" "myplugin"
write_plugin_page "$FX" "myplugin"

rc=0
out="$(bash "$FX/scripts/lib/lint-doc-freshness.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-2] missing mechanic page → rc=1" "1" "$rc"
assert_contains "[SPEC-2] output names the missing mechanic" "$out" "mymechanic"

# ─── SPEC-3: plugin page without newcomer opening → rc=1 ─────────────────────
print_test_section "SPEC-3: plugin page without newcomer opening"
FX="$TEST_TEMP_DIR/spec3"
build_fixture_repo "$FX"
write_mechanics_yaml "$FX"
write_mechanic_page "$FX"
write_plugin_manifest "$FX" "myplugin"
# Plugin page opens with bold label — fails conformance check
cat > "$FX/docs/wiki/plugins/myplugin.md" <<'EOF'
# myplugin

**My Plugin**

- **Kind:** `tool`
EOF

rc=0
out="$(bash "$FX/scripts/lib/lint-doc-freshness.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-3] plugin page without prose opening → rc=1" "1" "$rc"
assert_contains "[SPEC-3] output mentions conformance failure" "$out" "myplugin"

# ─── SPEC-4: mechanic page without newcomer opening → rc=1 ───────────────────
print_test_section "SPEC-4: mechanic page without newcomer opening"
FX="$TEST_TEMP_DIR/spec4"
build_fixture_repo "$FX"
write_mechanics_yaml "$FX"
write_plugin_manifest "$FX" "myplugin"
write_plugin_page "$FX" "myplugin"
# Mechanic page opens with a bold label — fails conformance check
cat > "$FX/docs/wiki/mechanics/mymechanic.md" <<'EOF'
# mymechanic

**My Mechanic**

Bullet list with no prose sentence:

- item one
- item two
EOF

rc=0
out="$(bash "$FX/scripts/lib/lint-doc-freshness.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-4] mechanic page without prose opening → rc=1" "1" "$rc"
assert_contains "[SPEC-4] output mentions conformance failure" "$out" "mymechanic"

# ─── SPEC-5: plugin page with stale hash → rc=1 ──────────────────────────────
print_test_section "SPEC-5: plugin page with stale hash footer"
FX="$TEST_TEMP_DIR/spec5"
build_fixture_repo "$FX"
write_mechanics_yaml "$FX"
write_mechanic_page "$FX"
write_plugin_manifest "$FX" "myplugin"
# Plugin page has all-zeros hash — won't match the actual manifest sha256
cat > "$FX/docs/wiki/plugins/myplugin.md" <<'EOF'
# myplugin

The myplugin plugin provides the core functionality for the myplugin stage of the pipeline.

## Details

<!-- zbuild-doc-hash: 0000000000000000000000000000000000000000000000000000000000000000 -->
EOF

rc=0
out="$(bash "$FX/scripts/lib/lint-doc-freshness.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-5] plugin page with wrong hash → rc=1" "1" "$rc"
assert_contains "[SPEC-5] output mentions hash mismatch" "$out" "mismatch"

# ─── SPEC-6: mechanic page with stale hash → rc=1 ────────────────────────────
print_test_section "SPEC-6: mechanic page with stale hash footer"
FX="$TEST_TEMP_DIR/spec6"
build_fixture_repo "$FX"
# Use the checker script itself as the defined_in source (it always exists).
write_mechanics_yaml "$FX" "mymechanic" "scripts/lib/lint-doc-freshness.sh"
write_plugin_manifest "$FX" "myplugin"
write_plugin_page "$FX" "myplugin"
# Mechanic page has all-zeros hash — won't match the actual source file sha256
cat > "$FX/docs/wiki/mechanics/mymechanic.md" <<'EOF'
# mymechanic

The mymechanic mechanic handles core processing in the pipeline and lets you configure its behavior.

## Details

<!-- zbuild-doc-hash: 0000000000000000000000000000000000000000000000000000000000000000 -->
EOF

rc=0
out="$(bash "$FX/scripts/lib/lint-doc-freshness.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-6] mechanic page with wrong hash → rc=1" "1" "$rc"
assert_contains "[SPEC-6] output mentions hash mismatch" "$out" "mismatch"

# ─── SPEC-7: orphan plugin page (no backing manifest) → rc=1 ─────────────────
print_test_section "SPEC-7: orphan plugin wiki page"
FX="$TEST_TEMP_DIR/spec7"
build_fixture_repo "$FX"
write_mechanics_yaml "$FX"
write_mechanic_page "$FX"
write_plugin_manifest "$FX" "myplugin"
write_plugin_page "$FX" "myplugin"
# ghost.md has no backing manifest with id: ghost
cat > "$FX/docs/wiki/plugins/ghost.md" <<'EOF'
# ghost

The ghost plugin handles phantom operations that have no real backing implementation.

## Details
EOF

rc=0
out="$(bash "$FX/scripts/lib/lint-doc-freshness.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-7] orphan plugin page → rc=1" "1" "$rc"
assert_contains "[SPEC-7] output names the orphan page" "$out" "ghost"

# ─── SPEC-8: all-green fixture + real repo gate ───────────────────────────────
print_test_section "SPEC-8: all-green fixture and real repo"

# (a) All-green fixture: pages present, conforming, no hash footers (freshness no-op), no orphans.
FX="$TEST_TEMP_DIR/spec8"
build_fixture_repo "$FX"
write_mechanics_yaml "$FX"
write_mechanic_page "$FX"
write_plugin_manifest "$FX" "myplugin"
write_plugin_page "$FX" "myplugin"

rc=0
out="$(bash "$FX/scripts/lib/lint-doc-freshness.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-8] all-green fixture → rc=0" "0" "$rc"
assert_contains "[SPEC-8] fixture pass line printed" "$out" "OK"

# (b) Real repo gate: all 36 plugin pages and 16 mechanic pages must pass.
rc=0
out="$(bash "$CHECKER" 2>&1)" || rc=$?
assert_eq "[SPEC-8] real repo gate → rc=0" "0" "$rc"
assert_contains "[SPEC-8] real repo pass line mentions plugins" "$out" "plugin"

# (c) Wiring guard: package.json must include lint-doc-freshness.sh in the lint chain.
pkg="$(cat "$REPO_ROOT/package.json")"
assert_contains "[SPEC-8] package.json lint chain includes lint-doc-freshness.sh" \
    "$pkg" "lint-doc-freshness.sh"

# ─── Persona-feature helpers ──────────────────────────────────────────────────

# Write a minimal kind:persona manifest.
write_persona_manifest() {
    local root="$1" id="$2"
    mkdir -p "$root/plugins/persona/$id"
    cat > "$root/plugins/persona/$id/manifest.yaml" <<EOF
id: $id
name: $id persona
kind: persona
version: 0.1.0
summary: A test persona for automated fixtures.
persona:
  role: a test role
  perspective: "A test perspective for automated testing purposes only."
EOF
}

# Write a conforming personas.md index listing the given ids.
# Call with no ids to produce a conforming page that lists nothing.
write_personas_index() {
    local root="$1"; shift
    local ids=("$@")
    {
        printf '# Personas\n\n'
        printf 'A persona is a data-only plugin that gives a pipeline stage a named identity and professional viewpoint.\n\n'
        for id in "${ids[@]}"; do
            printf '## %s\n\n' "$id"
            printf 'The %s persona provides a test identity for use in automated test fixtures.\n\n' "$id"
        done
    } > "$root/docs/wiki/plugins/personas.md"
}

# ─── SPEC-1 (persona): kind:persona skips per-id coverage check ──────────────
print_test_section "SPEC-1 (persona): kind:persona skips per-id coverage"
FX="$TEST_TEMP_DIR/spec-p1"
build_fixture_repo "$FX"
write_mechanics_yaml "$FX"
write_mechanic_page "$FX"
write_persona_manifest "$FX" "test-persona"
write_personas_index "$FX" "test-persona"
# No test-persona.md — kind:persona skips per-id coverage check

rc=0
out="$(bash "$FX/scripts/lib/lint-doc-freshness.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-1] kind:persona skips per-id coverage → rc=0" "0" "$rc"

# ─── SPEC-2 (persona): personas.md missing when personas exist → rc=1 ─────────
print_test_section "SPEC-2 (persona): missing personas.md → rc=1"
FX="$TEST_TEMP_DIR/spec-p2"
build_fixture_repo "$FX"
write_mechanics_yaml "$FX"
write_mechanic_page "$FX"
write_persona_manifest "$FX" "test-persona"
# intentionally do NOT create personas.md

rc=0
out="$(bash "$FX/scripts/lib/lint-doc-freshness.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-2] missing personas.md → rc=1" "1" "$rc"
assert_contains "[SPEC-2] error mentions personas.md" "$out" "personas.md"

# ─── SPEC-3 (persona): persona id absent from personas.md → rc=1 ─────────────
print_test_section "SPEC-3 (persona): id absent from personas.md → rc=1"
FX="$TEST_TEMP_DIR/spec-p3"
build_fixture_repo "$FX"
write_mechanics_yaml "$FX"
write_mechanic_page "$FX"
write_persona_manifest "$FX" "test-persona"
write_personas_index "$FX"  # conforming prose but no ids listed

rc=0
out="$(bash "$FX/scripts/lib/lint-doc-freshness.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-3] persona id absent from index → rc=1" "1" "$rc"
assert_contains "[SPEC-3] error says id not in personas.md" "$out" "not listed in"

# ─── SPEC-4 (persona): personas.md exempt from orphan check ──────────────────
print_test_section "SPEC-4 (persona): personas.md is not an orphan"
FX="$TEST_TEMP_DIR/spec-p4"
build_fixture_repo "$FX"
write_mechanics_yaml "$FX"
write_mechanic_page "$FX"
write_persona_manifest "$FX" "test-persona"
write_personas_index "$FX" "test-persona"
# No manifest with id:personas — orphan check must exempt 'personas' slug

rc=0
out="$(bash "$FX/scripts/lib/lint-doc-freshness.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-4] personas.md exempt from orphan → rc=0" "0" "$rc"

# SPEC-4[change]: personas.md states role is never injected into the prompt (perspective-only seam)
real_personas_content="$(cat "$REPO_ROOT/docs/wiki/plugins/personas.md")"
case "$real_personas_content" in
    *"never injected into the prompt"*) doc_persp_only=1 ;;
    *)                                  doc_persp_only=0 ;;
esac
assert_eq "[SPEC-4] personas.md states role is never injected into the prompt" "1" "$doc_persp_only"

# ─── SPEC-5 (persona): non-persona plugin still requires per-id page ──────────
print_test_section "SPEC-5 (persona): non-persona still requires per-id page"
FX="$TEST_TEMP_DIR/spec-p5"
build_fixture_repo "$FX"
write_mechanics_yaml "$FX"
write_mechanic_page "$FX"
write_plugin_manifest "$FX" "myplugin" "tool"
write_persona_manifest "$FX" "test-persona"
write_personas_index "$FX" "test-persona"
# myplugin.md intentionally absent

rc=0
out="$(bash "$FX/scripts/lib/lint-doc-freshness.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-5] non-persona still needs per-id page → rc=1" "1" "$rc"
assert_contains "[SPEC-5] error names the non-persona plugin" "$out" "myplugin"

# ─── SPEC-6 (persona): all-green persona fixture → rc=0 ──────────────────────
print_test_section "SPEC-6 (persona): all-green persona fixture → rc=0"
FX="$TEST_TEMP_DIR/spec-p6"
build_fixture_repo "$FX"
write_mechanics_yaml "$FX"
write_mechanic_page "$FX"
write_plugin_manifest "$FX" "myplugin"
write_plugin_page "$FX" "myplugin"
write_persona_manifest "$FX" "test-persona"
write_personas_index "$FX" "test-persona"

rc=0
out="$(bash "$FX/scripts/lib/lint-doc-freshness.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-6] all-green persona fixture → rc=0" "0" "$rc"

# ─── SPEC-7 (persona): personas.md requires conforming prose opening ───────────
print_test_section "SPEC-7 (persona): personas.md conformance check"
FX="$TEST_TEMP_DIR/spec-p7"
build_fixture_repo "$FX"
write_mechanics_yaml "$FX"
write_mechanic_page "$FX"
write_persona_manifest "$FX" "test-persona"
# personas.md opens with a bullet list and has no prose sentence — fails conformance;
# does contain test-persona id so the id-listing check passes
cat > "$FX/docs/wiki/plugins/personas.md" <<'EOF'
# Personas

- test-persona

## test-persona

- kind: persona
EOF

rc=0
out="$(bash "$FX/scripts/lib/lint-doc-freshness.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-7] personas.md without prose opening → rc=1" "1" "$rc"
assert_contains "[SPEC-7] error mentions newcomer prose" "$out" "prose"

# ─── SPEC-3 (persona): substring is not a false-positive listing ──────────────
# A persona id that appears ONLY as a substring of another listed id must still
# fail the strict listing check (review #1530: -qF "arch" wrongly matched
# "architect"). 'arch' is unlisted; 'architect' is listed → 'arch' must fail.
print_test_section "SPEC-3 (persona): substring id is not a false positive"
FX="$TEST_TEMP_DIR/spec-p3sub"
build_fixture_repo "$FX"
write_mechanics_yaml "$FX"
write_mechanic_page "$FX"
write_persona_manifest "$FX" "architect"
write_persona_manifest "$FX" "arch"
write_personas_index "$FX" "architect"  # lists 'architect' only; 'arch' present solely as its substring

rc=0
out="$(bash "$FX/scripts/lib/lint-doc-freshness.sh" 2>&1)" || rc=$?
assert_eq "[SPEC-3] substring-only persona id → rc=1" "1" "$rc"
assert_contains "[SPEC-3] error names the unlisted substring id 'arch'" "$out" "'arch'"

# ─── SPEC-1 (stage-io): docs/wiki/mechanics/stage-io.md exists ───────────────
# Change assertion — fails at baseline (before stage-io.md is created).
print_test_section "SPEC-1 (stage-io): stage-io.md wiki page exists"
assert_file_exists "[SPEC-1] docs/wiki/mechanics/stage-io.md exists" \
    "$REPO_ROOT/docs/wiki/mechanics/stage-io.md"

# ─── SPEC-3 (stage-io): Mechanics.md carries the stage-io row ────────────────
# Change assertion — fails at baseline (before the row is added).
print_test_section "SPEC-3 (stage-io): Mechanics.md has stage-io row"
mechanics_index="$REPO_ROOT/docs/wiki/Mechanics.md"
stage_io_row_present=0
grep -qF "mechanics/stage-io" "$mechanics_index" 2>/dev/null && stage_io_row_present=1
assert_eq "[SPEC-3] Mechanics.md carries the [[mechanics/stage-io]] row" "1" "$stage_io_row_present"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
