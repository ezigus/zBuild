#!/usr/bin/env bash
# tests/unit/judge-events-test.sh — the old-code copy and every kept answer
# leave events (#2466, ADR-072 §2 §4).
#
# Why: on #1805 run 41757933766 whether the old-code copy was removed, and which
# SPECs reused a kept verdict, could only be inferred: nothing recorded the copy
# being made or removed, and `judge.kept` fired only when every item was kept.
#
# V1 making the copy emits judge.base.created with its base commit; asking
#    again emits nothing; no base commit emits judge.base.failed with why
# V2 teardown removing it emits judge.base.released; with no copy, nothing
# V3 test-author's check, per SPEC: judge.kept.saved for each SPEC judged,
#    judge.kept.used for each one reused and not asked, judge.kept.stale with
#    why=file / why=disputed for one that has to be judged again
# V4 design's check, issue-acceptance and a lens: saved, then used, then stale
#    why=fingerprint once what they judge changes — design's per SPEC, and its
#    requirement coverage as one more item (#2470)
# V5 judge.kept is gone; every new event is declared by the plugins that emit it
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "the old-code copy and every kept answer leave events (#2466)"
setup_test_env "judge-events"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export _RUNNER_ENGINE_SHA="engine-a"

# _ev <type> [jq filter on .data] — how many events of <type> match.
_ev() { jq -c --arg t "$1" "select(.type == \$t) | .data | select(${2:-true})" "$ZBUILD_EVENTS_JSONL" 2>/dev/null | grep -c .; }
_reset() { : > "$ZBUILD_EVENTS_JSONL"; }

XR="$TEST_TEMP_DIR/xrepo"; mkdir -p "$XR/scripts"
(
    cd "$XR" || exit 1
    git init -q -b main; git config user.email t@t; git config user.name t
    printf 'refuse_missing_config() { [[ -f "$1" ]] || return 2; }\n' > scripts/cfg.sh
    git add -A; git commit -qm base; git checkout -qb feature
)
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state/runs/r1"; mkdir -p "$ZBUILD_STATE_DIR/artifacts"
export ZBUILD_REPO_ROOT="$XR"
_BASE_SHA="$(git -C "$XR" rev-parse main)"

print_test_section "V1-V2: the old-code copy"
(
    # shellcheck source=../../core/event-bus/event-bus.sh
    source "$REPO_ROOT/core/event-bus/event-bus.sh"
    # shellcheck source=../../scripts/lib/judge.sh
    source "$REPO_ROOT/scripts/lib/judge.sh"
    b=""; judge_base_dir_v b "$XR"; judge_base_dir_v b "$XR"
    printf '%s' "$b" > "$TEST_TEMP_DIR/v1-base"
    ZBUILD_STATE_DIR="" judge_base_dir_v b "$XR"
    nb="$TEST_TEMP_DIR/nobase"; mkdir -p "$nb"; git -C "$nb" init -q
    judge_base_dir_v b "$nb"
) >/dev/null 2>&1
assert_eq "[V1] making the copy emits judge.base.created, with its base commit" "1" \
    "$(_ev judge.base.created ".base == \"$_BASE_SHA\"")"
assert_eq "[V1] ...once: asking again emits nothing" "1" "$(_ev judge.base.created)"
assert_eq "[V1] no run folder: judge.base.failed, saying so" "1" "$(_ev judge.base.failed '.reason == "no_state_dir"')"
assert_eq "[V1] no base commit: judge.base.failed, saying so" "1" "$(_ev judge.base.failed '.reason == "no_base_commit"')"
_reset
(
    cd "$XR" || exit 1
    # shellcheck source=../../plugins/tool/teardown/plugin.sh
    source "$REPO_ROOT/plugins/tool/teardown/plugin.sh"
    printf '{"stage_statuses":{}}\n' > "$ZBUILD_STATE_DIR/pipeline-state.json"
    ZBUILD_TEARDOWN_SCOPE=release teardown_run teardown "$ZBUILD_STATE_DIR/pipeline-state.json"
    ZBUILD_TEARDOWN_SCOPE=release teardown_run teardown "$ZBUILD_STATE_DIR/pipeline-state.json"
) >/dev/null 2>&1
assert_eq "[V2] teardown removing the copy emits judge.base.released" "1" \
    "$(_ev judge.base.released '.by == "teardown" and (.path | endswith("base-code"))')"
assert_eq "[V2] ...and with no copy left, nothing" "1" "$(_ev judge.base.released)"

