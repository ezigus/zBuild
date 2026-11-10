#!/usr/bin/env bash
# tests/unit/judge-kept-test.sh — a judge's answer is kept while what it judged
# is unchanged, and judged again when a stage disputes it (#2464, ADR-072 §4
# §5, ADR-068 §6 §7).
#
# Why: on #1805 run 41643063636 test-author's assertion check called BNDY-1
# "corresponds" twice and then "partial", on the same unchanged test files, and
# that flip ended the run. Asked the same question, a judge gives a different
# answer; the engine took each one as fact.
#
# K1 design's coverage check: the same inputs a second time make no call and
#    give the same findings; its answers sit in the artifacts folder
# K2 ...a changed requirement, a changed file the judge opened, or another
#    engine is judged again
# K3 ...an answer from design disputing one of its findings is judged again,
#    with the answer shown, and that verdict is kept in turn
# K9 (review on #2465) a directory the judge searched is a dependency: a commit
#    that changes a file in it is judged again; the fingerprint leaves no file
#    behind; with no old-code copy the evidence keeps its path
# K4 test-author's check: per SPEC — an unchanged SPEC is not asked again, a
#    SPEC whose test changed is, alone
# K5 ...test-author's answer to one of its findings re-judges that SPEC alone,
#    with the answer shown
# K6 build keeps its answers in its result
# K7 issue-acceptance: kept while unchanged; build's answer to one of its
#    findings is judged again, with the answer shown
# K8 a review lens: kept while unchanged; build's answer to one of its
#    findings is judged again
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a judge's answer is kept while nothing it judged changes (#2464)"
setup_test_env "judge-kept"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export _RUNNER_ENGINE_SHA="engine-a"

XR="$TEST_TEMP_DIR/xrepo"; mkdir -p "$XR/scripts" "$XR/tests"
(
    cd "$XR" || exit 1
    git init -q -b main; git config user.email t@t; git config user.name t
    printf 'refuse_missing_config() { [[ -f "$1" ]] || return 2; }\n' > scripts/cfg.sh
    git add -A; git commit -qm base; git checkout -qb feature
)
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state/runs/r1"; mkdir -p "$ZBUILD_STATE_DIR/artifacts"
export ZBUILD_REPO_ROOT="$XR"

# _counting_judge <reply-var> — route_to_model that counts its calls, keeps
# each prompt, and lists $XR/scripts/cfg.sh as a file it opened.
_N="$TEST_TEMP_DIR/n"; _P="$TEST_TEMP_DIR/p"
_counting_judge() {
    eval 'route_to_model() {
        : stdin is not read
        local n; n=$(( $(cat "$_N") + 1 )); printf "%s" "$n" > "$_N"; printf "%s" "$2" > "$_P.$n"
        [[ -n "${ZBUILD_ROUTER_OPENED_FILE:-}" ]] && printf "%s\n" "$XR/scripts/cfg.sh" >> "$ZBUILD_ROUTER_OPENED_FILE"
        printf "%s" "${'"$1"'}"
    }'
}
_calls() { cat "$_N"; }

