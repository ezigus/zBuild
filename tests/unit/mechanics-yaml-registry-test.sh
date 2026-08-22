#!/usr/bin/env bash
# tests/unit/mechanics-yaml-registry-test.sh — validate config/mechanics.yaml registry.
#
# Covers:
#   SPEC-1  config/mechanics.yaml exists and validator exits 0 on it
#   SPEC-2  all 16 expected mechanic names are present in the registry
#   SPEC-3  every defined_in path in the registry resolves to an existing file
#   SPEC-4  validator rejects a registry with a missing defined_in field (non-zero exit)
#   SPEC-5  validator rejects a registry with a missing name field (non-zero exit)
#   SPEC-6  registry has a top-level mechanics array (not empty)
#   SPEC-7  every docs/wiki/mechanics/<name>.md has a registry entry
#   SPEC-8  A→B fallback: pure-bash path validates the real registry (no python3/yq needed)
#   SPEC-9  the validator is WIRED into the package.json lint chain (load-bearing)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "config/mechanics.yaml registry + validator (issue #1416)"
setup_test_env "mechanics-yaml-registry"

VALIDATOR="$REPO_ROOT/scripts/lib/validate-mechanics-yaml.sh"
MECHANICS_YAML="$REPO_ROOT/config/mechanics.yaml"
WIKI_DIR="$REPO_ROOT/docs/wiki/mechanics"

# ── SPEC-1: registry exists and validator exits 0 ────────────────────────────
assert_file_exists "[SPEC-1] config/mechanics.yaml exists" "$MECHANICS_YAML"

validator_rc=0
bash "$VALIDATOR" >/dev/null 2>&1 || validator_rc=$?
assert_eq "[SPEC-1] validator exits 0 on real registry" "0" "$validator_rc"

# ── SPEC-2: all 18 expected mechanic names are present ───────────────────────
EXPECTED_MECHANICS=(
    admission-gate
    aggregators
    convergence
    cycle
    event-bus
    gates
    leaf
    map
    parallel
    redaction-chokepoint
    route_back
    router-models-as-data
    scope-governance
    sequence
    stage-io
    state-and-resume
    vision-document
    write-boundary
)

missing_mechanics=()
for mechanic in "${EXPECTED_MECHANICS[@]}"; do
    if ! grep -qF "name: $mechanic" "$MECHANICS_YAML"; then
        missing_mechanics+=("$mechanic")
    fi
done

missing_count="${#missing_mechanics[@]}"
assert_eq "[SPEC-2] all 18 expected mechanics present in registry (missing: ${missing_mechanics[*]:-none})" "0" "$missing_count"

# ── SPEC-3: every defined_in path resolves to an existing file ───────────────
# Extract defined_in values and check each one
defined_in_errors=()
while IFS= read -r line; do
    if [[ "$line" =~ defined_in:[[:space:]]*(.+)$ ]]; then
        path="${BASH_REMATCH[1]}"
        path="${path#"${path%%[! ]*}"}"  # trim leading spaces
        if [[ -n "$path" && ! -f "$REPO_ROOT/$path" ]]; then
            defined_in_errors+=("$path")
        fi
    fi
done < "$MECHANICS_YAML"

defined_in_error_count="${#defined_in_errors[@]}"
assert_eq "[SPEC-3] all defined_in paths resolve to existing files (bad: ${defined_in_errors[*]:-none})" "0" "$defined_in_error_count"

# ── SPEC-4: validator rejects missing defined_in field ───────────────────────
# A→B fallback documented: if a mechanic is absent or malformed in the registry,
# the validator exits non-zero so the doc generator knows to fall back to source.
FIXTURE_MISSING_DEFINED_IN="$TEST_TEMP_DIR/bad-missing-defined-in.yaml"
cat > "$FIXTURE_MISSING_DEFINED_IN" <<'YAML'
mechanics:
  - name: some-mechanic
    summary: A mechanic with no defined_in field.
YAML

