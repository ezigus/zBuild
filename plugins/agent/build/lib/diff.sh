#!/usr/bin/env bash
# plugins/agent/build/lib/diff.sh — diff-harvest and scope-validation helpers.
# Sourced by plugin.sh after shared libs (numstat-format.sh, event-bus.sh) are loaded.


# #2010: zbuild_engine_tmpdir names where engine code writes temp files.
# Lazy-sourced, same pattern lifecycle.sh uses for stage-scratch.sh: this
# file is sourced from several entry points and cannot assume helpers.sh
# arrived first. helpers.sh sources only compat.sh, so there is no cycle.
if ! declare -F zbuild_engine_tmpdir >/dev/null 2>&1; then
    # shellcheck source=../../../../scripts/lib/helpers.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../scripts/lib" && pwd)/helpers.sh" 2>/dev/null || true
fi

[[ -n "${_ZBUILD_BUILD_DIFF_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_DIFF_LOADED=1

# _build_load_preexisting_untracked <state_dir> (#1265)
# Materialize the intake pre-existing-untracked snapshot to a sorted temp file
# for `grep -Fxq` membership lookup. Echoes the temp-file path on success
# (caller rm's it); returns 1 when the baseline file is absent.
_build_load_preexisting_untracked() {
    local state_dir="$1"
    local baseline="$state_dir/intake-untracked-baseline.txt"
    [[ -f "$baseline" ]] || return 1
    local tmp
    tmp="$(mktemp "$(zbuild_engine_tmpdir)/zbuild-preexist.XXXXXX")" || return 1
    tr '\0' '\n' < "$baseline" | sort -u > "$tmp"
    printf '%s' "$tmp"
    return 0
}

# Global output vars for _build_harvest_diff:
_BUILD_HARVEST_PREEXIST_UNTRACKED=""
_BUILD_HARVEST_DIFF_CONTENT=""
_BUILD_HARVEST_DIFF_FAILURE="false"

# _build_harvest_diff <repo_root> <output_diff_patch> <artifact_dir>
# Perform selective git add -N + git diff HEAD, enforce trailing-newline and
# NUL-detection invariants. Sets globals:
#   _BUILD_HARVEST_PREEXIST_UNTRACKED — temp file path (or empty)
#   _BUILD_HARVEST_DIFF_CONTENT       — diff content string
#   _BUILD_HARVEST_DIFF_FAILURE       — "true" if git diff failed
_build_harvest_diff() {
    local _repo_root="$1"
    local _output_diff_patch="$2"
    local _artifact_dir="$3"

    _BUILD_HARVEST_PREEXIST_UNTRACKED=""
    _BUILD_HARVEST_DIFF_CONTENT=""
    _BUILD_HARVEST_DIFF_FAILURE="false"

    # #1265: selective intent-add — skip pre-existing strays.
    local _preexist_untracked=""
    local _pu_state_dir; _pu_state_dir="$(dirname "$_artifact_dir")"
    _preexist_untracked="$(_build_load_preexisting_untracked "$_pu_state_dir" 2>/dev/null || true)"
    if [[ -n "$_preexist_untracked" && -f "$_preexist_untracked" ]]; then
        local -a _add_paths=()
        local _u
        while IFS= read -r -d '' _u; do
            [[ -z "$_u" ]] && continue
            grep -Fxq -- "$_u" "$_preexist_untracked" && continue
            _add_paths+=("$_u")
        done < <(git -C "$_repo_root" ls-files --others --exclude-standard -z 2>/dev/null)
        if [[ ${#_add_paths[@]} -gt 0 ]]; then
            git -C "$_repo_root" add -N -- "${_add_paths[@]}" 2>/dev/null || true
        fi
    else
        git -C "$_repo_root" add -N . 2>/dev/null || true
    fi

    # #530: stream directly to disk to preserve trailing newline.
    local _diff_rc=0
    git -C "$_repo_root" diff HEAD > "$_output_diff_patch" 2>/dev/null || _diff_rc=$?

    local _diff_failure="false"
    if [[ $_diff_rc -ne 0 ]]; then
        warn "_build_harvest_diff: git diff HEAD failed in $_repo_root rc=$_diff_rc"
        emit_event "loop.git_diff_failed" "plugin=build" \
            "cwd=$_repo_root" "rc=$_diff_rc"
        : > "$_output_diff_patch"
        _diff_failure="true"
    fi

    # Lossless readback via printf-x trick.
    local _diff_content=""
    if [[ -s "$_output_diff_patch" ]]; then
        _diff_content="$(cat "$_output_diff_patch"; printf x)"
        _diff_content="${_diff_content%x}"
    fi

    # #530 trailing-newline invariant — defense in depth.
    if [[ -s "$_output_diff_patch" ]]; then
        local _last_byte
        _last_byte="$(tail -c1 "$_output_diff_patch" | od -An -tx1 | tr -d ' \n')"
        if [[ "$_last_byte" != "0a" ]]; then
            printf '\n' >> "$_output_diff_patch"
            _diff_content+=$'\n'
            emit_event "build.diff.trailing_newline_restored" "plugin=build" \
                "last_byte=0x${_last_byte}" >/dev/null 2>&1 || true
        fi
    fi

    # #530 NUL detection via perl (#549: macOS BSD grep lacks -P).
    if [[ -s "$_output_diff_patch" ]] && \
       LC_ALL=C perl -0777 -ne 'exit(!/\x00/)' "$_output_diff_patch" 2>/dev/null; then
        emit_event "build.diff.binary_truncation_observed" "plugin=build" \
            "path=$_output_diff_patch" >/dev/null 2>&1 || true
    fi

    _BUILD_HARVEST_PREEXIST_UNTRACKED="$_preexist_untracked"
    _BUILD_HARVEST_DIFF_CONTENT="$_diff_content"
    _BUILD_HARVEST_DIFF_FAILURE="$_diff_failure"
}

# Global output vars for _build_validate_scope_violations:
_BUILD_VSCP_VIOLATION="false"
_BUILD_VSCP_VIOLATIONS_NL=""
_BUILD_VSCP_VIOLATIONS_CREATED_NL=""
_BUILD_VSCP_PRE_ZERO_NUMSTAT=""
_BUILD_VSCP_DIFF_CONTENT=""

# _build_validate_scope_violations <diff_content> <plan_files_csv> <repo_root>
#   <artifact_dir> <output_diff_patch> <router_rc> <preexist_untracked>
# Parse git diff --name-status -z, check per-path scope, handle OOS revert
# (timeout #827) vs full empty-diff (clean run). Cleans up the preexist
# temp file after use. Sets globals:
#   _BUILD_VSCP_VIOLATION             — "true"/"false"
#   _BUILD_VSCP_VIOLATIONS_NL         — newline-delimited OOS paths
#   _BUILD_VSCP_VIOLATIONS_CREATED_NL — newline-delimited created OOS paths
#   _BUILD_VSCP_PRE_ZERO_NUMSTAT      — numstat captured before zeroing
#   _BUILD_VSCP_DIFF_CONTENT          — updated diff_content (may be zeroed)
_build_validate_scope_violations() {
    local _diff_content="$1"
    local _plan_files_csv="$2"
    local _repo_root="$3"
    local _artifact_dir="$4"
    local _output_diff_patch="$5"
    local _router_rc="${6:-0}"
    local _preexist_untracked="${7:-}"

    _BUILD_VSCP_VIOLATION="false"
    _BUILD_VSCP_VIOLATIONS_NL=""
    _BUILD_VSCP_VIOLATIONS_CREATED_NL=""
    _BUILD_VSCP_PRE_ZERO_NUMSTAT=""
    _BUILD_VSCP_DIFF_CONTENT="$_diff_content"

    local _scope_violation="false"
    local _scratch_cleaned=0
    local -a _scope_violations=()
    local -a _scope_violations_created=()

    if [[ -n "$_diff_content" && -n "$_plan_files_csv" ]]; then
        local -a _allowed_files=()
        local _IFS_save="$IFS"
        IFS=','
        # shellcheck disable=SC2206
        _allowed_files=( $_plan_files_csv )
        IFS="$_IFS_save"

        local _ns_file="$_artifact_dir/.build-name-status.bin"
        git -C "$_repo_root" diff --name-status -z HEAD > "$_ns_file" 2>/dev/null || :

        local -a _tokens=()
        local _tok
        while IFS= read -r -d '' _tok; do
            _tokens+=("$_tok")
        done < "$_ns_file"
        rm -f "$_ns_file"

        local _i _n=${#_tokens[@]}
        _i=0
        while (( _i < _n )); do
            local _status="${_tokens[$_i]}"
            _i=$((_i+1))
            local _first_path="${_tokens[$_i]:-}"
            _i=$((_i+1))
            local -a _paths_to_check=("$_first_path")
            if [[ "$_status" =~ ^[RC] ]]; then
                _paths_to_check+=("${_tokens[$_i]:-}")
                _i=$((_i+1))
            fi
            local _p
            for _p in "${_paths_to_check[@]}"; do
                [[ -z "$_p" ]] && continue
                # #1265: skip paths already untracked at intake
                if [[ "$_status" =~ ^A ]] \
                   && [[ -n "$_preexist_untracked" && -f "$_preexist_untracked" ]] \
                   && grep -Fxq -- "$_p" "$_preexist_untracked"; then
                    continue
                fi
                if ! _build_path_in_scope "$_p" _allowed_files; then
                    # #1789: editor/VCS residue (sed -i.bak, git show HEAD:f >
                    # f.head) is the agent comparing versions of a file it was
                    # authorised to edit, not scope. Narrowing is by suffix and
                    # applies only OUT of scope, so a tracked or in-scope file
                    # carrying one of these suffixes is never touched.
                    if _build_path_is_scratch "$_p"; then
                        # Test against HEAD, not the index: the `git add -N`
                        # above (intent-to-add) makes `ls-files --error-unmatch`
                        # succeed for brand-new residue too.
                        if git -C "$_repo_root" cat-file -e "HEAD:$_p" 2>/dev/null; then
                            # Genuinely tracked: rm would leave a deletion in the
                            # diff — still an OOS change. Restore it instead.
                            git -C "$_repo_root" checkout HEAD -- "$_p" 2>/dev/null || true
                        else
                            git -C "$_repo_root" rm -q -f --cached --ignore-unmatch \
                                -- "$_p" >/dev/null 2>&1 || true
                            rm -f "$_repo_root/$_p" 2>/dev/null || true
                        fi
                        _scratch_cleaned=$((_scratch_cleaned+1))
                        emit_event "build.scratch.cleaned" "plugin=build" \
                            "path=$_p" "status=$_status"
                        continue
                    fi
                    _scope_violation="true"
                    _scope_violations+=("$_p")
                    [[ "$_status" =~ ^A ]] && _scope_violations_created+=("$_p")
                    emit_event "build.scope.violation" "plugin=build" \
                        "path=$_p" "status=$_status"
                fi
            done
        done
    fi

    # #1265: drop the pre-existing-untracked scratch file.
    [[ -n "$_preexist_untracked" ]] && rm -f "$_preexist_untracked" 2>/dev/null || true

    # A cleaned path is still present in $_diff_content, which was captured
    # before this function ran — plugin.sh derives files_changed/lines_added
    # from that string, so it would report files it just deleted.
    if [[ "$_scratch_cleaned" -gt 0 && "$_scope_violation" != "true" ]]; then
        git -C "$_repo_root" diff HEAD > "$_output_diff_patch" 2>/dev/null || true
        if [[ -s "$_output_diff_patch" ]]; then
            # printf x guards the trailing newline command substitution strips (#530).
            _diff_content="$(cat "$_output_diff_patch"; printf x)"
            _diff_content="${_diff_content%x}"
        else
            _diff_content=""
        fi
    fi

    local _pre_zero_numstat=""
    if [[ "$_scope_violation" == "true" ]]; then
        _pre_zero_numstat="$(git -C "$_repo_root" diff HEAD --numstat 2>/dev/null || true)"

        if [[ $_router_rc -ge 2 ]]; then
            # #827: timeout — revert OOS, preserve in-scope diff.
            warn "_build_validate_scope_violations: scope violation under router rc=$_router_rc — reverting OOS paths, preserving in-scope diff (#827)"
            local _oos_path
            for _oos_path in "${_scope_violations[@]}"; do
                [[ -z "$_oos_path" ]] && continue
                if git -C "$_repo_root" ls-files --error-unmatch -- "$_oos_path" >/dev/null 2>&1; then
                    git -C "$_repo_root" checkout HEAD -- "$_oos_path" 2>/dev/null || true
                else
                    rm -f "$_repo_root/$_oos_path" 2>/dev/null || true
                fi
            done
            git -C "$_repo_root" diff HEAD > "$_output_diff_patch" 2>/dev/null || true
            if [[ -s "$_output_diff_patch" ]]; then
                _diff_content="$(cat "$_output_diff_patch"; printf x)"
                _diff_content="${_diff_content%x}"
            else
                _diff_content=""
            fi
            _scope_violation="false"
            emit_event "build.timeout.partial_work_preserved" "plugin=build" \
                "router_rc=$_router_rc" \
                "oos_paths_reverted=${#_scope_violations[@]}" \
                "in_scope_diff_bytes=${#_diff_content}"
        else
            # Clean run: revert edited OOS files, zero the diff.
            warn "_build_validate_scope_violations: scope violation — writing empty diff.patch"
            local _rev_path
            for _rev_path in "${_scope_violations[@]}"; do
                [[ -z "$_rev_path" ]] && continue
                git -C "$_repo_root" checkout HEAD -- "$_rev_path" 2>/dev/null || true
            done
            _diff_content=""
            : > "$_output_diff_patch"
        fi
    fi

    _BUILD_VSCP_VIOLATION="$_scope_violation"
    if [[ ${#_scope_violations[@]} -gt 0 ]]; then
        _BUILD_VSCP_VIOLATIONS_NL="$(printf '%s\n' "${_scope_violations[@]}")"
    fi
    if [[ ${#_scope_violations_created[@]} -gt 0 ]]; then
        _BUILD_VSCP_VIOLATIONS_CREATED_NL="$(printf '%s\n' "${_scope_violations_created[@]}")"
    fi
    _BUILD_VSCP_PRE_ZERO_NUMSTAT="$_pre_zero_numstat"
    _BUILD_VSCP_DIFF_CONTENT="$_diff_content"
}

# _build_rewrite_cumulative_diff <scope_violation> <artifact_dir> <repo_root>
#   <output_diff_patch> <diff_failure>
# Rewrite diff.patch as the cumulative baseline→HEAD delta (#661 / ADR-020).
# No-op on scope_violation. Re-enforces trailing-newline invariant.
_build_rewrite_cumulative_diff() {
    local _scope_violation="$1"
    local _artifact_dir="$2"
    local _repo_root="$3"
    local _output_diff_patch="$4"
    local _diff_failure="${5:-false}"

    [[ "$_scope_violation" == "true" ]] && return 0

    local _baseline_sha="" _state_dir_for_baseline=""
    _state_dir_for_baseline="$(dirname "$_artifact_dir")"
    if [[ -f "$_state_dir_for_baseline/intake-baseline-ref.txt" ]]; then
        _baseline_sha="$(cat "$_state_dir_for_baseline/intake-baseline-ref.txt" \
            2>/dev/null || true)"
    elif [[ -n "${ZBUILD_STATE_DIR:-}" \
          && -f "$ZBUILD_STATE_DIR/intake-baseline-ref.txt" ]]; then
        _baseline_sha="$(cat "$ZBUILD_STATE_DIR/intake-baseline-ref.txt" \
            2>/dev/null || true)"
    fi

    local _do_rewrite="false"
    if [[ -n "$_baseline_sha" ]]; then
        _do_rewrite="true"
    elif [[ "$_diff_failure" != "true" ]]; then
        _do_rewrite="true"
    fi

    if [[ "$_do_rewrite" == "true" ]]; then
        local _cum_rc=0
        if [[ -n "$_baseline_sha" ]]; then
            git -C "$_repo_root" diff "$_baseline_sha..HEAD" \
                > "$_output_diff_patch" 2>/dev/null || _cum_rc=$?
        else
            git -C "$_repo_root" diff HEAD \
                > "$_output_diff_patch" 2>/dev/null || _cum_rc=$?
        fi
        if [[ $_cum_rc -ne 0 ]]; then
            warn "_build_rewrite_cumulative_diff: cumulative diff failed in $_repo_root rc=$_cum_rc baseline=${_baseline_sha:-<none>}"
            emit_event "loop.git_diff_failed" "plugin=build" \
                "cwd=$_repo_root" "rc=$_cum_rc" "phase=cumulative"
            : > "$_output_diff_patch"
        fi
    fi

    # #530 trailing-newline invariant on the rewritten file.
    if [[ -s "$_output_diff_patch" ]]; then
        local _cum_last_byte
        _cum_last_byte="$(tail -c1 "$_output_diff_patch" \
            | od -An -tx1 | tr -d ' \n')"
        if [[ "$_cum_last_byte" != "0a" ]]; then
            printf '\n' >> "$_output_diff_patch"
            emit_event "build.diff.trailing_newline_restored" "plugin=build" \
                "last_byte=0x${_cum_last_byte}" "phase=cumulative" \
                >/dev/null 2>&1 || true
        fi
    fi
}

