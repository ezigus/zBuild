#!/usr/bin/env bash
# scripts/lib/run-status-comment.sh — one live GitHub issue comment per run
# (#2131, ADR-064; keeper e-1 lifted from legacy/scripts/lib/pipeline-github.sh).
#
# A sidecar the runner spawns beside a run and reaps in its EXIT trap. It READS
# events.jsonl (never writes it — it has no path to the event bus at all) and
# keeps a single comment on the run's issue edited in place: header pinned at
# the top, one row per stage dispatch, newest first, bounded under GitHub's
# 65,536-byte limit. Every GitHub failure is logged to status-comment.log and
# ignored: the run never fails because GitHub did.
#
# Source-only library (`rsc_*`) with a `main` when executed:
#   bash run-status-comment.sh --events <jsonl> --state-dir <dir> --parent-pid <pid> [--once]
#
# No `set -e` at top level — sourced into the runner, which owns its options.

[[ -n "${_ZBUILD_RUN_STATUS_COMMENT_LOADED:-}" ]] && return 0 2>/dev/null
_ZBUILD_RUN_STATUS_COMMENT_LOADED=1

_RSC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RSC_ROOT="$(cd "$_RSC_DIR/../.." && pwd)"
# shellcheck source=./helpers.sh
[[ -n "${_ZBUILD_HELPERS_LOADED:-}" ]] || source "$_RSC_ROOT/scripts/lib/helpers.sh"
# shellcheck source=./identity.sh
source "$_RSC_ROOT/scripts/lib/identity.sh"

# Tunables — one place. Tests shrink the intervals; operators rarely touch them.
: "${ZBUILD_STATUS_COMMENT_MIN_INTERVAL:=5}"    # seconds between PATCHes (coalesce)
: "${ZBUILD_STATUS_COMMENT_POLL:=1}"            # seconds between events.jsonl checks
: "${ZBUILD_STATUS_COMMENT_GH_TIMEOUT:=30}"     # seconds per gh call
# shellcheck source=./run-status-render.sh
source "$_RSC_ROOT/scripts/lib/run-status-render.sh"   # rsc_render_body, rsc_outbound_body, the bound, the marker

# ─── rsc_log <state_dir> <msg> — the sidecar's only sink ─────────────────────
rsc_log() {
    local state_dir="$1"; shift
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$state_dir/status-comment.log" 2>/dev/null || true
}

# ─── rsc_enabled <state_dir> <repo_root> — every reason NOT to post ─────────
# Logs the first failing gate. The repo-slug gate is what keeps a test's temp
# repository (no github.com origin) from ever reaching GitHub.
rsc_enabled() {
    local state_dir="$1" repo_root="${2:-}"
    local why=""
    if [[ "${ZBUILD_STATUS_COMMENT:-1}" == "0" ]]; then why="ZBUILD_STATUS_COMMENT=0"
    elif [[ "${NO_GITHUB:-}" == "true" ]]; then why="NO_GITHUB=true"
    elif ! [[ "${ZBUILD_ISSUE:-0}" =~ ^[1-9][0-9]*$ ]]; then why="no issue number (goal run)"
    elif ! command -v gh >/dev/null 2>&1; then why="gh not on PATH"
    elif ! gh auth status >/dev/null 2>&1; then why="gh auth status failed"
    elif ! zbuild_repo_slug "$repo_root" >/dev/null 2>&1; then why="origin is not a github.com repository"
    fi
    if [[ -n "$why" ]]; then
        rsc_log "$state_dir" "disabled: $why"
        return 1
    fi
    return 0
}

# ═══ GitHub I/O — advisory: every function here returns 0 ═══════════════════

