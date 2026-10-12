#!/usr/bin/env bash
# tests/unit/map-element-persona-test.sh — a map element runs as the persona the
# template names for it, never as one guessed from its name (ADR-051 §2, §3,
# amended 2026-10-12).
#
# An element carries its own settings the way a stage does:
#     elements:
#       - id: security
#         persona: security
#
#   ME1 [change]: the parser reads `- id:` elements (and their keys) as the
#                 element list; plain `- name` elements still parse
#   ME2 [change]: template_map_element_persona gives the persona the template
#                 names for one element, empty for one that names none
#   ME3 [change]: a map group's own persona pin is not taken from an element's
#   ME4 [change]: resolve_persona for a map element: its declared persona; an
#                 element that declares none runs as the stage's pin or generic —
#                 even when a persona of the element's name exists
#   ME5 [change]: the startup preflight refuses a persona the template names
#                 that exists nowhere (stage pin or element), in its default mode
#   ME6 [change]: the shipped templates name a persona for every review lens,
#                 and every persona they name exists
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "map elements run as the persona the template names (ADR-051)"
setup_test_env "map-element-persona"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

# shellcheck source=../../core/pipeline/runner.sh
source "$REPO_ROOT/core/pipeline/runner.sh"
# shellcheck source=../../scripts/lib/persona-resolve.sh
source "$REPO_ROOT/scripts/lib/persona-resolve.sh"

TGT="$TEST_TEMP_DIR/target"; mkdir -p "$TGT"
export ZBUILD_REPO_ROOT="$TGT"

_tpl() {
    cat > "$TEST_TEMP_DIR/tpl.yaml"
    load_template "$TEST_TEMP_DIR/tpl.yaml" >/dev/null 2>&1
}

_tpl <<'EOF'
id: me
name: map element personas
flow:
  - lenses_group
lenses_group:
  type: map
  over: lenses
  elements:
    - id: sec
      persona: security
    - id: correctness
    - perf
  roles: [review_lens]
EOF

# ─── ME1 ─────────────────────────────────────────────────────────────────────
print_test_section "ME1: the element list"
assert_eq "[ME1] ids from '- id:' items, plain names kept" "sec,correctness,perf" \
    "${_TPL_MAP_ELEMENTS_lenses_group:-}"

# ─── ME2 ─────────────────────────────────────────────────────────────────────
print_test_section "ME2: an element's persona"
assert_eq "[ME2] the named persona" "security" "$(template_map_element_persona lenses_group sec)"
assert_eq "[ME2] none named → empty" "" "$(template_map_element_persona lenses_group correctness)"
assert_eq "[ME2] a plain element → empty" "" "$(template_map_element_persona lenses_group perf)"

# ─── ME3 ─────────────────────────────────────────────────────────────────────
print_test_section "ME3: the group's own pin"
assert_eq "[ME3] an element's persona is not the group's pin" "" \
    "$(template_stage_router_persona lenses_group)"

# ─── ME4 ─────────────────────────────────────────────────────────────────────
print_test_section "ME4: resolve_persona for a map element"
_rp() { ( export ZBUILD_CURRENT_STAGE=lenses_group ZBUILD_MAP_ELEMENT="$1"
          d="$(resolve_persona lenses_group 2>/dev/null)"; printf '%s' "${d##*/}" ); }
assert_eq "[ME4] a declared persona, whatever the element is called" "security" "$(_rp sec)"
assert_eq "[ME4] same name as a persona but none declared → generic" "generic" "$(_rp correctness)"
_tpl <<'EOF'
id: me2
flow:
  - lenses_group
lenses_group:
  type: map
  over: lenses
  persona: architect
  elements:
    - id: sec
      persona: security
    - id: correctness
  roles: [review_lens]
EOF
assert_eq "[ME4] none declared → the stage's pin" "architect" "$(_rp correctness)"
assert_eq "[ME4] the element's own beats the stage's pin" "security" "$(_rp sec)"

# ─── ME5 ─────────────────────────────────────────────────────────────────────
print_test_section "ME5: a persona that exists nowhere refuses at startup"
_pf() { ( unset ZBUILD_CONTRACT_VALIDATOR; _runner_validate_startup_preflight 2>&1; printf 'rc=%s' "$?" ); }
_out="$(_pf)"
assert_contains "[ME5] every named persona exists → clean" "$_out" "rc=0"
_tpl <<'EOF'
id: me3
flow:
  - plan
  - lenses_group
plan:
  roles: [planner]
  persona: no-such-planner
lenses_group:
  type: map
  over: lenses
  elements:
    - id: sec
      persona: secuirty
  roles: [review_lens]
EOF
_out="$(_pf)"
assert_contains "[ME5] refused in the default mode" "$_out" "rc=1"
assert_contains "[ME5] names the stage's missing persona" "$_out" "no-such-planner"
assert_contains "[ME5] names the element's missing persona" "$_out" "secuirty"
mkdir -p "$TGT/.zbuild/plugins/persona/no-such-planner"
cat > "$TGT/.zbuild/plugins/persona/no-such-planner/manifest.yaml" <<'EOF'
id: no-such-planner
name: Planner (this repository)
kind: persona
version: 0.1.0
persona:
  role: a planner
  perspective: "Plan it."
EOF
assert_not_contains_out() { if grep -qF -- "$3" <<< "$2"; then assert_fail "$1" "found: $3"; else assert_pass "$1"; fi; }
assert_not_contains_out "[ME5] the repository's own persona counts as existing" "$(_pf)" "no-such-planner"

# ─── ME6 ─────────────────────────────────────────────────────────────────────
print_test_section "ME6: the shipped templates"
for _t in simple deployed; do
    load_template "$REPO_ROOT/config/templates/$_t.yaml" >/dev/null 2>&1
    _missing=""
    IFS=',' read -ra _els <<< "${_TPL_MAP_ELEMENTS_review_lenses:-}"
    for _e in "${_els[@]}"; do
        [[ -n "$(template_map_element_persona review_lenses "$_e")" ]] || _missing+="$_e "
    done
    assert_eq "[ME6] $_t.yaml: lenses listed" "1" "$([[ ${#_els[@]} -ge 1 ]] && echo 1 || echo 0)"
    assert_eq "[ME6] $_t.yaml: every lens names its persona" "" "$_missing"
    assert_contains "[ME6] $_t.yaml: every persona it names exists" "$(_pf)" "rc=0"
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
