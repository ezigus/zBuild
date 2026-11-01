#!/usr/bin/env bash
# tests/unit/prompt-contract-every-stage-test.sh — every stage that calls a model
# sends a prompt in the contract order (ADR-067 §8, amended).
#
# For every stage whose code calls a model (route_to_model / route_to_model_loop),
# this runs the stage's real prompt code with only the model call stubbed, and
# checks the prompt the stage actually sends:
#
#   E1 [change]: the six sections, each once, in the contract order — From the
#                repo, What you own, What you judge against, Previous work, What
#                you must not do, Rules for this stage
#   E2 [change]: the engine's three blocks sit in their own sections, unchanged
#   E3 [change]: every model-calling stage has a composer here: a new stage is
#                covered or this test fails
#   T1 [guard] : test-author is told to check the new value or file itself, not
#                only that the step finished without an error
#   E5 [change]: no stage frames a persona itself — no prompt a stage sends
#                carries the perspective of a persona a shipped template pins a
#                stage to (a lens persona's perspective IS its lens question,
#                which the lens states as its own job), and no plugin calls
#                persona_stage_framing (the persona reaches the model through the
#                provider, ADR-051 amended)
#   E6 [change]: every stage's What you own opens with its job — not with a
#                heading, the output-contract boilerplate, a role sentence
#                ("You are a/the …") or a list of its tools ("You have …"): the engine's rules point at this section as
#                the whole of the stage's job, so it must say what that job is
#                first (#1801: plan's job sentence sat 40 lines down)
#   E4 [moved]  : (#2363) "read data the way its writer writes it" (#1799) is a
#                rule about writing code: it left the engine's rules for build,
#                test-author and the review lenses — engine-blocks-shared-only B4
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
print_test_header "every model-calling stage sends a prompt in the contract order"
setup_test_env "prompt-contract-every-stage"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_RUN_ID="prompt-contract-$$"
unset ZBUILD_STAGE_INPUTS ZBUILD_SCOPE_MANIFEST ZBUILD_CYCLE_FEEDBACK_DIR

# The engine's blocks, each with a sentinel, so E2 can find them.
export ZBUILD_STAGE_BLOCKS="$TEST_TEMP_DIR/blocks"
mkdir -p "$ZBUILD_STAGE_BLOCKS"
printf 'REPO-BLOCK-SENTINEL\n' > "$ZBUILD_STAGE_BLOCKS/from-repo.md"
printf 'PREVIOUS-WORK-SENTINEL\n' > "$ZBUILD_STAGE_BLOCKS/previous-work.md"
printf 'RULES-BLOCK-SENTINEL\n' > "$ZBUILD_STAGE_BLOCKS/rules.md"

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
# #2445: intake's model calls write and check the issue's requirement list.
_c_intake() { ( ad="$(_fixture intake)"; export ZBUILD_REPO_ROOT="${ad%/state/artifacts}"
    source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
    route_to_model() { [[ -s "$RAW/intake.txt" ]] || printf '%s' "$2" > "$RAW/intake.txt"; printf 'REQUIREMENT: fix the typo\nMISSING: none\n'; }
    local _j; _intake_requirements_json_v _j '{"title":"Fix a typo","body":"1. Fix the typo in README.md"}' ) >/dev/null 2>&1; }
_c_design() { ( ad="$(_fixture design)"; export ZBUILD_REPO_ROOT="${ad%/state/artifacts}"
    source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
    route_to_model() { printf '%s' "$2" > "$RAW/design.txt"; return 1; }
    _design_stage_run_inner "${ad%/artifacts}/scope-manifest.md" "$ad/design-out.md" "$ad" ) >/dev/null 2>&1; }
