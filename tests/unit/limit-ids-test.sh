#!/usr/bin/env bash
# tests/unit/limit-ids-test.sh — intake sorts a "do not"; a limit's id starts
# with LM; a wrong id is answered with a corrected one (#2603, ADR-070 §1).
#
# #2533 run 45387034249 stopped at intake: the prompt called a limit "not a
# requirement" yet gave it the requirement prefix, and the model wrote limit
# ids LIMSCOPE-1, LIMIT-OUT1, CONC-1, SCOP-1. The messages said "has no id",
# spoke of "every requirement id", and of old numbering and REMOVED lines.
#
# LI1 [change] the prompts sort a "do not": keep doing → requirement; another
#              issue's note → left out; must not build → LIMIT with an LM id
# LI2 [change] a LIMIT: line with an LM id is a limit, and a list with
#              RQ requirements and LM limits is accepted
# LI3 [change] a limit with an RQ id is asked again: "… does not start with LM
#              — write it as LM…"
# LI4 [change] a requirement with an LM id is asked again
# LI5 [change] a limit kept from the last list under an RQ id comes back with
#              an LM id, with no REMOVED line
# LI6 [change] a wrong id is answered with what is wrong and a corrected id: a
#              code of 5 letters names its length; LIMIT-OUT1 is never "no id";
#              no message speaks of old numbering or REMOVED lines
# (review on #2603)
# LI7 [change] a rerun shows the last list's LM limit with its id, and the LM
#              numbers, so the model keeps it in one call
# LI8 [change] a limit from an older run under an RQ id that this issue makes a
#              requirement is kept as that requirement, in one call
# LI9 [change] an RQ-id limit left out is recorded as removed, so its id stays
#              taken
# LI10 [change] a corrected id takes the next free number, never a taken one
# LI11 [change] a number with a leading 0 is named as the fault
# LI12 [change] a line with no id whose text starts with a hyphenated word is
#              told it has no id, not that the word is a bad id
# LI13 [change] LM is a taken prefix: a stage declaring id_prefix LM is refused
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a limit's id starts with LM (#2603)"
setup_test_env "limit-ids"
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

_asks() { cat "$TEST_TEMP_DIR"/ip-* 2>/dev/null | tr -s '[:space:]' ' '; }

print_test_section "LI1: the prompt sorts a do-not"
REQ="$TEST_TEMP_DIR/r1.json"; rm -f "$TEST_TEMP_DIR"/ip-*
_intake_list "$REQ" 'REQUIREMENT: RQCLM-1 Add the claimed label before the first stage.
LIMIT: LMNCI-1 Do not build a check of a CI job status through the GitHub Actions API' 'MISSING: none'
_p1="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/ip-1" 2>/dev/null)"
assert_contains "[LI1] keep doing → a requirement" "$_p1" "REQUIREMENT: RQRULE-1 The old rules keep working"
assert_contains "[LI1] another issue's note → left out" "$_p1" "Leave it out"
assert_contains "[LI1] must not build → a limit with an LM id" "$_p1" "LIMIT: LMSCOP-1 Do not"

print_test_section "LI2: an LM limit is a limit"
assert_eq "[LI2] the list holds the LM limit, marked a limit" "true" "$(jq -r '.requirements[] | select(.id == "LMNCI-1") | .limit' "$REQ" 2>/dev/null)"
assert_eq "[LI2] ...and the RQ requirement" "RQCLM-1" "$(jq -r '[.requirements[] | select(.limit != true) | .id] | join(",")' "$REQ" 2>/dev/null)"

print_test_section "LI3-LI4: a wrong prefix is asked again"
REQ="$TEST_TEMP_DIR/r3.json"; rm -f "$TEST_TEMP_DIR"/ip-*
_intake_list "$REQ" 'REQUIREMENT: RQCLM-1 Add the claimed label before the first stage.
LIMIT: CONC-1 Do not build a check of a CI job status through the GitHub Actions API' 'MISSING: none' 'REQUIREMENT: RQCLM-1 Add the claimed label before the first stage.
LIMIT: LMNCI-1 Do not build a check of a CI job status through the GitHub Actions API'
assert_contains "[LI3] a limit's id with no LM is asked again, with the corrected id" "$(_asks)" "CONC-1 does not start with LM — write it as LMCONC-1"
REQ="$TEST_TEMP_DIR/r4.json"; rm -f "$TEST_TEMP_DIR"/ip-*
_intake_list "$REQ" 'REQUIREMENT: LMCLM-1 Add the claimed label before the first stage.
LIMIT: LMNCI-1 Do not build a check of a CI job status through the GitHub Actions API' 'MISSING: none' 'REQUIREMENT: RQCLM-1 Add the claimed label before the first stage.
LIMIT: LMNCI-1 Do not build a check of a CI job status through the GitHub Actions API'
assert_contains "[LI4] a requirement's id with LM is asked again" "$(_asks)" "LMCLM-1 does not start with RQ — write it as RQCLM-1"

