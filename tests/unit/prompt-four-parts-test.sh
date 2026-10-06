#!/usr/bin/env bash
# tests/unit/prompt-four-parts-test.sh — every stage prompt has the same four
# parts, in order (#2308, ADR-067 §8).
#
# Why: each stage's prompt mixed its own job with general behaviour (saving as
# it goes, answering findings, reporting), and some of its rules cancelled the
# job itself: spec-coverage and issue-acceptance were told never to judge how a
# change is verified, design's re-prompt said to keep every other entry, and
# test-author's "never change" rule fought the checks it was told to update. On
# #2035 the change that passed every check missed half the issue.
#
# For every stage that calls a model (each declares a save-as-you-go file,
# ADR-063 §5), this composes the stage's real prompt — the plugin's own prompt
# code, with the model stubbed — then passes it through the router's real funnel
# (_route_redact_prompt), which is what every model call crosses.
#
# F1 [code] the stage's own text has "What you own", "What you judge against"
#           and "What you must not do", once each, in that order
# F2 [code] the stage's own text carries no copy of the shared part
# F3 [code] after the funnel, "How every stage works" comes last, once, and is
#           byte for byte the one shared source (stage_conduct_block)
# F4 [code] after the funnel, the stage's limits open with the rule that no
#           later text may take away part of its own job
# F5 [code] every model-calling stage has a composer here: a new stage is
#           covered or this test fails
# F6 [code] the loop passes the same prompt file through the funnel every
#           round: a second pass adds no second rule and no second shared part
# T1 [code] test-author is told to check the new value or file itself, not only
#           that the step finished without an error
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "every stage prompt in four parts (#2308)"
setup_test_env "prompt-four-parts"

export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_RUN_ID="prompt-four-parts-$$"
unset ZBUILD_STAGE_INPUTS ZBUILD_SCOPE_MANIFEST ZBUILD_RESTORED_ARTIFACTS_DIR ZBUILD_CYCLE_FEEDBACK_DIR

RAW="$TEST_TEMP_DIR/raw"; mkdir -p "$RAW"

# _fixture <name> — a throwaway git repo with state/artifacts, a scope manifest,
# a plan and a design. Echoes the artifacts dir.
_fixture() {
    local fix="$TEST_TEMP_DIR/fix-$1" ad
    ad="$fix/state/artifacts"; mkdir -p "$ad" "$fix/tests"
    git -C "$fix" init -q -b main >/dev/null 2>&1
    git -C "$fix" config user.email t@e.st; git -C "$fix" config user.name t
    printf 'assert_eq "[SPEC-1] placeholder" "1" "$got"\n' > "$fix/tests/acc-test.sh"
    git -C "$fix" add -A >/dev/null 2>&1; git -C "$fix" commit -q -m seed >/dev/null 2>&1
    printf 'scope: all\n' > "$fix/state/scope-manifest.md"
    printf '{"schema_version":1}\n' > "$fix/state/pipeline-state.json"
    printf '%s\n' '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"s1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}' > "$ad/plan.json"
    cat > "$ad/design.md" <<'EOF'
# Design

## Decision
Write the result on every exit.

```scope
foo.sh
tests/acc-test.sh
```

```acceptance
SPEC-1[code]: the stage writes its result on every exit
TESTFILES:
SPEC-1: tests/acc-test.sh
WIRING: none
```
EOF
    printf '%s' "$ad"
}

# One composer per model-calling stage. Each runs in a subshell, sources the
# real plugin, stubs only the model call, and writes the prompt the plugin
# built to $RAW/<stage>.txt.
_c_plan() { ( ad="$(_fixture plan)"; export ZBUILD_REPO_ROOT="${ad%/state/artifacts}"
    source "$REPO_ROOT/plugins/agent/plan/plugin.sh" >/dev/null 2>&1
    route_to_model() { printf '%s' "$2" > "$RAW/plan.txt"; printf '%s' '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'; }
    _plan_run_inner "${ad%/artifacts}/scope-manifest.md" "Fix a typo in README.md" "$ad/plan.json" "$ad" ) >/dev/null 2>&1; }