_c_build() { ( ad="$(_fixture build)"; export ZBUILD_REPO_ROOT="${ad%/state/artifacts}"
    source "$REPO_ROOT/plugins/agent/build/plugin.sh" >/dev/null 2>&1
    route_to_model_loop() { cp "$2" "$RAW/build.txt"; _ROUTE_LOOP_TERMINATED_REASON=done_sentinel; return 1; }
    _route_resolve_max_iterations() { echo 1; }
    _route_loop_close_final_banner() { :; }
    _build_stage_run_inner "${ad%/artifacts}/scope-manifest.md" "" "$ad/diff.patch" "$ad/build-summary.json" "$ad" ) >/dev/null 2>&1; }
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
# #2369: design's second model call — does the design cover the issue? Captured
# beside design's own prompt and checked like a stage.
_c_design_coverage() { ( ad="$(_fixture design-coverage)"
    source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
    route_to_model() { printf '%s' "$2" > "$RAW/design-coverage.txt"; printf 'VERDICT: covered\nREASON: r\n'; }
    _design_coverage "$ad/design.md" "- R-1: make the stage write its result" T2 ) >/dev/null 2>&1; }
_c_issue_acceptance() { ( ad="$(_fixture issue-acceptance)"; sd="${ad%/artifacts}"
    zb_test_issue_output "$sd" "ISSUE-TEXT: make the stage write its result" >/dev/null
    printf 'diff --git a/foo.sh b/foo.sh\n' > "$ad/d.patch"
    jq -n --arg g "$sd/intake-result.json" --arg d "$ad/design.md" --arg p "$ad/d.patch" \
        '{schema_version:2, stage:"issue-acceptance", inputs:{a:$g, b:$d, c:$p}}' > "$sd/idx.json"
    source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh" >/dev/null 2>&1
    route_to_model() { printf '%s' "$2" > "$RAW/issue-acceptance.txt"; return 1; }
    ZBUILD_STAGE_INPUTS="$sd/idx.json" ZBUILD_ARTIFACT_DIR="$ad" ZBUILD_REPO_ROOT="${sd%/state}" \
        issue_acceptance_run issue-acceptance "$sd/pipeline-state.json" ) >/dev/null 2>&1; }
# #2370: test-author's check of its own assertions builds two prompts: one
# pair, and every pair at once. Checked beside test-author's own prompt.
_c_test_author_check() { ( source "$REPO_ROOT/plugins/agent/test-author/plugin.sh" >/dev/null 2>&1
    route_to_model() { printf '%s' "$2" > "$_SC_CAP"; return 1; }
    _SC_CAP="$RAW/test-author-check.txt"
    _sc_call T2 "$(_sc_prompt "the stage writes its result" 'assert_eq "[SPEC-1] x" 1 "$got"')" >/dev/null
    # shellcheck disable=SC2034  # read through namerefs
    { _ids=(SPEC-1); _txts=("the stage writes its result"); _srcs=('assert_eq "[SPEC-1] x" 1 "$got"'); }
    _SC_CAP="$RAW/test-author-check-batch.txt"
    _sc_call T2 "$(_sc_batch_prompt _ids _txts _srcs)" >/dev/null ) >/dev/null 2>&1; }