# ─── rsc_gh <state_dir> <stdout_file> <args...> — gh under a watchdog ───────
# `timeout(1)` is not on macOS; the runner's bg+sleep+kill pattern is. The
# body travels as `-F body=@<file>` — a background job's stdin is /dev/null,
# and a 60 KB comment must never be an argv word. Returns gh's rc (124 on
# timeout) for the caller's LOG, never its exit; stderr is kept in
# _RSC_GH_ERR so a caller can tell a 404 from the rest. `-F`, not `-f`:
# only --field reads `@file`; --raw-field sends the literal string, and the
# first real run posted its own temp path as the comment (#2137).
_RSC_GH_ERR=""
rsc_gh() {
    local state_dir="$1" out="$2"; shift 2
    local err rc=0 pid wd
    _RSC_GH_ERR=""
    err="$(mktemp "${TMPDIR:-$state_dir}/rsc-gh-err.XXXXXX")" || return 1
    gh "$@" > "$out" 2> "$err" </dev/null &
    pid=$!
    # The watchdog must not inherit a caller's `$(...)` capture pipe: the
    # substitution would then block until the sleep ended, turning every
    # call into a GH_TIMEOUT-long wait.
    # The watchdog leaves a marker when it FIRES; that, plus a non-zero rc,
    # is what a timeout means. Testing "is the watchdog gone" instead raced a
    # gh that finished in the same instant the sleep ended and reported a
    # successful call as a timeout, dropping the comment id it had returned.
    ( sleep "$ZBUILD_STATUS_COMMENT_GH_TIMEOUT"; : > "$err.fired"; kill -TERM "$pid" 2>/dev/null || true ) >/dev/null 2>&1 </dev/null &
    wd=$!
    wait "$pid" 2>/dev/null; rc=$?
    kill -TERM "$wd" 2>/dev/null || true
    wait "$wd" 2>/dev/null || true
    if [[ $rc -ne 0 && -e "$err.fired" ]]; then rc=124; fi
    rm -f "$err.fired"
    _RSC_GH_ERR="$(head -c 400 "$err" 2>/dev/null | tr '\n' ' ')"
    if [[ $rc -ne 0 ]]; then
        local detail="${_RSC_GH_ERR:0:200}"
        [[ $rc -eq 124 ]] && detail="timeout after ${ZBUILD_STATUS_COMMENT_GH_TIMEOUT}s ${detail}"
        rsc_log "$state_dir" "gh $1 $2 rc=$rc ${detail}"
    fi
    rm -f "$err"
    return $rc
}

# ─── rsc_id_save / rsc_id_load — <state_dir>/status-comment.json ────────────
# tmp+mv (legacy e-1): a concurrent reader never sees a truncated id.
rsc_id_save() {
    local state_dir="$1" slug="$2" issue="$3" run_id="$4" id="$5" tmp
    tmp="$(mktemp "$state_dir/status-comment.json.XXXXXX")" || return 0
    jq -n --arg slug "$slug" --arg issue "$issue" --arg run_id "$run_id" --arg id "$id" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{schema_version:1, repo:$slug, issue:($issue|tonumber), run_id:$run_id, comment_id:($id|tonumber), created_at:$at}' \
        > "$tmp" 2>/dev/null && mv -f "$tmp" "$state_dir/status-comment.json" || rm -f "$tmp"
    return 0
}
rsc_id_load() {
    local f="$1/status-comment.json"
    [[ -s "$f" ]] || return 0
    jq -r '.comment_id // empty' "$f" 2>/dev/null || true
}

# ─── rsc_comment_find <state_dir> <slug> <issue> <run_id> — by marker ───────
# Only when the id file is gone (resume, lost create response): this is what
# makes "exactly one comment per run" hold across a restart.
rsc_comment_find() {
    local state_dir="$1" slug="$2" issue="$3" run_id="$4" out id=""
    out="$(mktemp "${TMPDIR:-$state_dir}/rsc-find.XXXXXX")" || return 0
    # The marker is matched HERE with --arg, never interpolated into a --jq
    # filter: a run id carrying a quote would break the filter, the search
    # would come back empty, and the next upsert would POST a second comment.
    # --paginate prints one array per page; take the first id on any page.
    if rsc_gh "$state_dir" "$out" api --paginate "repos/${slug}/issues/${issue}/comments" 2>/dev/null; then
        id="$(jq -r --arg m "${_RSC_MARKER_PREFIX}${run_id} -->" \
            '.[]? | select((.body // "") | contains($m)) | .id' "$out" 2>/dev/null | awk 'NF { print; exit }' || true)"
    fi
    rm -f "$out"
    [[ "$id" =~ ^[0-9]+$ ]] && printf '%s' "$id"
    return 0
}