_c_design() { ( ad="$(_fixture design)"; export ZBUILD_REPO_ROOT="${ad%/state/artifacts}"
    source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
    route_to_model_loop() { cp "$2" "$RAW/design.txt"; _ROUTE_LOOP_TERMINATED_REASON=done_sentinel; return 1; }
    _route_loop_close_final_banner() { :; }
    _design_stage_run_inner "${ad%/artifacts}/scope-manifest.md" "$ad/plan.json" "$ad/design-out.md" "$ad" ) >/dev/null 2>&1; }
_c_impact() { ( ad="$(_fixture impact)"; export ZBUILD_REPO_ROOT="${ad%/state/artifacts}"
    source "$REPO_ROOT/plugins/agent/impact/plugin.sh" >/dev/null 2>&1
    route_to_model() { printf '%s' "$2" > "$RAW/impact.txt"; printf '%s' '{"schema_version":1,"verdict":"complete","missing":[]}'; }
    resolve_tier() { printf 'T2'; }
    _impact_scope_prefilter() { printf '[]'; }
    _impact_run_inner "${ad%/artifacts}/scope-manifest.md" "$ad/design.md" "$ad/plan.json" "$ad/impact.json" "$ad" ) >/dev/null 2>&1; }
_c_build() { ( ad="$(_fixture build)"; export ZBUILD_REPO_ROOT="${ad%/state/artifacts}"
    source "$REPO_ROOT/plugins/agent/build/plugin.sh" >/dev/null 2>&1
    route_to_model_loop() { cp "$2" "$RAW/build.txt"; _ROUTE_LOOP_TERMINATED_REASON=done_sentinel; return 1; }
    _route_resolve_max_iterations() { echo 1; }
    _route_loop_close_final_banner() { :; }
    _build_stage_run_inner "${ad%/artifacts}/scope-manifest.md" "$ad/plan.json" "$ad/diff.patch" "$ad/build-summary.json" "$ad" ) >/dev/null 2>&1; }
_c_test_author() { ( ad="$(_fixture test-author)"; export ZBUILD_REPO_ROOT="${ad%/state/artifacts}" ZBUILD_ARTIFACT_DIR="$ad"
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh" >/dev/null 2>&1
    route_to_model_loop() { cp "$2" "$RAW/test-author.txt"; _ROUTE_LOOP_TERMINATED_REASON=router_timeout; return 1; }
    resolve_tier() { printf 'T2'; }
    test_author_run test-author "${ad%/artifacts}/pipeline-state.json" ) >/dev/null 2>&1; }
_c_monitor() { ( ad="$(_fixture monitor)"; export ZBUILD_ARTIFACT_DIR="$ad" ZBUILD_STATE_DIR="${ad%/artifacts}"
    source "$REPO_ROOT/plugins/agent/monitor/plugin.sh" >/dev/null 2>&1
    route_to_model() { printf '%s' "$2" > "$RAW/monitor.txt"; return 1; }
    monitor_stage_run monitor "${ad%/artifacts}/pipeline-state.json" ) >/dev/null 2>&1; }
_c_security_lens() { ( ad="$(_fixture security-lens)"
    source "$REPO_ROOT/plugins/agent/security-lens/plugin.sh" >/dev/null 2>&1
    route_to_model() { printf '%s' "$2" > "$RAW/security-lens.txt"; return 1; }
    resolve_tier() { printf 'T3'; }
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hi\n' > "$ad/bundle.txt"
    _security_lens_run_inner "$ad/bundle.txt" "" "$ad/security.json" "$ad" ) >/dev/null 2>&1; }
_c_review_lens() { ( ad="$(_fixture review-lens)"
    source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh" >/dev/null 2>&1
    route_to_model() { printf '%s' "$2" > "$RAW/review-lens.txt"; return 1; }
    resolve_tier() { printf 'T2'; }
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hi\n' > "$ad/bundle.txt"
    _review_lens_run_inner correctness "${ad%/artifacts}/scope-manifest.md" "$ad/bundle.txt" "$ad/lens.json" "$ad" ) >/dev/null 2>&1; }
_c_review_report() { ( source "$REPO_ROOT/plugins/agent/review-report/plugin.sh" >/dev/null 2>&1
    _rr_build_lens_prompt correctness 'diff --git a/foo.sh b/foo.sh' > "$RAW/review-report.txt" ) 2>/dev/null; }