print_test_section "K1-K3: design's coverage check"
(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh"
    artifact_dir="$ZBUILD_STATE_DIR/artifacts"
    _counting_judge _R
    D="$TEST_TEMP_DIR/k1.md"
    printf '# Design\n```acceptance\nWORK-1[code]: a --dry-run flag is accepted covers: RQST-1\nWIRING: none\n```\n' > "$D"
    REQS='- RQST-1: add a --dry-run flag'
    _R=$'RQST-1: uncovered | WHY: no SPEC refuses it | QUOTE: "add a --dry-run flag"\nWORK-1: ok\n'
    _cov() { printf 0 > "$_N"; _design_coverage "$D" "$REQS" T2 "${1:-}" >/dev/null 2>&1; printf '%s|%s|%s' "$(_calls)" "${#_DESIGN_UNCOVERED[@]}" "$_DESIGN_COV_OUTCOME"; }
    echo "K1a|$(_cov)"
    echo "K1b|$(_cov)"
    echo "K1f|$(ls "$artifact_dir" | grep -c 'judged')"
    REQS='- RQST-1: add a --dry-run flag to every command'
    echo "K2a|$(_cov)"
    echo "K2a2|$(_cov)"
    printf 'refuse_missing_config() { return 0; }\n' > "$XR/scripts/cfg.sh"
    echo "K2b|$(_cov)"
    _RUNNER_ENGINE_SHA=engine-b
    echo "K2c|$(_cov)"
    _ans='design finding 1: wrong — WORK-1 covers it: the flag is the whole of RQST-1'
    echo "K3a|$(_cov "$_ans")|$([[ "$(cat "$_P.1" 2>/dev/null)" == *"WORK-1 covers it"* ]] && echo shown)"
    echo "K3b|$(_cov "$_ans")"
) > "$TEST_TEMP_DIR/k1.out" 2>/dev/null
git -C "$XR" checkout -q -- scripts/cfg.sh
_l() { grep "^$1|" "$TEST_TEMP_DIR/k1.out" | head -1 | cut -d'|' -f2-; }
assert_eq "[K1] first time: judged, one finding" "1|1|" "$(_l K1a)"
assert_eq "[K1] the same inputs again: no call, the same finding" "0|1|" "$(_l K1b)"
assert_eq "[K1] the answers are kept in the artifacts folder" "1" "$(_l K1f)"
assert_eq "[K2] a changed requirement is judged again" "1|1|" "$(_l K2a)"
assert_eq "[K2] ...and then kept" "0|1|" "$(_l K2a2)"
assert_eq "[K2] a file the judge opened changed: judged again" "1|1|" "$(_l K2b)"
assert_eq "[K2] another engine: judged again" "1|1|" "$(_l K2c)"
assert_eq "[K3] design disputes the finding: judged again, the answer shown" "1|1||shown" "$(_l K3a)"
assert_eq "[K3] ...and that verdict is kept in turn" "0|1|" "$(_l K3b)"

print_test_section "K10: an answer with no fingerprint is not kept (review on #2471)"
(
    # shellcheck source=../../scripts/lib/judge.sh
    source "$REPO_ROOT/scripts/lib/judge.sh"
    kf="$TEST_TEMP_DIR/k10/design-judged.json"; mkdir -p "${kf%/*}"
    declare -A p=([WORK-1]="WORK-1: ok" [WORK-2]="WORK-2: ok") f=([WORK-1]="1-1" [WORK-2]="") d=()
    judge_kept_put_all "$kf" p f d
    jq -r 'keys | join(" ")' "$kf"
) > "$TEST_TEMP_DIR/k10.out" 2>/dev/null
assert_eq "[K10] a SPEC whose fingerprint could not be made is not kept; the others are" "WORK-1" "$(cat "$TEST_TEMP_DIR/k10.out")"

print_test_section "K9: what the fingerprint depends on (review on #2465)"
(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh"
    artifact_dir="$ZBUILD_STATE_DIR/artifacts"; rm -f "$artifact_dir/design-judged.json"
    _R=$'RQST-1: covered\nWORK-1: ok\n'
    route_to_model() {
        local n; n=$(( $(cat "$_N") + 1 )); printf "%s" "$n" > "$_N"
        [[ -n "${ZBUILD_ROUTER_OPENED_FILE:-}" ]] && printf "%s\n" "$XR/scripts" >> "$ZBUILD_ROUTER_OPENED_FILE"
        printf "%s" "$_R"
    }
    D="$TEST_TEMP_DIR/k9.md"
    printf '# Design\n```acceptance\nWORK-1[code]: a --dry-run flag is accepted covers: RQST-1\nWIRING: none\n```\n' > "$D"
    _cov() { printf 0 > "$_N"; _design_coverage "$D" "- RQST-1: add a --dry-run flag" T2 >/dev/null 2>&1; cat "$_N"; }
    echo "K9a|$(_cov)|$(_cov)"
    ( cd "$XR" && printf 'new\n' > scripts/new.sh && git add -A && git commit -qm more )
    echo "K9b|$(_cov)"
    _fp=""; ZBUILD_STAGE_SCRATCH="" TMPDIR="$TEST_TEMP_DIR/fp-tmp" judge_fp_v _fp "text"
    mkdir -p "$TEST_TEMP_DIR/fp-tmp"; ZBUILD_STAGE_SCRATCH="" TMPDIR="$TEST_TEMP_DIR/fp-tmp" judge_fp_v _fp "text"
    echo "K9c|${_fp:+fp}|$(ls -A "$TEST_TEMP_DIR/fp-tmp" | grep -c .)"
    _ev=""; _dcov_ev_items_v _ev $'- CNFG-1: scripts/cfg.sh:"x" — open scripts/cfg.sh' ""
    echo "K9d|$_ev"
) > "$TEST_TEMP_DIR/k9.out" 2>/dev/null
_l() { grep "^$1|" "$TEST_TEMP_DIR/k9.out" | head -1 | cut -d'|' -f2-; }
assert_eq "[K9] a searched directory: judged, then kept" "1|0" "$(_l K9a)"
assert_eq "[K9] ...a commit that changes a file in it: judged again" "1" "$(_l K9b)"
assert_eq "[K9] the fingerprint leaves no file behind" "fp|0" "$(_l K9c)"
assert_eq "[K9] with no old-code copy the evidence keeps its path" '- CNFG-1: scripts/cfg.sh:"x" — open scripts/cfg.sh' "$(_l K9d)"

