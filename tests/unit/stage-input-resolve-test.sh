#!/usr/bin/env bash
# tests/unit/stage-input-resolve-test.sh — the engine resolves declared inputs
# and hands them to `run` (#1826/#1894, ADR-055 §1 / ADR-054 §2).
#
# Every input declaration was inert before this: manifest_graph_get_inputs had
# four call sites, all static validators, so 25 of 37 plugin.sh files hardcoded
# artifact filenames instead.
#
#   1 [change] a plugin reads a declared input without knowing where it lives
#   2 [change] a missing output does not stop a stage: it is launched, and its
#              index simply has no entry for it (ADR-055, amended — a missing
#              prerequisite is the stage's own check)
#   3 [retired] the refusal that named producer, output id and consumer
#   4 [change] a `map` producer yields a JSON ARRAY of member paths (§1.4)
#   5 [change] ${stage_io_dir}/${run_id} interpolate; ${cycle_feedback_dir} is retired
#   6 [guard]  flag off (default) writes nothing and leaves the var unset
#   7 [guard]  role-resolved stages resolve to the manifest DISPATCH would use
#   8 [retired] the router's STAGE INPUTS block — the engine's Previous work
#              carries the paths now (stage-prompt-contract-test)
#   9 [change] a damaged output is left out of the index and announced, and the
#              stage is still launched
#  10 [change] an OPTIONAL damaged input is OMITTED and announced
#  11 [guard]  the refusal is NON-RETRYABLE — no retry storm under #1887
#  12 [change] a damaged MAP member is excluded, not carried by its siblings
#
# 515 lines, over CLAUDE.md's 500 guideline, deliberately: 166 of them are one
# shared fixture (three plugin manifests, a generated consumer, the template-flow
# globals and the dispatch helper) that all twelve specs run against. Splitting
# the 122 lines of damage specs into a sibling file would duplicate that fixture
# or need a new shared helper — 166 lines of duplication to save 15.
#
# shellcheck disable=SC2016  # SPEC-5 passes literal ${var} text as the INPUT under test
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

print_test_header "stage input resolution — declared inputs become paths (#1826)"
setup_test_env "stage-input-resolve"

unset ZBUILD_INPUTS_RESOLVE ZBUILD_STAGE_INPUTS ZBUILD_INPUTS_FLOW 2>/dev/null || true
# The consumer declares a REQUIRED external gh_issue_body. Since ADR-055 §3's
# pre-dispatch check, an unsupplied one refuses the stage — so this run supplies
# it, as a real --issue run does (input-resolve-external-test.sh owns the refusal).
ZBUILD_ISSUE="$(zb_test_issue)"; export ZBUILD_ISSUE
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR ZBUILD_RESTORED_ARTIFACTS_DIR 2>/dev/null || true

STATE="$TEST_TEMP_DIR/state"
ART="$STATE/artifacts"
PROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$ART" "$PROOT/tool/ir-producer" "$PROOT/tool/ir-consumer" "$PROOT/agent/ir-lens"

# ─── Fixtures ────────────────────────────────────────────────────────────────
# The consumer's ONLY knowledge of its inputs is their NAMES. It never states a
# path, and its plugin.sh never states a filename — that is the whole claim.
cat > "$PROOT/tool/ir-producer/manifest.yaml" <<'EOF'
id: ir-producer
name: Input Resolve Producer
kind: tool
version: 0.0.1
hooks:
  run: irp_run
inputs: []
outputs:
  - id: producer_out
    path: ${artifact_dir}/producer-out.json
    type: json
    required: true
    primary: true
  - id: producer_hint
    path: ${artifact_dir}/producer-hint.json
    type: json
    required: false
EOF
printf 'irp_run() { return 0; }\n' > "$PROOT/tool/ir-producer/plugin.sh"

cat > "$PROOT/agent/ir-lens/manifest.yaml" <<'EOF'
id: ir-lens
name: Input Resolve Lens
kind: agent
version: 0.0.1
hooks:
  run: irl_run
provides:
  role: ir_lens
inputs: []
outputs:
  - id: ir_lens_result
    path: ${artifact_dir}/irlens-${IR_LENS_ID}.json
    type: json
    required: true
    primary: true
EOF
printf 'irl_run() { return 0; }\n' > "$PROOT/agent/ir-lens/plugin.sh"

