#!/usr/bin/env bash
# scripts/lib/acceptance-run.sh — running one acceptance test file: its command, its time
# bound, and the memo of a file already run (#2110).
# Split from acceptance-block.sh (#2525), which sources it: load that file, not
# this one.
#
# Sourced library: no set -euo pipefail.

# #2010: zbuild_engine_tmpdir names where engine code writes temp files (the
# run memo, #2110). Lazy-sourced: helpers.sh sources only compat.sh, so there
# is no cycle.
if ! declare -F zbuild_engine_tmpdir >/dev/null 2>&1; then
    # shellcheck source=./helpers.sh
    source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/helpers.sh" || _ZBUILD_CONTRACT_LOAD_ERRORS+=" helpers.sh"
fi

# _acceptance_build_run_cmd <template> <testfile>
# Expands a {files}-template for a single acceptance testfile.
# Prints each command token NUL-separated for safe array construction by callers.
# Returns 1 when the template contains no {files} token (misconfiguration guard).
#
# The template is whitespace-tokenized (read -ra) and the resulting array is
# exec'd DIRECTLY by callers — the testfile path never passes through a shell,
# so a filename cannot inject shell metacharacters. This is deliberate and is
# why templates are simple whitespace-separated tokens (bash {files},
# pytest {files}, jest {files}, cargo test {files}); a template embedding a
# quoted multi-word argument (e.g. python3 -c 'import sys') is NOT supported —
# honoring shell quoting would require eval, reintroducing the injection risk
# this array-exec design avoids. ZBUILD_ACCEPTANCE_RUN_CMD is operator-declared
# config (same trust model as ZBUILD_TEST_CMD_TARGETED), not untrusted input.
_acceptance_build_run_cmd() {
    local template="$1" testfile="$2"
    [[ "$template" != *'{files}'* ]] && return 1
    local -a parts
    read -ra parts <<< "$template"
    local part
    for part in "${parts[@]}"; do
        if [[ "$part" == '{files}' ]]; then
            printf '%s\0' "$testfile"
        else
            printf '%s\0' "$part"
        fi
    done
    return 0
}

# _acceptance_timeout_prefix lives in timeout-cmd.sh (#1752), loaded above —
# the one helper every timeout bound in core/, scripts/ and plugins/ uses.

# _acceptance_file_timeout <testfile_rel> <stage_bound_s>  (#2110)
# The bound for ONE run of ONE file: the stage value raised to 3x the time the
# test stage MEASURED for that file (artifacts/test-timing.log, `file <ms>
# <path>`), never lowered, clamped at the test stage's own per-file ceiling
# (ZBUILD_TEST_FILE_TIMEOUT, default 480). A flat 60s condemned a file the test
# stage had just accepted at 129s — all 18 SPECs read `timeout`, 68 minutes per
# gate pass (#1840). The timing log's paths point into a staging dir that no
# longer exists, so the match is on the repo-relative suffix. Unmeasured file
# (targeted reruns log only their subset) → stage value. ZBUILD_NEGCTL_TIMEOUT_MEASURED=0
# disables the raise. The log is the gate's declared `test_timing` input
# (ZBUILD_NEGCTL_TIMING_LOG, ADR-055 §1); this helper never rebuilds a path.
_acceptance_file_timeout() {
    local tf="$1" stage_s="$2"
    [[ "$stage_s" =~ ^[0-9]+$ ]] || stage_s=60
    [[ "${ZBUILD_NEGCTL_TIMEOUT_MEASURED:-1}" == "1" ]] || { printf '%s' "$stage_s"; return 0; }
    local log="${ZBUILD_NEGCTL_TIMING_LOG:-}"
    [[ -n "$tf" && -n "$log" && -f "$log" ]] || { printf '%s' "$stage_s"; return 0; }
    local ceiling="${ZBUILD_TEST_FILE_TIMEOUT:-480}"
    [[ "$ceiling" =~ ^[0-9]+$ && "$ceiling" -gt 0 ]] || ceiling=480
    local kind ms path best_ms=0
    while read -r kind ms path; do
        [[ "$kind" == "file" && "$ms" =~ ^[0-9]+$ ]] || continue
        [[ "$path" == "$tf" || "$path" == */"$tf" ]] || continue
        (( ms > best_ms )) && best_ms=$ms
    done < "$log"
    local bound=$stage_s
    if (( best_ms > 0 )); then
        local measured_s=$(( (best_ms + 999) / 1000 ))
        (( measured_s * 3 > bound )) && bound=$(( measured_s * 3 ))
        (( bound > ceiling )) && bound=$ceiling
        (( bound < stage_s )) && bound=$stage_s
    fi
    printf '%s' "$bound"
}