_c_spec_coverage() { ( source "$REPO_ROOT/plugins/agent/spec-coverage/plugin.sh" >/dev/null 2>&1
    _scv_prompt "ISSUE-TEXT" "SPEC-1[code]: x" "- R-1: the stage writes its result" > "$RAW/spec-coverage.txt" ) 2>/dev/null; }
_c_issue_acceptance() { ( source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh" >/dev/null 2>&1
    _ia_prompt "ISSUE-TEXT" "SPEC-TEXT" "DIFF-TEXT" "pass" "- R-1: the stage writes its result" > "$RAW/issue-acceptance.txt" ) 2>/dev/null; }
# spec-correspondence builds two prompts: one pair, and every pair at once.
_c_spec_correspondence() { ( source "$REPO_ROOT/plugins/agent/spec-correspondence/plugin.sh" >/dev/null 2>&1
    _sc_prompt "the stage writes its result" 'assert_eq "[SPEC-1] x" 1 "$got"' > "$RAW/spec-correspondence.txt"
    # shellcheck disable=SC2034  # read through namerefs
    { _ids=(SPEC-1); _txts=("the stage writes its result"); _srcs=('assert_eq "[SPEC-1] x" 1 "$got"'); }
    _sc_batch_prompt _ids _txts _srcs > "$RAW/spec-correspondence-batch.txt" ) 2>/dev/null; }

# ─── F5: every model-calling stage has a composer ───────────────────────────
STAGES=()
for _m in "$REPO_ROOT"/plugins/*/*/manifest.yaml; do
    grep -qE '^[[:space:]]+role:[[:space:]]*checkpoint' "$_m" 2>/dev/null || continue
    STAGES+=("$(basename "$(dirname "$_m")")")
done
_missing=""
for _s in "${STAGES[@]}"; do
    declare -F "_c_${_s//-/_}" >/dev/null 2>&1 || _missing+="$_s "
done
assert_eq "[F5] every model-calling stage has a composer here" "" "$_missing"
assert_eq "[F5] the model-calling stages were found (fixture live)" "1" "$([[ ${#STAGES[@]} -ge 12 ]] && echo 1 || echo 0)"

# The shared part, from its one source. Empty here means there is no source.
CONDUCT=""; OWN_RULE=""
if [[ -f "$REPO_ROOT/scripts/lib/stage-conduct.sh" ]]; then
    # shellcheck source=../../scripts/lib/stage-conduct.sh
    source "$REPO_ROOT/scripts/lib/stage-conduct.sh"
    CONDUCT="$(stage_conduct_block)"; OWN_RULE="${_ZB_OWN_JOB_RULE:-}"
fi

H_OWN='## What you own'; H_TRUTH='## What you judge against'
H_LIMITS='## What you must not do'; H_CONDUCT='## How every stage works'

# _line <file> <heading> — the line number of the first line that is exactly <heading>.
_line() { local n; n="$(grep -nxF -- "$2" "$1" 2>/dev/null || true)"; n="${n%%$'\n'*}"; printf '%s' "${n%%:*}"; }

# _funnel <stage> <raw> <out> — the router's real funnel, as for a dispatched stage.
_funnel() {
    local sd="$TEST_TEMP_DIR/funnel-state-$1"; mkdir -p "$sd/artifacts"
    printf '{"schema_version":1}\n' > "$sd/pipeline-state.json"
    cp "$2" "$3.in"
    (
        # shellcheck source=../../core/router/route.sh
        source "$REPO_ROOT/core/router/route.sh" >/dev/null 2>&1
        export ZBUILD_PLUGIN_DIR="$REPO_ROOT/plugins/agent/$1" ZBUILD_STATE_DIR="$sd" \
            ZBUILD_CURRENT_STAGE="$1" ZBUILD_REPO_ROOT="$sd"
        unset ZBUILD_SCOPE_MANIFEST ZBUILD_STAGE_INPUTS
        _route_redact_prompt "$3.in" "$3" 0 ""
    ) >/dev/null 2>&1
}