cat > "$PROOT/tool/ir-consumer/manifest.yaml" <<'EOF'
id: ir-consumer
name: Input Resolve Consumer
kind: tool
version: 0.0.1
hooks:
  run: irc_run
inputs:
  - id: producer_out
    required: true
  - id: ir_lens_result
    required: false
  - id: producer_hint
    required: false
  - id: gh_issue_body
    source: external
    required: true
outputs:
  - id: consumer_out
    path: ${artifact_dir}/consumer-out.json
    type: json
    required: true
    primary: true
EOF

# The entrypoint writes a SENTINEL first: SPEC-2 asserts on its absence, which
# separates "the run failed" from "the stage was never launched".
{
    printf '_IRC_SENTINEL=%q\n' "$TEST_TEMP_DIR/irc-ran.txt"
    printf '_IRC_OUT=%q\n' "$TEST_TEMP_DIR/irc-seen.txt"
    cat <<'FIXTURE'
irc_run() {
    printf 'ran\n' > "$_IRC_SENTINEL"
    # Its own declared `required: true` output — absent, scan_plugin_outputs
    # (#1803) fails the dispatch and every rc assertion below tests that instead.
    printf '{"verdict":"pass"}\n' > "${ZBUILD_STATE_DIR:?}/artifacts/consumer-out.json"
    {
        printf 'index=%s\n' "${ZBUILD_STAGE_INPUTS-<unset>}"
        _p=""
        if [[ -n "${ZBUILD_STAGE_INPUTS:-}" && -s "${ZBUILD_STAGE_INPUTS:-}" ]]; then
            _p="$(jq -r '.inputs.producer_out // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null)"
        fi
        printf 'producer_out=%s\n' "${_p:-<none>}"
        printf 'body=%s\n' "$( [[ -n "$_p" && -s "$_p" ]] && cat "$_p" || echo '<unreadable>' )"
    } > "$_IRC_OUT"
    return 0
}
FIXTURE
} > "$PROOT/tool/ir-consumer/plugin.sh"

# The flow the engine resolved. _TPL_STAGES is what load_template populates; the
# map group's attrs are the vars template.sh exports for a `type: map` unit.
_TPL_STAGES=(ir-producer ir_lenses ir-consumer)
export _TPL_STAGE_TYPE_ir_lenses="map"
export _TPL_MAP_AS_ir_lenses="IR_LENS_ID"
export _TPL_MAP_ELEMENTS_ir_lenses="alpha,beta"
export _TPL_STAGE_ROLES_ir_lenses="ir_lens"

CONSUMER_DIR="$PROOT/tool/ir-consumer"
EVENTS="$TEST_TEMP_DIR/events.jsonl"

_dispatch_consumer() {
    local _old_j="${ZBUILD_EVENTS_JSONL:-}" _old_d="${ZBUILD_EVENTS_DB:-}"
    ZBUILD_EVENTS_JSONL="$EVENTS"; ZBUILD_EVENTS_DB="/dev/null"
    export ZBUILD_EVENTS_JSONL ZBUILD_EVENTS_DB
    plugin_hook_call "$CONSUMER_DIR" run "ir-consumer" "$STATE/pipeline-state.json"
    local rc=$?
    ZBUILD_EVENTS_JSONL="$_old_j"; ZBUILD_EVENTS_DB="$_old_d"
    return $rc
}

_seen() { grep "^$1=" "$TEST_TEMP_DIR/irc-seen.txt" 2>/dev/null | head -1 | cut -d= -f2-; }

# ─── SPEC-1: the plugin finds a path it was never told ──────────────────────
print_test_section "1. a plugin reads a declared input without knowing where it lives"
printf '{"marker":"PRODUCER-BODY-1826"}\n' > "$ART/producer-out.json"
printf '{"lens":"alpha"}\n' > "$ART/irlens-alpha.json"
printf '{"lens":"beta"}\n'  > "$ART/irlens-beta.json"
rm -f "$TEST_TEMP_DIR/irc-ran.txt" "$TEST_TEMP_DIR/irc-seen.txt"

_disp_err="$TEST_TEMP_DIR/dispatch1-stderr.txt"
ZBUILD_INPUTS_RESOLVE=1 ZBUILD_STATE_DIR="$STATE" _dispatch_consumer >/dev/null 2>"$_disp_err"
_rc1=$?

