#!/usr/bin/env bash
# scripts/lib/objective-ablation.sh — de-ceremonied ablation gates (ADR-037 §1, #971)
#
# Three deterministic checks that derive targets mechanically from git diff —
# no SPEC/WIRING grammar, no design.md acceptance-block parsing.
#
# Public functions:
#   _og_ablation_negctl <repo_root>       → echoes ABLATION_NEGCTL PASS|FAIL|SKIP
#   _og_ablation_reachability <repo_root> → echoes ABLATION_REACH PASS|FAIL|SKIP
#   _og_ablation_shape_floor <repo_root>  → echoes ABLATION_SHAPE PASS|FAIL|SKIP
#
# Source-only; no `set -e` at top level (would mutate caller options).

[[ -n "${_ZBUILD_OBJECTIVE_ABLATION_LOADED:-}" ]] && return 0
_ZBUILD_OBJECTIVE_ABLATION_LOADED=1

_OA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./merge-base.sh
source "$_OA_LIB_DIR/merge-base.sh"
# shellcheck source=./impact-prefilter.sh
source "$_OA_LIB_DIR/impact-prefilter.sh"

# ─── _oa_diff_files <repo_root> ──────────────────────────────────────────────
# Prints changed file paths (one per line) between merge-base and HEAD.
# ZBUILD_DIFF_CMD overrides for testability.
_oa_diff_files() {
    local repo_root="$1"
    local diff_cmd="${ZBUILD_DIFF_CMD:-}"
    if [[ -n "$diff_cmd" ]]; then
        bash -c "$diff_cmd" 2>/dev/null || true
        return
    fi
    local base_sha
    base_sha="$(zbuild_resolve_merge_base "$repo_root")"
    [[ -z "$base_sha" ]] && return
    git -C "$repo_root" diff --name-only "$base_sha" HEAD 2>/dev/null || true
}

# ─── _oa_run_test <testfile_abs> <cwd> ───────────────────────────────────────
# Runs a test file, returning its exit code. Timeout-guarded; never inherits
# pipeline parallelism knobs.
_oa_run_test() {
    local testfile="$1" cwd="$2"
    local timeout_s="${ZBUILD_NEGCTL_TIMEOUT:-60}"
    local -a runner=(bash "$testfile")
    if command -v timeout >/dev/null 2>&1; then
        runner=(timeout "$timeout_s" bash "$testfile")
    fi
    (
        cd "$cwd" || exit 2
        unset ZBUILD_TEST_QUIET
        unset ZBUILD_TEST_PARALLEL_JOBS ZBUILD_PARALLEL_SAFE_TIERS
        "${runner[@]}" </dev/null >/dev/null 2>&1
    )
}

