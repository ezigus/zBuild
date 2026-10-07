#!/usr/bin/env bash
# tests/unit/earlier-run-reference-test.sh — an input served from an earlier
# run's saved work is marked as that run's, for reference only, and a stage that
# judges results never counts it as this run's (ADR-050 §8, #2326).
#
# hydrate restores the earlier run's artifacts into ZBUILD_RESTORED_ARTIFACTS_DIR.
# A declared input with no copy from this run falls back to that copy (#2095
# keeps the fallback for hand-overs). Until #2326 nothing said so: the index,
# the prompt block and the events recorded it like any other input, and
# review-aggregator would count a lens's verdict from last run for a lens that
# wrote nothing this run.
#
#   E1 [change] the index marks an input served from an earlier run's copy;
#               an input served from this run is not marked
#   E2 [change] the prompt's input block labels that path "from an earlier run —
#               reference only, not this run's result"; this run's path is not
#   E3 [change] the input event records that the input came from an earlier run
#   E4 [change] a stage that judges results (convergence: gate, or aggregates:)
#               treats an input that exists only as an earlier run's copy as
#               missing: an optional one is not handed over, a required one
#               refuses the dispatch, and review-aggregator does not count a
#               restored lens verdict
#   E5 [guard]  a stage that does not judge still reads the earlier copy (#2095)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"

print_test_header "an earlier run's work is labelled and never counted as this run's (#2326)"
setup_test_env "earlier-run-reference"

unset ZBUILD_STAGE_INPUTS ZBUILD_INPUTS_FLOW 2>/dev/null || true
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR ZBUILD_RESTORED_ARTIFACTS_DIR 2>/dev/null || true

STATE="$TEST_TEMP_DIR/state"
ART="$STATE/artifacts"
RESTORED="$STATE/restored-artifacts/artifacts"
PROOT="$TEST_TEMP_DIR/plugins"
EVENTS="$TEST_TEMP_DIR/events.jsonl"
mkdir -p "$ART" "$RESTORED"
for _p in er-producer er-consumer er-gate er-gate-req er-lenses; do mkdir -p "$PROOT/tool/$_p"; done

# ─── Fixtures ───────────────────────────────────────────────────────────────
# Two producers' outputs: one written this run, one only in the earlier run.
cat > "$PROOT/tool/er-producer/manifest.yaml" <<'EOF'
id: er-producer
name: Earlier-run Producer
kind: tool
version: 0.0.1
hooks:
  run: erp_run
inputs: []
outputs:
  - id: fresh_doc
    path: ${artifact_dir}/fresh-doc.md
    type: markdown
    required: true
    primary: true
  - id: old_doc
    path: ${artifact_dir}/old-doc.md
    type: markdown
    required: false
EOF
printf 'erp_run() { return 0; }\n' > "$PROOT/tool/er-producer/plugin.sh"

