#!/usr/bin/env bash
# scripts/lib/shape-floor.sh — un-gameable shape-floor check (ADR-040, #1134)
#
# Extracted (B2 #1134) from the retired ablation shape-floor logic (#971) so the
# shape floor can live as its OWN T0 tool stage (ADR-037 keeps the un-gameable
# mechanical checks). The monolithic gate it came from was removed in #1139.
#
# The check: if any merge-base→HEAD diff file matches a glob in
# config/shape-change-paths.txt, a "shape change" is in flight. A shape change
# touches the pipeline's observable surface, so the event-sequence golden
# snapshots AND the _TPL_STAGES[N]-indexed order-assertion tests MUST also be in
# the diff — otherwise the change silently drifts the pipeline shape past its
# pinned tests. Missing any → FAIL missing_floor_files.
#
# Public function:
#   _sf_shape_floor <repo_root> → echoes SHAPE_FLOOR PASS|FAIL|SKIP
#
# Merge-base resolution: zbuild_resolve_merge_base (merge-base.sh) — proper
# merge-base against the default branch (origin/main → main → HEAD~1), NOT
# HEAD~1, so the floor sees the full branch change set.
#
# Source-only; no `set -e` at top level (would mutate caller options).

[[ -n "${_ZBUILD_SHAPE_FLOOR_LOADED:-}" ]] && return 0
_ZBUILD_SHAPE_FLOOR_LOADED=1

_SF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./merge-base.sh
source "$_SF_LIB_DIR/merge-base.sh"
# shellcheck source=./impact-prefilter.sh
source "$_SF_LIB_DIR/impact-prefilter.sh"

