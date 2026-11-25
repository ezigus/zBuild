#!/usr/bin/env bash
# plugins/tool/test/lib/already-failing.sh — a failing test file that already
# fails on the starting code is not this change's (#2591, ADR-054 §6a).
#
# #2532 runs 45017980554 (C7) and 45102665787 (RG9): a test outside the change
# failed every round, no stage could fix it, and the cycle ran out of rounds.
# Only a file the branch did not change is checked, so a test this branch wrote
# or edited never hides behind an old failure. Runs only when a file failed.

# _test_af_cmd_v <var> <dir> <file> — the targeted command for <file>, as <dir>
# would run it (its own scripts/run-tests.sh when no command is configured).
_test_af_cmd_v() {
    local -n _tacv="$1"; local tmpl="${ZBUILD_TEST_CMD_TARGETED:-}"
    [[ -z "$tmpl" && -f "$2/scripts/run-tests.sh" ]] && tmpl='bash scripts/run-tests.sh --files {files}'
    _tacv="$(_test_build_targeted_cmd "$tmpl" "$3")"
}

# _test_af_checks_v <array> <output> — the failing checks (✗ lines) an output
# names, colour codes and surrounding space gone.
_test_af_checks_v() {
    local -n _tafc="$1"; local l
    _tafc=()
    while IFS= read -r l; do
        [[ "$l" == *"✗"* ]] || continue
        l="$(sed $'s/\x1b\\[[0-9;]*m//g' <<< "$l")"
        l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"
        _tafc+=("$l")
    done <<< "$2"
}

# _test_already_failing_v <array> <staging> <repo_root> <pid_file> <pgid_file>
#   <failing files, one per line> — the failing files that fail on the merge
# base too, with no failing check there that is not failing on the base. Each
# is run alone on both sides: <staging>, and a copy of it set to the base the
# same way (so the files git ignores are there too). A file whose run on the
# base gives no counts the parser knows, or that passes when run again with the
# change, is not excused. <staging>-base is removed here and by the stage's
# RETURN trap.
_test_already_failing_v() {
    local -n _taf="$1"; local tmp="$2" repo="$3" pidf="$4" pgidf="$5" failing="$6"
    local base head f c ch cb oh ob rc_b v rec wt="$2-base" ok
    local -A changed=() seen=() bset=()
    local -a cand=() xh=() xb=()
    _taf=()
    [[ -n "$failing" ]] || return 0
    zbuild_resolve_merge_base_v base "$repo"
    [[ -n "$base" ]] || return 0
    head="$(git -C "$tmp" rev-parse HEAD 2>/dev/null)" || return 0
    [[ "$base" != "$head" ]] || return 0
    while IFS= read -r f; do [[ -n "$f" ]] && changed[$f]=1; done \
        < <(git -C "$tmp" diff --name-only "$base" HEAD 2>/dev/null || true)
    while IFS= read -r f; do
        [[ -n "$f" && -z "${changed[$f]:-}" && -z "${seen[$f]:-}" ]] || continue
        seen[$f]=1
        git -C "$tmp" cat-file -e "$base:$f" 2>/dev/null && cand+=("$f")
    done <<< "$failing"
    (( ${#cand[@]} > 0 )) || return 0
    rm -rf "$wt"
    # $tmp/.git is the copy's own (_test_own_git, #2605): carried to $wt, so the
    # checkout below moves only $wt. Leaving it out would leave $wt with no git.
    if command -v rsync >/dev/null 2>&1; then rsync -a "$tmp/" "$wt/" 2>/dev/null || cp -r "$tmp/." "$wt/"
    else mkdir -p "$wt" && cp -r "$tmp/." "$wt/"; fi
    git -C "$wt" checkout -q -f --detach "$base" >/dev/null 2>&1 || { rm -rf "$wt"; return 0; }
    git -C "$wt" clean -fdq >/dev/null 2>&1 || true
    for f in "${cand[@]}"; do
        _test_af_cmd_v ch "$tmp" "$f"; _test_af_cmd_v cb "$wt" "$f"
        [[ -n "$ch" && -n "$cb" ]] || continue
        rc_b=0
        ob="$(_test_spawn_suite "$wt" "$cb" "" "" "$pidf" "$pgidf")" || rc_b=$?
        IFS='|' read -r v _ _ _ rec <<< "$(_test_parse_summary "$ob" "$rc_b")"
        [[ "$rec" == "1" && "$v" == "fail" ]] || continue
        oh="$(_test_spawn_suite "$tmp" "$ch" "" "" "$pidf" "$pgidf")" || true
        [[ "$(_test_extract_failing_files "$oh" "$tmp")" == *"$f"* ]] || continue
        _test_af_checks_v xh "$oh"; _test_af_checks_v xb "$ob"
        bset=(); for c in ${xb[@]+"${xb[@]}"}; do bset[$c]=1; done
        ok=1; for c in ${xh[@]+"${xh[@]}"}; do [[ -n "${bset[$c]:-}" ]] || { ok=0; break; }; done
        (( ok == 1 )) && _taf+=("$f")
    done
    rm -rf "$wt"
    emit_event "test.already_failing" "files=${#_taf[@]}" "checked=${#cand[@]}" 2>/dev/null || true
    return 0
}
