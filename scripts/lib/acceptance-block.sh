#!/usr/bin/env bash
# Acceptance-block extractor — parses the ```acceptance fenced block from a
# design.md artifact and emits structured output for test_assessment consumption.
# See ADR-031 for block format specification.
#
# This file is source-only (a pure function, never executed directly), so it
# deliberately does NOT `set -euo pipefail` at top level: doing so mutates the
# shell options of any caller that sources it (e.g. plugins/agent/design),
# altering their control flow. This matches the no-side-effect-on-source
# convention of the sibling core/ and scripts/lib/ libraries. The function
# below is self-contained (guarded parameter expansions + explicit returns).
#
# Size: over 500 lines, deliberately, for the reason acceptance-negctl.sh gives.
# A sibling file under scripts/lib that this one sources would join
# _runner_contract_lib_closure and widen ADR-057 gate 2 for every later issue.

[[ -n "${_ACCEPTANCE_BLOCK_LOADED:-}" ]] && return 0
_ACCEPTANCE_BLOCK_LOADED=1

# One requirement line: `SPEC-<n>[<tag>]:`. The tag may hold hyphens, so
# `[no-code]` is a tag (#2304, ADR-069 §1) — it used to be `[a-z]+`, and a
# `SPEC-2[no-code]:` line was silently dropped from every list. Groups:
# 1 = the id, 3 = the tag (empty when the line has none).
_ACCEPTANCE_SPEC_RE='^(SPEC-[0-9]+)(\[([a-z-]+)\])?:'

# #2010: zbuild_engine_tmpdir names where engine code writes temp files (the
# run memo, #2110). Lazy-sourced, same pattern acceptance-reachability.sh uses:
# this file is sourced from several entry points and cannot assume helpers.sh
# arrived first. helpers.sh sources only compat.sh, so there is no cycle.
if ! declare -F zbuild_engine_tmpdir >/dev/null 2>&1; then
    # shellcheck source=./helpers.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/." && pwd)/helpers.sh" 2>/dev/null || true
fi

# extract_acceptance_block <design_md>
# Parses the ```acceptance fenced block from the given file and prints:
#   - One "SPEC: <text>" line per behavioral claim (in order)
#   - A "TESTFILES:" sentinel line
#   - One test-file path per line (non-blank lines after TESTFILES: sentinel)
# Returns 0 on success (block found and parsed), 1 when no block is present.
# Produces empty stdout on return 1. A malformed block (no closing fence or
# missing TESTFILES section) returns 1 with whatever partial output was emitted.
extract_acceptance_block() {
    local design_md="${1:-}"
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 1

    local in_block=0
    local in_testfiles=0
    local found_block=0
    local found_testfiles=0
    local -a specs=()
    local -a testfiles=()

    while IFS= read -r line; do
        if [[ "$line" == '```acceptance' ]]; then
            in_block=1
            found_block=1
            continue
        fi
        if [[ $in_block -eq 1 && "$line" == '```' ]]; then
            in_block=0
            break
        fi
        if [[ $in_block -eq 1 ]]; then
            if [[ "$line" == 'TESTFILES:' ]]; then
                in_testfiles=1
                found_testfiles=1
                continue
            fi
            if [[ $in_testfiles -eq 1 ]]; then
                # Stop testfile collection at WIRING: sentinel (may appear after TESTFILES:)
                if [[ "$line" == 'WIRING:'* ]]; then
                    in_testfiles=0
                elif [[ -n "$line" ]]; then
                    testfiles+=("$line")
                fi
            elif [[ "$line" == SPEC:* || "$line" =~ $_ACCEPTANCE_SPEC_RE ]]; then
                specs+=("$line")
            fi
        fi
    done < "$design_md"

    if [[ $found_block -eq 0 ]]; then
        return 1
    fi

    for spec in "${specs[@]+"${specs[@]}"}"; do
        printf '%s\n' "$spec"
    done

    if [[ $found_testfiles -eq 1 ]]; then
        printf 'TESTFILES:\n'
        for tf in "${testfiles[@]+"${testfiles[@]}"}"; do
            printf '%s\n' "$tf"
        done
    fi

    [[ $found_testfiles -eq 1 ]] || return 1
    return 0
}

