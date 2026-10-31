#!/usr/bin/env bash
# tests/unit/design-one-call-keeps-last-good-test.sh — design makes one model
# call per run, writes to a working copy, and replaces design.md only with a
# design that passes its checks (ADR-068 §8 amended).
#
# Why: #1944 run 38883031887 made 12 design calls in two rounds and wrote
# nothing. Each call started from scratch with the same prompt, because a call
# that ran out of time deleted design.md — the last good design never reached
# the next try. A repeat inside the stage had nothing new to work from.
#
# D1 [change] one model call per run, even when its design fails a check
# D2 [change] a design that fails its checks is `unusable` (the engine re-runs
#             the stage), and the result carries every check that failed
# D3 [change] a failed try leaves the last good design.md untouched; the try
#             is kept as the working copy
# D4 [change] a call that runs out of time without writing leaves the last
#             good design.md in place: outcome timed_out
# D5 [change] the model writes to the working copy, which starts as a copy of
#             the last good design
# D6 [guard]  a design that passes its checks replaces design.md, and the
#             working copy is cleared
# D7 [change] a rejected try comes back to the next run as the working copy,
#             named as rejected, and design's own result is still there when
#             the next run's model is called (so its findings reach the prompt)
# D8 [change] the prompt says which findings are design's: only those a
#             change to the design would fix
# D9 [guard]  a call cut off after writing a design that passes still counts
# D10 [change] each shipped template runs design at most 3 times (retry: 2),
#             and a design that still fails ends the run (stop_run_on_fail)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "design makes one call and keeps its last good design (ADR-068 §8)"
setup_test_env "design-one-call-keeps-last-good"

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"
apply_scope_redaction() { cp "$1" "$2"; return 0; }

BT='```'
GOOD="# Design

${BT}scope
foo.sh
${BT}

${BT}acceptance
SPEC-1[no-code]: the docs say so
WIRING: none
TESTFILES:
${BT}"
GOOD2="${GOOD}
A second version."
NO_WIRING="# Design

${BT}scope
foo.sh
${BT}

${BT}acceptance
SPEC-1[no-code]: the docs say so
TESTFILES:
${BT}"