# A consumer that does not judge: reads what the index names.
_consumer_manifest() {   # <id> <run_fn> <extra top-level line> <old_doc required>
    cat <<EOF
id: $1
name: Earlier-run consumer $1
kind: tool
version: 0.0.1
$3
hooks:
  run: $2
inputs:
  - id: fresh_doc
    required: true
  - id: old_doc
    required: $4
outputs:
  - id: ${1//-/_}_out
    path: \${artifact_dir}/$1-out.json
    type: json
    required: true
    primary: true
EOF
}
_consumer_plugin() {   # <id> <run_fn>
    printf '_ER_SEEN=%q\n' "$TEST_TEMP_DIR/$1-seen.txt"
    cat <<EOF
$2() {
    printf '{"verdict":"pass"}\n' > "\${ZBUILD_STATE_DIR:?}/artifacts/$1-out.json"
    local p; p="\$(jq -r '.inputs.old_doc // empty' "\$ZBUILD_STAGE_INPUTS" 2>/dev/null)"
    { printf 'path=%s\n' "\${p:-<none>}"
      printf 'body=%s\n' "\$( [[ -n "\$p" && -s "\$p" ]] && cat "\$p" || echo '<unreadable>' )"; } > "\$_ER_SEEN"
    return 0
}
EOF
}
_consumer_manifest er-consumer erc_run "convergence: advisory" false > "$PROOT/tool/er-consumer/manifest.yaml"
_consumer_plugin   er-consumer erc_run > "$PROOT/tool/er-consumer/plugin.sh"
_consumer_manifest er-gate ergt_run "convergence: gate" false > "$PROOT/tool/er-gate/manifest.yaml"
_consumer_plugin   er-gate ergt_run > "$PROOT/tool/er-gate/plugin.sh"
_consumer_manifest er-gate-req ergr_run "convergence: gate" true > "$PROOT/tool/er-gate-req/manifest.yaml"
_consumer_plugin   er-gate-req ergr_run > "$PROOT/tool/er-gate-req/plugin.sh"

# A map producer of lens results, consumed by the REAL review-aggregator manifest.
cat > "$PROOT/tool/er-lenses/manifest.yaml" <<'EOF'
id: er-lenses
name: Earlier-run lenses
kind: tool
version: 0.0.1
hooks:
  run: erl_run
inputs: []
outputs:
  - id: lens_result
    path: ${artifact_dir}/lens-${ER_LENS_ID}.json
    type: json
    required: true
    primary: true
EOF
printf 'erl_run() { return 0; }\n' > "$PROOT/tool/er-lenses/plugin.sh"
export _TPL_STAGE_TYPE_er_lenses="map"
export _TPL_MAP_AS_er_lenses="ER_LENS_ID"
export _TPL_MAP_ELEMENTS_er_lenses="x,y"

_TPL_STAGES=(er-producer er-consumer er-gate er-gate-req er-lenses)

printf 'FRESH-BODY written by this run\n'  > "$ART/fresh-doc.md"
printf 'OLD-BODY saved by the earlier run\n' > "$RESTORED/old-doc.md"
# The earlier run also saved a fresh-doc; this run's own copy must win and stay unmarked.
printf 'STALE fresh-doc from the earlier run\n' > "$RESTORED/fresh-doc.md"

_dispatch() {   # <stage>
    rm -f "$TEST_TEMP_DIR/$1-seen.txt" "$STATE/stage-inputs/$1.json"
    ZBUILD_EVENTS_JSONL="$EVENTS" ZBUILD_EVENTS_DB=/dev/null \
    ZBUILD_STATE_DIR="$STATE" ZBUILD_RESTORED_ARTIFACTS_DIR="$RESTORED" \
        plugin_hook_call "$PROOT/tool/$1" run "$1" "$STATE/pipeline-state.json"
}
_refute_contains() {   # <label> <haystack> <needle>
    if grep -qF -- "$3" <<< "$2"; then assert_fail "$1" "found: $3"; else assert_pass "$1"; fi
}
_seen() { grep "^$2=" "$TEST_TEMP_DIR/$1-seen.txt" 2>/dev/null | cut -d= -f2-; }
_index() { printf '%s' "$STATE/stage-inputs/$1.json"; }

# ─── E1: the index marks the earlier run's copy ─────────────────────────────
print_test_section "E1. the input index marks an input served from an earlier run"
: > "$EVENTS"
_dispatch er-consumer >/dev/null 2>"$TEST_TEMP_DIR/e1.err"
_rc=$?
if [[ "$_rc" -eq 0 ]]; then
    assert_pass "[E1] the dispatch succeeded"
else
    assert_fail "[E1] the dispatch succeeded" "rc=$_rc; $(tail -c 400 "$TEST_TEMP_DIR/e1.err" 2>/dev/null)"
fi
assert_eq "[E1] old_doc is served from the earlier run's copy (precondition)" \
    "$RESTORED/old-doc.md" "$(jq -r '.inputs.old_doc // empty' "$(_index er-consumer)" 2>/dev/null)"
assert_eq "[E1] the index marks old_doc as from an earlier run" \
    "$RESTORED/old-doc.md" \
    "$(jq -r '(.earlier_run // [])[]' "$(_index er-consumer)" 2>/dev/null)"
assert_eq "[E1] fresh_doc is this run's copy, and is not marked" \
    "false" "$(jq --arg p "$ART/fresh-doc.md" '(.earlier_run // []) | index($p) != null' "$(_index er-consumer)" 2>/dev/null)"

# ─── E2: the prompt block labels it ─────────────────────────────────────────
print_test_section "E2. the prompt's input block labels the earlier run's copy"
_block="$(stage_inputs_prompt_block "$(_index er-consumer)")"
_old_line="$(grep -F "$RESTORED/old-doc.md" <<< "$_block")"
_fresh_line="$(grep -F "$ART/fresh-doc.md" <<< "$_block")"
assert_contains "[E2] the earlier run's path is labelled" "$_old_line" \
    "from an earlier run — reference only, not this run's result"
_refute_contains "[E2] this run's path is not labelled" "$_fresh_line" "earlier run"

# ─── E3: the input event records it ─────────────────────────────────────────
print_test_section "E3. the input event records that the input came from an earlier run"
_ev="$(jq -c 'select(.type == "stage.input.earlier_run")' "$EVENTS" 2>/dev/null)"
assert_contains "[E3] a stage.input.earlier_run event names the input" "$_ev" '"input":"old_doc"'
assert_contains "[E3] ...and the stage" "$_ev" '"stage":"er-consumer"'
_refute_contains "[E3] no such event for this run's input" "$_ev" '"input":"fresh_doc"'
assert_eq "[E3] the event type is a known engine event" "true" \
    "$(jq '.known_types | index("stage.input.earlier_run") != null' "$REPO_ROOT/config/event-schema.json")"

# ─── E4: a stage that judges results does not count it ──────────────────────
print_test_section "E4. a stage that judges results treats an earlier run's copy as missing"
: > "$EVENTS"
_dispatch er-gate >/dev/null 2>&1
_g="$(jq -r '.inputs.old_doc // empty' "$(_index er-gate)" 2>/dev/null)"
if [[ "$_g" == "$RESTORED/"* ]]; then
    assert_fail "[E4] a gate is not handed the earlier run's copy" "index names $_g"
else
    assert_pass "[E4] a gate is not handed the earlier run's copy"
fi
# "Missing" means what it means for any input this run has not written: the
# index names this run's own path, and no file is there.
assert_eq "[E4] ...it is given this run's own path, as for any input not yet written" \
    "$ART/old-doc.md" "$_g"
if [[ ! -e "$ART/old-doc.md" ]]; then
    assert_pass "[E4] ...and no file is there"
else
    assert_fail "[E4] ...and no file is there" "$ART/old-doc.md exists"
fi
assert_eq "[E4] ...so the gate reads no body for it" "<unreadable>" "$(_seen er-gate body)"
assert_eq "[E4] ...and its own input is still this run's" \
    "$ART/fresh-doc.md" "$(jq -r '.inputs.fresh_doc // empty' "$(_index er-gate)" 2>/dev/null)"

_dispatch er-gate-req >/dev/null 2>"$TEST_TEMP_DIR/e4.err"
_rc=$?
if [[ "$_rc" -ne 0 ]]; then
    assert_pass "[E4] a gate whose required input exists only from an earlier run is not launched (rc=$_rc)"
else
    assert_fail "[E4] a gate whose required input exists only from an earlier run is not launched" "rc=0"
fi
assert_contains "[E4] ...with the INPUT_MISSING code" "$(cat "$TEST_TEMP_DIR/e4.err" 2>/dev/null)" "INPUT_MISSING"

# review-aggregator: lens-x exists only from the earlier run, lens-y from this run.
printf '{"name":"x","score":2,"findings":[{"file":"a.sh","category":"c","severity":"critical","message":"STALE-X"}]}\n' \
    > "$RESTORED/lens-x.json"
printf '{"name":"y","score":9,"findings":[]}\n' > "$ART/lens-y.json"
RA_IDX="$(ZBUILD_EVENTS_JSONL="$EVENTS" ZBUILD_EVENTS_DB=/dev/null ZBUILD_RESTORED_ARTIFACTS_DIR="$RESTORED" \
    _inputs_resolve_stage review-aggregator "$PROOT" "$STATE" \
    "$REPO_ROOT/plugins/agent/review-aggregator/manifest.yaml" 2>/dev/null)"
assert_file_exists "[E4] review-aggregator's index is written" "${RA_IDX:-/nonexistent}"
RA_OUT="$TEST_TEMP_DIR/ra"; mkdir -p "$RA_OUT"
( source "$REPO_ROOT/plugins/agent/review-aggregator/plugin.sh" >/dev/null 2>&1
  emit_event() { :; }; eb_emit_event() { :; }
  ZBUILD_STAGE_INPUTS="$RA_IDX" _review_aggregator_run_inner "$RA_OUT" "$RA_OUT/report.json" "$RA_OUT/report.md" ) \
    >/dev/null 2>&1 || true
assert_eq "[E4] review-aggregator counts only this run's lens (lens-x's restored verdict is not counted)" \
    '["y"]' "$(jq -c '[.lenses[].name]' "$RA_OUT/report.json" 2>/dev/null)"
_refute_contains "[E4] ...and none of lens-x's findings" "$(cat "$RA_OUT/report.json" 2>/dev/null)" "STALE-X"

# ─── E5: hand-overs that do not judge still read the earlier copy ───────────
print_test_section "E5. a stage that does not judge still reads the earlier run's copy (#2095)"
assert_contains "[E5] the consumer read the earlier run's body" "$(_seen er-consumer body)" "OLD-BODY"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
