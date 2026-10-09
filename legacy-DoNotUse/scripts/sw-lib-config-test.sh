#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/config test — Unit tests for centralized config reader   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: config Tests"

setup_test_env "sw-lib-config-test"
_test_cleanup_hook() { cleanup_test_env; }

# Source the lib (clear guard to re-source)
_SW_CONFIG_LOADED=""
source "$SCRIPT_DIR/lib/config.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# _config_get
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_config_get"

# Reads from defaults.json
val=$(_config_get "daemon.poll_interval" "0")
assert_gt "_config_get reads daemon.poll_interval from defaults" "$val" "0"

# Falls back when key absent everywhere
val=$(_config_get "nonexistent.key.path" "fallback-value")
assert_eq "_config_get returns fallback for missing key" "fallback-value" "$val"

# Env var wins
SHIPWRIGHT_DAEMON_POLL_INTERVAL=999
val=$(_config_get "daemon.poll_interval" "0")
assert_eq "_config_get prefers env var over defaults" "999" "$val"
unset SHIPWRIGHT_DAEMON_POLL_INTERVAL

# ═══════════════════════════════════════════════════════════════════════════════
# _config_get_int
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_config_get_int"

val=$(_config_get_int "daemon.poll_interval" "0")
# Should be a pure integer
if [[ "$val" =~ ^-?[0-9]+$ ]]; then
    assert_pass "_config_get_int returns pure integer ($val)"
else
    assert_fail "_config_get_int returns pure integer" "got: $val"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# _config_get_bool
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_config_get_bool"

if _config_get_bool "nonexistent.flag" "true"; then
    assert_pass "_config_get_bool true-fallback returns 0"
else
    assert_fail "_config_get_bool true-fallback returns 0"
fi

if _config_get_bool "nonexistent.flag" "false"; then
    assert_fail "_config_get_bool false-fallback returns 1"
else
    assert_pass "_config_get_bool false-fallback returns 1"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# _config_get_list — bash 3.2 safe JSON-array → CSV reader
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_config_get_list"

# Reads array from defaults.json
val=$(_config_get_list "pipeline.dod.test_dir_names" "x,y")
assert_contains "_config_get_list reads test_dir_names" "$val" "tests"

# Returns CSV format that splits cleanly with IFS=,
IFS=, read -r -a parts <<< "$val"
assert_gt "_config_get_list CSV splits into multiple parts" "${#parts[@]}" "1"

# Fallback used when key absent
val=$(_config_get_list "totally.missing.list" "alpha,beta,gamma")
assert_eq "_config_get_list uses fallback CSV" "alpha,beta,gamma" "$val"

# Env override (CSV string)
SHIPWRIGHT_PIPELINE_DOD_TEST_DIR_NAMES="env1,env2"
val=$(_config_get_list "pipeline.dod.test_dir_names" "x")
assert_eq "_config_get_list honors env override" "env1,env2" "$val"
unset SHIPWRIGHT_PIPELINE_DOD_TEST_DIR_NAMES

# daemon-config.json override takes precedence over defaults.json
_test_daemon_cfg="$TEST_TEMP_DIR/dc.json"
cat > "$_test_daemon_cfg" <<'EOF'
{"pipeline":{"dod":{"test_dir_names":["foo","bar"]}}}
EOF
_orig_dc="$_DAEMON_CONFIG_FILE"
_DAEMON_CONFIG_FILE="$_test_daemon_cfg"
val=$(_config_get_list "pipeline.dod.test_dir_names" "x")
assert_eq "_config_get_list prefers daemon-config.json over defaults" "foo,bar" "$val"
_DAEMON_CONFIG_FILE="$_orig_dc"
rm -f "$_test_daemon_cfg"

# Malformed JSON falls back gracefully
_test_bad_cfg="$TEST_TEMP_DIR/bad.json"
echo "not valid json {{{" > "$_test_bad_cfg"
_DAEMON_CONFIG_FILE="$_test_bad_cfg"
val=$(_config_get_list "totally.missing.list" "alpha,beta")
assert_eq "_config_get_list survives malformed daemon-config.json" "alpha,beta" "$val"
_DAEMON_CONFIG_FILE="$_orig_dc"
rm -f "$_test_bad_cfg"

print_test_results
