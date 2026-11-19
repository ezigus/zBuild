#!/usr/bin/env bash
# tests/unit/issue-terms-test.sh — an issue's ## Terms section reaches every
# stage word for word (#2555, ADR-070).
#
# Why: on #1764 run 43772987273 the issue said "that run's progress comment
# (ADR-064)". Intake's requirement kept "the run's progress comment" and lost
# "(ADR-064)", which said which comment; design, which never sees the issue,
# defined it as a new comment, and the coverage check, with only design's
# definition, said "covered". A term the issue defines must travel with the
# requirements, untouched by a model.
#
# TM1 [change] an issue with a ## Terms section: intake's list holds the section
#              word for word, and no model call wrote it (the model's reply has
#              no terms at all)
# TM2 [guard]  an issue without one: no terms, and the list is as before
# TM3 [change] a list kept from an earlier run gets the terms too
# TM4 [change] design's prompt shows the terms
# TM5 [change] design's coverage check is shown the terms, and told a SPEC that
#              uses a term differently from its definition contradicts it
# TM7 [change] (review) the copy is word for word on any issue: a CRLF body
#             leaves no carriage return; a `#` line inside a code fence does not
#             end the section; `## Terms:` and `## TERMS` are read; a `## Terms`
#             inside a code fence elsewhere is not the section
# TM6 [change] test-author's and issue-acceptance's prompts show the terms
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
print_test_header "an issue's terms reach every stage word for word (#2555)"
setup_test_env "issue-terms"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
set +e

TERMS='- **Run-status comment:** the comment ADR-064 already posts for every run. Not a new comment.
- **Holder:** who has the claim: the run id and machine, or the CI run URL.'
ISSUE_JSON="$(jq -nc --arg t "$TERMS" '{title: "Claim an issue",
    body: ("## Decision\n\nClaim the issue.\n\n## Terms\n\n" + $t + "\n\n## Required behavior\n\n- **R1.** The run-status comment (ADR-064) names the holder.")}')"
PLAIN_JSON='{"title":"Claim an issue","body":"## Required behavior\n\n- **R1.** The run adds the label."}'
REPLY='REQUIREMENT: RQCLA-1 The run-status comment (ADR-064) names the holder.'

# _intake_list <out.json> <issue json> [prev list json] — the list intake's own
# writer builds, with only the model stubbed.
_intake_list() {
    ( export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR" _INTAKE_PREV_REQ_JSON="${3:-}"
      # shellcheck source=../../plugins/agent/intake/plugin.sh
      source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
      route_to_model() {
          if [[ "$2" == *"Your job: check a list of requirements"* ]]; then printf 'MISSING: none\n'
          else printf '%s\n' "$REPLY"; fi
      }
      local _j
      _intake_requirements_json_v _j "$2" && printf '%s\n' "$_j" > "$1" ) >/dev/null 2>&1
}

# ── TM1 / TM2 / TM3 ──────────────────────────────────────────────────────────
print_test_section "TM1-TM3: intake copies the Terms section"
REQ="$TEST_TEMP_DIR/requirements.json"
_intake_list "$REQ" "$ISSUE_JSON"
assert_eq "[TM1] the list holds the issue's Terms section, word for word" "$TERMS" "$(jq -r '.terms // empty' "$REQ" 2>/dev/null)"
assert_eq "[TM1] ...and the requirement is the model's" "RQCLA-1" "$(jq -r '.requirements[0].id // empty' "$REQ" 2>/dev/null)"
_intake_list "$TEST_TEMP_DIR/plain.json" "$PLAIN_JSON"
assert_eq "[TM2] an issue with no Terms section: no terms" "absent" "$(jq -r 'if has("terms") then "present" else "absent" end' "$TEST_TEMP_DIR/plain.json" 2>/dev/null)"
assert_eq "[TM2] ...and its requirements as before" "RQCLA-1" "$(jq -r '.requirements[0].id // empty' "$TEST_TEMP_DIR/plain.json" 2>/dev/null)"
# A list from an earlier run, for this same issue, made before terms existed.
_PREV="$(jq -c 'del(.terms)' "$REQ" 2>/dev/null)"
_intake_list "$TEST_TEMP_DIR/kept.json" "$ISSUE_JSON" "$_PREV"
assert_eq "[TM3] a list kept from an earlier run gets the terms too" "$TERMS" "$(jq -r '.terms // empty' "$TEST_TEMP_DIR/kept.json" 2>/dev/null)"
_rt=""; acceptance_terms_v _rt "$REQ"
assert_eq "[TM3] ...from the terms reader every stage uses" "$TERMS" "$_rt"
_rt=x; acceptance_terms_v _rt "$TEST_TEMP_DIR/plain.json"
assert_eq "[TM3] ...which reads nothing from a list with no terms" "" "$_rt"

# TM7: the same copy, on the shapes issues come in.
_terms_of() { ( source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1; local _t; _ireq_terms_v _t "$1"; printf '%s' "$_t" ); }
assert_eq "[TM7] a CRLF body leaves no carriage return" "- a: b"$'\n'"- c: d" "$(_terms_of $'## Terms\r\n\r\n- a: b\r\n- c: d\r\n\r\n## Next\r\n')"
assert_eq "[TM7] a # line inside a code fence does not end it" "- a: b"$'\n'"\`\`\`"$'\n'"# not a heading"$'\n'"\`\`\`"$'\n'"- c: d" \
    "$(_terms_of $'## Terms\n- a: b\n```\n# not a heading\n```\n- c: d\n## Next')"
