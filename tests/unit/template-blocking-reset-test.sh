#!/usr/bin/env bash
# Unit test: load_template clears stale _TPL_STAGE_BLOCKING_<id> between loads.
# ADR-013 (CQ-3 / issue #863); regression guard for issue #952 follow-up.
#
# [SPEC-1] GUARD: loading a template with blocking:true sets the export.
# [SPEC-2] CHANGE: loading a second template where the same stage is non-blocking
#          clears the previously-set export (fails at merge-base without the fix).
# [SPEC-3] COLD-START: an env-inherited _TPL_STAGE_BLOCKING_<id> is cleared on the
#          FIRST load in a fresh process (the prior-_TPL_STAGES loop was a no-op
#          there, so the inherited export used to survive — CQ MEDIUM finding).
# [SPEC-4] ABSENT: a stage that was blocking in template A but is absent from the
#          next template's flow entirely still has its export cleared.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "load_template: stale _TPL_STAGE_BLOCKING_<id> cleared between loads"
setup_test_env "template-blocking-reset"

# Minimal new-shape fixture: secret-scan with blocking:true.
TPL_A="$TEST_TEMP_DIR/tpl-a.yaml"
cat > "$TPL_A" <<'EOF'
flow:
  - secret-scan

secret-scan:
  roles: [secret_scan]
  blocking: true
EOF

# Same stage, no blocking attribute.
TPL_B="$TEST_TEMP_DIR/tpl-b.yaml"
cat > "$TPL_B" <<'EOF'
flow:
  - secret-scan

secret-scan:
  roles: [secret_scan]
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

got1="${_TPL_STAGE_BLOCKING_secret_scan:-}"
assert_eq "[SPEC-1] load_template A: _TPL_STAGE_BLOCKING_secret_scan=true" "true" "$got1"

# ── [SPEC-2]: Blocking export is CLEARED after loading template B ─────────────
# This fails at baseline: without the fix the stale export persists.
print_test_section "[SPEC-2]: load_template clears stale _TPL_STAGE_BLOCKING_ on second load"

load_template "$TPL_B"

got2="${_TPL_STAGE_BLOCKING_secret_scan:-}"
assert_eq "[SPEC-2] load_template B: _TPL_STAGE_BLOCKING_secret_scan cleared (empty)" "" "$got2"

# ── [SPEC-3]: cold-start clears env-inherited stale export on FIRST load ───────
# Model a genuine cold start with a fresh subprocess: _TPL_STAGES is unset at
# load entry, so the old prior-_TPL_STAGES unset loop was a no-op and the
# inherited _TPL_STAGE_BLOCKING_secret_scan=true would survive. The prefix-scrub
# clears it. Fails at baseline (no-op loop), passes with the fix.
print_test_section "[SPEC-3]: cold-start clears env-inherited stale _TPL_STAGE_BLOCKING_"

cold_out="$(
    export _TPL_STAGE_BLOCKING_secret_scan=true
    export ZBUILD_PLUGINS_ROOT ZBUILD_STATE_DIR
    bash -c '
        source "$1/scripts/lib/helpers.sh"
        source "$1/scripts/lib/test-helpers.sh"
        source "$1/core/pipeline/template.sh"
        load_template "$2" >/dev/null 2>&1
        printf "%s" "${_TPL_STAGE_BLOCKING_secret_scan:-}"
    ' _ "$REPO_ROOT" "$TPL_B"
)"
assert_eq "[SPEC-3] cold-start: env _TPL_STAGE_BLOCKING_secret_scan cleared (empty)" "" "$cold_out"

# ── [SPEC-4]: stage blocking in A but ABSENT from next template's flow ─────────
print_test_section "[SPEC-4]: export cleared when blocking stage is absent from next template"

TPL_C="$TEST_TEMP_DIR/tpl-c.yaml"
cat > "$TPL_C" <<'EOF'
flow:
  - build

build:
  roles: [builder]
EOF

load_template "$TPL_A"
got_pre4="${_TPL_STAGE_BLOCKING_secret_scan:-}"
assert_eq "[SPEC-4] precondition: load A sets _TPL_STAGE_BLOCKING_secret_scan=true" "true" "$got_pre4"

load_template "$TPL_C"
got4="${_TPL_STAGE_BLOCKING_secret_scan:-}"
assert_eq "[SPEC-4] load_template C (secret-scan absent from flow): export cleared (empty)" "" "$got4"

cleanup_test_env
print_test_results
