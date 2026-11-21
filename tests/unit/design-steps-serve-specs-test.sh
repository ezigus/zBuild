#!/usr/bin/env bash
# tests/unit/design-steps-serve-specs-test.sh — each design step names the
# SPECs it serves (#2579 R1; ADR-068, amended 2026-11-21).
#
# Why: on #1764 run 44863026881 design's step 1 said "filter by the
# authenticated actor before scanning"; the "only" was in DSCLA-23, which the
# step's check was never shown. Build added a fallback that read any
# commenter, and the check passed it. A step is a summary of part of the
# SPECs; naming which ones lets every check of the step be shown them.
#
# SV1 [change] design's check refuses a step that names no SPEC, saying to
#              name the SPECs it serves after " | serves:"
# SV2 [change] design's check refuses a step that names an id the acceptance
#              block has no SPEC for
# SV3 [change] a step that names the SPECs it serves passes those checks, and
#              its areas stop where " | serves:" starts
# SV4 [change] design-steps.json holds each step's served SPECs, and the text
#              of each SPEC a step serves, with its parts
# SV5 [change] design's prompt asks for each step's SPECs after " | serves:"
# SV6 [change] (review) a served id keeps its id alone: a trailing [tag] is
#              taken off, words that are no id are set aside, an id named twice
#              counts once — under the caller's IFS too
# SV7 [change] (review) a step's words holding a record separator are written
#              to design-steps.json as one step
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "each design step names the SPECs it serves (#2579 R1)"
setup_test_env "design-steps-serve-specs"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

CR="$TEST_TEMP_DIR/check-repo"; mkdir -p "$CR/core"
( cd "$CR" && git init -q && git config user.email t@t && git config user.name t \
    && echo 'a() { :; }' > core/a.sh && git add -A && git commit -q -m seed ) >/dev/null 2>&1
_draft() {   # <file> <steps lines…>
    local f="$1"; shift
    { printf '# Design\n\n## Decision\nMinimal.\n\n```steps\n'
      printf '%s\n' "$@"
      printf '```\n\n```acceptance\nDSCLA-1[code]: only the actor'"'"'s comments are read\n  When: a holder comment by another user is listed\n  Then: it is not read\nDSCLA-2[no-code]: the helper is shared\nWIRING: none\n```\n'; } > "$f"
}
_viol() {   # <prefix> — the first violation starting with it
    local v
    for v in ${_DESIGN_VIOLATIONS[@]+"${_DESIGN_VIOLATIONS[@]}"}; do [[ "$v" == "$1"* ]] && { printf '%s' "$v"; return 0; }; done
    return 0
}

# ── SV1 ──────────────────────────────────────────────────────────────────────
_draft "$TEST_TEMP_DIR/none.md" "- filter by the actor before scanning | areas: core/a.sh"
_design_checks "$TEST_TEMP_DIR/none.md" "$CR" ""
_v="$(_viol STEP_NO_SPEC)"
assert_contains "[SV1] a step naming no SPEC fails design's check, naming the step" "$_v" "STEP_NO_SPEC 1"
_p=""; [[ -n "$_v" ]] && _p="$(_dck_plain "$_v")"
assert_contains "[SV1] ...and design is told to name the SPECs it serves" "$_p" "| serves:"

# ── SV2 ──────────────────────────────────────────────────────────────────────
_draft "$TEST_TEMP_DIR/unknown.md" "- filter by the actor | areas: core/a.sh | serves: DSCLA-1, DSNOPE-4"
_design_checks "$TEST_TEMP_DIR/unknown.md" "$CR" ""
assert_contains "[SV2] a step naming an id with no SPEC fails design's check, naming it" "$(_viol STEP_UNKNOWN_SPEC)" "STEP_UNKNOWN_SPEC DSNOPE-4"
assert_eq "[SV2] ...and not the id that is a SPEC" "" "$(_viol 'STEP_UNKNOWN_SPEC DSCLA-1')"

# ── SV3 ──────────────────────────────────────────────────────────────────────
_draft "$TEST_TEMP_DIR/ok.md" "- filter by the actor | areas: core/a.sh | serves: DSCLA-1" \
    "- share the helper | serves: [DSCLA-2] | areas: core/a.sh"
_design_checks "$TEST_TEMP_DIR/ok.md" "$CR" ""
assert_eq "[SV3] steps naming their SPECs pass the step checks" "" "$(_viol STEP_)"
_areas=(); zb_design_step_areas_v _areas "$TEST_TEMP_DIR/ok.md"
assert_eq "[SV3] ...and their areas hold no SPEC" "core/a.sh|core/a.sh" "$(IFS='|'; printf '%s' "${_areas[*]}")"