# ─── _acceptance_run_cached <key> <logfile> <cmd...>  (#2110) ───────────────
# Memoises ONE execution of a test file per gate pass. The gate used to run the
# whole file twice PER SPEC — 19 SPECs bound to one file = 38 runs of the same
# thing, each answering every question the first pair already had. The verdict
# for a SPEC is a pure function of (rc, capture) at baseline and at HEAD, so
# every SPEC bound to the same file reads the same pair. The memo is a
# directory of files (rc + capture), not a shell array: callers run inside
# `$( )` and `< <( )`, where an array would die with the subshell.
#
# Keyed by the absolute path, which already separates a baseline worktree from
# HEAD and one reverted-target worktree from another. Scope: the directory in
# _ACCEPTANCE_RUN_CACHE_DIR — created by the check that runs first (or by the
# plugin, so negctl and reachability share HEAD runs) and removed with it.
# When the directory is unset, every call executes (pre-#2110 behaviour).
_acceptance_run_cached() {
    local key="$1" logfile="$2"; shift 2
    local dir="${_ACCEPTANCE_RUN_CACHE_DIR:-}"
    if [[ -z "$dir" || ! -d "$dir" ]]; then
        if [[ -n "$logfile" ]]; then "$@" >>"$logfile" 2>&1 3>>"$logfile"; else "$@" >/dev/null 2>&1 3>&-; fi
        return $?
    fi
    # The key is a digest of the path, not a sanitised path: `tests/a/b.sh`
    # and `tests/a_b.sh` would otherwise share one entry, and the second file
    # would replay the first's verdict without ever running (review, #2110).
    local id; id="$(printf '%s' "$key" | cksum)"; id="${id%% *}-${#key}"
    local rcf="$dir/$id.rc" capf="$dir/$id.cap"
    local cached=""
    if [[ -f "$rcf" ]]; then
        read -r cached < "$rcf" || cached=""
    fi
    if [[ "$cached" =~ ^[0-9]+$ ]]; then
        [[ -n "$logfile" && -f "$capf" ]] && cat "$capf" >> "$logfile" 2>/dev/null
        return "$cached"
    fi
    local rc=0
    : > "$capf"
    "$@" >>"$capf" 2>&1 3>>"$capf" || rc=$?
    printf '%s\n' "$rc" > "$rcf"
    [[ -n "$logfile" ]] && cat "$capf" >> "$logfile" 2>/dev/null
    return "$rc"
}

# _acceptance_run_cache_begin — ensure a memo dir exists for this check. Sets
# _ACCEPTANCE_RUN_CACHE_OWNED=1 when this call created it (the caller removes
# it on return), 0 when it joined one the plugin already opened. A global, not
# stdout: the directory must be set in the CALLER's shell, and `$( )` would
# lose it.
_acceptance_run_cache_begin() {
    _ACCEPTANCE_RUN_CACHE_OWNED=0
    if [[ -n "${_ACCEPTANCE_RUN_CACHE_DIR:-}" && -d "$_ACCEPTANCE_RUN_CACHE_DIR" ]]; then
        return 0
    fi
    _ACCEPTANCE_RUN_CACHE_DIR="$(mktemp -d "$(zbuild_engine_tmpdir)/zb-accept-runs.XXXXXX" 2>/dev/null || true)"
    export _ACCEPTANCE_RUN_CACHE_DIR
    [[ -n "$_ACCEPTANCE_RUN_CACHE_DIR" ]] && _ACCEPTANCE_RUN_CACHE_OWNED=1
    return 0
}
