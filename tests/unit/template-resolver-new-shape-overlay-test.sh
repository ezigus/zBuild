#!/usr/bin/env bash
# Tests: per-repo template overlay, NEW shape (#1831, ADR-016 lock 1).
#
# ADR-016: "Full replace: there is no field-level merge with the shipped file."
# The merge understood only the OLD shape's `stages:` / `stage_definitions:`
# blocks. A NEW-shape override (ADR-027: top-level `flow:` + per-stage sections)
# has neither, so the merge copied the base wholesale, appended nothing, and the
# operator's override was discarded — silently, with the BASE template running.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/pipeline/template-resolver.sh
source "$REPO_ROOT/core/pipeline/template-resolver.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

print_test_header "per-repo overlay: new-shape full replace (#1831, ADR-016)"
setup_test_env "zb-tpl-overlay-new-shape"

REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO/.zbuild/templates"

# A new-shape override whose flow shares NO stage with simple.yaml's. If the
# override is discarded, the resolved flow is simple's 14 — an unmistakable
# difference, rather than a subtle one that a lenient assertion might absorb.
cat > "$REPO/.zbuild/templates/ovl.yaml" <<'EOF'
id: ovl
name: Overlay
extends: simple
defaults:
  strategy: fanout
flow:
  - solo

solo:
  gate: auto
  roles: [intake]
  io:
    destinations: [file]
EOF

# ─── [SPEC-1][change] the override replaces the base, it is not ignored ──────
print_test_section "[SPEC-1][change] a new-shape override actually takes effect"

_resolved="$(resolve_template_file ovl "$REPO")"
assert_eq "[SPEC-1] resolve_template_file succeeds" "0" "$?"

load_template "$_resolved" >/dev/null 2>&1
assert_eq "[SPEC-1] the resolved flow is the OVERRIDE's, not the base's" \
    "solo" "${_TPL_STAGES[*]}"
assert_eq "[SPEC-1] the base's 14 stages did not survive the replace" \
    "1" "${#_TPL_STAGES[@]}"

# ─── [SPEC-2][guard] `extends:` is still required (ADR-016 lock 2) ───────────
# Full replace is about FIELDS, not about lineage. An override with no
# `extends:` must still be refused — this fix must not weaken that lock.
print_test_section "[SPEC-2][guard] extends: is still required for a new-shape override"

cat > "$REPO/.zbuild/templates/noext.yaml" <<'EOF'
id: noext
name: No Extends
flow:
  - solo

solo:
  gate: auto
  roles: [intake]
  io:
    destinations: [file]
EOF
_rc=0
resolve_template_file noext "$REPO" >/dev/null 2>&1 || _rc=$?
assert_exit_code "[SPEC-2] a new-shape override with no extends: is refused" "1" "$_rc"

# And a declared base that does not exist is still refused (lock 3).
cat > "$REPO/.zbuild/templates/badbase.yaml" <<'EOF'
id: badbase
name: Bad Base
extends: no_such_template
flow:
  - solo

solo:
  gate: auto
  roles: [intake]
  io:
    destinations: [file]
EOF
_rc=0
resolve_template_file badbase "$REPO" >/dev/null 2>&1 || _rc=$?
assert_exit_code "[SPEC-2] a new-shape override extending a missing base is refused" "1" "$_rc"

# ─── [SPEC-3][guard] the OLD shape still merges the way it always did ────────
# The old path is the one every existing overlay fixture uses. A regression here
# would be invisible in the new-shape tests above.
print_test_section "[SPEC-3][guard] an old-shape override still merges over the base"

cat > "$REPO/.zbuild/templates/oldshape.yaml" <<'EOF'
id: oldshape
name: Old Shape
extends: simple
stages:
  - id: intake
    gate: auto
    io:
      destinations: [file]
  - id: build
    gate: auto
    io:
      destinations: [file]
EOF
_resolved_old="$(resolve_template_file oldshape "$REPO")"
load_template "$_resolved_old" >/dev/null 2>&1
assert_eq "[SPEC-3] old-shape override still yields its own 2 stages" \
    "2" "${#_TPL_STAGES[@]}"

# ─── [SPEC-4][guard] no override at all still resolves to the shipped file ───
print_test_section "[SPEC-4][guard] absent override resolves to the shipped template"

_shipped="$(resolve_template_file simple "$REPO")"
assert_eq "[SPEC-4] resolves to the shipped path when no override exists" \
    "$REPO_ROOT/config/templates/simple.yaml" "$_shipped"

print_test_results