# ─── rsc_comment_create / rsc_comment_patch ─────────────────────────────────
rsc_comment_create() {
    local state_dir="$1" slug="$2" issue="$3" body_file="$4" out id=""
    out="$(mktemp "${TMPDIR:-$state_dir}/rsc-create.XXXXXX")" || return 0
    if rsc_gh "$state_dir" "$out" api "repos/${slug}/issues/${issue}/comments" -F "body=@${body_file}" --jq .id; then
        id="$(tr -d '[:space:]' < "$out")"
    fi
    rm -f "$out"
    [[ "$id" =~ ^[0-9]+$ ]] && printf '%s' "$id"
    return 0
}
rsc_comment_patch() {
    local state_dir="$1" slug="$2" id="$3" body_file="$4" out rc=0
    out="$(mktemp "${TMPDIR:-$state_dir}/rsc-patch.XXXXXX")" || return 0
    rsc_gh "$state_dir" "$out" api "repos/${slug}/issues/comments/${id}" -X PATCH -F "body=@${body_file}" || rc=$?
    # A 404 means the comment is gone (deleted by a human); report it so the
    # caller can re-create ONCE.
    if [[ $rc -ne 0 && "$_RSC_GH_ERR" == *"404"* ]]; then rc=44; fi
    rm -f "$out"
    return $rc
}

# ─── rsc_upsert <state_dir> <slug> <issue> <run_id> <body_file> ─────────────
# id known → PATCH; else marker search → PATCH; else POST. A PATCH 404 clears
# the id and allows one re-create per process, so a vandalised comment cannot
# fan out. Always returns 0.
_RSC_RECREATED=0
_RSC_GIVEN_UP=0
rsc_upsert() {
    local state_dir="$1" slug="$2" issue="$3" run_id="$4" body_file="$5"
    local id rc=0
    [[ "$_RSC_GIVEN_UP" -eq 1 ]] && return 0
    id="$(rsc_id_load "$state_dir")"
    if [[ -z "$id" ]]; then
        id="$(rsc_comment_find "$state_dir" "$slug" "$issue" "$run_id")"
        [[ -n "$id" ]] && rsc_id_save "$state_dir" "$slug" "$issue" "$run_id" "$id"
    fi
    if [[ -n "$id" ]]; then
        rsc_comment_patch "$state_dir" "$slug" "$id" "$body_file"; rc=$?
        if [[ $rc -eq 0 ]]; then return 0; fi
        if [[ $rc -ne 44 ]]; then return 0; fi
        # Gone. Forget it; re-create at most once.
        rm -f "$state_dir/status-comment.json"
        if [[ "$_RSC_RECREATED" -ge 1 ]]; then
            _RSC_GIVEN_UP=1
            rsc_log "$state_dir" "comment ${id} gone again; giving up for this run"
            return 0
        fi
        _RSC_RECREATED=1
        rsc_log "$state_dir" "comment ${id} gone (404); re-creating once"
    fi
    id="$(rsc_comment_create "$state_dir" "$slug" "$issue" "$body_file")"
    if [[ -n "$id" ]]; then
        rsc_id_save "$state_dir" "$slug" "$issue" "$run_id" "$id"
        [[ "${GITHUB_ACTIONS:-}" == "true" ]] && \
            echo "::notice title=zbuild status comment::https://github.com/${slug}/issues/${issue}#issuecomment-${id}"
    fi
    return 0
}

# ═══ Loop / lifecycle ═══════════════════════════════════════════════════════

_RSC_STOP=0
_rsc_on_stop() { _RSC_STOP=1; }