bad_rc=0
ZBUILD_MECHANICS_YAML="$FIXTURE_MISSING_DEFINED_IN" bash "$VALIDATOR" >/dev/null 2>&1 || bad_rc=$?
assert_eq "[SPEC-4] validator rejects registry entry with missing defined_in (non-zero exit)" "1" \
    "$([[ "$bad_rc" -ne 0 ]] && echo 1 || echo 0)"

# ── SPEC-5: validator rejects missing name field ──────────────────────────────
FIXTURE_MISSING_NAME="$TEST_TEMP_DIR/bad-missing-name.yaml"
cat > "$FIXTURE_MISSING_NAME" <<'YAML'
mechanics:
  - defined_in: core/pipeline/runner.sh
    summary: Entry with no name.
YAML

bad_name_rc=0
ZBUILD_MECHANICS_YAML="$FIXTURE_MISSING_NAME" bash "$VALIDATOR" >/dev/null 2>&1 || bad_name_rc=$?
assert_eq "[SPEC-5] validator rejects registry entry with missing name (non-zero exit)" "1" \
    "$([[ "$bad_name_rc" -ne 0 ]] && echo 1 || echo 0)"

# ── SPEC-6: registry has a non-empty mechanics array ─────────────────────────
# Count entries by counting "name:" occurrences under mechanics:
mechanic_count=0
in_mechanics=0
while IFS= read -r line; do
    [[ "$line" =~ ^mechanics: ]] && in_mechanics=1 && continue
    [[ "$in_mechanics" -eq 0 ]] && continue
    [[ "$line" =~ name:[[:space:]].+ ]] && (( mechanic_count++ )) || true
done < "$MECHANICS_YAML"

assert_eq "[SPEC-6] registry mechanics array is non-empty (has entries)" "1" \
    "$([[ "$mechanic_count" -gt 0 ]] && echo 1 || echo 0)"

# ── SPEC-7: every docs/wiki/mechanics/<name>.md has a registry entry ─────────
wiki_orphans=()
if [[ -d "$WIKI_DIR" ]]; then
    for wiki_file in "$WIKI_DIR"/*.md; do
        [[ -f "$wiki_file" ]] || continue
        mechanic_name="$(basename "$wiki_file" .md)"
        if ! grep -qF "name: $mechanic_name" "$MECHANICS_YAML"; then
            wiki_orphans+=("$mechanic_name")
        fi
    done
fi

wiki_orphan_count="${#wiki_orphans[@]}"
assert_eq "[SPEC-7] all docs/wiki/mechanics/*.md files have registry entries (orphans: ${wiki_orphans[*]:-none})" "0" "$wiki_orphan_count"

# ── SPEC-8: pure-bash fallback path validates the real registry ───────────────
# Exercise the B-path by shimming python3 to be unavailable and running the validator.
STUB_BIN="$TEST_TEMP_DIR/no-python-bin"
mkdir -p "$STUB_BIN"
# Create a python3 stub that always fails (simulates unavailable python3)
cat > "$STUB_BIN/python3" <<'STUB'
#!/usr/bin/env bash
# stub: python3 unavailable — force A→B fallback in validate-mechanics-yaml.sh
exit 127
STUB
chmod +x "$STUB_BIN/python3"

bash_fallback_rc=0
PATH="$STUB_BIN:$PATH" bash "$VALIDATOR" >/dev/null 2>&1 || bash_fallback_rc=$?
assert_eq "[SPEC-8] pure-bash fallback path validates real registry (exits 0)" "0" "$bash_fallback_rc"

# ── SPEC-9: the validator is WIRED into the lint chain (load-bearing) ─────────
# The registry is only enforced if package.json's `lint` script actually invokes
# validate-mechanics-yaml.sh. This asserts the wiring is present — reverting
# package.json (dropping the validator from lint) flips this to fail, proving the
# wiring is load-bearing, not inert (ADR-036 reachability).
PKG_JSON="$REPO_ROOT/package.json"
lint_wired=0
grep -q "validate-mechanics-yaml.sh" "$PKG_JSON" 2>/dev/null && lint_wired=1
assert_eq "[SPEC-9] validate-mechanics-yaml.sh is wired into the package.json lint chain" "1" "$lint_wired"

print_test_results