print_test_section "K4-K5: test-author's check, per SPEC"
(
    # shellcheck source=../../plugins/agent/test-author/plugin.sh
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
    A="$ZBUILD_STATE_DIR/artifacts"
    _counting_judge _R
    R="$TEST_TEMP_DIR/k4-repo"; mkdir -p "$R/tests"; git -C "$R" init -q; D="$TEST_TEMP_DIR/k4.md"
    printf '# Design\n```acceptance\nLOOP-1[code]: fresh runs and nested re-entries start at round 1\nKEEP-1[code]: the saved round is read on resume\nWIRING: none\n```\n' > "$D"
    printf 'assert_eq "[LOOP-1] a fresh run starts at 1" "1" "$got"\n' > "$R/tests/loop-test.sh"
    printf 'assert_eq "[KEEP-1] resume reads the saved round" "2" "$got"\n' > "$R/tests/keep-test.sh"
    # #2467 (ADR-073 §6): a line per part (a one-line SPEC is its one Then), and the sections.
    _R=$'LOOP-1 Then 1: missing | WHY: only a fresh run | QUOTE: "nested re-entries"\nLOOP-1 sections: ok\nKEEP-1 Then 1: ok\nKEEP-1 sections: ok\n'
    _j() { printf 0 > "$_N"; _ta_correspondence "$D" "$R" T2 "$A" >/dev/null 2>&1; printf '%s|%s' "$(_calls)" "${#_TA_CORR_FINDINGS[@]}"; }
    echo "K4a|$(_j)"
    echo "K4b|$(_j)"
    printf 'assert_eq "[KEEP-1] resume reads the saved round" "3" "$got"\n' > "$R/tests/keep-test.sh"
    _R=$'KEEP-1 Then 1: ok\nKEEP-1 sections: ok\n'
    echo "K4c|$(_j)|$(grep -c 'LOOP-1' "$_P.1" 2>/dev/null)|$(grep -q 'KEEP-1' "$_P.1" 2>/dev/null && echo asked)"
    # The finding test-author answers is its result's finding 1, written by its own writer.
    _ta_write_result "$A" unusable "1 finding" 2 \
        "$(printf '%s\n' "LOOP-1 Then 1 is not asserted: only a fresh run" | stage_findings_json)"
    _TA_ANSWERS=("test-author finding 1: wrong — the helper re-enters a nested loop before the assertion")
    _R=$'LOOP-1 Then 1: ok\nLOOP-1 sections: ok\n'
    echo "K5a|$(_j)|$(grep -c 'KEEP-1' "$_P.1" 2>/dev/null)|$([[ "$(cat "$_P.1" 2>/dev/null)" == *"re-enters a nested loop"* ]] && echo shown)"
    echo "K5b|$(_j)"
) > "$TEST_TEMP_DIR/k4.out" 2>/dev/null
_l() { grep "^$1|" "$TEST_TEMP_DIR/k4.out" | head -1 | cut -d'|' -f2-; }
assert_eq "[K4] first time: both judged, one finding" "1|1" "$(_l K4a)"
assert_eq "[K4] unchanged: no call, the same finding" "0|1" "$(_l K4b)"
assert_eq "[K4] one SPEC's test changed: that SPEC alone is asked" "1|1|0|asked" "$(_l K4c)"
assert_eq "[K5] test-author disputes LOOP-1's finding: LOOP-1 alone, the answer shown" "1|0|0|shown" "$(_l K5a)"
assert_eq "[K5] ...and that verdict is kept" "0|0" "$(_l K5b)"