assert_eq "[TM7] ## Terms: is read" "- a: b" "$(_terms_of $'## Terms:\n- a: b\n')"
assert_eq "[TM7] ## TERMS is read" "- a: b" "$(_terms_of $'## TERMS\n- a: b\n')"
assert_eq "[TM7] a ## Terms inside a code fence is not the section" "" "$(_terms_of $'```\n## Terms\n- a: b\n```\n')"

# ── TM4 ──────────────────────────────────────────────────────────────────────
print_test_section "TM4: design's prompt"
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
assert_contains "[TM4] design's prompt has the terms section" "$_dp" "### Terms from the issue — each means this, and only this"
assert_contains "[TM4] ...with each term as the issue wrote it" "$_dp" "the comment ADR-064 already posts for every run. Not a new comment."

# ── TM5 ──────────────────────────────────────────────────────────────────────
print_test_section "TM5: design's coverage check"
( source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
  route_to_model() { printf '%s' "$2" > "$TEST_TEMP_DIR/cov-prompt"; printf 'RQCLA-1: covered\nDSCLA-1: ok\n'; }
  printf '%s\n' '# Design' '```acceptance' \
      'DSCLA-1[code]: the run-status comment names the holder covers: RQCLA-1' 'WIRING: none' '```' > "$TEST_TEMP_DIR/d5.md"
  _design_coverage "$TEST_TEMP_DIR/d5.md" "$(acceptance_requirements_list "$REQ")" T2 "" "" "$(acceptance_terms_v _t5 "$REQ"; printf '%s' "$_t5")" ) >/dev/null 2>&1
_cp="$(cat "$TEST_TEMP_DIR/cov-prompt" 2>/dev/null)"
assert_contains "[TM5] the check is shown the terms" "$_cp" "the comment ADR-064 already posts for every run. Not a new comment."
assert_contains "[TM5] ...and told a part using a term differently contradicts it (#2567: any part)" "$_cp" \
    "a SPEC line, a step, the decisions — that uses a term differently from its definition contradicts it"

# ── TM6 ──────────────────────────────────────────────────────────────────────
print_test_section "TM6: test-author and issue-acceptance"
R="$TEST_TEMP_DIR/ta/repo"; TA="$TEST_TEMP_DIR/ta/state/artifacts"; mkdir -p "$R/tests" "$TA"
( cd "$R" && git init -q -b main . && git config user.email t@e.st && git config user.name t \
    && : > README && git add -A && git commit -q -m seed && git checkout -q -b work ) >/dev/null 2>&1
printf '{"schema_version":1}' > "$TEST_TEMP_DIR/ta/state/pipeline-state.json"
printf '%s\n' '# Design' '```acceptance' 'DSCLA-1[code]: the run-status comment names the holder covers: RQCLA-1' 'WIRING: none' '```' > "$TA/design.md"
cp "$REQ" "$TA/requirements.json"
( export ZBUILD_REPO_ROOT="$R" ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/ta/events.jsonl"
  # shellcheck source=../../plugins/agent/test-author/plugin.sh
  source "$REPO_ROOT/plugins/agent/test-author/plugin.sh" >/dev/null 2>&1
  route_to_model_loop() { cp "$2" "$TEST_TEMP_DIR/ta-prompt"; _ROUTE_LOOP_TERMINATED_REASON=done_sentinel; _ROUTE_LOOP_LAST_RESPONSE=LOOP_COMPLETE; return 0; }
  route_to_model() { zb_test_check_ok "$2"; }
  test_author_run test-author "$TEST_TEMP_DIR/ta/state/pipeline-state.json" ) >/dev/null 2>&1
assert_contains "[TM6] test-author's prompt shows the terms" "$(cat "$TEST_TEMP_DIR/ta-prompt" 2>/dev/null)" \
    "the comment ADR-064 already posts for every run. Not a new comment."

G="$TEST_TEMP_DIR/repo"; mkdir -p "$G/core"
( cd "$G" && git init -q -b main && git config user.email t@t && git config user.name t
  printf 'keep\n' > core/a.sh && git add -A && git commit -q -m base
  git checkout -q -b feature && printf 'keep\nmore\n' > core/a.sh && git commit -qam change ) >/dev/null 2>&1
S="$TEST_TEMP_DIR/ia"; A="$S/artifacts"; IN="$S/inputs"; mkdir -p "$A" "$IN"
printf '{}' > "$S/pipeline-state.json"
zb_test_issue_output "$IN" "Claim an issue." >/dev/null
printf '%s\n' '# Design' '```acceptance' 'DSCLA-1[code]: the comment names the holder covers: RQCLA-1' 'WIRING: none' '```' > "$IN/design.md"
zb_test_test_run_output "$IN" pass 1 0 >/dev/null
jq -n --arg i "$IN/intake-result.json" --arg r "$REQ" --arg d "$IN/design.md" --arg t "$IN/test-results.json" \
    '{inputs: {a: $i, b: $r, c: $d, d: $t}}' > "$S/stage-inputs.json"
( export ZBUILD_STAGE_INPUTS="$S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$A" ZBUILD_REPO_ROOT="$G"
  # shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
  source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh" >/dev/null 2>&1
  route_to_model() { printf '%s' "$2" > "$TEST_TEMP_DIR/ia-prompt"; printf 'MET: RQCLA-1\nUNASKED: none\n'; }
  cd "$G" && issue_acceptance_run issue-acceptance "$S/pipeline-state.json" ) >/dev/null 2>&1
assert_contains "[TM6] issue-acceptance's prompt shows the terms" "$(cat "$TEST_TEMP_DIR/ia-prompt" 2>/dev/null)" \
    "the comment ADR-064 already posts for every run. Not a new comment."

cleanup_test_env
print_test_results
exit $((FAIL > 0))
