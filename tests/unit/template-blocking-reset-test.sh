#!/usr/bin/env bash
# Unit test: load_template clears stale _TPL_STAGE_BLOCKING_<id> between loads.
# ADR-013 (CQ-3 / issue #863); regression guard for issue #952 follow-up.
#
# [SPEC-1] GUARD: loading a template with blocking:true sets the export.
# [SPEC-2] CHANGE: loading a second template where the same stage is non-blocking
#          clears the previously-set export (fails at merge-base without the fix).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "load_template: stale _TPL_STAGE_BLOCKING_<id> cleared between loads"
setup_test_env "template-blocking-reset"

# Minimal new-shape fixture: cq-preflight with blocking:true.
TPL_A="$TEST_TEMP_DIR/tpl-a.yaml"
cat > "$TPL_A" <<'EOF'
flow:
  - cq-preflight

cq-preflight:
  roles: [cq_preflight]
  blocking: true
EOF

# Same stage, no blocking attribute.
TPL_B="$TEST_TEMP_DIR/tpl-b.yaml"
cat > "$TPL_B" <<'EOF'
flow:
  - cq-preflight

cq-preflight:
  roles: [cq_preflight]
EOF

export ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_PLUGINS_ROOT" "$ZBUILD_STATE_DIR"

# Source template.sh to bring load_template into scope.
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

# ── [SPEC-1]: Blocking export is SET after loading template A ─────────────────
print_test_section "[SPEC-1]: load_template sets _TPL_STAGE_BLOCKING_ for blocking:true stage"

load_template "$TPL_A"

got1="${_TPL_STAGE_BLOCKING_cq_preflight:-}"
assert_eq "[SPEC-1] load_template A: _TPL_STAGE_BLOCKING_cq_preflight=true" "true" "$got1"

# ── [SPEC-2]: Blocking export is CLEARED after loading template B ─────────────
# This fails at baseline: without the fix the stale export persists.
print_test_section "[SPEC-2]: load_template clears stale _TPL_STAGE_BLOCKING_ on second load"

load_template "$TPL_B"

got2="${_TPL_STAGE_BLOCKING_cq_preflight:-}"
assert_eq "[SPEC-2] load_template B: _TPL_STAGE_BLOCKING_cq_preflight cleared (empty)" "" "$got2"

cleanup_test_env
print_test_results
