#!/usr/bin/env bash
# Tests: scripts/lib/cleanup.sh — job-folder reclamation (#1920)
#
# `--state-dirs` used to delete pipeline-state.json{,.bak,.lock} and leave
# runs/<run_id>/ standing. These pin the scanner's guards, the guard NAMES
# (#1634 — a clean scan and a broken scan must not look identical), and the
# applier's containment revalidation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "cleanup job-folder reclamation (#1920)"
setup_test_env "cleanup-state-dirs-reclaim"

# shellcheck source=../../scripts/lib/cleanup.sh
source "$REPO_ROOT/scripts/lib/cleanup.sh"

STATE_DIR="$TEST_TEMP_DIR/state"
RUNS="$STATE_DIR/runs"
mkdir -p "$RUNS"
# _cleanup_is_active_run reads this, not the scanner's argument.
export ZBUILD_STATE_DIR="$STATE_DIR"

_age() {
    local path="$1" days="$2" secs
    secs=$(( days * 86400 ))
    if ! touch -d "@$(( $(date +%s) - secs ))" "$path" 2>/dev/null; then
        local ts; ts="$(date -r $(( $(date +%s) - secs )) "+%Y%m%d%H%M.%S")"
        touch -t "$ts" "$path"
    fi
}

# A job folder with the shape a real run leaves behind: state file plus the
# subtrees that are the whole point of reclaiming the DIRECTORY rather than
# three JSON files (ADR-058 §1).
_mkrun() {
    local rid="$1" status="$2" days="$3"
    local d="$RUNS/$rid"
    mkdir -p "$d/artifacts" "$d/scratch/test" "$d/runtime"
    printf 'evidence\n' > "$d/events.jsonl"
    printf 'big\n'      > "$d/scratch/test/staging.txt"
    if [[ "$status" != "NOSTATE" ]]; then
        jq -n --arg s "$status" --arg id "$rid" \
            '{schema_version:1, run_id:$id, issue:1, status:$s, stage_statuses:{},
              current_iteration:0, self_heal_count:{}, updated_at:"2026-01-01T00:00:00.000Z"}' \
            > "$d/pipeline-state.json"
        _age "$d/pipeline-state.json" "$days"
    else
        _age "$d" "$days"
    fi
}

_decision() {  # _decision <plan> <run_id>  → prune | skip | ""
    local plan="$1" rid="$2" line
    line="$(grep -F "$RUNS/$rid	" <<<"$plan" || true)"
    [[ -z "$line" ]] && return 0
    line="${line#*$'\t'}"
    printf '%s' "${line%%$'\t'*}"
}

_reason() {   # _reason <plan> <run_id>
    local plan="$1" rid="$2" line
    line="$(grep -F "$RUNS/$rid	" <<<"$plan" || true)"
    [[ -z "$line" ]] && return 0
    printf '%s' "${line##*$'\t'}"
}

_mkrun old-complete     complete    30
_mkrun old-failed       failed      30
_mkrun old-aborted      aborted     30
_mkrun fresh-complete   complete     0
_mkrun live             in_progress 30
_mkrun old-interrupted  interrupted 30
_mkrun weird-status     banana      30
_mkrun no-state         NOSTATE     30

plan="$(_cleanup_scan_state_dirs "$STATE_DIR" 7 false)"

# ── SPEC-1: terminal job folders older than retention are prune candidates ───
for rid in old-complete old-failed old-aborted; do
    if [[ "$(_decision "$plan" "$rid")" == "prune" ]]; then
        assert_pass "[SPEC-1] $rid is a prune candidate"
    else
        assert_fail "[SPEC-1] $rid is a prune candidate" "plan: $plan"
    fi
done

# ── SPEC-2: every guard emits a NAMED skip, never silence (#1634) ────────────
# A guard that `continue`s without a line makes "nothing to clean" and "the
# filter ate everything" the same output — the failure mode #1634 was filed for.
_expect_skip() {  # _expect_skip <run_id> <substring of reason>
    local rid="$1" needle="$2" dec reason
    dec="$(_decision "$plan" "$rid")"
    reason="$(_reason "$plan" "$rid")"
    if [[ "$dec" != "skip" ]]; then
        assert_fail "[SPEC-2] $rid is skipped" "decision=${dec:-<absent from plan>}"
        return
    fi
    if [[ "$reason" == *"$needle"* ]]; then
        assert_pass "[SPEC-2] $rid skipped, guard named: $reason"
    else
        assert_fail "[SPEC-2] $rid skip must name the guard ($needle)" "reason: $reason"
    fi
}
_expect_skip live            "active run"
_expect_skip fresh-complete  "newer than 7d"
_expect_skip old-interrupted "interrupted"
_expect_skip weird-status    "unrecognised"
_expect_skip no-state        "no pipeline-state.json"

# ── SPEC-3: in_progress is never a candidate, even with --force ──────────────
plan_force="$(_cleanup_scan_state_dirs "$STATE_DIR" 7 true)"
if [[ "$(_decision "$plan_force" "live")" == "skip" ]]; then
    assert_pass "[SPEC-3] in_progress skipped even with --force (fail-closed)"
