#!/usr/bin/env bash
# core/state/layout.sh — the one answer to "where does zBuild put things?"
# (#141, ADR-059 §1).
#
# WHY THIS EXISTS BEFORE THE MOVE. ADR-059 §1 re-keys everything from `run_id`
# to the issue, and its Consequences record the cost honestly: "~17 call sites
# assume the flat shape, and six fail silently". The worst is
# `_cleanup_is_active_run`, whose glob would match nothing, report *no run is
# live*, and un-gate three destructive scanners against running jobs.
#
# That risk is not caused by the move. It is caused by seventeen places
# RE-DERIVING the same paths, so moving them means finding all seventeen and
# being right about each. Collapsing them here first makes the move a change to
# THIS FILE — which is the same reason #1930 extracted identity and #1809
# extracted output paths.
#
# READER AND WRITER SHARE THESE FUNCTIONS. That is the property that matters: a
# reader that globs where the writer no longer writes is the silent failure, and
# two halves that cannot disagree cannot produce it.
#
# NOT YET THE NEW LAYOUT. The target shape in ADR-059 §1 is
# `$ZBUILD_HOME/repos/<repo>/issues/<N>/…`, and its `<repo>` segment is #141's
# open decision — `{owner}/{repo}` or a hash, and 12 hex or 64. Choosing here
# would commit every operator's on-disk state to a guess, and getting it wrong
# means migrating twice. So these functions return TODAY's paths, and the move
# is a change to their bodies once #141 answers.

[[ -n "${_ZBUILD_LAYOUT_LOADED:-}" ]] && return 0
_ZBUILD_LAYOUT_LOADED=1

# ─── zbuild_layout_state_root ────────────────────────────────────────────────
# The root every run's state lives under. Honours ZBUILD_STATE_ROOT, which is
# ADR-024's nested-run fence (#1127) and must keep working.
zbuild_layout_state_root() {
    printf '%s' "${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}"
}

# ─── zbuild_layout_runs_root ─────────────────────────────────────────────────
# Where per-run directories live. The single definition the WRITER (runner.sh)
# and every READER (cleanup, doctor, the CLI) must agree on.
zbuild_layout_runs_root() {
    printf '%s/runs' "$(zbuild_layout_state_root)"
}

# ─── zbuild_layout_run_dir <run_id> ──────────────────────────────────────────
zbuild_layout_run_dir() {
    local rid="${1:-}"
    [[ -n "$rid" ]] || return 1
    printf '%s/%s' "$(zbuild_layout_runs_root)" "$rid"
}

# ─── zbuild_layout_state_file_globs ──────────────────────────────────────────
# Every place a `pipeline-state.json` can be, newline-separated, most specific
# first.
#
# THIS IS THE ONE THAT BITES. `_cleanup_is_active_run` globs for state files to
# decide whether a run is live, and three destructive scanners are gated on its
# answer. When the layout moves and the glob does not, it matches nothing and
# reports "no run is live" — the FAIL-OPEN direction on a destructive path, and
# indistinguishable from "nothing is running".
#
# The flat `<root>/pipeline-state*.json` entry is the pre-#887 shape and is kept
# deliberately: an operator upgrading across the change still has runs there.
zbuild_layout_state_file_globs() {
    local root; root="$(zbuild_layout_state_root)"
    printf '%s/runs/*/pipeline-state*.json\n' "$root"
    printf '%s/pipeline-state*.json\n' "$root"
}

# ─── zbuild_layout_has_any_run_state ─────────────────────────────────────────
# rc=0 when at least one state file exists ANYWHERE the globs reach.
#
# Exists so a caller can tell "I looked and nothing is running" from "I looked
# in the wrong place". Those are the same observation to a glob and opposite
# answers to a reclaimer, which is exactly how a layout change turns into data
# loss rather than an error.
zbuild_layout_has_any_run_state() {
    local g f
    while IFS= read -r g; do
        [[ -n "$g" ]] || continue
        for f in $g; do
            [[ -f "$f" ]] && return 0
        done
    done < <(zbuild_layout_state_file_globs)
    return 1
}
