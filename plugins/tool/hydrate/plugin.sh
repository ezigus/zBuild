#!/usr/bin/env bash
# plugins/tool/hydrate/plugin.sh — Hydrate stage (#1074, ADR-050 §7, ADR-059 §3)
#
# Kind: tool  Tier: T0  (NO LLM calls — NEVER call route_to_model)
#
# Pulls prior artifacts for this issue out of `zbuild/state/issue-<N>` into the
# run's restored-artifacts area. First stage in the flow, before intake.
#
# THE PATH IS THE ENGINE'S, THE CONTENT IS THIS STAGE'S. A stage runs in its own
# subshell, so an export from here would die with it — that is ADR-052's whole
# diagnosis of #888. `ZBUILD_RESTORED_ARTIFACTS_DIR` is therefore exported by
# the runner unconditionally, at a location it derives itself, and this stage
# only fills it. Consumers already guard on `-s <file>`, so an empty or absent
# area falls through to fresh, which is the documented behaviour.
#
# PARTIALITY IS IMPOSSIBLE, NOT DETECTED. `git archive | tar` can fail
# mid-stream (disk full, permissions) leaving a half-extracted tree. PR #1880's
# review caught the engine adopting one and gated on the status. Extracting to a
# staging dir and promoting with a single `mv` removes the failure mode instead
# of checking for it: the exported area is complete or it does not exist.

[[ -n "${_ZBUILD_HYDRATE_LOADED:-}" ]] && return 0
_ZBUILD_HYDRATE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_ZBUILD_HYDRATE_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_ZBUILD_HYDRATE_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/state/artifact-persist.sh
source "$_ZBUILD_HYDRATE_ROOT/core/state/artifact-persist.sh"
# shellcheck source=../../../core/state/atomic.sh
source "$_ZBUILD_HYDRATE_ROOT/core/state/atomic.sh"

# ─── _hydrate_fetch <issue> ──────────────────────────────────────────────────
# Make origin's copy of the state branch available locally.
#
# WHY: `_artifact_persist_restore` reads `refs/heads/<branch>` first and
# `refs/remotes/origin/<branch>` second. On a fresh clone — which every CI
# runner is — NEITHER exists until something fetches, so restore reports "first
# run" for an issue that has plenty of prior work. That is the half of ADR-050
# that only ever worked because the CI workflow fetched the branch itself in a
# `run:` block; doing it here is what makes local and CI one mechanism.
#
# Fetch updates the REMOTE-TRACKING ref only. It never moves `refs/heads`, so a
# local snapshot that was never pushed survives this untouched — which is the
# point: preferring origin over unpushed local work would lose that work.
_hydrate_fetch() {
    local issue="$1"
    local branch; branch="$(_artifact_persist_branch "$issue")"
    git remote get-url origin >/dev/null 2>&1 || return 0
    git fetch --quiet --no-tags origin \
        "+refs/heads/${branch}:refs/remotes/origin/${branch}" 2>/dev/null
}

