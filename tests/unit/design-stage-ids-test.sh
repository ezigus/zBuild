#!/usr/bin/env bash
# tests/unit/design-stage-ids-test.sh — the design stage holds a new design to
# the ids of the last one that passed and to the issue's words, and tells its
# model how ids and [done] evidence are written (#2462, ADR-069 §1, §2).
#
# Why: design's checks can only keep an id stable if they are shown the last
# design that passed, and can only refuse an id the issue writes if they are
# shown the issue. The model must be told the rules it is held to, or every try
# fails on them.
#
# E1 [code] a design that drops an id the last passing design had, with no
#           REMOVED line, is unusable, and the finding names the id
# E2 [code] a SPEC id the issue's own text writes (intake records them in the
#           requirement list) is unusable
# E3 [code] design's prompt says what an id is, that ids never move, how one is
#           removed, and that [done] evidence is a file and an exact piece of its
#           text — never a line number
# E4 [code] the coverage call is not told the requirements are numbered R-1, R-2
# E5 [code] design may answer a finding of its own check (#2464, ADR-072 §5):
#           its reply's ANSWER line is kept in its result and shown to the
#           check, which judges again; the prompt says how to answer
# E6        a finding design is shown and does not answer is asked for, and
#           every answer, with how many findings it was shown, is in its
#           result (ADR-068 §6)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "the design stage holds ids to the last design and the issue (#2462)"
setup_test_env "design-stage-ids"
# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"
apply_scope_redaction() { cp "$1" "$2"; return 0; }
set +e

BT='```'
_design() {   # <acceptance lines...>
    printf '# Design\n\n%sscope\nfoo.sh\n%s\n\n%sacceptance\n' "$BT" "$BT" "$BT"
    printf '%s\n' "$@"
    printf 'WIRING: none\nTESTFILES:\n%s\n' "$BT"
}
DRAFT="" REPLY=""
route_to_model() {
    local _t; _t="$(zb_test_prompt_write_path "$2")"
    if [[ -n "$_t" ]]; then
        printf '%s\n' "$2" > "$TEST_TEMP_DIR/design-prompt"
        printf '%s' "$DRAFT" > "$_t"; printf '%s' "$REPLY"; return 0
    fi
    printf '%s\n' "$2" > "$TEST_TEMP_DIR/judge-prompt"
    zb_test_coverage_ok "$2"
}
_run() {   # <last design or ""> <issue text>
    local d="$TEST_TEMP_DIR/run"
    rm -rf "$d" "$TEST_TEMP_DIR/design-prompt" "$TEST_TEMP_DIR/judge-prompt"
    mkdir -p "$d/state/artifacts"
    git -C "$d" init -q >/dev/null 2>&1
    export ZBUILD_REPO_ROOT="$d"
    export ZBUILD_EVENTS_JSONL="$d/state/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
    _F_ART="$d/state/artifacts"
    printf 'scope: all\n' > "$d/state/scope-manifest.md"
    jq -nc --argjson i "${ISSUE_IDS:-[]}" '{requirements: [{id: "RQDOCS-1", text: "the docs say so"}], issue_ids: $i}' > "$_F_ART/requirements.json"
    jq -nc --arg t "$2" '{result_contract: 3, outcome: "pass", reason: "r", data: {issue_text: $t}}' > "$_F_ART/intake-result.json"
    [[ -n "$1" ]] && printf '%s' "$1" > "$_F_ART/design.md"
    _design_stage_run_inner "$d/state/scope-manifest.md" "$_F_ART/design.md" "$_F_ART" >/dev/null 2>&1
    OUTCOME="$(jq -r '.outcome // "MISSING"' "$_F_ART/design-verdict.json" 2>/dev/null || echo MISSING)"
    FINDINGS="$(jq -r '.data.findings[]?.text // empty' "$_F_ART/design-verdict.json" 2>/dev/null || true)"
}

# ── E1 ───────────────────────────────────────────────────────────────────────
DRAFT="$(_design 'DSDOCW-1[no-code]: the docs say so covers: RQDOCS-1')"
_run "$(_design 'DSDOCW-1[no-code]: the docs say so covers: RQDOCS-1' 'DSDOCW-2[no-code]: the readme says so covers: RQDOCS-1')" "Write the docs."
assert_eq "[E1] dropping an id of the last passing design: unusable" "unusable" "$OUTCOME"
assert_contains "[E1] ...the finding names it" "$FINDINGS" "DSDOCW-2 was in the last list"
DRAFT="$(_design 'DSDOCW-1[no-code]: the docs say so covers: RQDOCS-1' 'REMOVED: DSDOCW-2 — the readme is out of scope')"
_run "$(_design 'DSDOCW-1[no-code]: the docs say so covers: RQDOCS-1' 'DSDOCW-2[no-code]: the readme says so covers: RQDOCS-1')" "Write the docs."
assert_eq "[E1] dropped with a REMOVED line, it passes" "pass" "$OUTCOME"

