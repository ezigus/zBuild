#!/usr/bin/env bash
# Tests: vision_gate_mode precedence (ADR-049 / #1360) —
#   env ZBUILD_VISION_GATE  >  .zbuild/config.yaml vision.gate  >  default (enforce).
# The config path lets a repo persistently opt out ("just run") without an env var.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh"   # yaml_get
source "$REPO_ROOT/core/config/config.sh"                          # zbuild_config_get
source "$REPO_ROOT/scripts/lib/vision.sh"                          # vision_gate_mode

print_test_header "vision_gate_mode — env > config > default (ADR-049 #1360)"
setup_test_env "vision-gate-config"

cfg="$TEST_TEMP_DIR/config.yaml"
export ZBUILD_CONFIG_FILE="$cfg"

# ── CFG-1: no env, no config vision block → default enforce ──────────────────
: > "$cfg"
unset ZBUILD_VISION_GATE
assert_eq "[CFG-1] default (no env, no config) is enforce" "enforce" "$(vision_gate_mode)"

# ── CFG-2: config vision.gate=off, no env → off ("just run") ─────────────────
printf 'vision:\n  gate: off\n' > "$cfg"
unset ZBUILD_VISION_GATE
assert_eq "[CFG-2] config vision.gate=off resolves off" "off" "$(vision_gate_mode)"

# ── CFG-3: config vision.gate=warn, no env → warn ───────────────────────────
printf 'vision:\n  gate: warn\n' > "$cfg"
unset ZBUILD_VISION_GATE
assert_eq "[CFG-3] config vision.gate=warn resolves warn" "warn" "$(vision_gate_mode)"

# ── CFG-4: env overrides config (env enforce beats config off) ──────────────
printf 'vision:\n  gate: off\n' > "$cfg"
export ZBUILD_VISION_GATE=enforce
assert_eq "[CFG-4] env ZBUILD_VISION_GATE=enforce overrides config off" "enforce" "$(vision_gate_mode)"

# ── CFG-5: unknown config value → enforce (fail-closed on misconfig) ─────────
printf 'vision:\n  gate: banana\n' > "$cfg"
unset ZBUILD_VISION_GATE
assert_eq "[CFG-5] unknown config value fails closed to enforce" "enforce" "$(vision_gate_mode)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