# ─── hydrate_run <stage_id> <state_file> ─────────────────────────────────────
hydrate_run() {
    local _stage_id="${1:-hydrate}"
    local _state_file="${2:-}"

    local _issue="${ZBUILD_ISSUE_NUMBER:-${ZBUILD_ISSUE:-0}}"
    local _state_dir
    if [[ -n "$_state_file" ]]; then
        _state_dir="$(dirname "$_state_file")"
    else
        _state_dir="${ZBUILD_STATE_DIR:-}"
    fi
    local _artifacts_dir="${ZBUILD_ARTIFACT_DIR:-$_state_dir/artifacts}"

    emit_event "hydrate.start" "stage=$_stage_id" "issue=$_issue" 2>/dev/null || true

    if [[ ! "$_issue" =~ ^[0-9]+$ || "$_issue" -le 0 ]]; then
        # A --goal run has no state branch. ADR-059 §5 gives goal runs an
        # identity of their own (#1931); until then this is a genuine no-op.
        _hydrate_write_result "$_artifacts_dir" "complete" \
            "no issue number — nothing to hydrate (a --goal run; see #1931)" "skipped" 0
        emit_event "hydrate.complete" "stage=$_stage_id" "issue=$_issue" \
            "restored=0" "reason=no_issue" 2>/dev/null || true
        return 0
    fi

    # The engine derives and exports this; we only fill it. Recomputing the same
    # expression here rather than inventing one keeps the two halves from
    # drifting — a boundary whose halves disagree about where something lives is
    # not a boundary (#1809).
    local _target="${ZBUILD_RESTORED_ARTIFACTS_DIR:-$_state_dir/restored-artifacts/artifacts}"
    local _restored_root; _restored_root="$(dirname "$_target")"
    local _staging="${_restored_root}.staging"

    if ! _hydrate_fetch "$_issue"; then
        # Not fatal, and not silent. An offline developer still hydrates from a
        # local snapshot; a CI runner does not, and needs to see why.
        emit_event "hydrate.fetch.failed" "stage=$_stage_id" "issue=$_issue" 2>/dev/null || true
    fi

    rm -rf "$_staging" 2>/dev/null || true
    local _verdict="complete" _reason="" _status="empty" _count=0

    if _artifact_persist_restore "$_issue" "$_staging"; then
        _status="${_ARTIFACT_PERSIST_LAST_STATUS:-unknown}"
    else
        _status="failed"
        _verdict="degraded"
        # PATH-FREE on purpose. The library's reason embeds absolute paths
        # (`repo_root=… git_dir=… cwd=…`), which differ between two runs of the
        # same pipeline — the parity test caught exactly that. ADR-016 also
        # lists path leakage as mandatory: a result artifact can be quoted into
        # a GitHub comment. The detail still reaches the operator, on the event
        # and the warn below, which stay local.
        _reason="restore failed (see hydrate.restore.failed)"
        emit_event "hydrate.restore.failed" "stage=$_stage_id" "issue=$_issue" \
            "reason=${_ARTIFACT_PERSIST_LAST_REASON:-unknown}" 2>/dev/null || true
        warn "hydrate: restore failed: ${_ARTIFACT_PERSIST_LAST_REASON:-unknown}"
    fi

    # Promote ONLY a complete extraction. On failure the staging tree is
    # discarded whole — a half-restored artifact set seeded into a stage is
    # worse than no prior work at all (PR #1880 review).
    if [[ "$_status" != "failed" && -d "$_staging/artifacts" ]] \
       && [[ -n "$(ls -A "$_staging/artifacts" 2>/dev/null)" ]]; then
        _count="$(find "$_staging/artifacts" -type f 2>/dev/null | /usr/bin/grep -c . || printf '0')"
        rm -rf "$_restored_root" 2>/dev/null || true
        if mkdir -p "$(dirname "$_restored_root")" && mv "$_staging" "$_restored_root"; then
            [[ -n "$_reason" ]] || _reason="restored $_count artifact(s) from zbuild/state/issue-$_issue"
        else
            _verdict="degraded"
            _reason="restored tree could not be promoted into place"
            _count=0
        fi
    else
        rm -rf "$_staging" 2>/dev/null || true
        [[ -n "$_reason" ]] || _reason="no prior work for issue $_issue (first run)"
    fi

    _hydrate_write_result "$_artifacts_dir" "$_verdict" "$_reason" "$_status" "$_count"
    emit_event "hydrate.complete" "stage=$_stage_id" "issue=$_issue" \
        "restored=$_count" "status=$_status" 2>/dev/null || true
    # Always 0. Prior work is an optimisation: a run that cannot find any still
    # has everything it needs to do the work from scratch.
    return 0
}

_hydrate_write_result() {
    local _dir="$1" _verdict="$2" _reason="$3" _status="$4" _count="$5"
    mkdir -p "$_dir" 2>/dev/null || true
    local _file="$_dir/hydrate-result.json"
    if ! jq -n --arg v "$_verdict" --arg r "$_reason" --arg s "$_status" \
            --argjson c "${_count:-0}" \
            '{result_contract: 2, verdict: $v, disposition: "complete",
              reason: $r, data: {status: $s, restored: $c}}' \
            | atomic_write "$_file"; then
        emit_event "hydrate.result.write_failed" "file=$_file" 2>/dev/null || true
    fi
}
