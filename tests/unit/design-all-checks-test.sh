#!/usr/bin/env bash
# tests/unit/design-all-checks-test.sh — design runs every check each try and
# returns every finding at once (#2550, ADR-069).
#
# Why: on #1764 run 43735596812 try 2 failed design's numbering check, so its
# coverage check was not run; the gap it would have named (RQCLM-1) was first
# reported on try 3, the last. A try that returns one problem when there are
# two costs a whole try.
#
# C1 [change] a design that fails a script check is still sent to the coverage
#             check, and the try returns both findings
# C2 [change] when the coverage call cannot be run, the script findings are
#             still returned, the try is unusable (so it is run again), and its
#             result says coverage was not checked
# C3 [guard]  a design that passes every script check and whose coverage call
#             cannot be run still ends saying the coverage check could not run
# C4 [change] an issue whose items are all limits still gets the coverage
#             check, which is how a SPEC that builds one is caught (lens review)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "design returns every problem each try (#2550)"
setup_test_env "design-all-checks"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
set +e

# The requirement list, from intake's own writer with only the model stubbed.
REQ="$TEST_TEMP_DIR/requirements.json"
( export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR"
  # shellcheck source=../../plugins/agent/intake/plugin.sh
  source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
  route_to_model() {
      if [[ "$2" == *"Your job: check a list"* ]]; then printf 'MISSING: none\n'
      else printf 'REQUIREMENT: RQCLM-1 Add the claimed label.\nREQUIREMENT: RQHLD-1 Name the holder in the progress comment.\n'; fi
  }
  _j=""; _intake_requirements_json_v _j '{"title":"t","body":"Add the claimed label.\nName the holder in the progress comment."}' && printf '%s\n' "$_j" > "$REQ" ) >/dev/null 2>&1

FIX="$TEST_TEMP_DIR/fix"; ART="$FIX/state/artifacts"; mkdir -p "$ART"
git -C "$FIX" init -q >/dev/null 2>&1
printf 'scope: all\n' > "$FIX/state/scope-manifest.md"
jq -n --arg r "$REQ" '{inputs: {a: $r}}' > "$FIX/state/stage-inputs.json"

# _design <draft> <coverage reply|FAIL> — one design try: the design call writes
# <draft>; the coverage call answers <coverage reply>, or fails.
_design() {
    rm -f "$ART/design-verdict.json" "$ART"/*-judged.json "$TEST_TEMP_DIR/cov-called"
    ( source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
      export _DRAFT="$1" _COV="$2"
      route_to_model() {
          if [[ "$2" == *"covers what an ISSUE asked for"* ]]; then
              : > "$TEST_TEMP_DIR/cov-called"
              [[ "$_COV" == FAIL ]] && return 124
              printf '%s\n' "$_COV"; return 0
          fi
          local _t; _t="$(zb_test_prompt_write_path "$2")"
          [[ -n "$_t" ]] && { mkdir -p "$(dirname "$_t")"; printf '%s\n' "$_DRAFT" > "$_t"; }
          printf 'LOOP_COMPLETE\n'; return 0
      }
      _route_loop_close_final_banner() { return 0; }
      export ZBUILD_REPO_ROOT="$FIX" ZBUILD_STAGE_INPUTS="$FIX/state/stage-inputs.json"
      _design_stage_run_inner "$FIX/state/scope-manifest.md" "$ART/design.md" "$ART" ) >/dev/null 2>&1
}
_findings() { jq -r '[.data.findings[]?.text] | join("\n")' "$ART/design-verdict.json" 2>/dev/null; }

# A draft whose new SPEC is misnumbered (no design has passed: it must be
# DSHLD-1) and that covers RQCLM-1 only.
DRAFT='# Design
Decision: add the label.

```steps
- add the label | areas: core/pipeline/runner.sh
```

```acceptance
DSCLM-1[doc]: the label is added before the first stage covers: RQCLM-1
DSHLD-3[doc]: the holder is named covers: RQHLD-1
WIRING: none
```'
COV='RQCLM-1: covered
RQHLD-1: uncovered | WHY: no SPEC says the run id is named | QUOTE: Name the holder in the progress comment.
DSCLM-1: ok
DSHLD-3: ok'

# ── C1 ───────────────────────────────────────────────────────────────────────
print_test_section "C1: a failed script check does not hide the coverage check"
_design "$DRAFT" "$COV"
assert_eq "[C1] the coverage check was asked" "yes" "$([[ -e "$TEST_TEMP_DIR/cov-called" ]] && echo yes || echo no)"
_f="$(_findings)"
assert_contains "[C1] the try returns the script finding" "$_f" "DSHLD-3 is new"
assert_contains "[C1] ...and the coverage finding" "$_f" "RQHLD-1"
assert_eq "[C1] ...and is unusable, so it is run again" "unusable" "$(jq -r '.outcome' "$ART/design-verdict.json" 2>/dev/null)"

# ── C2 ───────────────────────────────────────────────────────────────────────
print_test_section "C2: a coverage call that cannot run keeps the script findings"
_design "$DRAFT" FAIL
_f="$(_findings)"
assert_contains "[C2] the script finding is returned" "$_f" "DSHLD-3 is new"
assert_contains "[C2] ...the result says coverage was not checked" "$_f" "coverage was not checked"
assert_eq "[C2] ...and the try is unusable" "unusable" "$(jq -r '.outcome' "$ART/design-verdict.json" 2>/dev/null)"

# ── C3 ───────────────────────────────────────────────────────────────────────
print_test_section "C3: a clean design whose coverage call cannot run"
CLEAN="${DRAFT//DSHLD-3/DSHLD-1}"
_design "$CLEAN" FAIL
assert_eq "[C3] it ends saying the coverage check could not run" "coverage_check_failed" \
    "$(jq -r '.reason' "$ART/design-verdict.json" 2>/dev/null)"

# ── C4 ───────────────────────────────────────────────────────────────────────
print_test_section "C4: limits and no requirement"
( export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR"
  source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
  route_to_model() {
      if [[ "$2" == *"Your job: check a list"* ]]; then printf 'MISSING: none\n'
      else printf 'LIMIT: RQNCI-1 Do not build a CI status check.\n'; fi
  }
  _j=""; _intake_requirements_json_v _j '{"title":"t","body":"Do not build a CI status check."}' && printf '%s\n' "$_j" > "$REQ" ) >/dev/null 2>&1
_design "${CLEAN//covers: RQCLM-1/}" 'DSCLM-1: ok
DSHLD-1: ok'
assert_eq "[C4] the coverage check was asked" "yes" "$([[ -e "$TEST_TEMP_DIR/cov-called" ]] && echo yes || echo no)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