print_test_section "K6: build keeps its answers"
(
    # shellcheck source=../../plugins/agent/build/plugin.sh
    source "$REPO_ROOT/plugins/agent/build/plugin.sh" >/dev/null 2>&1
    output_summary_json="$TEST_TEMP_DIR/k6/build-summary.json"; mkdir -p "${output_summary_json%/*}"
    terminated_reason=done_sentinel files_changed_count=1 files_changed_json='["scripts/cfg.sh"]' iterations=1 repo_root="$XR"
        scope_violations=(); scope_violations_created=()  # build sets them before it writes
    _ROUTE_LOOP_LAST_RESPONSE=$'Changed the flag.\nANSWER issue-acceptance finding 1: wrong — the flag already exists in cfg.sh\nLOOP_COMPLETE'
    _build_write_build_summary >/dev/null 2>&1
    echo "K6|$(jq -r '.data.answers[0] // ""' "$output_summary_json" 2>/dev/null)"
) > "$TEST_TEMP_DIR/k6.out" 2>/dev/null
assert_eq "[K6] build's answer is in its result" "issue-acceptance finding 1: wrong — the flag already exists in cfg.sh" \
    "$(grep '^K6|' "$TEST_TEMP_DIR/k6.out" | cut -d'|' -f2-)"

print_test_section "K7: issue-acceptance"
(
    # shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
    source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh" 2>/dev/null
    # shellcheck source=../../scripts/lib/stage-result.sh
    source "$REPO_ROOT/scripts/lib/stage-result.sh"
    resolve_tier() { printf 'T2'; }
    _counting_judge _R
    S="$TEST_TEMP_DIR/k7"; A="$S/artifacts"; IN="$S/inputs"; mkdir -p "$A" "$IN"; printf '{}' > "$S/pipeline-state.json"
    zb_test_issue_output "$IN" "Add a --dry-run flag." >/dev/null
    printf '%s\n' '# Design' '```acceptance' 'FLAG-1[code]: a --dry-run flag is accepted' 'WIRING: none' '```' > "$IN/design.md"
    printf '%s\n' 'diff --git a/p.sh b/p.sh' '+dry_run=1' > "$IN/diff.patch"
    zb_test_test_run_output "$IN" pass 1 0 >/dev/null
    jq -n --arg i "$IN/intake-result.json" --arg d "$IN/design.md" --arg p "$IN/diff.patch" --arg t "$IN/test-results.json" \
        '{inputs: {a: $i, b: $d, c: $p, d: $t}}' > "$S/stage-inputs.json"
    export ZBUILD_STAGE_INPUTS="$S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$A"
    _R=$'UNMET: [fix-code] the flag | WHY: it is never read | QUOTE: "Add a --dry-run flag"'
    _ia() { printf 0 > "$_N"; issue_acceptance_run issue-acceptance "$S/pipeline-state.json" >/dev/null 2>&1; printf '%s|%s' "$(_calls)" "$(jq -r '.outcome' "$A/issue-acceptance-result.json" 2>/dev/null)"; }
    echo "K7a|$(_ia)"
    echo "K7b|$(_ia)"
    (
        source "$REPO_ROOT/plugins/agent/build/plugin.sh" >/dev/null 2>&1
        output_summary_json="$A/build-summary.json"; terminated_reason=done_sentinel files_changed_count=1 files_changed_json='["p.sh"]' iterations=1 repo_root="$XR"
        scope_violations=(); scope_violations_created=()  # build sets them before it writes
        _ROUTE_LOOP_LAST_RESPONSE=$'ANSWER issue-acceptance finding 1: wrong — main() reads dry_run\nLOOP_COMPLETE'
        _build_write_build_summary >/dev/null 2>&1
    )
    _R=$'MET: the flag'
    echo "K7c|$(_ia)|$([[ "$(cat "$_P.1" 2>/dev/null)" == *"main() reads dry_run"* ]] && echo shown)"
    echo "K7d|$(_ia)"
) > "$TEST_TEMP_DIR/k7.out" 2>/dev/null
_l() { grep "^$1|" "$TEST_TEMP_DIR/k7.out" | head -1 | cut -d'|' -f2-; }
assert_eq "[K7] first time: judged" "1|fail" "$(_l K7a)"
assert_eq "[K7] unchanged: no call, the same outcome" "0|fail" "$(_l K7b)"
assert_eq "[K7] build disputes its finding: judged again, the answer shown" "1|pass|shown" "$(_l K7c)"
assert_eq "[K7] ...and kept" "0|pass" "$(_l K7d)"