# ─── E3: every model-calling stage has a composer ───────────────────────────
STAGES=()
for _d in "$REPO_ROOT"/plugins/*/*/; do
    _calls=0
    for _f in "$_d"*.sh "$_d"lib/*.sh; do
        [[ -f "$_f" ]] || continue
        grep -qE '^[^#]*route_to_model(_loop)?[[:space:]]' "$_f" && { _calls=1; break; }
    done
    [[ $_calls -eq 1 ]] && STAGES+=("$(basename "$_d")")
done
_missing=""
for _s in "${STAGES[@]}"; do
    declare -F "_c_${_s//-/_}" >/dev/null 2>&1 || _missing+="$_s "
done
assert_eq "[E3] every model-calling stage has a composer here" "" "$_missing"
assert_eq "[E3] the model-calling stages were found (fixture live; 8 since #2369/#2370 retired spec-coverage and spec-correspondence)" "1" "$([[ ${#STAGES[@]} -ge 8 ]] && echo 1 || echo 0)"

SECTIONS=("## From the repo" "## What you own" "## What you judge against" "## Previous work" "## What you must not do" "## Rules for this stage")

# _section_of <file> <line-text> — the contract section a line sits in.
_section_of() {
    awk -v want="$2" '/^## (From the repo|What you own|What you judge against|Previous work|What you must not do|Rules for this stage)$/ { sec = $0 }
        $0 == want { print sec; exit }' "$1"
}

_check() {
    local s="$1" f="$2"
    if [[ ! -s "$f" ]]; then
        assert_fail "[E1] $s: the prompt it sends was captured" "nothing captured at $f"
        return
    fi
    local rc=0; stage_prompt_check "$f" || rc=$?
    assert_eq "[E1] $s: the six sections in the contract order" "0" "$rc"
    local h counts=""
    for h in "${SECTIONS[@]}"; do counts+="$(grep -cxF -- "$h" "$f" || true) "; done
    assert_eq "[E1] $s: each section once" "1 1 1 1 1 1 " "$counts"
    assert_eq "[E2] $s: From the repo holds the engine's block" "## From the repo" "$(_section_of "$f" REPO-BLOCK-SENTINEL)"
    assert_eq "[E2] $s: Previous work holds the engine's block" "## Previous work" "$(_section_of "$f" PREVIOUS-WORK-SENTINEL)"
    assert_eq "[E2] $s: Rules for this stage holds the engine's block" "## Rules for this stage" "$(_section_of "$f" RULES-BLOCK-SENTINEL)"
}

for _s in "${STAGES[@]}"; do
    declare -F "_c_${_s//-/_}" >/dev/null 2>&1 || continue
    "_c_${_s//-/_}"
    _check "$_s" "$RAW/$_s.txt"
done
_c_test_author_check
_check "test-author (check, one pair)" "$RAW/test-author-check.txt"
_check "test-author (check, batch)" "$RAW/test-author-check-batch.txt"
_c_design_coverage
_check "design (coverage call)" "$RAW/design-coverage.txt"

# ─── E5: no stage frames a persona ──────────────────────────────────────────
_persp=()
_pinned="$(awk '/^  persona:/ { print $2 }' "$REPO_ROOT"/config/templates/*.yaml | sort -u)"
for _pid in $_pinned generic; do
    _pm="$REPO_ROOT/plugins/persona/$_pid/manifest.yaml"
    _pp="$(awk '/^[[:space:]]+perspective:/ { sub(/^[[:space:]]+perspective:[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }' "$_pm")"
    [[ ${#_pp} -ge 30 ]] && _persp+=("${_pp:0:60}")
done
assert_eq "[E5] the persona perspectives were read (fixture live)" "1" "$([[ ${#_persp[@]} -ge 4 ]] && echo 1 || echo 0)"
_framed=""
for _s in "${STAGES[@]}" test-author-check test-author-check-batch design-coverage; do
    [[ -s "$RAW/$_s.txt" ]] || continue
    for _pp in "${_persp[@]}"; do
        grep -qF -- "$_pp" "$RAW/$_s.txt" && { _framed+="$_s "; break; }
    done
done
assert_eq "[E5] no stage's prompt carries a persona's perspective" "" "$_framed"
_callers="$(grep -rlE '^[^#]*persona_stage_framing' "$REPO_ROOT/plugins" --include='*.sh' 2>/dev/null | grep -v '/tests/' || true)"
assert_eq "[E5] no plugin frames a persona itself" "" "$_callers"

# ─── E6: What you own opens with the job ─────────────────────────────────────
_bad=""
for _s in "${STAGES[@]}" test-author-check test-author-check-batch design-coverage; do
    f="$RAW/$_s.txt"; [[ -s "$f" ]] || continue
    _first="$(awk '/^## What you own/{p=1;next} p && NF {print; exit}' "$f")"
    if [[ "$_first" =~ ^# || "$_first" == *"OUTPUT CONTRACT"* || "$_first" =~ ^You\ are\ (an?|the)\  \
          || "$_first" =~ ^You\ have\  ]]; then
        _bad+="$_s($_first) "
    fi
done
assert_eq "[E6] every stage's What you own opens with its job" "" "$_bad"

# ─── T1: test-author checks the value itself ────────────────────────────────
_ta="$(cat "$RAW/test-author.txt" 2>/dev/null)"
assert_contains "[T1] test-author is told to check the new value or file itself" \
    "$_ta" "the new value or file itself"
assert_contains "[T1] ...not only that the step finished without an error" \
    "$_ta" "not only that the step finished without an error"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