# acceptance_spec_tag <spec_id> — the tag an assertion carries for a SPEC.
# Under an issue: [#<issue>/SPEC-n] — SPEC numbers restart with every design, so
# a bare [SPEC-3] cannot say WHICH issue's SPEC-3 it is, and two issues sharing a
# test file collided (#1845 stripped #1328's [SPEC-1..10]). The scheme adds to
# the old one and never overlaps it: `\[SPEC-[0-9]+\]` cannot match a new tag,
# and every reader matches the exact tag it builds here. With no issue (a
# --goal run, ZBUILD_ISSUE unset or 0) it is the bare legacy [SPEC-n].
acceptance_spec_tag() {
    local sid="${1:-}" issue="${ZBUILD_ISSUE:-}"
    if [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
        printf '[#%s/%s]' "$issue" "$sid"
    else
        printf '[%s]' "$sid"
    fi
}

# acceptance_list_spec_ids <design_md>  (ADR-036 / #922)
# Prints each STABLE SPEC id (e.g. "SPEC-1", "SPEC-2") from the ```acceptance
# block, one per line, in declaration order. Only `SPEC-<n>:` lines carry an
# id; bare legacy `SPEC:` lines are intentionally ignored (they have no id to
# map to a [SPEC-n]-tagged assertion). Returns 0 when ≥1 id is found, else 1.
# Stops at the TESTFILES: sentinel so per-SPEC binding lines (SPEC-n: path)
# in the TESTFILES section are not misidentified as spec-id declarations.
acceptance_list_spec_ids() {
    local design_md="${1:-}"
    local block_output line ids_found=0
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 1
    [[ -z "$block_output" ]] && return 1
    while IFS= read -r line; do
        # Stop scanning once we enter the TESTFILES section — per-SPEC binding
        # lines (SPEC-n: path) share the SPEC id regex and must not be emitted.
        [[ "$line" == "TESTFILES:" ]] && break
        if [[ "$line" =~ $_ACCEPTANCE_SPEC_RE ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            ids_found=1
        fi
    done <<< "$block_output"
    [[ $ids_found -eq 1 ]]
}

# _acceptance_spec_line <block_output> <spec_id>  (#2304, ADR-069 §1)
# Finds the requirement line for <spec_id> in an extracted block and sets, with
# no subshell (so reading a requirement costs no extra fork):
#   _ACC_SPEC_TAG    the tag, or empty
#   _ACC_SPEC_STATUS code | no-code | done | unknown:<tag> | "" (no tag). The
#                    old tags are still read: [change] is code, and [guard] is
#                    done (the design-gate rejects [guard], so a new design
#                    never carries it; an old one still reads sensibly).
#   _ACC_SPEC_REST   everything after the colon, leading space trimmed
#   _ACC_SPEC_TEXT   what it requires: REST, stopping before ` covers: ` and,
#                    when the requirement is done, before ` evidence: ` (neither
#                    is part of the requirement)
#   _ACC_SPEC_COVERS the issue requirement ids after ` covers: ` (R-1 R-3), up
#                    to any ` evidence: ` — space separated (#2306, ADR-070 §3)
# Returns 1 when the block has no such line. Stops at TESTFILES: — the per-SPEC
# binding lines there share the `SPEC-n:` shape, and a path is not a requirement.
_acceptance_spec_line() {
    local _block="${1:-}" _sid="${2:-}" _l
    _ACC_SPEC_TAG="" _ACC_SPEC_STATUS="" _ACC_SPEC_REST="" _ACC_SPEC_TEXT="" _ACC_SPEC_COVERS=""
    [[ -n "$_block" && -n "$_sid" ]] || return 1
    while IFS= read -r _l; do
        [[ "$_l" == "TESTFILES:" ]] && break
        if [[ "$_l" =~ $_ACCEPTANCE_SPEC_RE && "${BASH_REMATCH[1]}" == "$_sid" ]]; then
            _ACC_SPEC_TAG="${BASH_REMATCH[3]}"
            _ACC_SPEC_REST="${_l#*:}"
            _ACC_SPEC_REST="${_ACC_SPEC_REST#"${_ACC_SPEC_REST%%[![:space:]]*}"}"
            _ACC_SPEC_TEXT="${_ACC_SPEC_REST%% covers: *}"
            if [[ "$_ACC_SPEC_REST" == *" covers: "* ]]; then
                _ACC_SPEC_COVERS="${_ACC_SPEC_REST#* covers: }"
                _ACC_SPEC_COVERS="${_ACC_SPEC_COVERS%% evidence: *}"
            fi
            case "$_ACC_SPEC_TAG" in
                "")          _ACC_SPEC_STATUS="" ;;
                code|change) _ACC_SPEC_STATUS="code" ;;
                no-code)     _ACC_SPEC_STATUS="no-code" ;;
                done|guard)  _ACC_SPEC_STATUS="done"
                             _ACC_SPEC_TEXT="${_ACC_SPEC_TEXT%% evidence: *}" ;;
                *)           _ACC_SPEC_STATUS="unknown:$_ACC_SPEC_TAG" ;;
            esac
            return 0
        fi
    done <<< "$_block"
    return 1
}