print_test_section "V3: test-author's check, per SPEC"
_reset
(
    # shellcheck source=../../plugins/agent/test-author/plugin.sh
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
    A="$ZBUILD_STATE_DIR/artifacts"
    R="$TEST_TEMP_DIR/v3-repo"; mkdir -p "$R/tests"; git -C "$R" init -q; D="$TEST_TEMP_DIR/v3.md"
    printf '# Design\n```acceptance\nLOOP-1[code]: fresh runs start at round 1\nKEEP-1[code]: the saved round is read on resume\nWIRING: none\n```\n' > "$D"
    printf 'assert_eq "[LOOP-1] a fresh run starts at 1" "1" "$got"\n' > "$R/tests/loop-test.sh"
    printf 'assert_eq "[KEEP-1] resume reads the saved round" "2" "$got"\n' > "$R/tests/keep-test.sh"
    route_to_model() { printf '%s' "$_R"; }
    # #2467 (ADR-073 §6): a line per part (a one-line SPEC is its one Then), and the sections.
    _R=$'LOOP-1 Then 1: missing | WHY: only fresh | QUOTE: "fresh runs"\nLOOP-1 sections: ok\nKEEP-1 Then 1: ok\nKEEP-1 sections: ok\n'
    _ta_correspondence "$D" "$R" T2 "$A"
    printf 'MARK1\n' >> "$ZBUILD_EVENTS_JSONL"
    _ta_correspondence "$D" "$R" T2 "$A"
    printf 'MARK2\n' >> "$ZBUILD_EVENTS_JSONL"
    # A line after the assertion's own lines: the fingerprint is the same, the file is not.
    printf 'assert_eq "[KEEP-1] resume reads the saved round" "2" "$got"\n\n_unused_helper() { :; }\n' > "$R/tests/keep-test.sh"
    _R=$'KEEP-1 Then 1: ok\nKEEP-1 sections: ok\n'
    _ta_correspondence "$D" "$R" T2 "$A"
    printf 'MARK3\n' >> "$ZBUILD_EVENTS_JSONL"
    _ta_write_result "$A" unusable "1 finding" 2 \
        "$(printf '%s\n' "LOOP-1 Then 1 is not asserted: only fresh" | stage_findings_json)"
    _TA_ANSWERS=("test-author finding 1: wrong — it covers both")
    _R=$'LOOP-1 Then 1: ok\nLOOP-1 sections: ok\n'
    _ta_correspondence "$D" "$R" T2 "$A"
) >/dev/null 2>&1
_seg() {  # <n> — the events between marks n-1 and n, as a file
    awk -v n="$1" '/^MARK/ { k++; next } k == n - 1' "$ZBUILD_EVENTS_JSONL" > "$TEST_TEMP_DIR/seg"
    jq -c --arg t "$2" "select(.type == \$t) | .data | select(${3:-true})" "$TEST_TEMP_DIR/seg" 2>/dev/null | grep -c .
}
assert_eq "[V3] both SPECs judged: saved, each" "2" "$(_seg 1 judge.kept.saved '.check == "test-author"')"
assert_eq "[V3] ...naming LOOP-1" "1" "$(_seg 1 judge.kept.saved '.item == "LOOP-1"')"
assert_eq "[V3] unchanged: used, each" "2" "$(_seg 2 judge.kept.used '.check == "test-author"')"
assert_eq "[V3] ...and none saved again" "0" "$(_seg 2 judge.kept.saved)"
assert_eq "[V3] KEEP-1's test changed: stale, why=file" "1" "$(_seg 3 judge.kept.stale '.item == "KEEP-1" and .why == "file"')"
assert_eq "[V3] ...LOOP-1 used" "1" "$(_seg 3 judge.kept.used '.item == "LOOP-1"')"
assert_eq "[V3] ...KEEP-1 saved again" "1" "$(_seg 3 judge.kept.saved '.item == "KEEP-1"')"
assert_eq "[V3] LOOP-1 disputed: stale, why=disputed" "1" "$(_seg 4 judge.kept.stale '.item == "LOOP-1" and .why == "disputed"')"

print_test_section "V4: design's check, issue-acceptance and a lens"
_reset
(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh"
    artifact_dir="$ZBUILD_STATE_DIR/artifacts"
    route_to_model() { printf 'RQST-1: covered\nWORK-1: ok\n'; }
    D="$TEST_TEMP_DIR/v4.md"
    printf '# Design\n```acceptance\nWORK-1[code]: a flag is accepted covers: RQST-1\nWIRING: none\n```\n' > "$D"
    _design_coverage "$D" "- RQST-1: add a flag" T2
    _design_coverage "$D" "- RQST-1: add a flag" T2
    _design_coverage "$D" "- RQST-1: add a flag to every command" T2
) >/dev/null 2>&1
# #2470: kept per SPEC, and requirement coverage as one more item.
assert_eq "[V4] design: requirement coverage saved, and saved again once they change" "2" "$(_ev judge.kept.saved '.check == "design" and .item == "requirements"')"
assert_eq "[V4] ...the SPEC saved once" "1" "$(_ev judge.kept.saved '.check == "design" and .item == "WORK-1"')"
assert_eq "[V4] design: requirement coverage used once" "1" "$(_ev judge.kept.used '.check == "design" and .item == "requirements"')"
assert_eq "[V4] ...the unchanged SPEC used both times" "2" "$(_ev judge.kept.used '.check == "design" and .item == "WORK-1"')"
assert_eq "[V4] design: stale once its requirements change — that item only" "1|1" \
    "$(_ev judge.kept.stale '.check == "design" and .why == "fingerprint"')|$(_ev judge.kept.stale '.check == "design" and .item == "requirements"')"