# A bare rc comparison here reports "expected 0, got 1" and nothing else, which
# is useless when the dispatch is refused by a check that already explained
# itself on stderr. Carry that explanation into the failure detail.
if [[ "$_rc1" -eq 0 ]]; then
    assert_pass "[SPEC-1] the dispatch succeeded"
else
    assert_fail "[SPEC-1] the dispatch succeeded" \
        "rc=$_rc1; stderr: $(tr '\n' ' ' < "$_disp_err" 2>/dev/null | tail -c 400)"
fi
assert_file_exists "[SPEC-1] the index was written" "$STATE/stage-inputs/ir-consumer.json"
assert_eq "[SPEC-1] the plugin saw ZBUILD_STAGE_INPUTS" \
    "$STATE/stage-inputs/ir-consumer.json" "$(_seen index)"
assert_eq "[SPEC-1] and resolved producer_out to the producer's declared path" \
    "$ART/producer-out.json" "$(_seen producer_out)"
# The payload proves the path was USABLE, not merely well-formed.
assert_contains "[SPEC-1] the plugin read the producer's artifact through it" \
    "$(_seen body)" "PRODUCER-BODY-1826"
# [guard] the plugin.sh must not contain the filename it resolved — otherwise the
# assertion above passes on a hardcoded read and proves nothing.
if grep -qF 'producer-out.json' "$CONSUMER_DIR/plugin.sh"; then
    assert_fail "[SPEC-1] the consumer names no artifact filename of its own" \
        "plugin.sh hardcodes producer-out.json — the index is not what found it"
else
    assert_pass "[SPEC-1] the consumer names no artifact filename of its own"
fi
# [guard] an `external` input has no producer and no path; it must not appear.
if jq -e '.inputs | has("gh_issue_body")' "$STATE/stage-inputs/ir-consumer.json" >/dev/null 2>&1; then
    assert_fail "[SPEC-1] an external input is not indexed" "gh_issue_body got a path"
else
    assert_pass "[SPEC-1] an external input is not indexed"
fi
assert_eq "[SPEC-1] the index declares its schema_version" "2" \
    "$(jq -r '.schema_version' "$STATE/stage-inputs/ir-consumer.json")"

# ─── SPEC-4: a map producer yields an ARRAY under one id ────────────────────
print_test_section "4. a map producer yields a JSON array of member paths"
_lens_type="$(jq -r '.inputs.ir_lens_result | type' "$STATE/stage-inputs/ir-consumer.json")"
assert_eq "[SPEC-4] ir_lens_result is a JSON array" "array" "$_lens_type"
assert_eq "[SPEC-4] one entry per map element" "2" \
    "$(jq -r '.inputs.ir_lens_result | length' "$STATE/stage-inputs/ir-consumer.json")"
assert_eq "[SPEC-4] the group's 'as:' var is substituted per element" \
    "$ART/irlens-alpha.json $ART/irlens-beta.json" \
    "$(jq -r '.inputs.ir_lens_result | join(" ")' "$STATE/stage-inputs/ir-consumer.json")"
# [guard] a non-map producer stays a scalar — an array everywhere would satisfy
# the assertions above while breaking every single-artifact consumer.
assert_eq "[SPEC-4] a leaf producer's input stays a scalar string" "string" \
    "$(jq -r '.inputs.producer_out | type' "$STATE/stage-inputs/ir-consumer.json")"

# ─── SPEC-2 / SPEC-3: the pre-dispatch refusal ──────────────────────────────
print_test_section "2. a missing output does not stop the stage"
rm -f "$ART/producer-out.json" "$TEST_TEMP_DIR/irc-ran.txt" "$TEST_TEMP_DIR/irc-seen.txt"
rm -f "$STATE/stage-inputs/ir-consumer.json"
ZBUILD_STATE_DIR="$STATE" _dispatch_consumer >/dev/null 2>&1
_rc2=$?
assert_eq "[SPEC-2] the stage is launched (rc=0)" "0" "$_rc2"
assert_file_exists "[SPEC-2] its own entrypoint ran" "$TEST_TEMP_DIR/irc-ran.txt"
assert_eq "[SPEC-2] and the index has no entry for the missing output" "<none>" "$(_seen producer_out)"
printf '{"marker":"BACK"}\n' > "$ART/producer-out.json"