# ── E2 ───────────────────────────────────────────────────────────────────────
DRAFT="$(_design 'DSNOTE-1[no-code]: the docs say so covers: RQDOCS-1')"
ISSUE_IDS='["DSNOTE-1"]' _run "" "Write the docs. DSNOTE-1 in the tracker says how."
assert_eq "[E2] a SPEC id the issue writes: unusable" "unusable" "$OUTCOME"
assert_contains "[E2] ...the finding says so" "$FINDINGS" "DSNOTE-1 is written in the issue itself"

# ── E3 / E4 ──────────────────────────────────────────────────────────────────
_p="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/design-prompt" 2>/dev/null)"
assert_contains "[E3] the prompt says what an id is" "$_p" "3 or 4 capital letters or digits"
assert_contains "[E3] ...that a kept id never changes" "$_p" "never changes"
assert_contains "[E3] ...how one is removed" "$_p" "REMOVED: <id> — <why>"
assert_contains "[E3] ...that a new id takes the number after its code's highest" "$_p" "one more than the highest"
assert_contains "[E3] ...that [done] evidence quotes the file's text" "$_p" 'scripts/x.sh:"'
_line=0; [[ "$_p" == *"a file and line"* || "$_p" == *"scripts/x.sh:42"* ]] && _line=1
assert_eq "[E3] ...and never offers a line number" "0" "$_line"
DRAFT="$(_design 'DSDOCW-1[no-code]: the docs say so covers: RQDOCS-1')"
_run "" "Write the docs."
_j="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/judge-prompt" 2>/dev/null)"
assert_contains "[E4] the coverage call ran" "$_j" "RQDOCS-1"
_num=0; [[ "$_j" == *"numbered R-1"* || "$_j" == *"(R-2:"* ]] && _num=1
assert_eq "[E4] ...and is not told the ids are R-1, R-2" "0" "$_num"

# ── E5 ───────────────────────────────────────────────────────────────────────
assert_contains "[E5] design is told it may answer its own check's finding" "$_p" \
    "ANSWER design finding <n>: wrong — <why>"
REPLY=$'Wrote the design.\nANSWER design finding 1: wrong — DSDOCW-1 is the whole of RQDOCS-1'
_run "" "Write the docs."
assert_eq "[E5] the answer is kept in design's result" \
    "design finding 1: wrong — DSDOCW-1 is the whole of RQDOCS-1" \
    "$(jq -r '.data.answers[0] // ""' "$_F_ART/design-verdict.json" 2>/dev/null)"
assert_contains "[E5] ...and shown to the check" "$(cat "$TEST_TEMP_DIR/judge-prompt" 2>/dev/null)" "DSDOCW-1 is the whole of RQDOCS-1"
REPLY=""

# ── E6 ───────────────────────────────────────────────────────────────────────
# The engine's answer check (zb_answers_finish, finding-answers-test.sh B1-B3)
# is handed design's prompt and reply, and what it returns is kept.
eval "_e6_real_$(declare -f zb_answers_finish)"
zb_answers_finish() {
    local -n _e6a="$1"; printf '%s' "$2" > "$TEST_TEMP_DIR/finish-prompt"; printf '%s' "$3" > "$TEST_TEMP_DIR/finish-reply"
    _e6a+=("lens-scope-design finding 1: not mine — the README is not part of this issue"); _ZB_ANS_SHOWN=1; _ZB_ANS_MISSING=""
}
REPLY='Wrote the design.'
DRAFT="$(_design 'DSDOCW-1[no-code]: the docs say so covers: RQDOCS-1')"
_run "" "Write the docs."
assert_contains "[E6] the check is handed design's prompt" "$(cat "$TEST_TEMP_DIR/finish-prompt" 2>/dev/null)" "RQDOCS-1"
assert_eq "[E6] ...and its reply" "Wrote the design." "$(cat "$TEST_TEMP_DIR/finish-reply" 2>/dev/null)"
assert_eq "[E6] what it returns is kept in design's result" \
    "lens-scope-design finding 1: not mine — the README is not part of this issue" \
    "$(jq -r '.data.answers[0] // ""' "$_F_ART/design-verdict.json" 2>/dev/null)"
assert_eq "[E6] ...with how many findings it was shown" "1" \
    "$(jq -r '.data.findings_shown // "none"' "$_F_ART/design-verdict.json" 2>/dev/null)"
eval "$(declare -f _e6_real_zb_answers_finish | sed '1s/_e6_real_//')"
REPLY=""

cleanup_test_env
print_test_results
exit $((FAIL > 0))