# ─── rsc_flush <events> <state_dir> <slug> <issue> <run_id> [override] ──────
# Render → redact → upsert. A redactor failure posts nothing (logged).
rsc_flush() {
    local events="$1" state_dir="$2" slug="$3" issue="$4" run_id="$5" override="${6:-}"
    local body_file
    body_file="$(mktemp "${TMPDIR:-$state_dir}/rsc-body.XXXXXX")" || return 0
    if ! rsc_outbound_body "$events" "$state_dir" "$override" > "$body_file"; then
        rsc_log "$state_dir" "redaction_failed: body not posted"
        rm -f "$body_file"; return 0
    fi
    rsc_upsert "$state_dir" "$slug" "$issue" "$run_id" "$body_file"
    rm -f "$body_file"
    return 0
}

_rsc_has_type() {   # _rsc_has_type <events> <regex-of-types>
    [[ -s "$1" ]] && grep -qE "\"type\":\"($2)\"" "$1" 2>/dev/null
}

# ─── rsc_tail_loop <events> <state_dir> <parent_pid> <slug> <issue> <run_id> ─
# Poll (not tail -F: the file may not exist yet, and a size check is enough at
# this cadence). No GitHub call before pipeline.start|resume — a refused lock
# or a preflight return between spawn and start must never create a comment.
# A terminal event flushes at once but does NOT end the loop: always-run
# stages emit after pipeline.end, and the runner's EXIT trap reaps us after
# them. TERM/INT → final render; parent death → final render marked as such.
rsc_tail_loop() {
    local events="$1" state_dir="$2" parent="$3" slug="$4" issue="$5" run_id="$6"
    local last_size=-1 size dirty=0 seen_start=0 terminal_seen=0 last_flush=0 now flushed_once=0
    trap '_rsc_on_stop' TERM INT
    trap '' HUP
    while :; do
        if [[ "$_RSC_STOP" -eq 1 ]]; then
            local ov=""
            _rsc_has_type "$events" 'pipeline\.end|pipeline\.aborted|pipeline\.abort' || ov="interrupted"
            [[ "$seen_start" -eq 1 ]] && rsc_flush "$events" "$state_dir" "$slug" "$issue" "$run_id" "$ov"
            rsc_log "$state_dir" "stopped on signal"
            return 0
        fi
        if [[ -n "$parent" ]] && ! kill -0 "$parent" 2>/dev/null; then
            local ov=""
            _rsc_has_type "$events" 'pipeline\.end|pipeline\.aborted|pipeline\.abort' \
                || ov="interrupted (runner exited without a terminal event)"
            [[ "$seen_start" -eq 1 ]] && rsc_flush "$events" "$state_dir" "$slug" "$issue" "$run_id" "$ov"
            rsc_log "$state_dir" "parent ${parent} gone; final render done"
            return 0
        fi
        size=0; [[ -f "$events" ]] && size="$(wc -c < "$events" 2>/dev/null | tr -d ' ')"
        if [[ "$size" != "$last_size" ]]; then dirty=1; last_size="$size"; fi
        if [[ $dirty -eq 1 && $seen_start -eq 0 ]]; then
            _rsc_has_type "$events" 'pipeline\.start|pipeline\.resume' && seen_start=1
        fi
        local terminal_now=0
        if [[ $dirty -eq 1 && $terminal_seen -eq 0 ]]; then
            if _rsc_has_type "$events" 'pipeline\.end|pipeline\.aborted|pipeline\.abort'; then
                terminal_seen=1; terminal_now=1
            fi
        fi
        now="$(date +%s)"
        if [[ $dirty -eq 1 && $seen_start -eq 1 ]] && \
           [[ $flushed_once -eq 0 || $terminal_now -eq 1 || $(( now - last_flush )) -ge "${ZBUILD_STATUS_COMMENT_MIN_INTERVAL%.*}" ]]; then
            rsc_flush "$events" "$state_dir" "$slug" "$issue" "$run_id"
            dirty=0; flushed_once=1; last_flush="$now"
        fi
        # Interruptible sleep: a TERM lands on `wait`, not inside `sleep`.
        sleep "$ZBUILD_STATUS_COMMENT_POLL" & wait $! 2>/dev/null
    done
}

