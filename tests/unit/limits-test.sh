#!/usr/bin/env bash
# tests/unit/limits-test.sh — an item the issue says not to do or build stays
# a limit, with its "Do not", from intake to issue-acceptance (#2550, ADR-070
# §1, ADR-069, ADR-072 §3).
#
# Why: on #1764 run 43735596812 the issue said "Do not build: a check of a CI
# job's status …; a 'do I still hold the claim' check before each stage".
# Intake's check found both items, but its list stored them as "a check of a CI
# job's status …" — a thing to build. Design, which does not read the issue,
# built both, and its coverage check rejected the design: a try lost on words
# the list had dropped.
#
# LM1 [change] intake keeps a "do not" item as a limit — its LIMIT: line, from
#              either call, is in its list with limit: true and its "Do not"
# LM2 [change] a LIMIT: line whose words do not start with "Do not" or "Never"
#              is asked again
# LM3 [change] intake's prompts ask for LIMIT: lines
# LM4 [change] the requirement list every stage is shown leaves limits out; the
#              limits list holds them
# LM5 [change] design's script check asks no SPEC for a limit, and refuses a
#              SPEC that covers one
# LM6 [change] design's prompt shows the limits, and says to write no SPEC or
#              step for them
# LM7 [change] design's coverage check is shown the limits, asks no line for
#              them, and is told a SPEC that does what one forbids contradicts it
# LM8 [change] issue-acceptance is shown the limits and answers KEPT or BROKEN
#              for each; BROKEN is unmet, fix-code; a limit with no line makes
#              the answer unusable
# LM9  [change] intake's check cannot drop a limit as NOT-A-REQUIREMENT: that
#              line is refused and asked again (lens review on #2550)
# LM10 [change] an id keeps its kind from the last list: a limit that comes
#              back as a requirement, or a requirement as a limit, is asked again
# LM11 [change] a KEPT: or BROKEN: line with no id makes the answer unusable —
#              it does not stop issue-acceptance
# LM12 [change] intake's summary counts and lists limits apart from requirements
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a 'do not' item stays a limit (#2550)"
setup_test_env "limits"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
set +e

ISSUE_JSON='{"title":"Claim an issue","body":"1. Add the claimed label before the first stage.\n\nDo not build:\n- a check of a CI job status through the GitHub Actions API\n- a do I still hold the claim check before each stage"}'

# _intake_list <out.json> <write reply> <check reply> [<reask reply>] — the list
# intake's own writer builds, with only the model stubbed. Each call's prompt is
# kept as $TEST_TEMP_DIR/ip-<n>.
_intake_list() {
    ( export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR"
      # shellcheck source=../../plugins/agent/intake/plugin.sh
      source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
      export _LW="$2" _LC="$3" _LR="${4:-}"
      : > "$TEST_TEMP_DIR/ic"
      route_to_model() {
          local n; n=$(( $(grep -c . "$TEST_TEMP_DIR/ic") + 1 )); printf 'x\n' >> "$TEST_TEMP_DIR/ic"
          printf '%s' "$2" > "$TEST_TEMP_DIR/ip-$n"
          if [[ "$2" == *"Your job: check a list of requirements"* ]]; then printf '%s\n' "$_LC"
          elif [[ -n "$_LR" && "$n" -gt 1 ]]; then printf '%s\n' "$_LR"
          else printf '%s\n' "$_LW"; fi
      }
      local _j
      _intake_requirements_json_v _j "$ISSUE_JSON" && printf '%s\n' "$_j" > "$1" ) >/dev/null 2>&1
}

# ── LM1 / LM3 ────────────────────────────────────────────────────────────────
print_test_section "LM1/LM3: intake keeps a 'do not' item as a limit"
REQ="$TEST_TEMP_DIR/requirements.json"
_intake_list "$REQ" 'REQUIREMENT: RQCLM-1 Add the claimed label before the first stage.
LIMIT: LMNCI-1 Do not build a check of a CI job status through the GitHub Actions API' \
'LIMIT: LMSTG-1 Do not build a do I still hold the claim check before each stage'
assert_eq "[LM1] the write call's limit is in the list, marked a limit" "true" \
    "$(jq -r '.requirements[] | select(.id == "LMNCI-1") | .limit' "$REQ" 2>/dev/null)"
assert_eq "[LM1] ...with its Do not" "Do not build a check of a CI job status through the GitHub Actions API" \
    "$(jq -r '.requirements[] | select(.id == "LMNCI-1") | .text' "$REQ" 2>/dev/null)"
assert_eq "[LM1] the check call's limit is added, marked a limit" "true" \
    "$(jq -r '.requirements[] | select(.id == "LMSTG-1") | .limit' "$REQ" 2>/dev/null)"
assert_eq "[LM1] a requirement is no limit" "null" \
    "$(jq -r '.requirements[] | select(.id == "RQCLM-1") | .limit' "$REQ" 2>/dev/null)"
_p1="$(cat "$TEST_TEMP_DIR/ip-1" 2>/dev/null)"; _pc="$(cat "$TEST_TEMP_DIR/ip-2" 2>/dev/null)"
assert_contains "[LM3] the write call asks for LIMIT: lines" "$_p1" "LIMIT: LMSCOP-1 Do not"
assert_contains "[LM3] the check call asks for LIMIT: lines" "$_pc" "LIMIT: LM<code>-<n> Do not"

# ── LM2 ──────────────────────────────────────────────────────────────────────
print_test_section "LM2: a LIMIT line must say what not to do"
REQ2="$TEST_TEMP_DIR/requirements-2.json"
_intake_list "$REQ2" 'REQUIREMENT: RQCLM-1 Add the claimed label before the first stage.
LIMIT: LMNCI-1 a check of a CI job status through the GitHub Actions API' 'MISSING: none' \
'REQUIREMENT: RQCLM-1 Add the claimed label before the first stage.
LIMIT: LMNCI-1 Do not build a check of a CI job status through the GitHub Actions API'
assert_contains "[LM2] the re-ask says a limit starts with Do not" "$(cat "$TEST_TEMP_DIR/ip-2" 2>/dev/null)" 'starting with "Do not"'
assert_eq "[LM2] ...and the answer to it is kept" "Do not build a check of a CI job status through the GitHub Actions API" \
    "$(jq -r '.requirements[] | select(.id == "LMNCI-1") | .text' "$REQ2" 2>/dev/null)"

# ── LM4 ──────────────────────────────────────────────────────────────────────
print_test_section "LM4: the lists"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
_rl="$(acceptance_requirements_list "$REQ")"; _ll="$(acceptance_limits_list "$REQ" 2>/dev/null)"
assert_contains "[LM4] the requirement list holds the requirement" "$_rl" "- RQCLM-1: Add the claimed label"
if [[ "$_rl" == *LMNCI-1* || "$_rl" == *LMSTG-1* ]]; then assert_fail "[LM4] ...and no limit" "$_rl"
else assert_pass "[LM4] ...and no limit"; fi
assert_contains "[LM4] the limits list holds each limit" "$_ll" "- LMNCI-1: Do not build a check of a CI job status"
assert_contains "[LM4] ...both" "$_ll" "- LMSTG-1: Do not build"

# ── LM5 ──────────────────────────────────────────────────────────────────────
print_test_section "LM5: design's script check"
( source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
  D="$TEST_TEMP_DIR/d5"; mkdir -p "$D"
  printf '%s\n' '# Design' '```acceptance' \
      'DSCLM-1[doc]: the label is added before the first stage covers: RQCLM-1' 'WIRING: none' '```' > "$D/ok.md"
  _design_checks "$D/ok.md" "$TEST_TEMP_DIR" "$REQ" >/dev/null 2>&1
  printf '%s\n' "${_DESIGN_VIOLATIONS[@]+"${_DESIGN_VIOLATIONS[@]}"}" > "$D/ok.v"
  printf '%s\n' '# Design' '```acceptance' \
      'DSCLM-1[doc]: the label is added before the first stage covers: RQCLM-1' \
      'DSNCI-1[doc]: the CI status is read covers: LMNCI-1' 'WIRING: none' '```' > "$D/bad.md"
  _design_checks "$D/bad.md" "$TEST_TEMP_DIR" "$REQ" >/dev/null 2>&1
  printf '%s\n' "${_DESIGN_VIOLATIONS[@]+"${_DESIGN_VIOLATIONS[@]}"}" > "$D/bad.v" )
_v5="$(cat "$TEST_TEMP_DIR/d5/ok.v" 2>/dev/null)"
if [[ "$_v5" == *"REQUIREMENT_NOT_COVERED LMNCI-1"* || "$_v5" == *"REQUIREMENT_NOT_COVERED LMSTG-1"* ]]; then
    assert_fail "[LM5] no SPEC is asked for a limit" "$_v5"
else assert_pass "[LM5] no SPEC is asked for a limit"; fi
assert_contains "[LM5] a SPEC that covers a limit is refused" "$(cat "$TEST_TEMP_DIR/d5/bad.v" 2>/dev/null)" "LIMIT_COVERED DSNCI-1 LMNCI-1"

# ── LM6 ──────────────────────────────────────────────────────────────────────
print_test_section "LM6: design's prompt"
FIX="$TEST_TEMP_DIR/fix"; mkdir -p "$FIX/state/artifacts"
git -C "$FIX" init -q >/dev/null 2>&1
jq -n --arg r "$REQ" '{inputs: {a: $r}}' > "$FIX/state/stage-inputs.json"
printf 'scope: all\n' > "$FIX/state/scope-manifest.md"
( source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
  route_to_model() { return 1; }
  _route_loop_close_final_banner() { return 0; }
  export ZBUILD_REPO_ROOT="$FIX" ZBUILD_STAGE_INPUTS="$FIX/state/stage-inputs.json"
  _design_stage_run_inner "$FIX/state/scope-manifest.md" "$FIX/state/artifacts/design.md" "$FIX/state/artifacts" ) >/dev/null 2>&1
_dp="$(cat "$FIX/state/artifacts/design-prompt.txt" 2>/dev/null)"
assert_contains "[LM6] design's prompt shows each limit" "$_dp" "- LMNCI-1: Do not build a check of a CI job status"
assert_contains "[LM6] ...and says to write no SPEC or step for one" "$_dp" "Write no SPEC for a limit"

# ── LM7 ──────────────────────────────────────────────────────────────────────
print_test_section "LM7: design's coverage check"
( source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
  route_to_model() { printf '%s' "$2" > "$TEST_TEMP_DIR/cov-prompt"; printf 'RQCLM-1: covered\nDSCLM-1: ok\n'; }
  printf '%s\n' '# Design' '```acceptance' \
      'DSCLM-1[doc]: the label is added before the first stage covers: RQCLM-1' 'WIRING: none' '```' > "$TEST_TEMP_DIR/d7.md"
  _design_coverage "$TEST_TEMP_DIR/d7.md" "$(acceptance_requirements_list "$REQ")" T2 "" "$(acceptance_limits_list "$REQ")"
  printf '%s|%s' "$_DESIGN_COV_OUTCOME" "${#_DESIGN_UNCOVERED[@]}" > "$TEST_TEMP_DIR/cov-out" ) >/dev/null 2>&1
_cp="$(cat "$TEST_TEMP_DIR/cov-prompt" 2>/dev/null)"
assert_contains "[LM7] the check is shown each limit" "$_cp" "- LMNCI-1: Do not build a check of a CI job status"
assert_contains "[LM7] ...and told a SPEC that does what one forbids contradicts it" "$_cp" "does what a limit forbids"
assert_eq "[LM7] an answer with no line for a limit is complete" "|0" "$(cat "$TEST_TEMP_DIR/cov-out" 2>/dev/null)"

# ── LM8 ──────────────────────────────────────────────────────────────────────
print_test_section "LM8: issue-acceptance"
G="$TEST_TEMP_DIR/repo"; mkdir -p "$G/core"
( cd "$G" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'keep\n' > core/a.sh && git add -A && git commit -q -m base
  git checkout -q -b feature && printf 'keep\nci_job_status_check() { :; }\n' > core/a.sh && git commit -qam change ) >/dev/null 2>&1
S="$TEST_TEMP_DIR/ia"; A="$S/artifacts"; IN="$S/inputs"; mkdir -p "$A" "$IN"
printf '{}' > "$S/pipeline-state.json"
zb_test_issue_output "$IN" "Add the claimed label. Do not build a check of a CI job status." >/dev/null
printf '%s\n' '# Design' '```acceptance' 'DSCLM-1[doc]: the label is added covers: RQCLM-1' 'WIRING: none' '```' > "$IN/design.md"
zb_test_test_run_output "$IN" pass 1 0 >/dev/null
jq -n --arg i "$IN/intake-result.json" --arg r "$REQ" --arg d "$IN/design.md" --arg t "$IN/test-results.json" \
    '{inputs: {a: $i, b: $r, c: $d, d: $t}}' > "$S/stage-inputs.json"
_ia() {
    ( export ZBUILD_STAGE_INPUTS="$S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$A" ZBUILD_REPO_ROOT="$G" _IA_REPLY="$1"
      # shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
      source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh" >/dev/null 2>&1
      route_to_model() { printf '%s' "$2" > "$TEST_TEMP_DIR/ia-prompt"; printf '%s\n' "$_IA_REPLY"; }
      rm -f "$A/issue-acceptance-judged.json"
      cd "$G" && issue_acceptance_run issue-acceptance "$S/pipeline-state.json" ) >/dev/null 2>&1
}
_ia 'MET: RQCLM-1
KEPT: LMNCI-1
KEPT: LMSTG-1
UNASKED: none'
_ip="$(cat "$TEST_TEMP_DIR/ia-prompt" 2>/dev/null)"
assert_contains "[LM8] issue-acceptance is shown each limit" "$_ip" "- LMNCI-1: Do not build a check of a CI job status"
assert_contains_lines "[LM8] ...and asked KEPT or BROKEN for each" "$_ip" $'BROKEN: <id>\nwhy:'
assert_eq "[LM8] every limit kept: it passes" "pass" "$(jq -r '.outcome' "$A/issue-acceptance-result.json" 2>/dev/null)"
_ia 'MET: RQCLM-1
BROKEN: LMNCI-1 | WHY: the change adds a CI status check | ACCEPTED IF: it is accepted | QUOTE: core/a.sh | ci_job_status_check() { :; }
KEPT: LMSTG-1
UNASKED: none'
assert_eq "[LM8] a broken limit fails it" "fail" "$(jq -r '.outcome' "$A/issue-acceptance-result.json" 2>/dev/null)"
assert_contains "[LM8] ...as an unmet item" "$(jq -r '[.data.unmet[]?] | join("\n")' "$A/issue-acceptance-result.json" 2>/dev/null)" "LMNCI-1"
assert_eq "[LM8] ...whose finding goes to the code's fixer (fix-code: the code output, #2556)" "1" \
    "$(jq -r '[.data.findings[]? | select(.text | contains("LMNCI-1"))] | length' "$A/issue-acceptance-code-result.json" 2>/dev/null)"
_ia 'MET: RQCLM-1
KEPT: LMNCI-1
UNASKED: none'
assert_eq "[LM8] a limit with no line: the answer cannot be used" "unusable" "$(jq -r '.outcome' "$A/issue-acceptance-result.json" 2>/dev/null)"

# ── LM9 ──────────────────────────────────────────────────────────────────────
print_test_section "LM9: the check cannot drop a limit"
REQ9="$TEST_TEMP_DIR/requirements-9.json"
_intake_list "$REQ9" 'REQUIREMENT: RQCLM-1 Add the claimed label before the first stage.
LIMIT: LMNCI-1 Do not build a check of a CI job status through the GitHub Actions API' \
'NOT-A-REQUIREMENT: LMNCI-1 — it is a limit'
assert_contains "[LM9] the check is asked again: a limit gets no NOT-A-REQUIREMENT line" "$(cat "$TEST_TEMP_DIR/ip-3" 2>/dev/null)" "LMNCI-1 is a limit"

# ── LM10 ─────────────────────────────────────────────────────────────────────
print_test_section "LM10: an id keeps its kind"
( export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR"
  source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
  export _INTAKE_PREV_REQ_JSON="$(cat "$REQ")"
  : > "$TEST_TEMP_DIR/ic10"
  route_to_model() {
      local n; n=$(( $(grep -c . "$TEST_TEMP_DIR/ic10") + 1 )); printf 'x\n' >> "$TEST_TEMP_DIR/ic10"
      printf '%s' "$2" > "$TEST_TEMP_DIR/ip10-$n"
      if [[ "$2" == *"Your job: check a list"* ]]; then printf 'MISSING: none\n'
      else printf 'REQUIREMENT: RQCLM-1 Add the claimed label before the first stage.\nREQUIREMENT: LMNCI-1 a check of a CI job status through the GitHub Actions API\nLIMIT: LMSTG-1 Do not build a do I still hold the claim check before each stage\n'; fi
  }
  # A changed issue: an unchanged one keeps the last list and asks no model.
  _j=""; _intake_requirements_json_v _j "${ISSUE_JSON/first stage./first stage, every run.}" ) >/dev/null 2>&1
assert_contains "[LM10] a limit listed as a requirement is asked again" "$(cat "$TEST_TEMP_DIR/ip10-2" 2>/dev/null)" "LMNCI-1 was a limit in the last list"

# ── LM11 ─────────────────────────────────────────────────────────────────────
print_test_section "LM11: a limit line with no id"
rm -f "$A/issue-acceptance-result.json"
_ia 'MET: RQCLM-1
KEPT:
KEPT: LMNCI-1
KEPT: LMSTG-1
UNASKED: none'
assert_eq "[LM11] a KEPT: line with no id: the answer cannot be used" "unusable" \
    "$(jq -r '.outcome' "$A/issue-acceptance-result.json" 2>/dev/null)"
assert_contains "[LM11] ...and it says the line names no limit" \
    "$(jq -r '.reason' "$A/issue-acceptance-result.json" 2>/dev/null)" "line names no limit"

# ── LM12 ─────────────────────────────────────────────────────────────────────
print_test_section "LM12: intake's summary"
( source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
  _intake_pass_summary_write "$TEST_TEMP_DIR/intake-summary.md" 1764 "$REQ" "" "t" ) >/dev/null 2>&1
_sm="$(cat "$TEST_TEMP_DIR/intake-summary.md" 2>/dev/null)"
assert_contains "[LM12] the summary counts only the requirements" "$_sm" "1 requirement(s): RQCLM-1"
assert_contains "[LM12] ...and the limits apart" "$_sm" "2 limit(s): LMNCI-1, LMSTG-1"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
