#!/usr/bin/env bash
# Tests: core/pipeline/template.sh — pr_draft parse, validate, export (issue #1436)
# Mirrors template-merge-policy-test.sh structure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/template — pr_draft parse, validate, export (#1436)"
setup_test_env "template-pr-draft"

_test_cleanup_hook() { cleanup_test_env; }

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/template-resolver.sh
source "$REPO_ROOT/core/pipeline/template-resolver.sh"

# Minimal new-shape template helper: single-stage flow with the given top-level key.
_make_tpl() {
    local file="$1" extra="${2:-}"
    cat > "$file" <<YAML
id: test-pr-draft
name: Test PR Draft
extends: null
${extra}defaults:
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
}

# ─── SPEC-1: pr_draft: true → _TPL_PR_DRAFT=true ────────────────────────────
# CHANGE: pr_draft key not parsed at baseline → _TPL_PR_DRAFT unset/wrong.
# Fails at baseline; passes after template.sh is updated.

_tpl_true="$TEST_TEMP_DIR/pr-draft-true.yaml"
_make_tpl "$_tpl_true" "pr_draft: true
"

set +e
load_template "$_tpl_true"
_rc1=$?
set -e

assert_eq "[SPEC-1] load_template (pr_draft: true) exit 0" "0" "$_rc1"
assert_eq "[SPEC-1] _TPL_PR_DRAFT == true when pr_draft: true" "true" "$_TPL_PR_DRAFT"

# ─── SPEC-2: pr_draft: false → _TPL_PR_DRAFT=false ──────────────────────────
# CHANGE: pr_draft key not parsed at baseline.

_tpl_false="$TEST_TEMP_DIR/pr-draft-false.yaml"
_make_tpl "$_tpl_false" "pr_draft: false
"

set +e
load_template "$_tpl_false"
_rc2=$?
set -e

assert_eq "[SPEC-2] load_template (pr_draft: false) exit 0" "0" "$_rc2"
assert_eq "[SPEC-2] _TPL_PR_DRAFT == false when pr_draft: false" "false" "$_TPL_PR_DRAFT"

# ─── SPEC-3: pr_draft absent → _TPL_PR_DRAFT=false (default) ────────────────
# CHANGE: at baseline _TPL_PR_DRAFT is unset; after change it defaults to false.

_tpl_absent="$TEST_TEMP_DIR/pr-draft-absent.yaml"
_make_tpl "$_tpl_absent" ""

set +e
load_template "$_tpl_absent"
_rc3=$?
set -e

assert_eq "[SPEC-3] load_template (pr_draft absent) exit 0" "0" "$_rc3"
assert_eq "[SPEC-3] _TPL_PR_DRAFT defaults to false when pr_draft absent" \
    "false" "${_TPL_PR_DRAFT:-UNSET}"

# ─── SPEC-4: pr_draft: invalid → load_template returns non-zero ──────────────
# CHANGE: invalid value was silently ignored at baseline; now validated and fails.

_tpl_bad="$TEST_TEMP_DIR/pr-draft-bad.yaml"
_make_tpl "$_tpl_bad" "pr_draft: maybe
"

set +e
_err4="$(load_template "$_tpl_bad" 2>&1)"
_rc4=$?
set -e

if [[ "$_rc4" -ne 0 ]]; then
    assert_pass "[SPEC-4] load_template (pr_draft: maybe) returns non-zero"
else
    assert_fail "[SPEC-4] load_template (pr_draft: maybe) returns non-zero" "got rc=0"
fi
_err4_match=0
[[ "$_err4" == *"maybe"* ]] && _err4_match=1
assert_eq "[SPEC-4] error message references invalid pr_draft value" "1" "$_err4_match"

# ─── Results ─────────────────────────────────────────────────────────────────

print_test_results
exit $((FAIL > 0))