# ─── SPEC-5: the canonical templating vars ──────────────────────────────────
print_test_section "5. the canonical templating vars interpolate"
# ${stage_io_dir} is in manifest_graph_canonical_vars and ADR-055 §2, and had NO
# resolver anywhere in the tree before this change.
assert_eq "[SPEC-5] \${stage_io_dir} resolves to state_dir/artifacts/stage-io" \
    "$STATE/artifacts/stage-io/x.json" \
    "$(_verdict_resolve_path '${stage_io_dir}/x.json' "$STATE")"
# ADR-068 §8: the engine writes no feedback copy, so ${cycle_feedback_dir} names
# nothing and is no longer a canonical var.
if grep -qw 'cycle_feedback_dir' <<< "$(manifest_graph_canonical_vars)"; then
    assert_fail "[SPEC-5] \${cycle_feedback_dir} is not a canonical var" "listed"
else
    assert_pass "[SPEC-5] \${cycle_feedback_dir} is not a canonical var"
fi
assert_eq "[SPEC-5] \${run_id} resolves to ZBUILD_RUN_ID" \
    "$STATE/runs/run-42/x" \
    "$(ZBUILD_RUN_ID=run-42 _verdict_resolve_path '${state_dir}/runs/${run_id}/x' "$STATE")"
# [guard] run_id is interpolated into a filesystem path — a traversal attempt is
# sanitized, not passed through.
assert_eq "[SPEC-5-guard] a traversing run_id is sanitized" \
    "$STATE/runs/.._.._etc/x" \
    "$(ZBUILD_RUN_ID='../../etc' _verdict_resolve_path '${state_dir}/runs/${run_id}/x' "$STATE")"
# [guard] the pre-existing three still resolve — this helper has two other callers.
assert_eq "[SPEC-5-guard] \${artifact_dir} is unchanged" "$ART/a.md" \
    "$(_verdict_resolve_path '${artifact_dir}/a.md' "$STATE")"
assert_eq "[SPEC-5-guard] a relative path still anchors under state_dir" "$STATE/rel.md" \
    "$(_verdict_resolve_path 'rel.md' "$STATE")"

# ─── SPEC-6: resolution is unconditional, and does not leak ─────────────────
# #1825 deleted ZBUILD_INPUTS_RESOLVE. #1826 shipped behind it so the engine
# could land inert, but an inert flag that stays inert is the pattern Phase 0
# exists to end. What still matters — and is what this spec now pins — is that
# the index is scoped to ONE dispatch: `local -x` at plugin_hook_call means
# stage N's index cannot bleed into stage N+1.
print_test_section "6. resolution is unconditional and scoped to one dispatch"
rm -rf "$STATE/stage-inputs"
rm -f "$TEST_TEMP_DIR/irc-ran.txt" "$TEST_TEMP_DIR/irc-seen.txt"
ZBUILD_STATE_DIR="$STATE" _dispatch_consumer >/dev/null 2>&1
_rc6=$?
assert_eq "[SPEC-6] the dispatch succeeds with no flag set" "0" "$_rc6"
assert_eq "[SPEC-6] the stage ran" "ran" "$(cat "$TEST_TEMP_DIR/irc-ran.txt" 2>/dev/null || true)"
if [[ -d "$STATE/stage-inputs" ]]; then
    assert_pass "[SPEC-6] the index is written with no flag set"
else
    assert_fail "[SPEC-6] the index is written with no flag set" "no stage-inputs dir — resolution did not run"
fi
# [guard] and it stays unset in the CALLER after the dispatch (`local -x`).
if [[ -v ZBUILD_STAGE_INPUTS ]]; then
    assert_fail "[SPEC-6] ZBUILD_STAGE_INPUTS does not leak into the caller" "still set after return"
else
    assert_pass "[SPEC-6] ZBUILD_STAGE_INPUTS does not leak into the caller"
fi

