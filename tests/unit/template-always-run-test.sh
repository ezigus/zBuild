#!/usr/bin/env bash
# Tests: the `always_run:` template attribute (#1831) — parsing, isolation from
# the flow, and fail-closed validation.
#
# The RUNNER-side half (dispatch on every exit path) is
# tests/integration/always-run-exit-paths-test.sh; this file owns the template
# contract only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

print_test_header "always_run template attribute (#1831)"
setup_test_env "zb-always-run-tpl"

_MINIMAL_HEAD='id: t
name: T
extends: null
defaults:
  strategy: map
'

_write_tpl() {
    # $1 = path, $2 = body appended to the minimal head
    printf '%s%s' "$_MINIMAL_HEAD" "$2" > "$1"
}

# ─── [SPEC-1][change] the shipped template declares it and it parses ─────────
print_test_section "[SPEC-1][change] simple.yaml declares always_run: release"

load_template "$REPO_ROOT/config/templates/simple.yaml" >/dev/null 2>&1
assert_eq "[SPEC-1] _TPL_ALWAYS_RUN is [release persist], in that order" \
    "release persist" "${_TPL_ALWAYS_RUN[*]}"
assert_eq "[SPEC-1] release resolves by role, not by directory" \
    "teardown" "${_TPL_STAGE_ROLES_release:-<unset>}"
assert_eq "[SPEC-1] release carries its own timeout_s" \
    "30" "${_TPL_STAGE_ROUTER_TIMEOUT_release:-<unset>}"

# ─── [SPEC-2][guard] an always-run stage is NOT in the flow ──────────────────
# This is the load-bearing separation. _TPL_STAGES[] drives dispatch units,
# canonical-order validation, the event-sequence goldens, and every test that
# pins a stage count. An always-run stage has no place in the pipeline's data
# dependencies and must never affect convergence or the run's verdict — so if
# it leaks into the flow list, that is a defect, not a detail.
print_test_section "[SPEC-2][guard] always-run stages never enter _TPL_STAGES[]"

_in_flow=0
for _s in "${_TPL_STAGES[@]}"; do
    [[ "$_s" == "release" || "$_s" == "persist" ]] && _in_flow=1
done
assert_eq "[SPEC-2] neither release nor persist is in _TPL_STAGES[]" "0" "$_in_flow"
# The number is 15 because #1074 added `hydrate` as a FLOW stage. The assertion
# is about the always-run stages NOT being in here: release and persist are two
# more entries that would make it 17 if they leaked into the flow.
assert_eq "[SPEC-2] simple.yaml flow count excludes both always-run stages" \
    "18" "${#_TPL_STAGES[@]}"

# ─── [SPEC-3][guard] state does not leak between loads ──────────────────────
# load_template is called repeatedly in one process. A template with no
# always_run must not inherit the previous template's list — that would run a
# stage the operator never declared, on every exit path.
print_test_section "[SPEC-3][guard] a template with no always_run gets an empty list"

_tpl_none="$TEST_TEMP_DIR/none.yaml"
_write_tpl "$_tpl_none" 'flow:
  - alpha

alpha:
  gate: auto
  roles: [intake]
  io:
    destinations: [file]
'
load_template "$_tpl_none" >/dev/null 2>&1
assert_eq "[SPEC-3] _TPL_ALWAYS_RUN is empty after loading a template without it" \
    "0" "${#_TPL_ALWAYS_RUN[@]}"

# ─── [SPEC-4][guard] fail CLOSED on a name with no section ──────────────────
# A typo here must REFUSE the template. An always-run stage that silently does
# not exist is exactly the failure this attribute was built to remove (#1878 —
# "the snapshot was never called"), so degrading to "run nothing" would ship the
# defect under a new name.
print_test_section "[SPEC-4][guard] an undefined always_run member refuses the template"

_tpl_bad="$TEST_TEMP_DIR/bad.yaml"
_write_tpl "$_tpl_bad" 'flow:
  - alpha

always_run:
  - typo_not_a_stage

alpha:
  gate: auto
  roles: [intake]
  io:
    destinations: [file]
'
_rc=0
load_template "$_tpl_bad" >/dev/null 2>&1 || _rc=$?
assert_exit_code "[SPEC-4] undefined always_run member is refused" "1" "$_rc"

# A section with no roles: is equally unusable — the runner resolves by role.
_tpl_noroles="$TEST_TEMP_DIR/noroles.yaml"
_write_tpl "$_tpl_noroles" 'flow:
  - alpha

always_run:
  - bare

alpha:
  gate: auto
  roles: [intake]
  io:
    destinations: [file]

bare:
  gate: auto
  io:
    destinations: [file]
'
_rc=0
load_template "$_tpl_noroles" >/dev/null 2>&1 || _rc=$?
assert_exit_code "[SPEC-4] always_run member with no roles: is refused" "1" "$_rc"