# acceptance_spec_status <design_md> <spec_id>  (#2304, ADR-069 §1)
# Echoes the requirement's status: code, no-code, done, unknown:<tag>, or an
# empty line when it carries no tag or the id is absent.
acceptance_spec_status() {
    local design_md="${1:-}" spec_id="${2:-}" block_output
    [[ -n "$design_md" && -n "$spec_id" && -f "$design_md" ]] || { printf '\n'; return 0; }
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || { printf '\n'; return 0; }
    _acceptance_spec_line "$block_output" "$spec_id" || { printf '\n'; return 0; }
    printf '%s\n' "$_ACC_SPEC_STATUS"
}

# acceptance_spec_evidence <design_md> <spec_id>  (#2304, ADR-069 §1)
# Echoes the evidence an "already done" requirement names — the items after
# ` evidence: ` on its line (`file:line` or a test file), one per line. Empty
# for any other status, and when none is named.
acceptance_spec_evidence() {
    local design_md="${1:-}" spec_id="${2:-}" block_output
    [[ -n "$design_md" && -n "$spec_id" && -f "$design_md" ]] || return 0
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    _acceptance_spec_line "$block_output" "$spec_id" || return 0
    [[ "$_ACC_SPEC_STATUS" == "done" && "$_ACC_SPEC_REST" == *" evidence: "* ]] || return 0
    local _ev="${_ACC_SPEC_REST#* evidence: }"
    local -a _items=()
    # %% (from the FIRST " covers: "), not %: evidence ends where covers begins.
    read -ra _items <<< "${_ev%% covers: *}"
    [[ ${#_items[@]} -gt 0 ]] && printf '%s\n' "${_items[@]}"
    return 0
}

# acceptance_spec_covers <design_md> <spec_id>  (#2306, ADR-070 §3)
# Echoes the issue requirement ids the SPEC says it covers — the items after
# ` covers: ` on its line, up to any ` evidence: ` — one per line. Empty when it
# names none.
acceptance_spec_covers() {
    local design_md="${1:-}" spec_id="${2:-}" block_output
    [[ -n "$design_md" && -n "$spec_id" && -f "$design_md" ]] || return 0
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    _acceptance_spec_line "$block_output" "$spec_id" || return 0
    local -a _ids=()
    read -ra _ids <<< "${_ACC_SPEC_COVERS//,/ }"
    [[ ${#_ids[@]} -gt 0 ]] && printf '%s\n' "${_ids[@]}"
    return 0
}

# acceptance_requirements_list <requirements.json>  (#2306, ADR-070 §4)
# The issue's requirements as every stage is shown them: one `- R-n: <text>`
# line each, in order. Empty when the file is absent or unreadable (a goal run).
acceptance_requirements_list() {
    local f="${1:-}"
    [[ -n "$f" && -s "$f" ]] || return 0
    jq -r '.requirements[]? | "- \(.id): \(.text)"' "$f" 2>/dev/null || true
}

# acceptance_spec_text <design_md> <spec_id>  (#1978)
# Echoes what the SPEC REQUIRES — the prose after `SPEC-n[tag]:` — with no id,
# no tag, and (#2304) no evidence. Empty when the id is absent or the block is
# missing.
acceptance_spec_text() {
    local design_md="${1:-}" spec_id="${2:-}" block_output
    [[ -n "$design_md" && -n "$spec_id" && -f "$design_md" ]] || return 0
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    [[ -z "$block_output" ]] && return 0
    _acceptance_spec_line "$block_output" "$spec_id" || return 0
    printf '%s\n' "$_ACC_SPEC_TEXT"
    return 0
}

# acceptance_list_wiring <design_md>  (ADR-036 Level-3 / #956)
# Prints the WIRING targets declared in the ```acceptance block, one per line.
# The special token "none" is printed as-is when WIRING: none is declared
# (pure-utility exemption). Path-traversal guard applied (same as testfiles).
# Returns 0 when a WIRING: section is present (even if "none"), 1 when absent.
acceptance_list_wiring() {
    local design_md="${1:-}"
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 1

    local in_block=0 in_wiring=0 found_wiring=0

    while IFS= read -r line; do
        line="${line%$'\r'}"  # tolerate CRLF on ALL lines (sentinels + paths)
        if [[ "$line" == '```acceptance' ]]; then
            in_block=1
            continue
        fi
        if [[ $in_block -eq 1 && "$line" == '```' ]]; then
            break
        fi
        if [[ $in_block -eq 1 ]]; then
            # Stop wiring collection when a new recognized sentinel is hit
            if [[ $in_wiring -eq 1 ]]; then
                case "$line" in
                    TESTFILES:|SPEC:*|SPEC-[0-9]*) in_wiring=0 ;;
                    '') continue ;;
                    *)
                        [[ -z "$line" ]] && continue
                        [[ "$line" == /* || "/$line/" == *"/../"* ]] && continue
                        printf '%s\n' "$line"
                        continue
                        ;;
                esac
            fi
            if [[ "$line" == 'WIRING: none' ]]; then
                printf 'none\n'
                found_wiring=1
                in_wiring=0
            elif [[ "$line" == 'WIRING:' ]]; then
                found_wiring=1
                in_wiring=1
            elif [[ "$line" == 'WIRING: '* ]]; then
                # inline single path (not "none")
                local wpath="${line#WIRING: }"
                wpath="${wpath%$'\r'}"
                [[ -z "$wpath" || "$wpath" == /* || "/$wpath/" == *"/../"* ]] || printf '%s\n' "$wpath"
                found_wiring=1
                in_wiring=0
            fi
        fi
    done < "$design_md"

    [[ $found_wiring -eq 1 ]] && return 0
    return 1
}

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

# _acceptance_timeout_prefix — shared helper, extracted to timeout-cmd.sh (#1752)
if ! declare -F _acceptance_timeout_prefix >/dev/null 2>&1; then
    # shellcheck source=./timeout-cmd.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/timeout-cmd.sh"
fi

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

# acceptance_list_testfiles <design_md>  (ADR-036 / #922)
# Prints the repo-relative TESTFILES paths from the ```acceptance block, one
# per line. Includes both bare paths AND paths declared with a SPEC-n: prefix
# (stripping the prefix to expose the bare path). Mirrors the path-traversal
# guard used by build (never surfaces an absolute or ".."-containing path).
# Empty when the block/TESTFILES is absent.
# acceptance_list_supersedes <design_md>  (#2243)
# The existing checks this change makes wrong, from design.md's ```supersedes
# block — a fact about the change, stated by design; updating them to the new
# behaviour is test-author's (#1842: nobody could, so build evaded one). One line
# per check:  <repo-relative-path> <tag>: <why>
# Prints "<path>\t<tag>\t<why>" per valid line. Absolute and ../ paths are
# refused, as for TESTFILES. No block → nothing.
acceptance_list_scope() {
    # #2252: the files design scoped the change to — its ```scope block, one per
    # line, as build is given them (plugins/agent/build/lib/scope.sh). Lets a
    # gate tell a file build could have edited from one only design can change.
    local design_md="${1:-}" line in_block=0
    [[ -n "$design_md" && -f "$design_md" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^'```scope'[[:space:]]*$ ]]; then in_block=1; continue; fi
        if [[ $in_block -eq 1 && "$line" =~ ^'```'[[:space:]]*$ ]]; then break; fi
        [[ $in_block -eq 1 ]] || continue
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        # The siblings' rule: only an in-repo relative path (review on #2253).
        [[ -z "$line" || "$line" == /* || "/$line/" == *"/../"* ]] && continue
        printf '%s\n' "${line#./}"
    done < "$design_md"
}

acceptance_list_supersedes() {
    local design_md="${1:-}" line in_block=0 path rest tag why
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 0
    while IFS= read -r line; do
        line="${line%$'\r'}"
        if [[ "$line" == '```supersedes' ]]; then in_block=1; continue; fi
        # Every block counts, not only the first (review #2247).
        if [[ $in_block -eq 1 && "$line" == '```' ]]; then in_block=0; continue; fi
        [[ $in_block -eq 1 && -n "$line" ]] || continue
        path="${line%% *}"; rest="${line#* }"
        [[ "$path" == /* || "/$path/" == *"/../"* || "$rest" == "$line" ]] && continue
        tag="${rest%%:*}"; why="${rest#*:}"; why="${why# }"
        [[ "$tag" == "["*"]" ]] || continue
        printf '%s\t%s\t%s\n' "$path" "$tag" "$why"
    done < "$design_md"
}

acceptance_list_testfiles() {
    local design_md="${1:-}"
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 0
    local block_output line in_testfiles=0
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    [[ -z "$block_output" ]] && return 0
    while IFS= read -r line; do
        if [[ "$line" == "TESTFILES:" ]]; then
            in_testfiles=1
            continue
        fi
        if [[ $in_testfiles -eq 1 && -n "$line" ]]; then
            line="${line%$'\r'}"
            [[ -z "$line" ]] && continue
            # Stop at WIRING: sentinel (defensive: may appear after TESTFILES: in output)
            [[ "$line" == 'WIRING:'* ]] && break
            # Strip SPEC-n: prefix — emit the bare path(s) into the union
            if [[ "$line" =~ ^SPEC-[0-9]+:[[:space:]]+(.*) ]]; then
                local _bound_str="${BASH_REMATCH[1]}"
                local -a _bound_parts
                read -ra _bound_parts <<< "$_bound_str"
                local _bp
                for _bp in "${_bound_parts[@]}"; do
                    [[ -z "$_bp" || "$_bp" == /* || "/$_bp/" == *"/../"* ]] && continue
                    printf '%s\n' "$_bp"
                done
                continue
            fi
            [[ "$line" == /* || "/$line/" == *"/../"* ]] && continue
            printf '%s\n' "$line"
        fi
    done <<< "$block_output"
}

# acceptance_has_per_spec_binding <design_md>  (#1480)
# Returns 0 when the TESTFILES section contains ≥1 SPEC-n: prefixed binding line,
# indicating that per-SPEC binding mode is active. Returns 1 otherwise.
acceptance_has_per_spec_binding() {
    local design_md="${1:-}"
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 1
    local block_output
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 1
    local in_testfiles=0 line
    while IFS= read -r line; do
        if [[ "$line" == "TESTFILES:" ]]; then in_testfiles=1; continue; fi
        if [[ $in_testfiles -eq 1 ]]; then
            [[ "$line" == 'WIRING:'* ]] && break
            [[ "$line" =~ ^SPEC-[0-9]+:[[:space:]] ]] && return 0
        fi
    done <<< "$block_output"
    return 1
}

# acceptance_spec_has_binding <design_md> <spec_id>  (#1480)
# Returns 0 when the TESTFILES section has ≥1 SPEC-<id>: prefixed line for the
# given spec_id. Returns 1 otherwise (caller should use tag-scan fallback in negctl).
acceptance_spec_has_binding() {
    local design_md="${1:-}" spec_id="${2:-}"
    [[ -z "$design_md" || -z "$spec_id" || ! -f "$design_md" ]] && return 1
    local block_output
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 1
    local in_testfiles=0 line
    while IFS= read -r line; do
        if [[ "$line" == "TESTFILES:" ]]; then in_testfiles=1; continue; fi
        if [[ $in_testfiles -eq 1 ]]; then
            [[ "$line" == 'WIRING:'* ]] && break
            # Match SPEC-<id>: <path> (no classifier bracket in TESTFILES prefix syntax)
            if [[ "$line" =~ ^${spec_id}:[[:space:]] ]]; then return 0; fi
        fi
    done <<< "$block_output"
    return 1
}

# acceptance_spec_desc <design_md> <spec_id>  (#1684)
# Echoes the description text from the SPEC-n line in the acceptance block —
# the text after the colon on the matching `SPEC-<id>[classifier]: <text>` line.
# Truncates to 100 characters with '…' when longer — long enough that the
# clause distinguishing one SPEC from another survives, which is the point of
# showing it. Returns empty string (not an error) when the SPEC id is not found.
# Stops scanning at TESTFILES: to avoid misidentifying per-SPEC binding lines
# in the TESTFILES section.
acceptance_spec_desc() {
    local design_md="${1:-}" spec_id="${2:-}"
    [[ -z "$design_md" || -z "$spec_id" || ! -f "$design_md" ]] && return 0
    local block_output
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    _acceptance_spec_line "$block_output" "$spec_id" || return 0
    local text="$_ACC_SPEC_TEXT"
    if [[ ${#text} -gt 100 ]]; then
        printf '%s…\n' "${text:0:100}"
    else
        printf '%s\n' "$text"
    fi
    return 0
}

# acceptance_list_testfiles_for_spec <design_md> <spec_id>  (#1480)
# Returns testfile paths for the given SPEC-id:
#   - When SPEC-<id>: prefixed lines exist → returns those bound paths only.
#   - When no SPEC-<id>: prefix → returns the unqualified global paths (backward-compat).
# Multiple space-separated paths on a SPEC-n: line are emitted one per line.
# Path-traversal guard applied (same as acceptance_list_testfiles).
acceptance_list_testfiles_for_spec() {
    local design_md="${1:-}" spec_id="${2:-}"
    [[ -z "$design_md" || -z "$spec_id" || ! -f "$design_md" ]] && return 0
    local block_output
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    local in_testfiles=0 line
    local -a per_spec=() global=()
    while IFS= read -r line; do
        if [[ "$line" == "TESTFILES:" ]]; then in_testfiles=1; continue; fi
        if [[ $in_testfiles -eq 1 && -n "$line" ]]; then
            line="${line%$'\r'}"
            [[ -z "$line" ]] && continue
            [[ "$line" == 'WIRING:'* ]] && break
            if [[ "$line" =~ ^(SPEC-[0-9]+):[[:space:]]+(.*) ]]; then
                local _bid="${BASH_REMATCH[1]}" _bpaths="${BASH_REMATCH[2]}"
                if [[ "$_bid" == "$spec_id" ]]; then
                    local -a _bparts; read -ra _bparts <<< "$_bpaths"
                    local _bp
                    for _bp in "${_bparts[@]}"; do
                        [[ -z "$_bp" || "$_bp" == /* || "/$_bp/" == *"/../"* ]] || per_spec+=("$_bp")
                    done
                fi
            else
                [[ "$line" == /* || "/$line/" == *"/../"* ]] || global+=("$line")
            fi
        fi
    done <<< "$block_output"
    # Return per-SPEC paths when bound; else fall back to global unqualified pool.
    if [[ ${#per_spec[@]} -gt 0 ]]; then
        printf '%s\n' "${per_spec[@]}"
    else
        printf '%s\n' "${global[@]+"${global[@]}"}"
    fi
}

# design_decisions_prose <design_md> [max_lines] — the design's DECISION PROSE:
# everything outside fenced blocks, capped (default 120 lines). Empty when absent.
# Shared by build (honours the decisions) and review-lens (judges against them,
# #1654) — one extractor, so the two cannot read a design differently.
design_decisions_prose() {
    local design_md="${1:-}" cap="${2:-120}" body
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 0
    body="$(awk -v cap="$cap" '
        /^```/ { infence = !infence; next }
        infence { next }
        { print; emitted++ }
        emitted >= cap { exit }
    ' "$design_md" 2>/dev/null || true)"
    body="$(printf '%s\n' "$body" | sed '/./,$!d')"
    [[ -z "${body//[[:space:]]/}" ]] && return 0
    printf '%s\n' "$body"
}

# acceptance_requirements_for_judge <design_md> [repo_root]  (#2304, ADR-069 §7)
# The requirements as issue-acceptance reads them: each one's words and, in
# plain words, what its status means — never the raw tag. A done requirement
# also gets its evidence and up to 20 lines around each cited line, read from
# the commit at HEAD (what ships, not the working copy); 6000 characters of
# excerpts in all. The caller cleans the text before it reaches a model.
acceptance_requirements_for_judge() {
    local design_md="${1:-}" root="${2:-.}" blk l sid ev path n from body budget=6000
    blk="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    while IFS= read -r l; do
        [[ "$l" == "TESTFILES:" ]] && break
        [[ "$l" =~ $_ACCEPTANCE_SPEC_RE ]] || continue
        sid="${BASH_REMATCH[1]}"
        _acceptance_spec_line "$blk" "$sid" || continue
        printf -- '- %s: %s\n' "$sid" "$_ACC_SPEC_TEXT"
        case "$_ACC_SPEC_STATUS" in
            no-code) printf '  Status: needs work (no code) — nothing checked it mechanically; judge it yourself, and say whether its tests would catch it broken\n' ;;
            done)    printf '  Status: already done — design says the code already does this; check the claim\n' ;;
            *)       printf '  Status: needs work (code) — its test failed on the old code and passes now\n'; continue ;;
        esac
        [[ "$_ACC_SPEC_STATUS" == "done" && "$_ACC_SPEC_REST" == *" evidence: "* ]] || continue
        local _evl="${_ACC_SPEC_REST#* evidence: }"
        local -a _evs=(); read -ra _evs <<< "${_evl%% covers: *}"
        for ev in "${_evs[@]+"${_evs[@]}"}"; do
            printf '  Evidence: %s\n' "$ev"
            path="$ev" n=1
            [[ "$ev" =~ ^(.+):([0-9]+)$ ]] && { path="${BASH_REMATCH[1]}"; n=$((10#${BASH_REMATCH[2]})); }
            [[ "$path" != /* && "/$path/" != *"/../"* && $budget -gt 0 ]] || continue
            from=$(( n > 10 ? n - 10 : 1 ))
            # awk reads to the end (no early exit), so git never takes SIGPIPE.
            body="$(git -C "$root" show "HEAD:$path" 2>/dev/null \
                | awk -v a="$from" -v b="$((from + 19))" 'NR >= a && NR <= b { printf "    %d| %s\n", NR, $0 }')" || body=""
            [[ -n "$body" ]] || { printf '    (not found in the commit at HEAD)\n'; continue; }
            body="${body:0:$budget}"; budget=$((budget - ${#body}))
            printf '%s\n' "$body"
        done
    done <<< "$blk"
    return 0
}