print_test_section "LI6: the messages"
REQ="$TEST_TEMP_DIR/r6.json"; rm -f "$TEST_TEMP_DIR"/ip-*
_intake_list "$REQ" 'REQUIREMENT: RQCLAIM-1 Add the claimed label before the first stage.
LIMIT: LIMIT-OUT1 Do not build a check of a CI job status through the GitHub Actions API' 'MISSING: none' 'REQUIREMENT: RQCLM-1 Add the claimed label before the first stage.
LIMIT: LMNCI-1 Do not build a check of a CI job status through the GitHub Actions API'
_a6="$(_asks)"
assert_contains "[LI6] a 5-letter code is named, with a corrected id" "$_a6" "RQCLAIM-1's code CLAIM has 5 letters; it needs 3 or 4"
assert_contains "[LI6] LIMIT-OUT1 is not in the id form, with an example" "$_a6" "LIMIT-OUT1 is not in the id form"
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it says: $3"; else assert_pass "$1"; fi; }
_lacks "[LI6] ...never 'has no id'" "$_a6" "has no id"
REQ="$TEST_TEMP_DIR/r6b.json"; rm -f "$TEST_TEMP_DIR"/ip-*
_intake_list "$REQ" 'REQUIREMENT: RQCLM-1 Add the claimed label before the first stage.
LIMIT: CONC-1 Do not build a check of a CI job status through the GitHub Actions API' 'MISSING: none' 'REQUIREMENT: RQCLM-1 Add the claimed label before the first stage.
LIMIT: LMNCI-1 Do not build a check of a CI job status through the GitHub Actions API'
_lacks "[LI6] ...nothing about REMOVED lines or old numbering" "$(_asks)" "REMOVED line"

print_test_section "LI5: a limit with an old RQ id"
PREV='{"requirements":[{"id":"RQCLM-1","text":"Add the claimed label before the first stage."},{"id":"RQNCI-1","text":"Do not build a check of a CI job status through the GitHub Actions API","limit":true}]}'
( export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR"
  source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
  export _INTAKE_PREV_REQ_JSON="$PREV"
  : > "$TEST_TEMP_DIR/ic5"
  route_to_model() {
      local n; n=$(( $(grep -c . "$TEST_TEMP_DIR/ic5") + 1 )); printf 'x\n' >> "$TEST_TEMP_DIR/ic5"
      printf '%s' "$2" > "$TEST_TEMP_DIR/ip5-$n"
      if [[ "$2" == *"Your job: check a list"* ]]; then printf 'MISSING: none\n'
      else printf 'REQUIREMENT: RQCLM-1 Add the claimed label before the first stage, every run.\nLIMIT: LMNCI-1 Do not build a check of a CI job status through the GitHub Actions API\n'; fi
  }
  _j=""; _intake_requirements_json_v _j "${ISSUE_JSON/first stage./first stage, every run.}" && printf '%s\n' "$_j" > "$TEST_TEMP_DIR/r5.json" ) >/dev/null 2>&1
assert_eq "[LI5] the old RQ limit comes back as LMNCI-1, a limit" "true" "$(jq -r '.requirements[] | select(.id == "LMNCI-1") | .limit' "$TEST_TEMP_DIR/r5.json" 2>/dev/null)"
assert_eq "[LI5] ...in one call: no re-ask for a REMOVED line" "2" "$(grep -c . "$TEST_TEMP_DIR/ic5" 2>/dev/null)"

# _rerun <label> <prev json> <write reply> — intake on a changed issue with a
# last list; each prompt kept as ip<label>-<n>, the result as r<label>.json.
_rerun() {
    ( export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR"
      source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
      export _INTAKE_PREV_REQ_JSON="$2" _RW="$3" _RL="$1"
      : > "$TEST_TEMP_DIR/ic$1"
      route_to_model() {
          local n; n=$(( $(grep -c . "$TEST_TEMP_DIR/ic$_RL") + 1 )); printf 'x\n' >> "$TEST_TEMP_DIR/ic$_RL"
          printf '%s' "$2" > "$TEST_TEMP_DIR/ip$_RL-$n"
          if [[ "$2" == *"Your job: check a list"* ]]; then printf 'MISSING: none\n'; else printf '%s\n' "$_RW"; fi
      }
      _j=""; _intake_requirements_json_v _j "${ISSUE_JSON/first stage./first stage, every run.}" && printf '%s\n' "$_j" > "$TEST_TEMP_DIR/r$1.json" ) >/dev/null 2>&1
}
_calls() { grep -c . "$TEST_TEMP_DIR/ic$1" 2>/dev/null; }