# ─── _sf_diff_files <repo_root> ──────────────────────────────────────────────
# Prints changed file paths (one per line) between merge-base and HEAD.
# ZBUILD_DIFF_CMD overrides for testability.
_sf_diff_files() {
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

# ─── _sf_schema_diff <repo_root> ─────────────────────────────────────────────
# Prints the unified diff for config/event-schema.json between merge-base and HEAD.
# ZBUILD_SCHEMA_DIFF_CMD overrides for testability.
_sf_schema_diff() {
    local repo_root="$1"
    local schema_diff_cmd="${ZBUILD_SCHEMA_DIFF_CMD:-}"
    if [[ -n "$schema_diff_cmd" ]]; then
        bash -c "$schema_diff_cmd" 2>/dev/null || true
        return
    fi
    local base_sha
    base_sha="$(zbuild_resolve_merge_base "$repo_root")"
    [[ -z "$base_sha" ]] && return
    git -C "$repo_root" diff "$base_sha" HEAD -- config/event-schema.json 2>/dev/null || true
}

# ─── _sf_is_schema_append_only <repo_root> ────────────────────────────────────
# Returns rc=0 when the config/event-schema.json diff is a pure append of
# known_types entries: no removed lines AND every added line is a bare JSON
# array element ("some.event" / "some.event",). Appending a name to known_types
# cannot change any recorded event SEQUENCE, so it must not demand golden
# updates (#1711). An ADDITIVE but STRUCTURAL change — a new object key, a new
# required field — CAN change pipeline shape and stays gated: a key carries a
# colon, so it fails the element-shape test.
# ZBUILD_SCHEMA_DIFF_CMD overrides the diff call for testability.
_sf_is_schema_append_only() {
    local repo_root="$1"
    local diff_out added
    diff_out="$(_sf_schema_diff "$repo_root")"
    [[ -z "$diff_out" ]] && return 1
    # Fail if any content line was removed (lines starting with '-' but not '---' header)
    if grep -qE '^-[^-]' <<< "$diff_out"; then
        return 1
    fi
    # Must have at least one added content line (not just headers)
    added="$(printf '%s\n' "$diff_out" | grep -E '^\+[^+]' || true)"
    [[ -z "$added" ]] && return 1
    # Every added line must be a bare array element; any other added shape
    # (an object key, a nested structure) is not a known_types append.
    if grep -qvE '^\+[[:space:]]*"[^"]+",?[[:space:]]*$' <<< "$added"; then
        return 1
    fi
    return 0
}

# ─── _sf_template_diff <repo_root> <path> ─────────────────────────────────────
# Echoes the merge-base→HEAD diff for ONE template file.
# ZBUILD_TEMPLATE_DIFF_CMD overrides the diff call for testability (it receives
# the path as $1), mirroring ZBUILD_SCHEMA_DIFF_CMD.
_sf_template_diff() {
    local repo_root="$1" path="$2"
    local cmd="${ZBUILD_TEMPLATE_DIFF_CMD:-}"
    if [[ -n "$cmd" ]]; then
        bash -c "$cmd" _ "$path" 2>/dev/null || true
        return
    fi
    local base_sha
    base_sha="$(zbuild_resolve_merge_base "$repo_root")"
    [[ -z "$base_sha" ]] && return
    git -C "$repo_root" diff "$base_sha" HEAD -- "$path" 2>/dev/null || true
}

# ─── _sf_is_template_comment_only <repo_root> <path> ──────────────────────────
# Returns rc=0 when a config/templates/*.yaml diff adds and removes NOTHING but
# comments and blank lines — documentation churn that cannot move a stage, so it
# cannot drift the pipeline shape past the pinned goldens (#1924).
#
# Same shape as the #1711 schema-append-only escape hatch above, and needed for
# the same reason: `config/templates/*.yaml` matches on FILENAME, so adding a
# paragraph of env-var docs to a template demanded edits to seven golden and
# order-assertion files that had nothing to do with the change. The floor stayed
# red, escalated route_target=design, and no amount of building could clear it.
#
# YAML has no heredocs, so a line whose first non-blank character is `#` is a
# comment — with one exception: inside a block scalar (`|` / `>`) such a line is
# literal text. In these templates block scalars carry only prose descriptions,
# which are as inert as comments, so the exception is harmless here. Anything
# else — a key, a list item, a value — has a non-`#` first character and fails
# the test, keeping every real shape change gated.
_sf_is_template_comment_only() {
    local repo_root="$1" path="$2"
    local diff_out changed
    diff_out="$(_sf_template_diff "$repo_root" "$path")"
    [[ -z "$diff_out" ]] && return 1
    # Content lines only: drop the ---/+++ file headers, then keep +/- lines whose
    # payload is neither blank nor a comment. Any survivor = a real change.
    changed="$( { grep -E '^[+-]([^+-]|$)' <<< "$diff_out" || true; } \
        | { grep -vE '^[+-][[:space:]]*(#.*)?$' || true; } )"
    [[ -z "$changed" ]]
}

# ─── _sf_collect_missing_floor_files <repo_root> <diff_files_text> ───────────
# Prints repo-relative paths of event-sequence.golden and _TPL_STAGES[N]-indexed
# test files that are absent from the supplied diff_files_text (one path per line).
_sf_collect_missing_floor_files() {
    local repo_root="$1"
    local diff_files="$2"
    local tests_root="$repo_root/tests"
    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if ! grep -qxF "$f" <<< "$diff_files"; then
            printf '%s\n' "$f"
        fi
    done < <(_impact_list_event_goldens "$tests_root")
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if ! grep -qxF "$f" <<< "$diff_files"; then
            printf '%s\n' "$f"
        fi
    done < <(_impact_list_order_assertions "$tests_root")
}

# ─── _sf_shape_floor <repo_root> ─────────────────────────────────────────────
# If any diff file matches config/shape-change-paths.txt → shape change detected.
# Exception: when config/event-schema.json is the SOLE matched file and its diff
# is append-only (no removals), the change is treated as no shape change (SKIP).
# Exception (#1924): when every matched file is a config/templates/*.yaml whose
# diff is comments and blank lines only, likewise SKIP — see
# _sf_is_template_comment_only.
# Then verifies event-sequence.golden files AND _TPL_STAGES[N]-indexed test files
# are also in the diff. Missing any → SHAPE_FLOOR FAIL missing_floor_files.
# Reuses _impact_list_event_goldens and _impact_list_order_assertions (impact-prefilter.sh).
_sf_shape_floor() {
    local repo_root="$1"
    local paths_file="$repo_root/config/shape-change-paths.txt"

    local diff_files
    diff_files="$(_sf_diff_files "$repo_root")"

    # Detect shape change — track all matched files to support append-only exemption.
    local shape_change=0
    local _matched_files=""
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
                    _matched_files+="$pf"$'\n'
                fi
            done <<< "$diff_files"
        done < "$paths_file"
    fi

    if [[ $shape_change -eq 0 ]]; then
        printf 'SHAPE_FLOOR SKIP no_shape_change\n'
        return 0
    fi

    # Append-only exemption: config/event-schema.json sole match + additive diff → SKIP.
    # `sole match` means one distinct FILE. _matched_files accumulates one entry per
    # (pattern, file) hit, so a file matching two globs would otherwise count twice and
    # silently disable the exemption; dedupe before counting.
    local _mf _matched_count=0 _schema_matched=0
    while IFS= read -r _mf; do
        [[ -z "$_mf" ]] && continue
        _matched_count=$(( _matched_count + 1 ))
        [[ "$_mf" == "config/event-schema.json" ]] && _schema_matched=1
    done <<< "$(printf '%s' "$_matched_files" | sort -u)"
    if [[ $_schema_matched -eq 1 && $_matched_count -eq 1 ]] \
        && _sf_is_schema_append_only "$repo_root"; then
        printf 'SHAPE_FLOOR SKIP schema_append_only\n'
        return 0
    fi

    # Comment-only exemption (#1924): every matched file is a template whose diff
    # touches nothing but comments and blank lines. Unlike the schema exemption
    # this is not sole-match-gated — the property is per-file, so it holds however
    # many templates were documented in one change. A single non-template match,
    # or one template with a real edit, drops through to the floor check below.
    local _tpl_only=1
    while IFS= read -r _mf; do
        [[ -z "$_mf" ]] && continue
        case "$_mf" in
            config/templates/*.yaml)
                _sf_is_template_comment_only "$repo_root" "$_mf" || { _tpl_only=0; break; } ;;
            *)  _tpl_only=0; break ;;
        esac
    done <<< "$(printf '%s' "$_matched_files" | sort -u)"
    if [[ $_matched_count -gt 0 && $_tpl_only -eq 1 ]]; then
        printf 'SHAPE_FLOOR SKIP template_comment_only\n'
        return 0
    fi

    # Verify golden files are in diff.
    local tests_root="$repo_root/tests"
    local missing=0 golden order_file
    while IFS= read -r golden; do
        [[ -z "$golden" ]] && continue
        if ! grep -qxF "$golden" <<< "$diff_files"; then
            missing=1; break
        fi
    done < <(_impact_list_event_goldens "$tests_root")

    # Verify _TPL_STAGES[N]-indexed test files are in diff.
    if [[ $missing -eq 0 ]]; then
        while IFS= read -r order_file; do
            [[ -z "$order_file" ]] && continue
            if ! grep -qxF "$order_file" <<< "$diff_files"; then
                missing=1; break
            fi
        done < <(_impact_list_order_assertions "$tests_root")
    fi

    if [[ $missing -eq 1 ]]; then
        printf 'SHAPE_FLOOR FAIL missing_floor_files\n'
    else
        printf 'SHAPE_FLOOR PASS\n'
    fi
}