# _check <stage> <raw_file>
_check() {
    local s="$1" raw="$2" out="$TEST_TEMP_DIR/funnel-$(basename "$2")"
    if [[ ! -s "$raw" ]]; then
        assert_fail "[F1] $s: the stage's prompt was composed" "no prompt captured at $raw"
        return
    fi
    local c1 c2 c3
    c1="$(grep -cxF -- "$H_OWN" "$raw" || true)"; c2="$(grep -cxF -- "$H_TRUTH" "$raw" || true)"
    c3="$(grep -cxF -- "$H_LIMITS" "$raw" || true)"
    assert_eq "[F1] $s: each of its three parts appears once" "1 1 1" "$c1 $c2 $c3"
    local l1 l2 l3
    l1="$(_line "$raw" "$H_OWN")"; l2="$(_line "$raw" "$H_TRUTH")"; l3="$(_line "$raw" "$H_LIMITS")"
    if [[ -n "$l1" && -n "$l2" && -n "$l3" ]] && (( l1 < l2 && l2 < l3 )); then
        assert_pass "[F1] $s: own, then judge against, then must not do"
    else
        assert_fail "[F1] $s: own, then judge against, then must not do" "lines ${l1:-none} ${l2:-none} ${l3:-none}"
    fi
    assert_eq "[F2] $s: its own text carries no copy of the shared part" "0" \
        "$(grep -cxF -- "$H_CONDUCT" "$raw" || true)"

    _funnel "$s" "$raw" "$out"
    assert_eq "[F3] $s: the shared part appears once after the funnel" "1" \
        "$(grep -cxF -- "$H_CONDUCT" "$out" 2>/dev/null || true)"
    local l4; l4="$(_line "$out" "$H_CONDUCT")"; l3="$(_line "$out" "$H_LIMITS")"
    if [[ -n "$l3" && -n "$l4" ]] && (( l3 < l4 )); then
        assert_pass "[F3] $s: the shared part comes after the stage's limits"
    else
        assert_fail "[F3] $s: the shared part comes after the stage's limits" "lines ${l3:-none} ${l4:-none}"
    fi
    if [[ -z "$CONDUCT" ]]; then
        assert_fail "[F3] $s: the shared part is the one shared source" "there is no shared source (stage_conduct_block)"
    else
        assert_eq "[F3] $s: the shared part is the one shared source, byte for byte" \
            "$CONDUCT" "$(sed -n "${l4:-999999},\$p" "$out" 2>/dev/null)"
    fi
    local after=""; [[ -n "$l3" ]] && after="$(sed -n "$(( l3 + 1 ))p" "$out")"
    if [[ -z "$OWN_RULE" ]]; then
        assert_fail "[F4] $s: its limits open with the rule nothing overrides" "there is no shared rule"
    else
        assert_eq "[F4] $s: its limits open with the rule nothing overrides" "$OWN_RULE" "$after"
    fi
}

for _s in "${STAGES[@]}"; do
    declare -F "_c_${_s//-/_}" >/dev/null 2>&1 || continue
    "_c_${_s//-/_}"
    _check "$_s" "$RAW/$_s.txt"
done
_check spec-correspondence "$RAW/spec-correspondence-batch.txt"

# ─── F6: a second pass through the funnel changes nothing ───────────────────
# Every stage, not one representative (review #2321): the guard is per file.
for _s in "${STAGES[@]}"; do
    [[ -s "$RAW/$_s.txt" ]] || continue
    _f6="$TEST_TEMP_DIR/funnel-twice-$_s"
    _funnel "$_s" "$RAW/$_s.txt" "$_f6.1"
    _funnel "$_s" "$_f6.1" "$_f6.2"
    assert_eq "[F6] $_s: a second pass adds no second no-override rule" "1" \
        "$(grep -cxF -- "${OWN_RULE:-<no rule>}" "$_f6.2" 2>/dev/null || true)"
    assert_eq "[F6] $_s: ...and no second shared part" "1" "$(grep -cxF -- "$H_CONDUCT" "$_f6.2" 2>/dev/null || true)"
done

# ─── T1: test-author checks the value itself ────────────────────────────────
_ta="$(cat "$RAW/test-author.txt" 2>/dev/null)"
assert_contains "[T1] test-author is told to check the new value or file itself" \
    "$_ta" "the new value or file itself"
assert_contains "[T1] ...not only that the step finished without an error" \
    "$_ta" "not only that the step finished without an error"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