# ─── rsc_find_state_dir <run_id> — the run's state dir, by its run id ───────
# Same globs `--attach` and cleanup use (core/state/layout.sh), so the ADR-059
# issues/<N>/runs/<id> shape resolves as well as the flat runs/<id> one.
rsc_find_state_dir() {
    local run_id="$1" glob f
    [[ -n "$run_id" ]] || return 1
    if ! declare -F zbuild_layout_state_file_globs >/dev/null 2>&1; then
        # shellcheck source=../../core/state/layout.sh
        source "$_RSC_ROOT/core/state/layout.sh" 2>/dev/null || return 1
    fi
    while IFS= read -r glob; do
        [[ -n "$glob" ]] || continue
        # shellcheck disable=SC2086  # the glob is meant to expand
        for f in $glob; do
            [[ -f "$f" ]] || continue
            if jq -e --arg id "$run_id" '.run_id == $id' "$f" >/dev/null 2>&1; then
                dirname "$f"; return 0
            fi
        done
    done < <(zbuild_layout_state_file_globs)
    return 1
}

# ─── main ───────────────────────────────────────────────────────────────────
#   --events <jsonl> --state-dir <dir> [--parent-pid <pid>] [--slug o/r]
#   [--issue N] [--run-id id] [--repo-root <dir>] [--once]
# Identity falls back to status-comment.json, then the environment.
rsc_main() {
    local events="" state_dir="" parent="" slug="" issue="" run_id="" repo_root="" once=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --events) events="${2:-}"; shift 2 ;;
            --state-dir) state_dir="${2:-}"; shift 2 ;;
            --parent-pid) parent="${2:-}"; shift 2 ;;
            --slug) slug="${2:-}"; shift 2 ;;
            --issue) issue="${2:-}"; shift 2 ;;
            --run-id) run_id="${2:-}"; shift 2 ;;
            --repo-root) repo_root="${2:-}"; shift 2 ;;
            --once) once=1; shift ;;
            *) echo "run-status-comment: unknown argument: $1" >&2; return 2 ;;
        esac
    done
    [[ -n "$state_dir" ]] || { echo "run-status-comment: --state-dir required" >&2; return 2; }
    [[ -n "$events" ]] || events="$state_dir/events.jsonl"
    if [[ -s "$state_dir/status-comment.json" ]]; then
        [[ -n "$slug" ]] || slug="$(jq -r '.repo // empty' "$state_dir/status-comment.json" 2>/dev/null || true)"
        [[ -n "$issue" ]] || issue="$(jq -r '.issue // empty' "$state_dir/status-comment.json" 2>/dev/null || true)"
        [[ -n "$run_id" ]] || run_id="$(jq -r '.run_id // empty' "$state_dir/status-comment.json" 2>/dev/null || true)"
    fi
    [[ -n "$issue" ]] || issue="${ZBUILD_ISSUE:-}"
    [[ -n "$run_id" ]] || run_id="${ZBUILD_RUN_ID:-}"
    [[ -n "$slug" ]] || slug="$(zbuild_repo_slug "${repo_root:-$PWD}" 2>/dev/null || true)"
    if [[ -z "$slug" || ! "$issue" =~ ^[1-9][0-9]*$ || ! "$run_id" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        rsc_log "$state_dir" "cannot post: slug='${slug}' issue='${issue}' run_id='${run_id}'"
        return 0
    fi
    # The summary path resolver lives in the engine; optional (fixtures use
    # the artifacts/<stage>-summary.md fallback).
    if ! declare -F _summaries_stage_summary_path >/dev/null 2>&1; then
        # shellcheck source=../../core/pipeline/input-resolve.sh
        source "$_RSC_ROOT/core/pipeline/input-resolve.sh" 2>/dev/null || true
    fi
    rsc_log "$state_dir" "start: repo=${slug} issue=${issue} run_id=${run_id} parent=${parent:-none} events=${events}"
    if [[ $once -eq 1 ]]; then
        rsc_flush "$events" "$state_dir" "$slug" "$issue" "$run_id"
        return 0
    fi
    rsc_tail_loop "$events" "$state_dir" "$parent" "$slug" "$issue" "$run_id"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    rsc_main "$@"
    exit $?
fi
