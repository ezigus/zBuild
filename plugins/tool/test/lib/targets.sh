#!/usr/bin/env bash
# plugins/tool/test/lib/targets.sh — which test files a targeted rerun runs, and its command (moved from plugin.sh, #2565:
# plugin.sh under 500 lines).
#
# Sourced by plugin.sh after its bootstrap. Sourced library: no set -euo.

[[ -n "${_ZBUILD_TEST_TARGETS_LOADED:-}" ]] && return 0
_ZBUILD_TEST_TARGETS_LOADED=1

# _test_list_file_v <var> <repo_root> <name> — the repository's config/<name>,
# else the engine's own (#2556).
_test_list_file_v() {
    local -n _tlf="$1"; _tlf=""
    if [[ -f "$2/config/$3" ]]; then _tlf="$2/config/$3"
    elif [[ -f "$_ZBUILD_TEST_STAGE_ROOT/config/$3" ]]; then _tlf="$_ZBUILD_TEST_STAGE_ROOT/config/$3"; fi
}

# ─── _test_compute_target_files (ADR-034 / #846, #2121) ──────────────────────
# Unions: the prior-iter red-set (ZBUILD_TEST_RED_SET JSON array of relative
# paths, advisory — dead entries dropped); for each ZBUILD_TEST_CHANGED_FILES
# entry (comma-separated, repo-relative) every test under tests/ or
# plugins/*/*/tests/ that names its PATH, the same for its bare basename only
# when that basename is unique in the repo, and — for a file inside a plugin —
# that plugin's own tests/*-test.sh; and the files in the test folders holding
# a SPEC tag of the design (optional input `design` via ZBUILD_STAGE_INPUTS). Deduplicated, one
# repo-relative path per line. Empty when every input is absent/empty.
# Usage: _test_compute_target_files <repo_root>
_test_compute_target_files() {
    local repo_root="$1"
    local red_set_json="${ZBUILD_TEST_RED_SET:-}"
    local changed_files_csv="${ZBUILD_TEST_CHANGED_FILES:-}"

    local -a all_files=()

    # Add files from red-set JSON (array of repo-relative paths).
    # #1239: the red-set is an ADVISORY hint, not a contract. Resolve each path
    # against the CURRENT tree ($repo_root) and DROP any that does not exist —
    # a stale/absolute/deleted path is never turned into a target (and thus never
    # a phantom "No such file" failure). When every hint is dead the list stays
    # empty and the caller falls back to a full regression run.
    if [[ -n "$red_set_json" && -f "$red_set_json" ]]; then
        local _rf
        while IFS= read -r _rf; do
            [[ -n "$_rf" ]] || continue
            [[ -f "$repo_root/$_rf" ]] && all_files+=("$_rf")
        done < <(jq -r '.[]? // empty' "$red_set_json" 2>/dev/null || true)
    fi

    # #2121: selection is by PATH. A changed file selects (a) every test under
    # tests/ or plugins/*/*/tests/ that names its repo-relative path, (b) the
    # same for its bare basename ONLY when that basename is unique in the repo
    # (`source_module.sh` yes; `plugin.sh`/`manifest.yaml` no — those matched
    # 286 files, 39 minutes, on #1841), and (c) for a file inside a plugin,
    # that plugin's own tests/ directory, which the old tests/-only scan never
    # saw.
    if [[ -n "$changed_files_csv" ]]; then
        local -a _scan_dirs=()
        [[ -d "$repo_root/tests" ]] && _scan_dirs+=("$repo_root/tests")
        local _pt
        for _pt in "$repo_root"/plugins/*/*/tests; do
            [[ -d "$_pt" ]] && _scan_dirs+=("$_pt")
        done
        # One walk for the uniqueness test, not one per changed file: the set
        # of basenames that occur more than once in the repo.
        local -A _dup_bn=()
        local _dn
        while IFS= read -r _dn; do
            [[ -n "$_dn" ]] && _dup_bn["$_dn"]=1
        done < <(find "$repo_root" -type f -not -path '*/.git/*' 2>/dev/null \
                    | sed 's|.*/||' | LC_ALL=C sort | uniq -d)
        local _IFS_save="$IFS"; IFS=','
        local -a _changed_arr=()
        read -ra _changed_arr <<< "$changed_files_csv"
        IFS="$_IFS_save"
        local _cf _bn _match _plug_tests
        for _cf in "${_changed_arr[@]}"; do
            _cf="${_cf## }"; _cf="${_cf% }"; _cf="${_cf#./}"
            [[ -z "$_cf" ]] && continue
            if [[ ${#_scan_dirs[@]} -gt 0 ]]; then
                while IFS= read -r _match; do
                    [[ -z "$_match" ]] && continue
                    all_files+=("${_match#"$repo_root"/}")
                done < <(grep -rlF -- "$_cf" "${_scan_dirs[@]}" 2>/dev/null || true)
                _bn="$(basename "$_cf")"
                if [[ -n "$_bn" && -z "${_dup_bn[$_bn]+set}" ]]; then
                    while IFS= read -r _match; do
                        [[ -z "$_match" ]] && continue
                        all_files+=("${_match#"$repo_root"/}")
                    done < <(grep -rlF -- "$_bn" "${_scan_dirs[@]}" 2>/dev/null || true)
                fi
            fi
            if [[ "$_cf" == plugins/*/*/* ]]; then
                _plug_tests="$repo_root/$(printf '%s' "$_cf" | cut -d/ -f1-3)/tests"
                if [[ -d "$_plug_tests" ]]; then
                    while IFS= read -r _match; do
                        [[ -z "$_match" ]] && continue
                        all_files+=("${_match#"$repo_root"/}")
                    done < <(find "$_plug_tests" -maxdepth 1 -name '*-test.sh' -type f 2>/dev/null || true)
                fi
            fi
        done
    fi

    # #2121: the acceptance tests are always in the set — they are the
    # assertions the acceptance gate will judge, delivered the #2098 way.
    # #2508: found by their tags in the test folders.
    if true; then
        local _design_md
        # #2364: the acceptance contract, found by what it contains.
        _design_md="$(earlier_acceptance_contract "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"
        if [[ -n "$_design_md" && -f "$_design_md" ]] && declare -F acceptance_list_testfiles >/dev/null 2>&1; then
            local _dtf
            while IFS= read -r _dtf; do
                [[ -n "$_dtf" && -f "$repo_root/$_dtf" ]] && all_files+=("$_dtf")
            done < <(acceptance_list_testfiles "$_design_md" "$repo_root" 2>/dev/null || true)
        fi
    fi

    # #2556 (ADR-040): a change to a run-shaping file always runs the shape
    # tests, so a targeted rerun cannot leave out the tests that pin the run.
    if [[ -n "$changed_files_csv" ]]; then
        local _sp_file _sp_tests _sp_l _sp_hit="" _sp_cf
        local -a _sp_globs=()
        _test_list_file_v _sp_file "$repo_root" shape-change-paths.txt
        _test_list_file_v _sp_tests "$repo_root" shape-tests.txt
        if [[ -n "$_sp_file" && -n "$_sp_tests" ]]; then
            while IFS= read -r _sp_l || [[ -n "$_sp_l" ]]; do
                _sp_l="${_sp_l%%#*}"; _sp_l="${_sp_l//[[:space:]]/}"; [[ -n "$_sp_l" ]] && _sp_globs+=("$_sp_l")
            done < "$_sp_file"
            local -a _sp_cfs=(); local _sp_ifs="$IFS"; IFS=','; read -ra _sp_cfs <<< "$changed_files_csv"; IFS="$_sp_ifs"
            for _sp_cf in ${_sp_cfs[@]+"${_sp_cfs[@]}"}; do
                _sp_cf="${_sp_cf## }"; _sp_cf="${_sp_cf% }"; _sp_cf="${_sp_cf#./}"
                for _sp_l in ${_sp_globs[@]+"${_sp_globs[@]}"}; do
                    # shellcheck disable=SC2053  # the list's globs match by design
                    [[ "$_sp_cf" == $_sp_l ]] && { _sp_hit=1; break 2; }
                done
            done
            if [[ -n "$_sp_hit" ]]; then
                while IFS= read -r _sp_l || [[ -n "$_sp_l" ]]; do
                    _sp_l="${_sp_l%%#*}"; _sp_l="${_sp_l//[[:space:]]/}"
                    # Only a path inside the repository is ever run.
                    [[ -n "$_sp_l" && "$_sp_l" != /* && "/$_sp_l/" != *"/../"* && -f "$repo_root/$_sp_l" ]] && all_files+=("$_sp_l")
                done < "$_sp_tests"
            fi
        fi
    fi

    # Deduplicate and emit sorted list (skip blanks)
    if [[ ${#all_files[@]} -gt 0 ]]; then
        printf '%s\n' "${all_files[@]}" | sort -u | grep -v '^[[:space:]]*$' || true
    fi
}

# ─── _test_build_targeted_cmd (ADR-034 / #846) ───────────────────────────────
# Renders the repo-configurable targeted-run command. <template> is a command
# containing the literal `{files}`, which is replaced with the shell-quoted,
# space-separated list of target test files. Echoes the rendered command, or an
# EMPTY string when <template> or <file_list> is empty (the caller then runs the
# full suite — never a broken targeted command).
#
# The targeted runner is responsible for emitting output the verdict parser
# recognises and for running every file independently (no `&&` short-circuit).
# zbuild's default — `scripts/run-tests.sh --files {files}` — does both: it loops
# the files and emits the `unit: N/M passed` tier-summary, identical to the full
# run. Other repos set ZBUILD_TEST_CMD_TARGETED to their framework's subset
# command (e.g. `jest {files}`, `pytest {files}`, `cargo test {files}`).
# Usage: _test_build_targeted_cmd <template> <file_list>
_test_build_targeted_cmd() {
    local template="$1" file_list="$2"
    [[ -z "$template" || -z "$file_list" ]] && return 0
    # Guard a misconfigured template (no {files}) — silently dropping the file
    # list would run the WRONG command. Empty return → caller runs the full suite.
    [[ "$template" != *'{files}'* ]] && return 0

    local _files_q="" _f
    while IFS= read -r _f; do
        [[ -z "$_f" ]] && continue
        _files_q="${_files_q:+$_files_q }'${_f}'"
    done <<< "$file_list"
    [[ -z "$_files_q" ]] && return 0

    printf '%s' "${template/\{files\}/$_files_q}"
}