# ─── SPEC-7: role-resolved stages, against the LIVE template ────────────────
print_test_section "7. role-resolved stages resolve to the dispatch manifest"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
if load_template "$REPO_ROOT/config/templates/simple.yaml" >/dev/null 2>&1; then
    _m() { basename "$(dirname "$(_inputs_stage_manifest "$1" "$REPO_ROOT/plugins" 2>/dev/null || echo /none/none)")"; }
    _c() { local p; p="$(manifest_graph_collect "$REPO_ROOT/plugins" "$1" 2>/dev/null || true)"; \
           [[ -n "$p" ]] && basename "$(dirname "$p")" || echo "<none>"; }

    # The gap: contract-validator.sh:213's id-only collect skips these two
    # entirely and lands `pr` on pr-open, documented as unreachable at dispatch.
    assert_eq "[SPEC-7-baseline] id-only finds no manifest for review_lenses"   "<none>" "$(_c review_lenses)"
    assert_eq "[SPEC-7-baseline] id-only resolves pr to the unreachable pr-open" "pr-open" "$(_c pr)"

    # #2372: acceptance-gate is no longer a stage (test runs the check).
    assert_eq "[SPEC-7] review_lenses resolves to review-lens"       "review-lens"     "$(_m review_lenses)"
    assert_eq "[SPEC-7] pr resolves to pr-delivery, not pr-open"     "pr-delivery"     "$(_m pr)"
    # [guard] the id-matching majority is unchanged.
    assert_eq "[SPEC-7-guard] intake still resolves to intake" "intake" "$(_m intake)"
    assert_eq "[SPEC-7-guard] plan still resolves to plan" \
        "plan" "$(_m plan)"
else
    assert_fail "[SPEC-7] simple.yaml loads" "load_template failed"
fi

# ─── SPEC-8: the prompt literal for agent stages ────────────────────────────
# ZBUILD_STAGE_INPUTS cannot reach a model (env-scrub.sh unsets ZBUILD_* before
# every claude spawn, ADR-024/#671), so paths go into the prompt as literal text
# at _route_redact_prompt — before apply_scope_redaction, riding the ADR-004
# chokepoint rather than bypassing it.
# ─── SPEC-9: a damaged output is left out, and the stage still runs ──────────
print_test_section "9. a damaged output is left out of the index"
# SPEC-7 leaves _TPL_STAGES holding the LIVE template's flow, and the producer
# index is keyed on it — without restoring the fixture flow every input below
# resolves to zero producers and passes for the wrong reason.
_TPL_STAGES=(ir-producer ir_lenses ir-consumer)
rm -f "$TEST_TEMP_DIR/irc-ran.txt" "$STATE/stage-inputs/ir-consumer.json"
# Non-zero but invalid JSON: the half-written file that passes -s today.
printf '{"verdict":' > "$ART/producer-out.json"

: > "$EVENTS"
ZBUILD_STATE_DIR="$STATE" _dispatch_consumer >/dev/null 2>&1
_rc9=$?
assert_eq "[SPEC-9] the stage is still launched (rc=0)" "0" "$_rc9"
if jq -e '.inputs | has("producer_out")' "$STATE/stage-inputs/ir-consumer.json" >/dev/null 2>&1; then
    assert_fail "[SPEC-9] the damaged output is left out of the index" "producer_out was handed over"
else
    assert_pass "[SPEC-9] the damaged output is left out of the index"
fi
assert_contains "[SPEC-9] the omission is announced" "$(cat "$EVENTS" 2>/dev/null)" "stage.input.degraded"

# ─── SPEC-10: an OPTIONAL damaged input is omitted, and announced ────────────
print_test_section "10. an optional damaged input is omitted from the index"
rm -f "$TEST_TEMP_DIR/irc-ran.txt" "$STATE/stage-inputs/ir-consumer.json"
printf '{"verdict":"pass"}\n' > "$ART/producer-out.json"   # required one healthy again
printf '{"hint":'                > "$ART/producer-hint.json" # optional one truncated
: > "$EVENTS"

ZBUILD_INPUTS_RESOLVE=1 ZBUILD_STATE_DIR="$STATE" _dispatch_consumer >/dev/null 2>&1
_rc10=$?
_idx10="$STATE/stage-inputs/ir-consumer.json"

if jq -e '.inputs | has("producer_hint")' "$_idx10" >/dev/null 2>&1; then
    assert_fail "[SPEC-10] the damaged optional input is not indexed" \
        "producer_hint was handed over as a path to a broken file"
else
    assert_pass "[SPEC-10] the damaged optional input is not indexed"