# ─── [SPEC-5][change] order is preserved, and both list forms parse ─────────
# Order matters: ADR-059 §3 puts `persist` after `release` deliberately, so that
# a slow network push can never delay an abort. A list that reorders itself
# would silently invert that.
print_test_section "[SPEC-5][change] the list is ordered, in both YAML forms"

_mk_two() {
    _write_tpl "$1" "flow:
  - alpha

$2

alpha:
  gate: auto
  roles: [intake]
  io:
    destinations: [file]

first:
  gate: auto
  roles: [teardown]
  io:
    destinations: [file]

second:
  gate: auto
  roles: [test]
  io:
    destinations: [file]
"
}

_tpl_block="$TEST_TEMP_DIR/block.yaml"
_mk_two "$_tpl_block" 'always_run:
  - first
  - second'
load_template "$_tpl_block" >/dev/null 2>&1
assert_eq "[SPEC-5] block form preserves declared order" \
    "first second" "${_TPL_ALWAYS_RUN[*]}"

_tpl_inline="$TEST_TEMP_DIR/inline.yaml"
_mk_two "$_tpl_inline" 'always_run: [first, second]'
load_template "$_tpl_inline" >/dev/null 2>&1
assert_eq "[SPEC-5] inline form preserves declared order" \
    "first second" "${_TPL_ALWAYS_RUN[*]}"

# ─── [SPEC-6][guard] the OLD template shape gets always_run too ─────────────
# `always_run:` is a top-level key in both shapes, and its members are top-level
# sections in both. The first cut of this parsed it inside the NEW-shape
# translator only, so every old-shape template silently lost its always-run
# stages — the parity fixture (old shape, `extends: simple`) stopped running
# teardown at all, and only the event-sequence golden noticed.
#
# The old shape is deprecated, not dead. Silently dropping resource cleanup for
# it is worse than refusing to load it.
print_test_section "[SPEC-6][guard] an old-shape template inherits always_run from its base"

# shellcheck source=../../core/pipeline/template-resolver.sh
source "$REPO_ROOT/core/pipeline/template-resolver.sh"

_ovl_repo="$TEST_TEMP_DIR/oldshape-repo"
mkdir -p "$_ovl_repo/.zbuild/templates"
cat > "$_ovl_repo/.zbuild/templates/oldar.yaml" <<'EOF'
id: oldar
name: Old Shape With Inherited always_run
extends: simple
stages:
  - id: intake
    gate: auto
EOF
_ovl_file="$(resolve_template_file oldar "$_ovl_repo")"
load_template "$_ovl_file" >/dev/null 2>&1
assert_eq "[SPEC-6] old-shape overlay still gets always_run from its base" \
    "release persist" "${_TPL_ALWAYS_RUN[*]}"
assert_eq "[SPEC-6] and its own single stage, not the base's flow" \
    "1" "${#_TPL_STAGES[@]}"
assert_eq "[SPEC-6] the release role survives the old-shape path" \
    "teardown" "${_TPL_STAGE_ROLES_release:-<unset>}"

# ─── [SPEC-7][change] both roles: list forms, like every other stage ────────
# `_tpl_parse_stages_v2` accepts inline AND block form, so an always-run section
# modelled on a flow stage — which is what a template author will write — must
# work too. The first cut accepted only the inline form; a block-form section
# then hit the fail-closed "declares no roles:" refusal, which is a confusing
# way to say "unsupported syntax".
print_test_section "[SPEC-7][change] roles: parses in block form as well as inline"

_tpl_block_roles="$TEST_TEMP_DIR/blockroles.yaml"
_write_tpl "$_tpl_block_roles" 'flow:
  - alpha

always_run:
  - blockform
  - inlineform

alpha:
  gate: auto
  roles: [intake]
  io:
    destinations: [file]

blockform:
  gate: auto
  roles:
    - teardown
  router:
    timeout_s: 12
  io:
    destinations: [file]

inlineform:
  gate: auto
  roles: [persist]
  router:
    timeout_s: 13
  io:
    destinations: [file]
'
_rc=0
load_template "$_tpl_block_roles" >/dev/null 2>&1 || _rc=$?
assert_exit_code "[SPEC-7] a block-form roles: section loads" "0" "$_rc"
assert_eq "[SPEC-7] block-form roles: is captured" \
    "teardown" "${_TPL_STAGE_ROLES_blockform:-<unset>}"
assert_eq "[SPEC-7] and timeout_s after it still parses" \
    "12" "${_TPL_STAGE_ROUTER_TIMEOUT_blockform:-<unset>}"
# #2042: the SPEC says BOTH list forms. Asserting only the block form left the
# inline form — for an always-run section, which is the case this SPEC is about
# — unverified, so a regression there would have passed. `alpha` above uses the
# inline form but is a FLOW stage, which is a different parse path.
assert_eq "[SPEC-7] inline-form roles: is captured on an always-run section too" \
    "persist" "${_TPL_STAGE_ROLES_inlineform:-<unset>}"
assert_eq "[SPEC-7] and its timeout_s parses as well" \
    "13" "${_TPL_STAGE_ROUTER_TIMEOUT_inlineform:-<unset>}"

print_test_results