print_test_section "LI7: a rerun shows the LM limit"
_rerun 7 '{"requirements":[{"id":"RQCLM-1","text":"Add the claimed label before the first stage."},{"id":"LMNCI-1","text":"Do not build a check of a CI job status through the GitHub Actions API","limit":true}]}' \
'REQUIREMENT: RQCLM-1 Add the claimed label before the first stage, every run.
LIMIT: LMNCI-1 Do not build a check of a CI job status through the GitHub Actions API'
assert_contains "[LI7] the last list shows the limit with its LM id" "$(cat "$TEST_TEMP_DIR/ip7-1" 2>/dev/null)" "LIMIT: LMNCI-1 Do not build"
assert_contains "[LI7] ...and the LM numbers" "$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/ip7-1" 2>/dev/null)" "LMNCI 1"
assert_eq "[LI7] kept in one call" "2" "$(_calls 7)"

print_test_section "LI8: an old RQ-id limit, now a requirement"
_rerun 8 '{"requirements":[{"id":"RQCLM-1","text":"Add the claimed label before the first stage."},{"id":"RQRULE-1","text":"Do not change the old rules","limit":true}]}' \
'REQUIREMENT: RQCLM-1 Add the claimed label before the first stage, every run.
REQUIREMENT: RQRULE-1 The old rules keep working'
assert_eq "[LI8] kept as a requirement, in one call" "2" "$(_calls 8)"
assert_eq "[LI8] ...no longer a limit" "null" "$(jq -r '.requirements[] | select(.id == "RQRULE-1") | .limit' "$TEST_TEMP_DIR/r8.json" 2>/dev/null)"

print_test_section "LI9: an old RQ-id limit, left out"
_rerun 9 '{"requirements":[{"id":"RQCLM-1","text":"Add the claimed label before the first stage."},{"id":"RQRULE-1","text":"Do not change the old rules","limit":true}]}' \
'REQUIREMENT: RQCLM-1 Add the claimed label before the first stage, every run.
LIMIT: LMRULE-1 Do not change the old rules'
assert_eq "[LI9] the old id is recorded as removed" "RQRULE-1" "$(jq -r '[.removed[]?.id] | join(",")' "$TEST_TEMP_DIR/r9.json" 2>/dev/null)"
assert_eq "[LI9] ...in one call" "2" "$(_calls 9)"

print_test_section "LI10-LI11: suggestions"
( source "$REPO_ROOT/scripts/lib/item-ids.sh"
  _v=(); zb_ids_check_v _v "RQLOOP-1 RQLOOP-2" "" "RQLOOP-1 RQLOOP-2 LOOP-2" "" "" RQ 0
  for v in "${_v[@]}"; do printf 'LI10|%s\n' "$(zb_id_plain "$v" requirement)"; done
  _v=(); zb_ids_check_v _v "" "" "RQLOOP-01" "" "" RQ 0
  for v in "${_v[@]}"; do printf 'LI11|%s\n' "$(zb_id_plain "$v" requirement)"; done ) > "$TEST_TEMP_DIR/li10.out" 2>/dev/null
_l10() { grep "^$1|" "$TEST_TEMP_DIR/li10.out" | cut -d'|' -f2- | tr '\n' ' '; }
assert_contains "[LI10] the next free number" "$(_l10 LI10)" "write it as RQLOOP-3"
assert_contains "[LI11] a leading 0 is named" "$(_l10 LI11)" "RQLOOP-01's number starts at 1, with no leading 0"

print_test_section "LI12: a hyphenated first word is no id"
REQ="$TEST_TEMP_DIR/r12.json"; rm -f "$TEST_TEMP_DIR"/ip-*
_intake_list "$REQ" 'REQUIREMENT: Read-only files are never written.
LIMIT: LMNCI-1 Do not build a check of a CI job status through the GitHub Actions API' 'MISSING: none' 'REQUIREMENT: RQCLM-1 Add the claimed label before the first stage.
LIMIT: LMNCI-1 Do not build a check of a CI job status through the GitHub Actions API'
assert_contains "[LI12] told it has no id" "$(_asks)" "Read-only files are never written.\" has no id"
_lacks "[LI12] ...not that Read-only is a bad id" "$(_asks)" "Read-only is not in the id form"

print_test_section "LI13: LM is taken"
( source "$REPO_ROOT/scripts/lib/helpers.sh"; source "$REPO_ROOT/core/plugin-registry/registry.sh" 2>/dev/null; source "$REPO_ROOT/scripts/lib/item-ids.sh"
  P="$TEST_TEMP_DIR/plugins13"
  _mk() { mkdir -p "$P/tool/$1"; printf 'id: %s\nname: %s\nkind: tool\nversion: 0.0.1\n%s\nhooks:\n  run: %s_run\ninputs: []\noutputs: []\n' "$1" "$1" "$2" "$1" > "$P/tool/$1/manifest.yaml"; printf '%s_run() { return 0; }\n' "$1" > "$P/tool/$1/plugin.sh"; }
  _mk intake $'id_prefix: RQ\nlimit_id_prefix: LM'; _mk alpha 'id_prefix: LM'
  zb_id_prefixes_check "$P"; echo "LI13|rc=$?" ) > "$TEST_TEMP_DIR/li13.out" 2>&1
assert_contains "[LI13] a stage taking LM is refused" "$(cat "$TEST_TEMP_DIR/li13.out")" "rc=1"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
