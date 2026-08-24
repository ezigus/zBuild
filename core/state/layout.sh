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

# zbuild_repo_slug (#1930). Guarded: this file is sourced from contexts that may
# not have scripts/lib on hand, and the segment has a fallback for that.
_ZBUILD_LAYOUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_ZBUILD_LAYOUT_DIR/../../scripts/lib/identity.sh" ]]; then
    # shellcheck source=../../scripts/lib/identity.sh
    source "$_ZBUILD_LAYOUT_DIR/../../scripts/lib/identity.sh"
fi

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

# ─── zbuild_layout_data_root ─────────────────────────────────────────────────
# Where zBuild keeps a repository's WORK. Deliberately NOT $ZBUILD_HOME: that is
# ADR-023's INSTALL root (`~/.local/share/zbuild`, the copied engine), and
# ADR-059 §1's diagram calls the data root `$ZBUILD_HOME` by mistake — pointing
# run state at the engine's own install directory would put mutable work inside
# the immutable tree ADR-023 exists to protect. The data root is `~/.zbuild`,
# which is what every existing path already resolves to.
zbuild_layout_data_root() {
    printf '%s' "${ZBUILD_DATA_ROOT:-$HOME/.zbuild}"
}

# ─── zbuild_layout_repo_segment ──────────────────────────────────────────────
# The `<repo>` path segment: `owner/repo` as GITHUB spells it, taken from
# `remote.origin.url` — never from the local directory name.
#
# That distinction is the point. One repository is commonly checked out at
# several local paths (this repo lives at three), and a directory-derived
# segment would scatter one repository's work across three trees that never see
# each other's prior work. The remote is the identity; the path is an accident
# of where someone cloned it. Case is preserved, so the directory reads exactly
# as GitHub spells it.
#
# NO REMOTE: there is no GitHub name, so the fallback is namespaced under
# `local/` to be unmistakable. A bare directory name would look exactly like a
# real repo segment and silently mix the two.
zbuild_layout_repo_segment() {
    local slug=""
    if declare -F zbuild_repo_slug >/dev/null 2>&1; then
        slug="$(zbuild_repo_slug || true)"
    fi
    if [[ -n "$slug" ]]; then
        printf '%s' "$slug"
        return 0
    fi
    local top base
    top="$(git rev-parse --show-toplevel 2>/dev/null || printf '')"
    base="$(basename "${top:-$PWD}")"
    base="${base//[^A-Za-z0-9._-]/_}"
    [[ -n "$base" ]] || base="unknown"
    printf 'local/%s' "$base"
}

# ─── zbuild_layout_repo_root ─────────────────────────────────────────────────
# `<data_root>/repos/<owner>/<repo>` — the base everything for this repository
# hangs off (ADR-059 §1).
zbuild_layout_repo_root() {
    printf '%s/repos/%s' "$(zbuild_layout_data_root)" "$(zbuild_layout_repo_segment)"
}

# ─── zbuild_layout_key_root <run_key> ────────────────────────────────────────
# The directory for one issue or one goal. <run_key> is zbuild_run_key's output
# — `issue-<N>` or `goal-<hash>` — split so the tree reads the way ADR-059 §1
# draws it: `issues/1809/`, `goals/goal-47bc…/`.
zbuild_layout_key_root() {
    local key="${1:-}"
    [[ -n "$key" ]] || return 1
    case "$key" in
        issue-*) printf '%s/issues/%s' "$(zbuild_layout_repo_root)" "${key#issue-}" ;;
        goal-*)  printf '%s/goals/%s'  "$(zbuild_layout_repo_root)" "$key" ;;
        *)       return 1 ;;
    esac
}
