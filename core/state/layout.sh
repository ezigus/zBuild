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
# Takes an optional ROOT so a caller with its own override (ZBUILD_STATE_DIR)
# gets the same PATTERNS relative to it. Without that argument the override
# path had to inline its own copy — which is precisely the divergence this
# function exists to prevent.
# shellcheck disable=SC2120  # the ROOT argument IS passed — from
# scripts/lib/cleanup.sh's _cleanup_is_active_run, which shellcheck cannot see
# because it analyses each file independently. Needed for shellcheck 0.9.0 (what
# CI installs); 0.11.0 does not raise it, which is why local lint passed.
zbuild_layout_state_file_globs() {
    local root="${1:-}"
    [[ -n "$root" ]] || root="$(zbuild_layout_state_root)"
    # #141: runs now nest under their issue or goal, so the readers need those
    # shapes too. Emitted FIRST because they are where new runs land; the flat
    # shapes stay for runs written before the switch and for identity-less runs.
    local _repo; _repo="$(zbuild_layout_repo_root 2>/dev/null || true)"
    if [[ -n "$_repo" ]]; then
        printf '%s/issues/*/runs/*/pipeline-state*.json\n' "$_repo"
        printf '%s/goals/*/runs/*/pipeline-state*.json\n' "$_repo"
    fi
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
# Precedence: $ZBUILD_DATA_ROOT > the PARENT of $ZBUILD_STATE_ROOT > $HOME/.zbuild.
#
# The middle term is not a convenience — it is what keeps #1127's fence intact.
# That fence works by exporting ZBUILD_STATE_ROOT to a throwaway dir so a nested
# runner (the in-pipeline `test` stage spawns the suite in a scrubbed shell that
# PRESERVES HOME, ADR-024) roots its ENTIRE tree inside it and cannot clobber the
# parent's `latest` symlink or global event log.
#
# #141 moved run state under the DATA root, which ZBUILD_STATE_ROOT does not
# control — so a fenced nested run with an issue would have escaped into the real
# ~/.zbuild/repos/ and reintroduced exactly the defect #1127 fixed. Deriving the
# data root from the fence closes that. The parent is the right derivation
# because it is the default relationship: $HOME/.zbuild/state -> $HOME/.zbuild.
#
# Caught by tests/integration/state-root-isolation-test.sh, which asserts the
# fence directly. It is the reason that file exists.
zbuild_layout_data_root() {
    if [[ -n "${ZBUILD_DATA_ROOT:-}" ]]; then
        printf '%s' "$ZBUILD_DATA_ROOT"; return 0
    fi
    if [[ -n "${ZBUILD_STATE_ROOT:-}" ]]; then
        # The state root ITSELF, not its parent. The parent was tried and is
        # wrong: #1127's fence is `$tmp/.zbuild-nested-state` where `$tmp` is the
        # rsync'd STAGING REPO itself (plugins/tool/test/plugin.sh rsyncs the repo
        # to $tmp, then fences inside it). Taking the parent therefore put run
        # data INSIDE the repo under test — which ADR-023 forbids outright, and
        # which made zbuild_worktree_assert_outside refuse the tree, aborting
        # every nested run between init_state and the first dispatch. Green on
        # macOS only because /tmp -> /private/tmp made the prefix compare miss.
        printf '%s' "${ZBUILD_STATE_ROOT%/}"; return 0
    fi
    printf '%s' "$HOME/.zbuild"
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

# ─── zbuild_layout_run_state_dir <run_key> <run_id> ──────────────────────────
# WHERE A RUN'S STATE ACTUALLY GOES (#141, ADR-059 §1) — the writer's answer.
#
# `<repo>/issues/<N>/runs/<run_id>/` or `<repo>/goals/<key>/runs/<run_id>/`.
# The per-run level stays, because scratch, runtime/, events and
# pipeline-state.json genuinely belong to one run. What changes is that they now
# sit UNDER the issue, so everything for an issue is in one place and a reader
# can find it without a scan.
#
# Falls back to the flat `<state_root>/runs/<run_id>` when the run has no
# identity — a run with neither issue nor goal has nothing to nest under, and
# inventing a bucket would key unrelated work together.
# ─── zbuild_layout_key_worktree <key> ────────────────────────────────────────
# The ONE tree for an issue (or goal), reused across every run of it.
#
# ADR-059 §2, and the reason the whole redesign exists: a worktree holds a
# BRANCH, and the branch is named for the issue (`zbuild/issue-<N>-<slug>`).
# Keying the tree by run while the branch is keyed by issue is the mismatch that
# produced #1658 and #1869 — two runs of one issue want one branch in two trees,
# and git refuses, terminally. One tree per issue removes that by construction
# instead of reclaiming after the fact.
#
# Returns non-zero for a key with no identity; the caller then keeps the
# pre-#141 per-run path. Exclusivity is NOT this function's job — #1940's
# per-issue lock (ADR-059 §4) is what stops two live runs sharing the tree.
# Hangs off the RUN root ($ZBUILD_RUN_ROOT, default ~/.zbuild) — deliberately
# NOT the data root. #1127's fence sets ZBUILD_STATE_ROOT (and cost/cache) but
# never ZBUILD_RUN_ROOT, because the fence lives INSIDE the rsync'd staging repo:
# a worktree derived from it would sit inside the repo the run is editing, and
# zbuild_worktree_assert_outside rightly refuses that. Keeping the tree on the
# run root preserves exactly where pre-#141 trees lived; only the KEY changes.
zbuild_layout_key_worktree() {
    local key="${1:-}"
    [[ -n "$key" ]] || return 1
    local sub
    case "$key" in
        issue-*) sub="issues/${key#issue-}" ;;
        goal-*)  sub="goals/$key" ;;
        *)       return 1 ;;
    esac
    printf '%s/repos/%s/%s/worktree' \
        "${ZBUILD_RUN_ROOT:-${HOME}/.zbuild}" "$(zbuild_layout_repo_segment)" "$sub"
}

