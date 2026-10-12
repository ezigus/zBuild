#!/usr/bin/env bash
# [#1801/SPEC-4] The template loader rejects a stage_timeout_s value below
# the stage's router.timeout_s, and rejects a non-integer value.
#
# These tests FAIL on pre-change code (where stage_timeout_s is not a
# recognized field and no cross-field validation exists) and PASS after the change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

print_test_header "[#1801/SPEC-4] template loader validates stage_timeout_s"
setup_test_env "stage-timeout-loader-validation"

_MINIMAL_HEAD='id: t
name: T
extends: null
defaults:
  strategy: fanout
'

_write_tpl() {
    printf '%s%s' "$_MINIMAL_HEAD" "$2" > "$1"
}

# ─── Reject: stage_timeout_s < router.timeout_s ───────────────────────────────
print_test_section "[#1801/SPEC-4] stage_timeout_s below router.timeout_s is rejected"

_tpl_low="$TEST_TEMP_DIR/low.yaml"
_write_tpl "$_tpl_low" 'flow:
  - alpha

alpha:
  gate: auto
  roles: [intake]
  stage_timeout_s: 30
  router:
    timeout_s: 600
  io:
    destinations: [file]
'
# stage_timeout_s=30 is below router.timeout_s=600 — the loader must refuse this.
_rc_low=0
load_template "$_tpl_low" >/dev/null 2>&1 || _rc_low=$?
assert_exit_code "[#1801/SPEC-4] stage_timeout_s=30 below router.timeout_s=600 is rejected (rc=1)" \
    "1" "$_rc_low"

# ─── Reject: stage_timeout_s is not an integer ────────────────────────────────
print_test_section "[#1801/SPEC-4] non-integer stage_timeout_s is rejected"

_tpl_bad="$TEST_TEMP_DIR/bad.yaml"
_write_tpl "$_tpl_bad" 'flow:
  - beta

beta:
  gate: auto
  roles: [intake]
  stage_timeout_s: "1h"
  io:
    destinations: [file]
'
_rc_bad=0
load_template "$_tpl_bad" >/dev/null 2>&1 || _rc_bad=$?
assert_exit_code "[#1801/SPEC-4] non-integer stage_timeout_s (\"1h\") is rejected (rc=1)" \
    "1" "$_rc_bad"

# ─── Accept: stage_timeout_s >= router.timeout_s ──────────────────────────────
print_test_section "[#1801/SPEC-4] stage_timeout_s at or above router.timeout_s is accepted"

_tpl_ok="$TEST_TEMP_DIR/ok.yaml"
_write_tpl "$_tpl_ok" 'flow:
  - gamma

gamma:
  gate: auto
  roles: [intake]
  stage_timeout_s: 1200
  router:
    timeout_s: 600
  io:
    destinations: [file]
'
_rc_ok=0
load_template "$_tpl_ok" >/dev/null 2>&1 || _rc_ok=$?
assert_exit_code "[#1801/SPEC-4] stage_timeout_s=1200 >= router.timeout_s=600 is accepted (rc=0)" \
    "0" "$_rc_ok"
assert_eq "[#1801/SPEC-4] accepted template exports _TPL_STAGE_TIMEOUT_S_gamma=1200" \
    "1200" "${_TPL_STAGE_TIMEOUT_S_gamma:-<unset>}"

# ─── Accept: stage_timeout_s with no router.timeout_s ─────────────────────────
print_test_section "[#1801/SPEC-4] stage_timeout_s with no router block is accepted"

_tpl_norouter="$TEST_TEMP_DIR/norouter.yaml"
_write_tpl "$_tpl_norouter" 'flow:
  - delta

delta:
  gate: auto
  roles: [intake]
  stage_timeout_s: 900
  io:
    destinations: [file]
'
_rc_nr=0
load_template "$_tpl_norouter" >/dev/null 2>&1 || _rc_nr=$?
assert_exit_code "[#1801/SPEC-4] stage_timeout_s with no router block is accepted (rc=0)" \
    "0" "$_rc_nr"
assert_eq "[#1801/SPEC-4] exports _TPL_STAGE_TIMEOUT_S_delta=900" \
    "900" "${_TPL_STAGE_TIMEOUT_S_delta:-<unset>}"

# ─── Accept: equal values (stage_timeout_s == router.timeout_s) ───────────────
print_test_section "[#1801/SPEC-4] stage_timeout_s equal to router.timeout_s is accepted"

_tpl_eq="$TEST_TEMP_DIR/eq.yaml"
_write_tpl "$_tpl_eq" 'flow:
  - epsilon

epsilon:
  gate: auto
  roles: [intake]
  stage_timeout_s: 600
  router:
    timeout_s: 600
  io:
    destinations: [file]
'
_rc_eq=0
load_template "$_tpl_eq" >/dev/null 2>&1 || _rc_eq=$?
assert_exit_code "[#1801/SPEC-4] stage_timeout_s=600 equal to router.timeout_s=600 is accepted (rc=0)" \
    "0" "$_rc_eq"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
