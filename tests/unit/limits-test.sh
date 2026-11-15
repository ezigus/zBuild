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
LIMIT: RQNCI-1 Do not build a check of a CI job status through the GitHub Actions API' \
'LIMIT: RQSTG-1 Do not build a do I still hold the claim check before each stage'
assert_eq "[LM1] the write call's limit is in the list, marked a limit" "true" \
    "$(jq -r '.requirements[] | select(.id == "RQNCI-1") | .limit' "$REQ" 2>/dev/null)"
assert_eq "[LM1] ...with its Do not" "Do not build a check of a CI job status through the GitHub Actions API" \
    "$(jq -r '.requirements[] | select(.id == "RQNCI-1") | .text' "$REQ" 2>/dev/null)"
assert_eq "[LM1] the check call's limit is added, marked a limit" "true" \
    "$(jq -r '.requirements[] | select(.id == "RQSTG-1") | .limit' "$REQ" 2>/dev/null)"
assert_eq "[LM1] a requirement is no limit" "null" \
    "$(jq -r '.requirements[] | select(.id == "RQCLM-1") | .limit' "$REQ" 2>/dev/null)"
_p1="$(cat "$TEST_TEMP_DIR/ip-1" 2>/dev/null)"; _pc="$(cat "$TEST_TEMP_DIR/ip-2" 2>/dev/null)"
assert_contains "[LM3] the write call asks for LIMIT: lines" "$_p1" "LIMIT: <id> Do not"
assert_contains "[LM3] the check call asks for LIMIT: lines" "$_pc" "LIMIT: <id> Do not"

# ── LM2 ──────────────────────────────────────────────────────────────────────
print_test_section "LM2: a LIMIT line must say what not to do"
REQ2="$TEST_TEMP_DIR/requirements-2.json"
_intake_list "$REQ2" 'REQUIREMENT: RQCLM-1 Add the claimed label before the first stage.
LIMIT: RQNCI-1 a check of a CI job status through the GitHub Actions API' 'MISSING: none' \
'REQUIREMENT: RQCLM-1 Add the claimed label before the first stage.
LIMIT: RQNCI-1 Do not build a check of a CI job status through the GitHub Actions API'
assert_contains "[LM2] the re-ask says a limit starts with Do not" "$(cat "$TEST_TEMP_DIR/ip-2" 2>/dev/null)" 'starting with "Do not"'
assert_eq "[LM2] ...and the answer to it is kept" "Do not build a check of a CI job status through the GitHub Actions API" \
    "$(jq -r '.requirements[] | select(.id == "RQNCI-1") | .text' "$REQ2" 2>/dev/null)"

# ── LM4 ──────────────────────────────────────────────────────────────────────
print_test_section "LM4: the lists"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
_rl="$(acceptance_requirements_list "$REQ")"; _ll="$(acceptance_limits_list "$REQ" 2>/dev/null)"
assert_contains "[LM4] the requirement list holds the requirement" "$_rl" "- RQCLM-1: Add the claimed label"
if [[ "$_rl" == *RQNCI-1* || "$_rl" == *RQSTG-1* ]]; then assert_fail "[LM4] ...and no limit" "$_rl"
else assert_pass "[LM4] ...and no limit"; fi
assert_contains "[LM4] the limits list holds each limit" "$_ll" "- RQNCI-1: Do not build a check of a CI job status"
assert_contains "[LM4] ...both" "$_ll" "- RQSTG-1: Do not build"

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
      'DSNCI-1[doc]: the CI status is read covers: RQNCI-1' 'WIRING: none' '```' > "$D/bad.md"
  _design_checks "$D/bad.md" "$TEST_TEMP_DIR" "$REQ" >/dev/null 2>&1
  printf '%s\n' "${_DESIGN_VIOLATIONS[@]+"${_DESIGN_VIOLATIONS[@]}"}" > "$D/bad.v" )
_v5="$(cat "$TEST_TEMP_DIR/d5/ok.v" 2>/dev/null)"
if [[ "$_v5" == *"REQUIREMENT_NOT_COVERED RQNCI-1"* || "$_v5" == *"REQUIREMENT_NOT_COVERED RQSTG-1"* ]]; then
    assert_fail "[LM5] no SPEC is asked for a limit" "$_v5"
else assert_pass "[LM5] no SPEC is asked for a limit"; fi
assert_contains "[LM5] a SPEC that covers a limit is refused" "$(cat "$TEST_TEMP_DIR/d5/bad.v" 2>/dev/null)" "LIMIT_COVERED DSNCI-1 RQNCI-1"

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
assert_contains "[LM6] design's prompt shows each limit" "$_dp" "- RQNCI-1: Do not build a check of a CI job status"
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
assert_contains "[LM7] the check is shown each limit" "$_cp" "- RQNCI-1: Do not build a check of a CI job status"
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
KEPT: RQNCI-1
KEPT: RQSTG-1
UNASKED: none'
_ip="$(cat "$TEST_TEMP_DIR/ia-prompt" 2>/dev/null)"
assert_contains "[LM8] issue-acceptance is shown each limit" "$_ip" "- RQNCI-1: Do not build a check of a CI job status"
assert_contains "[LM8] ...and asked KEPT or BROKEN for each" "$_ip" "BROKEN: <id> | WHY:"
assert_eq "[LM8] every limit kept: it passes" "pass" "$(jq -r '.outcome' "$A/issue-acceptance-result.json" 2>/dev/null)"
_ia 'MET: RQCLM-1
BROKEN: RQNCI-1 | WHY: the change adds a CI status check | QUOTE: core/a.sh | ci_job_status_check() { :; }
KEPT: RQSTG-1
UNASKED: none'
assert_eq "[LM8] a broken limit fails it" "fail" "$(jq -r '.outcome' "$A/issue-acceptance-result.json" 2>/dev/null)"
assert_contains "[LM8] ...as an unmet item" "$(jq -r '[.data.unmet[]?] | join("\n")' "$A/issue-acceptance-result.json" 2>/dev/null)" "RQNCI-1"
assert_eq "[LM8] ...whose finding goes to the code's fixer (fix-code)" "1" \
    "$(jq -r '[.data.findings[]? | select(.topic == "code-findings" and (.text | contains("RQNCI-1")))] | length' "$A/issue-acceptance-result.json" 2>/dev/null)"
_ia 'MET: RQCLM-1
KEPT: RQNCI-1
UNASKED: none'
assert_eq "[LM8] a limit with no line: the answer cannot be used" "unusable" "$(jq -r '.outcome' "$A/issue-acceptance-result.json" 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