else
    assert_fail "[SPEC-3] in_progress skipped even with --force" "plan: $plan_force"
fi

# ── SPEC-4: --force releases interrupted, unknown-status and state-less dirs ─
for rid in old-interrupted weird-status no-state; do
    if [[ "$(_decision "$plan_force" "$rid")" == "prune" ]]; then
        assert_pass "[SPEC-4] $rid becomes a candidate with --force"
    else
        assert_fail "[SPEC-4] $rid becomes a candidate with --force" "plan: $plan_force"
    fi
done

# ── SPEC-5: the current run is skipped by ZBUILD_RUN_ID even when terminal ───
plan_cur="$(ZBUILD_RUN_ID=old-complete _cleanup_scan_state_dirs "$STATE_DIR" 7 false)"
if [[ "$(_decision "$plan_cur" "old-complete")" == "skip" ]] \
   && [[ "$(_reason "$plan_cur" "old-complete")" == *"current run"* ]]; then
    assert_pass "[SPEC-5] current run skipped by ZBUILD_RUN_ID, guard named"
else
    assert_fail "[SPEC-5] current run skipped by ZBUILD_RUN_ID" "plan: $plan_cur"
fi

# ── SPEC-6: dry-run removes nothing ─────────────────────────────────────────
_cleanup_apply_dir_plan "$plan" true "$RUNS"
if [[ -d "$RUNS/old-complete" ]]; then
    assert_pass "[SPEC-6] dry-run preserves the job folder"
else
    assert_fail "[SPEC-6] dry-run preserves the job folder"
fi

# ── SPEC-7: apply reclaims the WHOLE folder, not the state JSON ─────────────
# The nested assertions are the point: the old applier deleted three files and
# left artifacts/, events.jsonl and scratch/ behind, which is the bug.
_cleanup_apply_dir_plan "$plan" false "$RUNS"
if [[ ! -e "$RUNS/old-complete" ]]; then
    assert_pass "[SPEC-7] apply removes the job folder entirely"
else
    assert_fail "[SPEC-7] apply removes the job folder entirely" \
        "survivors: $(find "$RUNS/old-complete" 2>/dev/null | head -5 | tr '\n' ' ')"
fi
if [[ ! -e "$RUNS/old-failed/scratch/test/staging.txt" && ! -e "$RUNS/old-failed/events.jsonl" ]]; then
    assert_pass "[SPEC-7] nested scratch + evidence go with the folder"
else
    assert_fail "[SPEC-7] nested scratch + evidence go with the folder"
fi
# Guarded entries must have survived the same apply call.
if [[ -d "$RUNS/live" && -d "$RUNS/fresh-complete" && -d "$RUNS/old-interrupted" ]]; then
    assert_pass "[SPEC-7] skip-decision folders survive the same apply"
else
    assert_fail "[SPEC-7] skip-decision folders survive the same apply"
fi

# ── SPEC-8: containment — outside targets refused, inside target still acted ─
# Both halves in ONE call. A refusal assertion alone cannot tell "the guard
# rejected it" from "the applier did nothing at all"; the positive control is
# what makes the two distinguishable.
outside="$TEST_TEMP_DIR/outside-the-root"
mkdir -p "$outside"
_mkrun positive-control complete 30
mixed="$(printf '%s\tprune\tinjected\n%s\tprune\trun=positive-control\n' \
    "$outside" "$RUNS/positive-control")"
_cleanup_apply_dir_plan "$mixed" false "$RUNS"
if [[ -d "$outside" ]]; then
    assert_pass "[SPEC-8] target outside the runs root is refused"
else
    assert_fail "[SPEC-8] target outside the runs root is refused"
fi
if [[ ! -e "$RUNS/positive-control" ]]; then
    assert_pass "[SPEC-8] positive control: the same call DID delete inside the root"
else
    assert_fail "[SPEC-8] positive control: the same call DID delete inside the root" \
        "applier was inert — the refusal above proves nothing"
fi

# ── SPEC-9: the runs root itself is never the target ────────────────────────
_mkrun root-probe complete 30
root_plan="$(printf '%s\tprune\tinjected root\n' "$RUNS")"
_cleanup_apply_dir_plan "$root_plan" false "$RUNS"
if [[ -d "$RUNS" && -d "$RUNS/root-probe" ]]; then
    assert_pass "[SPEC-9] applier refuses the runs root itself"
else
    assert_fail "[SPEC-9] applier refuses the runs root itself"
fi

# ── SPEC-10: a skip line is never actioned, even if it reaches the applier ──
skip_line="$(printf '%s\tskip\tnewer than 7d\n' "$RUNS/fresh-complete")"
_cleanup_apply_dir_plan "$skip_line" false "$RUNS"
if [[ -d "$RUNS/fresh-complete" ]]; then
    assert_pass "[SPEC-10] a skip decision is not deleted"
else
    assert_fail "[SPEC-10] a skip decision is not deleted"
fi

print_test_results
