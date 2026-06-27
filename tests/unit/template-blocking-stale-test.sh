#!/usr/bin/env bash
# Unit test: stale _TPL_STAGE_BLOCKING_* exports are cleared when load_template
# is called a second time in the same process with a template that does NOT
# declare blocking:true for a previously-blocking stage. (Bug fix: PR #950.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "stale _TPL_STAGE_BLOCKING_* cleared on second load_template (#952)"
setup_test_env "template-blocking-stale"

# ── Fixture A: cq-preflight declares blocking: true ──────────────────────────
TPL_A="$TEST_TEMP_DIR/tpl-a.yaml"
cat > "$TPL_A" <<'EOF'
id: tpl-a
name: Template A
flow:
  - intake
  - cq-preflight

intake:
  roles: [intake]

cq-preflight:
  roles: [cq_preflight]
  blocking: true
EOF

# ── Fixture B: cq-preflight present but NOT blocking ─────────────────────────
TPL_B="$TEST_TEMP_DIR/tpl-b.yaml"
cat > "$TPL_B" <<'EOF'
id: tpl-b
name: Template B
flow:
  - intake
  - cq-preflight

intake:
  roles: [intake]

cq-preflight:
  roles: [cq_preflight]
EOF

# Source template.sh once — provides load_template for this process.
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

# ── Load A: blocking flag must be set ────────────────────────────────────────
load_template "$TPL_A"
got_after_a="${_TPL_STAGE_BLOCKING_cq_preflight:-}"
# [SPEC-2] guard: first load with blocking:true exports the flag correctly.
assert_eq "[SPEC-2] blocking flag set after loading template A (blocking: true)" \
    "true" "$got_after_a"

# ── Load B: stale flag must be cleared ───────────────────────────────────────
load_template "$TPL_B"
got_after_b="${_TPL_STAGE_BLOCKING_cq_preflight:-}"
# [SPEC-1] change: second load without blocking: must clear the flag.
# At baseline (pre-fix) this fails because the flag is never unset.
assert_eq "[SPEC-1] stale blocking flag cleared after loading template B (no blocking:)" \
    "" "$got_after_b"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
