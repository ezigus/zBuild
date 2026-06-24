#!/usr/bin/env bash
# Tests: core/pipeline/template.sh — merge_policy parse, validate, export (issue #1049)
# ADR-037 §4: per-template merge_policy knob (auto_unless_flagged | auto | manual)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/template — merge_policy parse, validate, export (#1049)"
setup_test_env "template-merge-policy"

_test_cleanup_hook() { cleanup_test_env; }

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/template-resolver.sh
source "$REPO_ROOT/core/pipeline/template-resolver.sh"

SIMPLE_TPL="$REPO_ROOT/config/templates/simple.yaml"

# ─── SPEC-1: simple.yaml loads and _TPL_MERGE_POLICY == manual ───────────────
# CHANGE: load_template previously discarded merge_policy → _TPL_MERGE_POLICY
# was unset/empty. Now it must be parsed and exported as "manual".

set +e
load_template "$SIMPLE_TPL"
_load_rc=$?
set -e

assert_eq "[SPEC-1] load_template simple.yaml exit 0" "0" "$_load_rc"
assert_eq "[SPEC-1] _TPL_MERGE_POLICY == manual after loading simple.yaml" \
    "manual" "$_TPL_MERGE_POLICY"

# ─── SPEC-2: merge_policy: auto ──────────────────────────────────────────────
# CHANGE: previously discarded; now parsed. Fails at baseline.

_tpl_auto="$TEST_TEMP_DIR/auto.yaml"
cat > "$_tpl_auto" <<'YAML'
id: test-auto
name: Test Auto
extends: null
merge_policy: auto
defaults:
  strategy: fanout
flow:
  - intake
intake:
  gate: auto
  roles: [intake]
  io:
    destinations: [file]
    tail_lines: 50
YAML

set +e
load_template "$_tpl_auto"
_rc2=$?
set -e

assert_eq "[SPEC-2] load_template (merge_policy: auto) exit 0" "0" "$_rc2"
assert_eq "[SPEC-2] _TPL_MERGE_POLICY == auto" "auto" "$_TPL_MERGE_POLICY"

# ─── SPEC-3: merge_policy: auto_unless_flagged ───────────────────────────────
# CHANGE: previously discarded; now parsed. Fails at baseline.

_tpl_auf="$TEST_TEMP_DIR/auf.yaml"
cat > "$_tpl_auf" <<'YAML'
id: test-auf
name: Test AUF
extends: null
merge_policy: auto_unless_flagged
defaults:
  strategy: fanout
flow:
  - intake
intake:
  gate: auto
  roles: [intake]
  io:
    destinations: [file]
    tail_lines: 50
YAML

set +e
load_template "$_tpl_auf"
_rc3=$?
set -e

assert_eq "[SPEC-3] load_template (merge_policy: auto_unless_flagged) exit 0" "0" "$_rc3"
assert_eq "[SPEC-3] _TPL_MERGE_POLICY == auto_unless_flagged" \
    "auto_unless_flagged" "$_TPL_MERGE_POLICY"

# ─── SPEC-4: merge_policy absent → default auto_unless_flagged ───────────────
# CHANGE: previously nothing was set; now defaults to auto_unless_flagged.

_tpl_absent="$TEST_TEMP_DIR/absent.yaml"
cat > "$_tpl_absent" <<'YAML'
id: test-absent
name: Test Absent
extends: null
defaults:
  strategy: fanout
flow:
  - intake
intake:
  gate: auto
  roles: [intake]
  io:
    destinations: [file]
    tail_lines: 50
YAML

set +e
load_template "$_tpl_absent"
_rc4=$?
set -e

assert_eq "[SPEC-4] load_template (merge_policy absent) exit 0" "0" "$_rc4"
assert_eq "[SPEC-4] _TPL_MERGE_POLICY defaults to auto_unless_flagged" \
    "auto_unless_flagged" "$_TPL_MERGE_POLICY"

# ─── SPEC-5: merge_policy: bogus_value → load_template returns non-zero ──────
# CHANGE: previously silently discarded; now validated and fails. Fails at baseline.

_tpl_bogus="$TEST_TEMP_DIR/bogus.yaml"
cat > "$_tpl_bogus" <<'YAML'
id: test-bogus
name: Test Bogus
extends: null
merge_policy: bogus_value
defaults:
  strategy: fanout
flow:
  - intake
intake:
  gate: auto
  roles: [intake]
  io:
    destinations: [file]
    tail_lines: 50
YAML

set +e
_err_output="$(load_template "$_tpl_bogus" 2>&1)"
_rc5=$?
set -e

assert_gt "[SPEC-5] load_template (merge_policy: bogus_value) returns non-zero" \
    "$_rc5" "0"
# Verify error message mentions the invalid value
_err_match=0
[[ "$_err_output" == *"bogus_value"* ]] && _err_match=1
assert_eq "[SPEC-5] error message references invalid merge_policy value" \
    "1" "$_err_match"

# ─── Results ─────────────────────────────────────────────────────────────────

print_test_results
