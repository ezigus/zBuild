#!/usr/bin/env bash
# Tests: core/config/config.sh — backend selection via .zbuild/config.yaml (ADR-011)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/config — backend selection via .zbuild/config.yaml"

setup_test_env "core-config-load"

# Ensure isolation: point ZBUILD_CONFIG_FILE at nothing so the project's real
# .zbuild/config.yaml is never consulted during unit tests.
export ZBUILD_CONFIG_FILE="/dev/null"

# Prevent zbuild_project_root from picking up project config
export ZBUILD_PROJECT_ROOT="$TEST_TEMP_DIR/project"

# Source the registry first (yaml_get dependency), then the config module
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/config/config.sh
source "$REPO_ROOT/core/config/config.sh"

# ─── Helper: write a minimal config.yaml in temp dir ────────────────────────
write_config() {
    local content="$1"
    local cfg="$TEST_TEMP_DIR/config.yaml"
    printf '%s\n' "$content" > "$cfg"
    echo "$cfg"
}

# ─── Test 1: No config file → all defaults ──────────────────────────────────
print_test_section "1. No config file → compiled-in defaults"
export ZBUILD_CONFIG_FILE="/dev/null"
unset ZBUILD_MEMORY_BACKEND ZBUILD_ORCHESTRATOR_BACKEND ZBUILD_CACHE_BACKEND 2>/dev/null || true

mem="$(zbuild_config_get_backend "memory")"
orch="$(zbuild_config_get_backend "orchestrator")"
cache="$(zbuild_config_get_backend "cache")"

assert_eq "memory default is sqlite"         "sqlite"        "$mem"
assert_eq "orchestrator default is bash-parallel" "bash-parallel" "$orch"
assert_eq "cache default is local"           "local"         "$cache"

# ─── Test 2: Config file sets backends.memory = ruflo ───────────────────────
print_test_section "2. Config file with backends.memory: ruflo"
cfg="$(write_config "backends:
  memory: ruflo
")"
export ZBUILD_CONFIG_FILE="$cfg"
unset ZBUILD_MEMORY_BACKEND ZBUILD_ORCHESTRATOR_BACKEND ZBUILD_CACHE_BACKEND 2>/dev/null || true

mem="$(zbuild_config_get_backend "memory")"
orch="$(zbuild_config_get_backend "orchestrator")"

assert_eq "memory reads ruflo from config"       "ruflo"         "$mem"
assert_eq "orchestrator falls back to default"   "bash-parallel" "$orch"

# ─── Test 3: Config file sets all three backends ─────────────────────────────
print_test_section "3. Config file with all three backends"
cfg="$(write_config "backends:
  memory: ruflo
  orchestrator: ruflo-hive
  cache: s3
")"
export ZBUILD_CONFIG_FILE="$cfg"
unset ZBUILD_MEMORY_BACKEND ZBUILD_ORCHESTRATOR_BACKEND ZBUILD_CACHE_BACKEND 2>/dev/null || true

mem="$(zbuild_config_get_backend "memory")"
orch="$(zbuild_config_get_backend "orchestrator")"
cache="$(zbuild_config_get_backend "cache")"

assert_eq "memory=ruflo from config"      "ruflo"      "$mem"
assert_eq "orchestrator=ruflo-hive"       "ruflo-hive" "$orch"
assert_eq "cache=s3"                      "s3"         "$cache"

# ─── Test 4: ZBUILD_CONFIG_FILE env var overrides file discovery ─────────────
print_test_section "4. ZBUILD_CONFIG_FILE env var controls which file is used"
cfg="$(write_config "backends:
  memory: ruflo
")"
export ZBUILD_CONFIG_FILE="$cfg"
unset ZBUILD_MEMORY_BACKEND 2>/dev/null || true

mem="$(zbuild_config_get_backend "memory")"
assert_eq "ZBUILD_CONFIG_FILE points to ruflo config" "ruflo" "$mem"

# Switch to different file
cfg2="$TEST_TEMP_DIR/config2.yaml"
printf 'backends:\n  memory: sqlite\n' > "$cfg2"
export ZBUILD_CONFIG_FILE="$cfg2"

mem2="$(zbuild_config_get_backend "memory")"
assert_eq "ZBUILD_CONFIG_FILE switch picks up new file" "sqlite" "$mem2"

# ─── Test 5: ZBUILD_MEMORY_BACKEND env var overrides everything ──────────────
print_test_section "5. ZBUILD_MEMORY_BACKEND env var overrides config file"
cfg="$(write_config "backends:
  memory: ruflo
")"
export ZBUILD_CONFIG_FILE="$cfg"
export ZBUILD_MEMORY_BACKEND="sqlite"

mem="$(zbuild_config_get_backend "memory")"
assert_eq "env var ZBUILD_MEMORY_BACKEND wins over config file" "sqlite" "$mem"

unset ZBUILD_MEMORY_BACKEND

# ─── Test 6: Empty config file → all defaults ────────────────────────────────
print_test_section "6. Empty config file → all defaults"
empty_cfg="$TEST_TEMP_DIR/empty.yaml"
: > "$empty_cfg"
export ZBUILD_CONFIG_FILE="$empty_cfg"
unset ZBUILD_MEMORY_BACKEND ZBUILD_ORCHESTRATOR_BACKEND ZBUILD_CACHE_BACKEND 2>/dev/null || true

mem="$(zbuild_config_get_backend "memory")"
orch="$(zbuild_config_get_backend "orchestrator")"
cache="$(zbuild_config_get_backend "cache")"

assert_eq "empty config: memory defaults to sqlite"         "sqlite"        "$mem"
assert_eq "empty config: orchestrator defaults to bash-parallel" "bash-parallel" "$orch"
assert_eq "empty config: cache defaults to local"           "local"         "$cache"

# ─── Test 7: Unknown backend value is returned as-is ─────────────────────────
print_test_section "7. Unknown backend value is passed through (no hard-fail)"
cfg="$(write_config "backends:
  memory: my-custom-backend
")"
export ZBUILD_CONFIG_FILE="$cfg"
unset ZBUILD_MEMORY_BACKEND 2>/dev/null || true

mem="$(zbuild_config_get_backend "memory")"
assert_eq "unknown backend value returned unchanged" "my-custom-backend" "$mem"

# ─── Test 8: ZBUILD_CONFIG_FILE=/dev/null → treats as no config (all defaults) ──
print_test_section "8. ZBUILD_CONFIG_FILE=/dev/null → all defaults"
export ZBUILD_CONFIG_FILE="/dev/null"
unset ZBUILD_MEMORY_BACKEND ZBUILD_ORCHESTRATOR_BACKEND ZBUILD_CACHE_BACKEND 2>/dev/null || true

mem="$(zbuild_config_get_backend "memory")"
orch="$(zbuild_config_get_backend "orchestrator")"
cache="$(zbuild_config_get_backend "cache")"

assert_eq "/dev/null config: memory defaults"         "sqlite"        "$mem"
assert_eq "/dev/null config: orchestrator defaults"   "bash-parallel" "$orch"
assert_eq "/dev/null config: cache defaults"          "local"         "$cache"

# ─── Cleanup ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