# ── SV4 ──────────────────────────────────────────────────────────────────────
_design_write_steps "$TEST_TEMP_DIR/ok.md" "$TEST_TEMP_DIR/design-steps.json"
J="$TEST_TEMP_DIR/design-steps.json"
assert_eq "[SV4] each step's served SPECs" '[["DSCLA-1"],["DSCLA-2"]]' "$(jq -c '[.steps[].serves]' "$J" 2>/dev/null)"
assert_eq "[SV4] ...each step's words and areas as before" 'filter by the actor|core/a.sh' "$(jq -r '.steps[0] | "\(.description)|\(.areas | join(","))"' "$J" 2>/dev/null)"
assert_contains "[SV4] the text of a SPEC a step serves" "$(jq -r '.specs["DSCLA-1"] // ""' "$J" 2>/dev/null)" "only the actor's comments are read"
assert_contains "[SV4] ...with its parts" "$(jq -r '.specs["DSCLA-1"] // ""' "$J" 2>/dev/null)" "Then: it is not read"

# ── SV5 ──────────────────────────────────────────────────────────────────────
route_to_model() {
    local _t; _t="$(zb_test_prompt_write_path "$2")"
    [[ -n "$_t" ]] && { cp "$2" "$TEST_TEMP_DIR/design-prompt.txt" 2>/dev/null || printf '%s' "$2" > "$TEST_TEMP_DIR/design-prompt.txt"; }
    return 0
}
apply_scope_redaction() { cp "$1" "$2"; return 0; }
D="$TEST_TEMP_DIR/run"; ST="$D/state"; AD="$ST/artifacts"
mkdir -p "$AD"; git -C "$D" init -q >/dev/null 2>&1
printf 'scope: all\n' > "$ST/scope-manifest.md"
export ZBUILD_REPO_ROOT="$D" ZBUILD_EVENTS_JSONL="$ST/events.jsonl" ZBUILD_EVENTS_DIR="$ST"
: > "$ZBUILD_EVENTS_JSONL"
_design_stage_run_inner "$ST/scope-manifest.md" "$AD/design.md" "$AD" >/dev/null 2>&1
assert_contains "[SV5] design's prompt asks for each step's SPECs" "$(cat "$TEST_TEMP_DIR/design-prompt.txt" 2>/dev/null)" "| serves: "

# ── SV6 ──────────────────────────────────────────────────────────────────────
_l='- filter | areas: core/a.sh | serves: DSCLA-23[code], DSCLA-1 (the filter), DSCLA-1'
zb_design_step_split "$_l"
assert_eq "[SV6] a tag taken off, prose set aside, a repeat counted once" "DSCLA-23 DSCLA-1" "$_ZB_STEP_SERVES"
_ifs_split() { local IFS=$'\n\t'; zb_design_step_split "$_l"; }
_ifs_split
assert_eq "[SV6] ...under a caller IFS of newline and tab too" "DSCLA-23 DSCLA-1" "$_ZB_STEP_SERVES"
_draft "$TEST_TEMP_DIR/ifs.md" "- filter | areas: core/a.sh | serves: DSCLA-1, DSCLA-2"
_ifs_check() { local IFS=$'\n\t'; _design_checks "$TEST_TEMP_DIR/ifs.md" "$CR" ""; }
_ifs_check
assert_eq "[SV6] design's check under that IFS: no step violation" "" "$(_viol STEP_)"
_ifs_write() { local IFS=$'\n\t'; _design_write_steps "$TEST_TEMP_DIR/ifs.md" "$TEST_TEMP_DIR/ifs.json"; }
_ifs_write
assert_eq "[SV6] ...and design-steps.json holds both SPECs' text" "DSCLA-1 DSCLA-2" "$(jq -r '.specs | keys | join(" ")' "$TEST_TEMP_DIR/ifs.json" 2>/dev/null)"

# ── SV7 ──────────────────────────────────────────────────────────────────────
_draft "$TEST_TEMP_DIR/rs.md" "- filter$(printf '\036')first | areas: core/a.sh | serves: DSCLA-1" "- share | areas: core/a.sh | serves: DSCLA-2"
_design_write_steps "$TEST_TEMP_DIR/rs.md" "$TEST_TEMP_DIR/rs.json"
assert_eq "[SV7] two steps, the first in one piece" "2|filter first" "$(jq -r '"\(.steps | length)|\(.steps[0].description)"' "$TEST_TEMP_DIR/rs.json" 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