zbuild_layout_run_state_dir() {
    local key="${1:-}" rid="${2:-}"
    [[ -n "$rid" ]] || return 1
    local base=""
    [[ -n "$key" ]] && base="$(zbuild_layout_key_root "$key" 2>/dev/null || true)"
    if [[ -n "$base" ]]; then
        printf '%s/runs/%s' "$base" "$rid"
    else
        printf '%s/%s' "$(zbuild_layout_runs_root)" "$rid"
    fi
}

# ─── zbuild_layout_run_dirs ──────────────────────────────────────────────────
# Every directory that IS a run, newline-separated — new layout first, then the
# pre-#141 flat one.
#
# The readers each used to derive their own root, which is how a layout change
# turns into a blind reclaimer: the writer moves and five scanners keep walking
# an empty directory, reporting "nothing to clean" for a store full of runs.
# That is indistinguishable from a clean machine, and it is the FAIL-OPEN
# direction. One enumerator, shared, so they cannot disagree.
#
# The flat root is retained deliberately: migration is "leave old, no reads" for
# WRITES, but a reclaimer that cannot see pre-switch runs would strand them
# forever. Reading both is what lets the old location drain.
#
# The `[[ -d ]]` guards below are LOAD-BEARING, not redundant with the trailing
# `/` in each glob. `nullglob` is not set here, so an unmatched pattern is
# iterated as its own literal text — dropping the test would emit
# `.../issues/*/runs/*` as if it were a run directory, and every caller reclaims
# by path. Do not remove them as "the glob already guarantees a directory".
zbuild_layout_run_dirs() {
    local d repo
    repo="$(zbuild_layout_repo_root 2>/dev/null || true)"
    if [[ -n "$repo" ]]; then
        for d in "$repo"/issues/*/runs/*/ "$repo"/goals/*/runs/*/; do
            [[ -d "$d" ]] && printf '%s\n' "${d%/}"
        done
    fi
    for d in "$(zbuild_layout_runs_root)"/*/; do
        [[ -d "$d" ]] && printf '%s\n' "${d%/}"
    done
}