fi
# [guard] omission must be SELECTIVE, or dropping everything would also pass.
if jq -e '.inputs | has("ir_lens_result")' "$_idx10" >/dev/null 2>&1; then
    assert_pass "[SPEC-10] a healthy optional input is still indexed"
else
    assert_fail "[SPEC-10] a healthy optional input is still indexed" \
        "ir_lens_result was dropped too — the check is not selective"
fi
assert_eq "[SPEC-10] the run was NOT stopped by an advisory input" "0" "$_rc10"
assert_contains "[SPEC-10] the omission is announced" \
    "$(cat "$EVENTS" 2>/dev/null)" "stage.input.degraded"

# ─── SPEC-11: the refusal cannot become a retry storm (#1887) ────────────────
print_test_section "11. a refused dispatch is not retryable"
# #1887 wraps plugin_hook_call in a disposition-driven re-dispatch loop. A
# refusal is rc=1 with no result = ADR-054 §6 `broken`; were that retryable, a
# missing input would re-dispatch until the budget ran out.
# shellcheck source=../../core/pipeline/disposition.sh
source "$REPO_ROOT/core/pipeline/disposition.sh"
if disposition_retryable "broken" 2>/dev/null; then
    assert_fail "[SPEC-11] a refusal's disposition is not retryable" \
        "broken is retryable — a missing input becomes a re-dispatch loop"
else
    assert_pass "[SPEC-11] a refusal's disposition is not retryable"
fi
if disposition_halts "broken" 2>/dev/null; then
    assert_pass "[SPEC-11] and it halts the run"
else
    assert_fail "[SPEC-11] and it halts the run" "broken does not halt"
fi
# [guard] not vacuous — a disposition that SHOULD retry still does.
if disposition_retryable "interrupted" 2>/dev/null; then
    assert_pass "[SPEC-11] the retryable set is not simply empty"
else
    assert_fail "[SPEC-11] the retryable set is not simply empty" \
        "interrupted is not retryable either — the assertion above proves nothing"
fi

# ─── SPEC-12: a damaged MAP member is excluded, not carried ─────────────────
# A map input is a SET: without the same rule the scalar branch applies, N-1
# broken members ride in on one healthy sibling.
print_test_section "12. a damaged map member is excluded and announced"
_TPL_STAGES=(ir-producer ir_lenses ir-consumer)
rm -f "$TEST_TEMP_DIR/irc-ran.txt" "$STATE/stage-inputs/ir-consumer.json"
printf '{"verdict":"pass"}\n' > "$ART/producer-out.json"
printf '{"hint":"ok"}\n'      > "$ART/producer-hint.json"
printf '{"lens":"alpha"}\n'   > "$ART/irlens-alpha.json"   # healthy
printf '{"lens":'             > "$ART/irlens-beta.json"    # truncated
: > "$EVENTS"

ZBUILD_INPUTS_RESOLVE=1 ZBUILD_STATE_DIR="$STATE" _dispatch_consumer >/dev/null 2>&1
_idx12="$STATE/stage-inputs/ir-consumer.json"
_lens12="$(jq -r '.inputs.ir_lens_result // [] | join(" ")' "$_idx12" 2>/dev/null)"

assert_eq "[SPEC-12] only the healthy member is indexed" "$ART/irlens-alpha.json" "$_lens12"
if grep -qF 'irlens-beta.json' <<< "$_lens12"; then
    assert_fail "[SPEC-12] the truncated member is excluded" "beta rode in on alpha's health"
else
    assert_pass "[SPEC-12] the truncated member is excluded"
fi
assert_contains "[SPEC-12] the exclusion is announced" \
    "$(cat "$EVENTS" 2>/dev/null)" "damaged_member"
# [guard] not vacuous — with BOTH members healthy the array keeps two entries.
printf '{"lens":"beta"}\n' > "$ART/irlens-beta.json"
rm -f "$STATE/stage-inputs/ir-consumer.json"
ZBUILD_INPUTS_RESOLVE=1 ZBUILD_STATE_DIR="$STATE" _dispatch_consumer >/dev/null 2>&1
assert_eq "[SPEC-12] two healthy members both survive" "2" \
    "$(jq -r '.inputs.ir_lens_result | length' "$STATE/stage-inputs/ir-consumer.json" 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
