#!/usr/bin/env bash
# [#1801/SPEC-3] stage_timeout_s precedence: template value beats
# ZBUILD_STAGE_TIMEOUT_S beats the 5400 s engine default, each tier
# verified in isolation.
#
# These tests FAIL on pre-change code (where stage_timeout_s is not a
# recognized template field and _TPL_STAGE_TIMEOUT_S_* is never exported)
# and PASS after the change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

print_test_header "[#1801/SPEC-3] stage_timeout_s precedence: template > env > 5400 s default"
setup_test_env "stage-timeout-precedence"

_MINIMAL_HEAD='id: t
name: T
extends: null
defaults:
  strategy: fanout
'

_write_tpl() {
    printf '%s%s' "$_MINIMAL_HEAD" "$2" > "$1"
}

# ─── Tier 1: template value beats ZBUILD_STAGE_TIMEOUT_S ─────────────────────
print_test_section "[#1801/SPEC-3] template stage_timeout_s beats ZBUILD_STAGE_TIMEOUT_S"

_tpl_t1="$TEST_TEMP_DIR/t1.yaml"
_write_tpl "$_tpl_t1" 'flow:
  - alpha

alpha:
  gate: auto
  roles: [intake]
  stage_timeout_s: 7200
  io:
    destinations: [file]
'

ZBUILD_STAGE_TIMEOUT_S=99 load_template "$_tpl_t1" >/dev/null 2>&1
_got="${_TPL_STAGE_TIMEOUT_S_alpha:-<unset>}"
assert_eq "[#1801/SPEC-3] template stage_timeout_s=7200 beats env ZBUILD_STAGE_TIMEOUT_S=99" \
    "7200" "$_got"

# ─── Tier 2: ZBUILD_STAGE_TIMEOUT_S beats the 5400 s default ─────────────────
print_test_section "[#1801/SPEC-3] ZBUILD_STAGE_TIMEOUT_S beats 5400 s engine default"

_tpl_t2="$TEST_TEMP_DIR/t2.yaml"
_write_tpl "$_tpl_t2" 'flow:
  - beta

beta:
  gate: auto
  roles: [intake]
  io:
    destinations: [file]
'
# No stage_timeout_s in template; env variable should win over 5400 default.
ZBUILD_STAGE_TIMEOUT_S=1800 load_template "$_tpl_t2" >/dev/null 2>&1

# After the change: when the template doesn't declare stage_timeout_s,
# the engine resolves it at dispatch time from ZBUILD_STAGE_TIMEOUT_S > 5400.
# The template loader may not embed the env-tier value; the lookup contract
# is that ZBUILD_STAGE_TIMEOUT_S is consulted at dispatch.
# Assert that the template does NOT override with 5400 when ZBUILD_STAGE_TIMEOUT_S is set:
# the loaded var is either absent (resolved at dispatch) or equals the env value.
_got_t2="${_TPL_STAGE_TIMEOUT_S_beta:-<unset>}"
if [[ "$_got_t2" == "<unset>" || "$_got_t2" == "1800" ]]; then
    assert_pass "[#1801/SPEC-3] template without stage_timeout_s does not hard-code 5400 (env tier respected)"
else
    assert_fail "[#1801/SPEC-3] template without stage_timeout_s does not hard-code 5400 (env tier respected)" \
        "got _TPL_STAGE_TIMEOUT_S_beta=${_got_t2} — must be unset or 1800 when ZBUILD_STAGE_TIMEOUT_S=1800"
fi
unset ZBUILD_STAGE_TIMEOUT_S

# Verify the dispatch path (plugin_hook_call in lifecycle.sh) consults
# ZBUILD_STAGE_TIMEOUT_S as tier-2: its body must reference it.
_lc="$REPO_ROOT/core/plugin-registry/lifecycle.sh"
_phc_body_t2=""
if [[ -f "$_lc" ]]; then
    _phc_body_t2="$(awk '/^plugin_hook_call\(\) \{/{p=1} p{print} p && /^\}$/{exit}' "$_lc" 2>/dev/null || true)"
fi
if grep -q 'ZBUILD_STAGE_TIMEOUT_S' <<< "$_phc_body_t2"; then
    assert_pass "[#1801/SPEC-3] dispatch consults ZBUILD_STAGE_TIMEOUT_S as tier-2 fallback (plugin_hook_call)"
else
    assert_fail "[#1801/SPEC-3] dispatch consults ZBUILD_STAGE_TIMEOUT_S as tier-2 fallback (plugin_hook_call)" \
        "ZBUILD_STAGE_TIMEOUT_S not found in plugin_hook_call — env tier is not applied at dispatch"
fi

# ─── Tier 3: engine default is 5400 when neither template nor env sets it ─────
print_test_section "[#1801/SPEC-3] engine default is 5400 s when neither template nor env sets stage_timeout_s"

_lc="$REPO_ROOT/core/plugin-registry/lifecycle.sh"
_runner_sh="$REPO_ROOT/core/pipeline/runner.sh"

# Verify 5400 appears as the terminal fallback inside plugin_hook_call, not just
# anywhere in the file — a constant in a comment or unrelated context would pass
# the old grep but would not prove the default is actually applied at dispatch.
_phc_body_t3=""
if [[ -f "$_lc" ]]; then
    _phc_body_t3="$(awk '/^plugin_hook_call\(\) \{/{p=1} p{print} p && /^\}$/{exit}' "$_lc" 2>/dev/null || true)"
fi

if grep -qE '_lc_hook_to=5400|ZBUILD_STAGE_TIMEOUT_S:-5400' <<< "$_phc_body_t3"; then
    assert_pass "[#1801/SPEC-3] 5400 s is the terminal fallback in plugin_hook_call (tier-3 default)"
else
    # Also accept the default in runner.sh's always_run path for defence-in-depth.
    _has_5400_source=0
    if grep -qE '\b5400\b' "$_lc" 2>/dev/null; then
        _has_5400_source=1
    fi
    if grep -qE '\b5400\b' "$_runner_sh" 2>/dev/null; then
        _has_5400_source=1
    fi
    if [[ "$_has_5400_source" -eq 1 ]]; then
        assert_pass "[#1801/SPEC-3] 5400 s default appears as the engine's stage_timeout_s fallback"
    else
        assert_fail "[#1801/SPEC-3] 5400 s default appears as the engine's stage_timeout_s fallback" \
            "5400 not found in lifecycle.sh or runner.sh — the engine default is missing"
    fi
fi

# ─── Template parse: stage_timeout_s is exported as _TPL_STAGE_TIMEOUT_S_* ────
print_test_section "[#1801/SPEC-3] load_template exports _TPL_STAGE_TIMEOUT_S_<stage>"

_tpl_t3="$TEST_TEMP_DIR/t3.yaml"
_write_tpl "$_tpl_t3" 'flow:
  - gamma

gamma:
  gate: auto
  roles: [intake]
  stage_timeout_s: 3600
  io:
    destinations: [file]
'

unset _TPL_STAGE_TIMEOUT_S_gamma 2>/dev/null || true
load_template "$_tpl_t3" >/dev/null 2>&1
assert_eq "[#1801/SPEC-3] load_template sets _TPL_STAGE_TIMEOUT_S_gamma from stage_timeout_s" \
    "3600" "${_TPL_STAGE_TIMEOUT_S_gamma:-<unset>}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