# The model. It writes where the prompt tells it to — the path on the line
# after "EXACT absolute path:" — like the real one, so the test never assumes
# which file design hands it. WRITE is what it writes (empty: nothing); RC is
# what the call returns (124: ran out of time).
WRITE=""; RC=0
_model_call() {
    local prompt="$1" n target
    n=$(( $(cat "$TEST_TEMP_DIR/design-calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/design-calls"
    printf '%s\n' "$prompt" > "$TEST_TEMP_DIR/design-prompt-$n"
    target="$(zb_test_prompt_write_path "$prompt")"
    printf '%s' "$target" > "$TEST_TEMP_DIR/design-target-$n"
    # What the model found at that path when it started.
    if [[ -n "$target" && -f "$target" ]]; then cp "$target" "$TEST_TEMP_DIR/design-start-$n"; fi
    [[ -f "${_F_DRAFT:-}" ]] && cp "$_F_DRAFT" "$TEST_TEMP_DIR/draft-at-call-$n"
    [[ -s "$_F_ART/design-verdict.json" ]] && cp "$_F_ART/design-verdict.json" "$TEST_TEMP_DIR/result-at-call-$n"
    [[ -n "$WRITE" && -n "$target" ]] && printf '%s' "$WRITE" > "$target"
    return "$RC"
}
route_to_model() { _model_call "$2"; }

# _fresh — an empty run directory; _run — one dispatch of design in it.
_fresh() {
    local d="$TEST_TEMP_DIR/run"
    rm -rf "$d"; mkdir -p "$d/state/artifacts"
    git -C "$d" init -q >/dev/null 2>&1
    export ZBUILD_REPO_ROOT="$d"
    export ZBUILD_EVENTS_JSONL="$d/state/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
    _F_ART="$d/state/artifacts"; _F_DESIGN="$_F_ART/design.md"; _F_DRAFT="$_F_ART/design-draft.md"
    printf 'scope: all\n' > "$d/state/scope-manifest.md"
    printf '{"title":"t","goal":"g","steps":[{"id":"s1","description":"d","files":["foo.sh"]}]}\n' > "$_F_ART/plan.json"
}
_run() {
    rm -f "$TEST_TEMP_DIR"/design-calls "$TEST_TEMP_DIR"/design-prompt-* "$TEST_TEMP_DIR"/design-target-* \
        "$TEST_TEMP_DIR"/design-start-* "$TEST_TEMP_DIR"/result-at-call-* "$TEST_TEMP_DIR"/draft-at-call-*
    _design_stage_run_inner "$TEST_TEMP_DIR/run/state/scope-manifest.md" "$_F_ART/plan.json" "$_F_DESIGN" "$_F_ART" >/dev/null 2>&1
    STAGE_RC=$?
    OUTCOME="$(jq -r '.outcome // "MISSING"' "$_F_ART/design-verdict.json" 2>/dev/null || echo MISSING)"
    FINDINGS="$(jq -r '.data.findings[]?.text // empty' "$_F_ART/design-verdict.json" 2>/dev/null || true)"
    CALLS="$(cat "$TEST_TEMP_DIR/design-calls" 2>/dev/null || echo 0)"
}

# ── D1 + D2 + D3 ─────────────────────────────────────────────────────────────
_fresh; printf '%s' "$GOOD" > "$_F_DESIGN"
WRITE="$NO_WIRING"; RC=0
_run
assert_eq "[D1] one model call, though its design fails a check" "1" "$CALLS"
assert_eq "[D2] a design that fails its checks is unusable" "unusable" "$OUTCOME"
assert_contains "[D2] the result names the check that failed" "$FINDINGS" "WIRING"
assert_contains "[D2] the summary names it too" "$(cat "$_F_ART/design-summary.md" 2>/dev/null)" "WIRING"
assert_eq "[D3] the last good design.md is untouched" "$GOOD" "$(cat "$_F_DESIGN" 2>/dev/null)"
assert_eq "[D3] the failed try is kept as the working copy" "$NO_WIRING" "$(cat "$_F_DRAFT" 2>/dev/null)"

# ── D4 ───────────────────────────────────────────────────────────────────────
_fresh; printf '%s' "$GOOD" > "$_F_DESIGN"
WRITE=""; RC=124
_run
assert_eq "[D4] out of time with nothing written: timed_out" "timed_out" "$OUTCOME"
assert_eq "[D4] the last good design.md is still there" "$GOOD" "$(cat "$_F_DESIGN" 2>/dev/null)"
assert_eq "[D4] the untouched copy of it is not kept as a rejected try" "absent" \
    "$([[ -e "$_F_DRAFT" ]] && echo present || echo absent)"

# ── D5 + D6 ──────────────────────────────────────────────────────────────────
_fresh; printf '%s' "$GOOD" > "$_F_DESIGN"
WRITE="$GOOD2"; RC=0
_run
assert_eq "[D5] the model is told to write the working copy" "$_F_DRAFT" "$(cat "$TEST_TEMP_DIR/design-target-1" 2>/dev/null)"
assert_eq "[D5] the working copy starts as the last good design" "$GOOD" "$(cat "$TEST_TEMP_DIR/draft-at-call-1" 2>/dev/null)"
assert_eq "[D6] a design that passes: pass" "pass" "$OUTCOME"
assert_eq "[D6] it replaces design.md" "$GOOD2" "$(cat "$_F_DESIGN" 2>/dev/null)"
assert_eq "[D6] the working copy is cleared" "absent" "$([[ -e "$_F_DRAFT" ]] && echo present || echo absent)"

# ── D7 ───────────────────────────────────────────────────────────────────────
# The previous run's try failed its checks: design's own writer records that.
_fresh; printf '%s' "$GOOD" > "$_F_DESIGN"; printf '%s' "$NO_WIRING" > "$_F_DRAFT"
_design_write_outcome "$_F_ART" unusable "design.md fails its checks" \
    "$(printf '%s\n' "The acceptance block has no WIRING line" | stage_findings_json)"
WRITE="$GOOD2"; RC=0
_run
assert_eq "[D7] the rejected try is the working copy the model starts from" "$NO_WIRING" \
    "$(cat "$TEST_TEMP_DIR/design-start-1" 2>/dev/null)"
assert_contains "[D7] the prompt says the working copy is a rejected try" \
    "$(cat "$TEST_TEMP_DIR/design-prompt-1" 2>/dev/null)" "rejected"
assert_contains "[D7] design's own result is still there when the model is called" \
    "$(cat "$TEST_TEMP_DIR/result-at-call-1" 2>/dev/null)" "no WIRING line"

# ── D8 ───────────────────────────────────────────────────────────────────────
assert_contains "[D8] the prompt says a finding is design's only if a design change would fix it" \
    "$(cat "$TEST_TEMP_DIR/design-prompt-1" 2>/dev/null)" "only if changing the design would fix it"

# ── D9 ───────────────────────────────────────────────────────────────────────
_fresh
WRITE="$GOOD"; RC=124
_run
assert_eq "[D9] cut off after writing a design that passes: pass" "pass" "$OUTCOME"
assert_eq "[D9] that design is design.md" "$GOOD" "$(cat "$_F_DESIGN" 2>/dev/null)"

# ── D10 ──────────────────────────────────────────────────────────────────────
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
for _tpl in simple deployed; do
    _TPL_STAGES=(); _TPL_CYCLES=()
    load_template "$REPO_ROOT/config/templates/$_tpl.yaml" >/dev/null 2>&1
    assert_eq "[D10] $_tpl: the engine re-runs design twice (3 runs in all)" "2" "$(template_stage_retry design)"
    assert_eq "[D10] $_tpl: a design that still fails ends the run" "design" \
        "$(printenv _TPL_CYCLE_STOP_RUN_build_test_cycle || true)"
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
