#!/usr/bin/env bash
# plugins/tool/persist/plugin.sh — Persist stage (#1071, ADR-050 §7, ADR-059 §3)
#
# Kind: tool  Tier: T0  (NO LLM calls — NEVER call route_to_model)
#
# Snapshots the run's artifact area to `zbuild/state/issue-<N>` and PUSHES it,
# on every pipeline exit path. Declared always-run in the template (#1831),
# AFTER release.
#
# WHY A STAGE AND NOT ENGINE CODE: `_runner_snapshot_artifacts` is called from
# six stage-boundary sites, which is ADR-050 §4's incremental design and stays.
# What never existed is the RUN-END half: a final snapshot and a push that
# happen however the run ends. Wiring that at a seventh call site would repeat
# the failure #1878 already found — "the snapshot was never called" — so it is
# declared in the template instead, where "on every exit path" is a property of
# the flow rather than a line number an edit can drop.
#
# Always returns 0. A failed push degrades to "state is local only", which is
# today's behaviour for every local run, so the fallback is already proven.

[[ -n "${_ZBUILD_PERSIST_LOADED:-}" ]] && return 0
_ZBUILD_PERSIST_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_ZBUILD_PERSIST_DIR="$_ZBUILD_PLUGIN_DIR"
_ZBUILD_PERSIST_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_ZBUILD_PERSIST_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/state/artifact-persist.sh
source "$_ZBUILD_PERSIST_ROOT/core/state/artifact-persist.sh"
# shellcheck source=../../../core/state/atomic.sh
source "$_ZBUILD_PERSIST_ROOT/core/state/atomic.sh"
# #1071: the shared credential patterns, extracted from plugins/tool/secret-scan
# when this stage became their second consumer. Cross-calling the plugin's
# private `_ss_scan_content` would be the boundary #1809 refused to accept.
# shellcheck source=../../../scripts/lib/secret-patterns.sh
source "$_ZBUILD_PERSIST_ROOT/scripts/lib/secret-patterns.sh"

# ─── _persist_scan_artifacts <artifacts_dir> ─────────────────────────────────
# Echo `<relative-path>:<finding-kind>` for the FIRST artifact that looks like it
# carries a credential; return 1 when the area is clean.
#
# WHY HERE AND NOT EARLIER: these artifacts are already snapshotted to a LOCAL
# branch today with no scan at all. This stage is what makes them leave the
# machine, and "about to be published" is a different risk from "written to a
# file on the operator's disk". The gate belongs where the risk changes.
#
# Binary files are skipped rather than scanned: `grep -q` on binary content is
# unreliable, and a credential in a binary artifact is not a shape this
# pipeline produces.
_persist_scan_artifacts() {
    local art_dir="$1" f rel kind
    [[ -d "$art_dir" ]] || return 1
    while IFS= read -r -d '' f; do
        # Skip anything that is not text. `grep -Iq .` returns non-zero for a
        # binary file, which is the cheapest portable test available.
        grep -Iq . "$f" 2>/dev/null || continue
        if kind="$(zbuild_scan_secret_content "$(cat "$f" 2>/dev/null)")"; then
            rel="${f#"$art_dir"/}"
            printf '%s:%s' "$rel" "$kind"
            return 0
        fi
    done < <(find "$art_dir" -type f -print0 2>/dev/null)
    return 1
}