# ─── _oa_is_test_file <path> ─────────────────────────────────────────────────
# A changed path is a test file if it ends in -test.sh AND lives under a tests/
# directory — matching scripts/run-tests.sh's discovery: top-level tests/, plus
# co-located core/*/tests/ and plugins/*/*/tests/ (incl. *-unit-test.sh, which
# also ends in -test.sh). The old `tests/*-test.sh` glob missed the co-located
# tests (Copilot #1025): a tautological core/plugin test change could slip past
# negctl, and reachability would incorrectly SKIP when only such tests changed.
_oa_is_test_file() {
    local f="$1"
    [[ "$f" == *-test.sh ]] || return 1
    [[ "$f" == tests/* || "$f" == */tests/* ]]
}

# ─── _og_ablation_negctl <repo_root> ─────────────────────────────────────────
# Changed *-test.sh files are the negctl targets. For each:
#   baseline worktree (merge-base impl + HEAD test) → expect non-zero
#   HEAD run → expect zero
#   ≥1 valid control → ABLATION_NEGCTL PASS; all tautological → FAIL tautology.
_og_ablation_negctl() {
    local repo_root="$1"

    local base_sha
    base_sha="$(zbuild_resolve_merge_base "$repo_root")"
    if [[ -z "$base_sha" ]]; then
        printf 'ABLATION_NEGCTL SKIP no_baseline\n'
        return 0
    fi
    local head_sha
    head_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
    if [[ -n "$head_sha" && "$base_sha" == "$head_sha" ]]; then
        printf 'ABLATION_NEGCTL SKIP no_impl_delta\n'
        return 0
    fi

    # Collect changed test files from diff.
    local -a test_files=()
    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        _oa_is_test_file "$f" || continue
        [[ -f "$repo_root/$f" ]] && test_files+=("$f")
    done < <(_oa_diff_files "$repo_root")

    if [[ ${#test_files[@]} -eq 0 ]]; then
        printf 'ABLATION_NEGCTL SKIP no_test_files_changed\n'
        return 0
    fi

    # Create baseline worktree and overlay test files from HEAD.
    local wt_dir
    wt_dir="$(mktemp -d "${TMPDIR:-/tmp}/zb-og-negctl.XXXXXX")"
    # shellcheck disable=SC2064
    trap "git -C '$repo_root' worktree remove --force '$wt_dir' >/dev/null 2>&1 || true; rm -rf '$wt_dir' 2>/dev/null || true" RETURN
    if ! git -C "$repo_root" worktree add --detach "$wt_dir" "$base_sha" >/dev/null 2>&1; then
        printf 'ABLATION_NEGCTL SKIP worktree_failed\n'
        return 0
    fi
    for f in "${test_files[@]}"; do
        mkdir -p "$wt_dir/$(dirname "$f")"
        git -C "$repo_root" show "HEAD:$f" > "$wt_dir/$f" 2>/dev/null || true
        chmod +x "$wt_dir/$f" 2>/dev/null || true
    done

    local found_pass=0 found_tautology=0 found_head_fail=0
    local rc_base rc_head
    for f in "${test_files[@]}"; do
        [[ ! -f "$wt_dir/$f" ]] && continue
        rc_base=0; rc_head=0
        _oa_run_test "$wt_dir/$f" "$wt_dir" || rc_base=$?
        _oa_run_test "$repo_root/$f" "$repo_root" || rc_head=$?
        if [[ $rc_base -ne 0 && $rc_head -eq 0 ]]; then
            found_pass=1; break
        elif [[ $rc_base -eq 0 ]]; then
            found_tautology=1
        elif [[ $rc_head -ne 0 ]]; then
            found_head_fail=1
        fi
    done

    if [[ $found_pass -eq 1 ]]; then
        printf 'ABLATION_NEGCTL PASS\n'
    elif [[ $found_tautology -eq 1 ]]; then
        printf 'ABLATION_NEGCTL FAIL tautology\n'
    elif [[ $found_head_fail -eq 1 ]]; then
        printf 'ABLATION_NEGCTL FAIL not_passing_at_head\n'
    else
        printf 'ABLATION_NEGCTL FAIL tautology\n'
    fi
}

# ─── _og_ablation_reachability <repo_root> ───────────────────────────────────
# Changed non-test source files are the reachability candidates. For each,
# a baseline worktree with all other HEAD changes overlaid (candidate reverted)
# is tested; ≥1 flip (pass→fail) → ABLATION_REACH PASS. All inert → FAIL inert.
_og_ablation_reachability() {
    local repo_root="$1"

    local base_sha
    base_sha="$(zbuild_resolve_merge_base "$repo_root")"
    if [[ -z "$base_sha" ]]; then
        printf 'ABLATION_REACH SKIP no_baseline\n'
        return 0
    fi
    local head_sha
    head_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
    if [[ -n "$head_sha" && "$base_sha" == "$head_sha" ]]; then
        printf 'ABLATION_REACH SKIP no_impl_delta\n'
        return 0
    fi

    # Split diff into impl files (non-test) and test files.
    local -a all_changed=() impl_files=() test_files=()
    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        all_changed+=("$f")
        if _oa_is_test_file "$f"; then
            [[ -f "$repo_root/$f" ]] && test_files+=("$f")
        else
            impl_files+=("$f")
        fi
    done < <(_oa_diff_files "$repo_root")

    if [[ ${#impl_files[@]} -eq 0 ]]; then
        printf 'ABLATION_REACH SKIP no_impl_files_changed\n'
        return 0
    fi
    if [[ ${#test_files[@]} -eq 0 ]]; then
        printf 'ABLATION_REACH SKIP no_test_files_for_reachability\n'
        return 0
    fi

    local any_pass=0 target wt_dir cf tf rc_reverted rc_head found_flip
    for target in "${impl_files[@]}"; do
        wt_dir="$(mktemp -d "${TMPDIR:-/tmp}/zb-og-reach.XXXXXX")"
        if ! git -C "$repo_root" worktree add --detach "$wt_dir" "$base_sha" >/dev/null 2>&1; then
            rm -rf "$wt_dir" 2>/dev/null || true
            continue
        fi

        # Overlay ALL changed files from HEAD, except the reachability target.
        for cf in "${all_changed[@]}"; do
            [[ "$cf" == "$target" ]] && continue
            mkdir -p "$wt_dir/$(dirname "$cf")"
            if git -C "$repo_root" show "HEAD:$cf" > "$wt_dir/$cf.zbtmp" 2>/dev/null; then
                mv "$wt_dir/$cf.zbtmp" "$wt_dir/$cf"
                chmod +x "$wt_dir/$cf" 2>/dev/null || true
            else
                rm -f "$wt_dir/$cf.zbtmp" "$wt_dir/$cf" 2>/dev/null || true
            fi
        done
        # Ensure test files are at HEAD version.
        for tf in "${test_files[@]}"; do
            mkdir -p "$wt_dir/$(dirname "$tf")"
            git -C "$repo_root" show "HEAD:$tf" > "$wt_dir/$tf" 2>/dev/null || true
            chmod +x "$wt_dir/$tf" 2>/dev/null || true
        done

        # Check for flip: passes at HEAD, fails when target is reverted.
        found_flip=0
        for tf in "${test_files[@]}"; do
            [[ ! -f "$wt_dir/$tf" ]] && continue
            rc_reverted=0; rc_head=0
            _oa_run_test "$wt_dir/$tf" "$wt_dir" || rc_reverted=$?
            _oa_run_test "$repo_root/$tf" "$repo_root" || rc_head=$?
            if [[ $rc_reverted -ne 0 && $rc_head -eq 0 ]]; then
                found_flip=1; break
            fi
        done

        git -C "$repo_root" worktree remove --force "$wt_dir" >/dev/null 2>&1 || true
        rm -rf "$wt_dir" 2>/dev/null || true

        if [[ $found_flip -eq 1 ]]; then
            any_pass=1; break
        fi
    done

    if [[ $any_pass -eq 1 ]]; then
        printf 'ABLATION_REACH PASS\n'
    else
        printf 'ABLATION_REACH FAIL inert\n'
    fi
}

# ─── _og_ablation_shape_floor <repo_root> ────────────────────────────────────
# If any diff file matches config/shape-change-paths.txt → shape change detected.
# Then verifies event-sequence.golden files AND _TPL_STAGES[N]-indexed test files
# are also in the diff. Missing any → ABLATION_SHAPE FAIL missing_floor_files.
# Reuses _impact_list_event_goldens and _impact_list_order_assertions (impact-prefilter.sh).
_og_ablation_shape_floor() {
    local repo_root="$1"
    local paths_file="$repo_root/config/shape-change-paths.txt"

    local diff_files
    diff_files="$(_oa_diff_files "$repo_root")"

    # Detect shape change.
    local shape_change=0
    if [[ -f "$paths_file" && -n "$diff_files" ]]; then
        local pattern pf
        while IFS= read -r pattern; do
            pattern="${pattern#"${pattern%%[![:space:]]*}"}"
            [[ -z "$pattern" || "$pattern" == "#"* ]] && continue
            while IFS= read -r pf; do
                [[ -z "$pf" ]] && continue
                # shellcheck disable=SC2053
                if [[ "$pf" == $pattern ]]; then
                    shape_change=1
                    break 2
                fi
            done <<< "$diff_files"
        done < "$paths_file"
    fi

    if [[ $shape_change -eq 0 ]]; then
        printf 'ABLATION_SHAPE SKIP no_shape_change\n'
        return 0
    fi

    # Verify golden files are in diff.
    local tests_root="$repo_root/tests"
    local missing=0 golden order_file
    while IFS= read -r golden; do
        [[ -z "$golden" ]] && continue
        if ! printf '%s\n' "$diff_files" | grep -qxF "$golden"; then
            missing=1; break
        fi
    done < <(_impact_list_event_goldens "$tests_root")

    # Verify _TPL_STAGES[N]-indexed test files are in diff.
    if [[ $missing -eq 0 ]]; then
        while IFS= read -r order_file; do
            [[ -z "$order_file" ]] && continue
            if ! printf '%s\n' "$diff_files" | grep -qxF "$order_file"; then
                missing=1; break
            fi
        done < <(_impact_list_order_assertions "$tests_root")
    fi

    if [[ $missing -eq 1 ]]; then
        printf 'ABLATION_SHAPE FAIL missing_floor_files\n'
    else
        printf 'ABLATION_SHAPE PASS\n'
    fi
}