_reset
(
    # shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
    source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh"
    # shellcheck source=../../scripts/lib/stage-result.sh
    source "$REPO_ROOT/scripts/lib/stage-result.sh"
    resolve_tier() { printf 'T2'; }
    route_to_model() { printf 'MET: the flag\n'; }
    S="$TEST_TEMP_DIR/v4ia"; A="$S/artifacts"; IN="$S/inputs"; mkdir -p "$A" "$IN"; printf '{}' > "$S/pipeline-state.json"
    zb_test_issue_output "$IN" "Add a flag." >/dev/null
    printf '%s\n' 'diff --git a/p.sh b/p.sh' '+flag=1' > "$IN/diff.patch"
    jq -n --arg i "$IN/intake-result.json" --arg p "$IN/diff.patch" '{inputs: {a: $i, c: $p}}' > "$S/stage-inputs.json"
    export ZBUILD_STAGE_INPUTS="$S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$A"
    issue_acceptance_run issue-acceptance "$S/pipeline-state.json"
    issue_acceptance_run issue-acceptance "$S/pipeline-state.json"
    printf '%s\n' 'diff --git a/p.sh b/p.sh' '+flag=2' > "$IN/diff.patch"
    issue_acceptance_run issue-acceptance "$S/pipeline-state.json"
) >/dev/null 2>&1
assert_eq "[V4] issue-acceptance: saved, used, stale" "2|1|1" \
    "$(_ev judge.kept.saved '.check == "issue-acceptance"')|$(_ev judge.kept.used '.check == "issue-acceptance"')|$(_ev judge.kept.stale '.check == "issue-acceptance" and .why == "fingerprint"')"
_reset
(
    # shellcheck source=../../core/plugin-registry/registry.sh
    source "$REPO_ROOT/core/plugin-registry/registry.sh"
    # shellcheck source=../../plugins/agent/review-lens/plugin.sh
    source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
    ART="$TEST_TEMP_DIR/v4lens"; mkdir -p "$ART"
    printf '%s\n' 'diff --git a/scripts/cfg.sh b/scripts/cfg.sh' '+x=1' > "$ART/diff.patch"
    printf 'scope: all\n' > "$TEST_TEMP_DIR/v4-scope.md"
    route_to_model() { printf '{"score":9,"findings":[]}'; }
    _l() { ZBUILD_CURRENT_STAGE=review_lenses ZBUILD_REVIEW_LENS_ID=red-team \
        _review_lens_run_inner red-team "$TEST_TEMP_DIR/v4-scope.md" "$ART/diff.patch" "$ART/lens-red-team.json" "$ART"; }
    _l; _l
    printf '%s\n' 'diff --git a/scripts/cfg.sh b/scripts/cfg.sh' '+x=2' > "$ART/diff.patch"
    _l
) >/dev/null 2>&1
assert_eq "[V4] a lens: saved, used, stale" "2|1|1" \
    "$(_ev judge.kept.saved '.check == "lens-red-team"')|$(_ev judge.kept.used '.check == "lens-red-team"')|$(_ev judge.kept.stale '.check == "lens-red-team" and .why == "fingerprint"')"

print_test_section "V5: declared, and judge.kept gone"
_decl() { grep -c -- "- $2\$" "$REPO_ROOT/plugins/$1/manifest.yaml" || true; }
for _p in agent/design agent/test-author agent/issue-acceptance agent/review-lens; do
    for _e in judge.kept.saved judge.kept.used judge.kept.stale; do
        assert_eq "[V5] $_p declares $_e" "1" "$(_decl "$_p" "$_e")"
    done
    assert_eq "[V5] $_p no longer declares judge.kept" "0" "$(_decl "$_p" judge.kept)"
done
assert_eq "[V5] design declares judge.base.created" "1" "$(_decl agent/design judge.base.created)"
assert_eq "[V5] design declares judge.base.failed" "1" "$(_decl agent/design judge.base.failed)"
assert_eq "[V5] teardown declares judge.base.released" "1" "$(_decl tool/teardown judge.base.released)"
assert_eq "[V5] ...and so does design, which replaces a copy for a new base commit" "1" "$(_decl agent/design judge.base.released)"
assert_eq "[V5] no code emits judge.kept any more" "0" \
    "$(grep -rn '"judge\.kept"' "$REPO_ROOT/scripts" "$REPO_ROOT/plugins" --include='*.sh' | grep -v '/tests/' | grep -c . || true)"

cleanup_test_env
print_test_results