print_test_section "K8: a review lens"
(
    # shellcheck source=../../core/plugin-registry/registry.sh
    source "$REPO_ROOT/core/plugin-registry/registry.sh"
    # shellcheck source=../../plugins/agent/review-lens/plugin.sh
    source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
    ART="$TEST_TEMP_DIR/k8"; mkdir -p "$ART"
    printf '%s\n' 'diff --git a/scripts/cfg.sh b/scripts/cfg.sh' '+refuse_missing_config() { [[ -f "$1" ]] || return 2; }' > "$ART/diff.patch"
    printf 'scope: all\n' > "$TEST_TEMP_DIR/k8-scope.md"
    _counting_judge _R
    _R='{"score":5,"findings":[{"file":"scripts/cfg.sh","severity":"high","message":"exit code 2 is not documented","introduced":true,"quote":"|| return 2"}]}'
    _lens() {
        printf 0 > "$_N"
        _TPL_STAGE_FAIL_ON_review_lenses="medium high critical" ZBUILD_CURRENT_STAGE=review_lenses ZBUILD_REVIEW_LENS_ID=red-team \
            _review_lens_run_inner red-team "$TEST_TEMP_DIR/k8-scope.md" "$ART/diff.patch" "$ART/lens-red-team.json" "$ART" >/dev/null 2>&1 || true
        printf '%s|%s' "$(_calls)" "$(jq -r '.outcome // "none"' "$ART/lens-red-team.json" 2>/dev/null)"
    }
    echo "K8a|$(_lens)"
    echo "K8b|$(_lens)"
    (
        source "$REPO_ROOT/plugins/agent/build/plugin.sh" >/dev/null 2>&1
        output_summary_json="$ART/build-summary.json"; terminated_reason=done_sentinel files_changed_count=1 files_changed_json='["scripts/cfg.sh"]' iterations=1 repo_root="$XR"
        scope_violations=(); scope_violations_created=()  # build sets them before it writes
        _ROUTE_LOOP_LAST_RESPONSE=$'ANSWER lens-red-team-code finding 1: wrong — exit code 2 is in the README\nLOOP_COMPLETE'
        _build_write_build_summary >/dev/null 2>&1
    )
    _R='{"score":9,"findings":[]}'
    echo "K8c|$(_lens)|$([[ "$(cat "$_P.1" 2>/dev/null)" == *"exit code 2 is in the README"* ]] && echo shown)"
) > "$TEST_TEMP_DIR/k8.out" 2>/dev/null
_l() { grep "^$1|" "$TEST_TEMP_DIR/k8.out" | head -1 | cut -d'|' -f2-; }
assert_eq "[K8] first time: judged" "1|fail" "$(_l K8a)"
assert_eq "[K8] unchanged: no call, the same outcome" "0|fail" "$(_l K8b)"
assert_eq "[K8] build disputes its finding: judged again, the answer shown" "1|pass|shown" "$(_l K8c)"

cleanup_test_env
print_test_results