# ─── persist_run <stage_id> <state_file> ─────────────────────────────────────
persist_run() {
    local _stage_id="${1:-persist}"
    local _state_file="${2:-}"

    local _issue="${ZBUILD_ISSUE_NUMBER:-${ZBUILD_ISSUE:-0}}"
    local _state_dir
    if [[ -n "$_state_file" ]]; then
        _state_dir="$(dirname "$_state_file")"
    else
        _state_dir="${ZBUILD_STATE_DIR:-}"
    fi
    local _artifacts_dir="${ZBUILD_ARTIFACT_DIR:-$_state_dir/artifacts}"

    emit_event "persist.start" "stage=$_stage_id" "issue=$_issue" 2>/dev/null || true

    local _verdict="complete" _reason="" _pushed="false" _snapshot="skipped"
    # #1966: the CI backstop must tell "nothing to push" (no issue, no goal) from
    # "did not push" (identity existed, the push did not happen). Without the
    # distinction it either fires on every identity-less run or cannot fire at all.
    local _identity_present="false"
    _artifact_persist_has_identity "$_issue" && _identity_present="true"

    if ! _artifact_persist_has_identity "$_issue"; then
        # Neither an issue nor a goal: no identity, so nothing to persist under.
        # A --goal run DOES have one (#1931) and no longer lands here.
        _reason="no identity — neither an issue nor a goal"
        _persist_write_result "$_artifacts_dir" "complete" "$_reason" "$_snapshot" "$_pushed" "$_identity_present"
        emit_event "persist.complete" "stage=$_stage_id" "issue=$_issue" \
            "pushed=false" "reason=no_issue" 2>/dev/null || true
        return 0
    fi

    # ── 1. Final snapshot ────────────────────────────────────────────────────
    # The per-stage snapshots (ADR-050 §4) have already run at each boundary.
    # This one catches whatever the LAST stage produced, which no boundary call
    # covers — including the stage that failed and ended the run.
    if _artifact_persist_snapshot "$_state_dir" "$_issue"; then
        _snapshot="${_ARTIFACT_PERSIST_LAST_STATUS:-unknown}"
    else
        _snapshot="failed"
        _verdict="degraded"
        # Path-free: the library reason carries absolute paths, which differ
        # between runs and can be quoted into a GitHub comment (ADR-016).
        _reason="snapshot failed (see persist.snapshot.failed)"
        emit_event "persist.snapshot.failed" "stage=$_stage_id" "issue=$_issue" \
            "reason=${_ARTIFACT_PERSIST_LAST_REASON:-unknown}" 2>/dev/null || true
    fi

    # ── 2. Record the outcome, then snapshot AGAIN so it reaches the branch ──
    # Every other stage's result file is on the state branch; persist's was on
    # neither branch, because it was written after the only snapshot. The stage
    # whose job is durability had no durable record of itself (ADR-050 §3
    # amendment). The first snapshot cannot contain the file that describes it,
    # so a second one carries it.
    #
    # pushed = null, not false: the push has not been attempted yet, and a push
    # can never record its own outcome. The authoritative value is written to
    # the LOCAL copy at step 5 and reported in the CI log. A reader of the
    # BRANCH copy sees null and must not read it as "the push failed".
    _persist_write_result "$_artifacts_dir" "$_verdict" \
        "${_reason:-snapshotted zbuild/state/issue-$_issue}" \
        "$_snapshot" "null" "$_identity_present"
    # AMEND only when the snapshot above created the tip ("saved"). On
    # unchanged/empty/failed it created nothing, so the tip belongs to an earlier
    # stage boundary and amending would discard that legitimate commit — this
    # second snapshot must then extend normally. Either way the branch gains at
    # most ONE commit per persist run.
    local _snap_mode=""
    [[ "$_snapshot" == "saved" ]] && _snap_mode="amend"
    # Loud, for the same reason step 1 is. A silent failure here means
    # persist-result.json never reaches the branch — which is the exact defect
    # this ordering was written to fix, just relocated. The verdict is NOT
    # demoted: the push can still succeed and the local copy still carries the
    # truth, so this degrades the record, not the run.
    if ! _artifact_persist_snapshot "$_state_dir" "$_issue" "" "$_snap_mode" >/dev/null 2>&1; then
        emit_event "persist.snapshot.failed" "stage=$_stage_id" "issue=$_issue" \
            "reason=${_ARTIFACT_PERSIST_LAST_REASON:-second snapshot failed}" 2>/dev/null || true
        warn "persist: result snapshot failed — persist-result.json will not reach the state branch"
    fi

    # ── 3. Secret gate, before anything leaves the machine ───────────────────
    # After the write above, so the gate scans persist-result.json too: nothing
    # reaches origin unscanned.
    local _finding
    if _finding="$(_persist_scan_artifacts "$_artifacts_dir")"; then
        # REFUSED, not degraded-and-pushed. Publishing a credential is not
        # recoverable by a later run the way a missing snapshot is.
        emit_event "persist.push.refused" "stage=$_stage_id" "issue=$_issue" \
            "finding=${_finding}" 2>/dev/null || true
        warn "persist: refusing to push — artifact looks like it carries a credential (${_finding})"
        _persist_write_result "$_artifacts_dir" "degraded" \
            "push refused: possible credential in ${_finding}" "$_snapshot" "false" "$_identity_present"
        emit_event "persist.complete" "stage=$_stage_id" "issue=$_issue" \
            "pushed=false" "reason=secret_refused" 2>/dev/null || true
        return 0
    fi

    # ── 4. Push (once, ADR-050 §4) ───────────────────────────────────────────
    if _artifact_persist_push "$_issue"; then
        case "${_ARTIFACT_PERSIST_LAST_STATUS:-}" in
            saved) _pushed="true" ;;
            *)     _pushed="false"
                   # Also path-free: "no origin remote configured" is safe, but
                   # "unresolvable repo: …cwd=…" is not, and both arrive here.
                   [[ -n "$_reason" ]] || _reason="nothing was pushed (see persist.complete)" ;;
        esac
    else
        _pushed="false"
        _verdict="degraded"
        _reason="push failed (see persist.push.failed)"
        # Loud. A silent push failure is how #1921 went unnoticed for the life
        # of the feature — hundreds of local commits and nothing on origin, with
        # no event anywhere saying so.
        emit_event "persist.push.failed" "stage=$_stage_id" "issue=$_issue" \
            "reason=${_ARTIFACT_PERSIST_LAST_REASON:-unknown}" 2>/dev/null || true
        warn "persist: push failed (state is local only): ${_ARTIFACT_PERSIST_LAST_REASON:-unknown}"
    fi

    # ── 5. The local copy gets the authoritative push outcome ────────────────
    # Deliberately NOT re-snapshotted: that would need a third snapshot and a
    # second push, and the push outcome would still be one step behind itself.
    # The branch keeps pushed=null; local and the CI log carry the truth.
    [[ -n "$_reason" ]] || _reason="snapshotted and pushed zbuild/state/issue-$_issue"
    _persist_write_result "$_artifacts_dir" "$_verdict" "$_reason" "$_snapshot" "$_pushed" "$_identity_present"
    emit_event "persist.complete" "stage=$_stage_id" "issue=$_issue" \
        "pushed=$_pushed" "snapshot=$_snapshot" 2>/dev/null || true
    # Always 0: persistence is advisory. It must never change a run's verdict —
    # a run that produced good work and could not reach the network still
    # produced good work.
    return 0
}

# ─── _persist_write_result <dir> <verdict> <reason> <snap> <pushed> [id_present] ─
# Guarded like teardown's: an unguarded pipe would abort persist_run on a failed
# write, before persist.complete and before the `return 0` ADR-054 §4 requires.
_persist_write_result() {
    local _dir="$1" _verdict="$2" _reason="$3" _snap="$4" _pushed="$5" _ip="${6:-false}"
    mkdir -p "$_dir" 2>/dev/null || true
    local _file="$_dir/persist-result.json"
    if ! jq -n \
            --arg v "$_verdict" --arg r "$_reason" \
            --arg s "$_snap" --argjson p "$_pushed" --argjson ip "$_ip" \
            '{result_contract: 2, verdict: $v, disposition: "complete",
              reason: $r, data: {snapshot: $s, pushed: $p, identity_present: $ip}}' \
            | atomic_write "$_file"; then
        emit_event "persist.result.write_failed" "file=$_file" 2>/dev/null || true
    fi
}
