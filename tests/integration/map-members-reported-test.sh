#!/usr/bin/env bash
# Integration: what each member of a map group did is on the run's status
# comment, and a group whose members did not all finish says so (ADR-064 §4,
# ADR-047 §2).
#
# Why: on #1801 and #1944 (2026-10-28) five of six review lenses ran out of
# time. The status comment had no row for any lens — a map member's events
# carried no seq, so no row opened — and nothing anywhere said the review was
# incomplete; the run read as clean.
#
# MR1 each member has its own row, named <group>.<element> (not an iteration)
# MR2 each member's row shows its own outcome
# MR3 each member's row shows what that member reported
# MR4 the group has a row saying how many members did not finish, and which
# MR5 the run's log says so too
# MR6 a group whose members all finished says that, and the log warns nothing
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "map members on the status comment; an incomplete group says so"
setup_test_env "map-members-reported"
export ZBUILD_CONTRACT_VALIDATOR=warn

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_CYCLES_ENABLED=0 ZBUILD_SCOPE_OVERRIDE=1
mkdir -p "$HOME/.zbuild"; printf 'bootstrap' > "$HOME/.zbuild/scope-override-token"

REPO="$(setup_git_temp_repo map-members-reported)"
mkdir -p "$REPO/.zbuild/templates"
cat > "$REPO/.zbuild/templates/map-rows.yaml" <<'EOF'
id: map-rows
extends: simple
flow:
  - lenses
lenses:
  type: map
  over: lenses
  elements: [alpha, beta]
  roles: [mock_lens]
  as: ZBUILD_REVIEW_LENS_ID
  max_parallel: 2
  on_member_error: continue
  aggregate: advisory
EOF
(cd "$REPO" && git add .zbuild && git commit -qm "map-rows template") >/dev/null 2>&1

# A lens stand-in: writes its result and its summary, as the review lens does.
# MOCK_BETA_OUTCOME says how beta ends.
_d="$PLUGINS_ROOT/agent/mock-lens"; mkdir -p "$_d"; fixture_link_personas "$PLUGINS_ROOT"
cat > "$_d/manifest.yaml" <<'EOF'
id: mock-lens
name: mock lens
kind: agent
version: 0.0.1
hooks:
  run: mock_lens_run
requires:
  core: [redaction]
provides:
  role: mock_lens
  result_contract: 3
outputs:
  - id: lens_result
    path: "${artifact_dir}/mock-${ZBUILD_REVIEW_LENS_ID}.json"
    type: mock-lens.json@1
    format: json
    required: true
    primary: true
  - id: lens_summary
    path: "${artifact_dir}/mock-${ZBUILD_REVIEW_LENS_ID}-summary.md"
    type: mock-lens-summary.md@1
    format: markdown
    required: true
    summary: true
EOF
cat > "$_d/plugin.sh" <<EOF
mock_lens_run() {
    local _art="\${ZBUILD_ARTIFACT_DIR:-\$(dirname "\$2")/artifacts}" _id="\$ZBUILD_REVIEW_LENS_ID"
    mkdir -p "\$_art"
    source "$REPO_ROOT/scripts/lib/stage-result.sh"
    local _o=pass _r="\$_id found nothing"
    [[ "\$_id" == beta ]] && { _o="\${MOCK_BETA_OUTCOME:-pass}"; _r="beta ended \$_o"; }
    stage_result_write "\$_art/mock-\$_id.json" "\$_o" "\$_r"
    printf '## mock %s — %s\n\n- %s reported this\n' "\$_id" "\$_o" "\$_id" > "\$_art/mock-\$_id-summary.md"
    return 0
}
EOF

source "$REPO_ROOT/scripts/lib/run-status-comment.sh"
export ZBUILD_STATUS_NOW=2026-10-29T12:00:00Z

# _run <case> — one run; leaves the status comment body and the run's log.
_run() {
    local c="$1"
    export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/$c/state" ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/$c/events"
    export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
    mkdir -p "$ZBUILD_STATE_DIR" "$ZBUILD_EVENTS_DIR"
    ( cd "$REPO" && timeout 120 bash "$RUNNER" --template map-rows --goal "map members $c" ) \
        > "$TEST_TEMP_DIR/$c.log" 2>&1 || true
    rsc_render_body "$ZBUILD_EVENTS_JSONL" "$ZBUILD_STATE_DIR" > "$TEST_TEMP_DIR/$c.body" 2>/dev/null || true
}
_row() { grep -F -- "$2" "$TEST_TEMP_DIR/$1.body" || true; }

# ─── one member does not finish ──────────────────────────────────────────────
MOCK_BETA_OUTCOME=timed_out _run incomplete

print_test_section "MR1: a row per member"
alpha="$(_row incomplete '1.1 lenses.alpha**')"
beta="$(_row incomplete '1.2 lenses.beta**')"
if [[ -n "$alpha" ]]; then assert_pass "[MR1] alpha has its own row"; else assert_fail "[MR1] alpha has its own row" "$(cat "$TEST_TEMP_DIR/incomplete.body")"; fi
if [[ -n "$beta" ]]; then assert_pass "[MR1] beta has its own row"; else assert_fail "[MR1] beta has its own row" "no '1.2 lenses.beta' row"; fi
assert_eq "[MR1] a member is not a loop's iteration" "0" "$(grep -c ' · iter ' <<< "$alpha$beta" || true)"

print_test_section "MR2: each row its own outcome"
assert_contains "[MR2] alpha's row: pass" "$alpha" "· **pass**"
assert_contains "[MR2] beta's row: timed_out" "$beta" "· **timed_out**"

print_test_section "MR3: each row what that member reported"
assert_contains "[MR3] alpha's row: alpha's summary" "$alpha" "alpha reported this"
assert_contains "[MR3] beta's row: beta's summary" "$beta" "beta reported this"

print_test_section "MR4: the group's row says the review is incomplete"
group="$(_row incomplete '**1 lenses**')"
assert_contains "[MR4] the group's row says how many did not finish, and which" \
    "$group" "1 of 2 lenses did not finish: beta (timed_out)"

print_test_section "MR5: the run's log says so"
assert_contains "[MR5] the log names the unfinished member" \
    "$(cat "$TEST_TEMP_DIR/incomplete.log")" "1 of 2 lenses did not finish: beta (timed_out)"

# ─── every member finishes ───────────────────────────────────────────────────
MOCK_BETA_OUTCOME=fail _run complete
print_test_section "MR6: a group whose members all finished"
assert_contains "[MR6] the group's row says all finished" \
    "$(_row complete '**1 lenses**')" "all 2 lenses finished"
assert_eq "[MR6] the log warns nothing" "0" \
    "$(grep -c 'did not finish' "$TEST_TEMP_DIR/complete.log" || true)"

print_test_results
exit $((FAIL > 0))
