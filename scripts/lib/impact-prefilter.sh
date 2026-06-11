#!/usr/bin/env bash
# scripts/lib/impact-prefilter.sh — deterministic pre-LLM scope prefilter (#781)
#
# Why this exists: impact's LLM-driven symbol tracer catches reference-style
# scope gaps but misses (a) hardcoded numeric literals encoding pipeline
# shape (e.g. "7 stages", "14 plugin.run.start events") and (b) golden
# snapshot files under tests/golden/**/*.golden that pin event sequences.
# This library runs CLAUDE.md's "Test scope discovery" rule deterministically
# before the impact LLM call so the model can't accidentally omit them.
#
# Public functions:
#   _impact_detect_shape_change <plan_json_text> → rc 0 if shape change, 1 else
#   _impact_parse_shape_counts <standard_yaml_path> → dedup'd integers, one per line
#   _impact_grep_numeric_candidates <N> <tests_root> <step_files_csv> → matching files
#   _impact_list_event_goldens <tests_root> → all event-sequence.golden paths
#   _impact_scope_prefilter <plan_json_text> <repo_root> → JSON array of forced gaps
#
# Hardened for `set -euo pipefail` callers: all greps wrap with `|| true`.

# Idempotent source guard.
if [[ "${_ZBUILD_IMPACT_PREFILTER_LOADED:-}" == "1" ]]; then
    return 0
fi
_ZBUILD_IMPACT_PREFILTER_LOADED=1

# ─── _impact_detect_shape_change <plan_json> [repo_root] ────────────────────
# Returns rc=0 if any entry in plan.steps[].files[] matches any glob in
# config/shape-change-paths.txt. Otherwise rc=1.
_impact_detect_shape_change() {
    local plan_json="$1"
    local repo_root="${2:-$(pwd)}"
    local paths_file="$repo_root/config/shape-change-paths.txt"

    [[ -f "$paths_file" ]] || return 1
    [[ -z "$plan_json" ]] && return 1

    # Extract plan.steps[].files[] entries (one path per line).
    local plan_files
    plan_files="$(printf '%s' "$plan_json" | jq -r '
        .steps[]? | .files[]? | select(type == "string")
    ' 2>/dev/null || true)"

    [[ -z "$plan_files" ]] && return 1

    # Iterate glob patterns; strip comments and blanks.
    local pattern
    while IFS= read -r pattern; do
        # Strip leading whitespace + comment lines + blank lines.
        pattern="${pattern#"${pattern%%[![:space:]]*}"}"
        [[ -z "$pattern" || "$pattern" == "#"* ]] && continue

        # Check each plan file against pattern (bash glob match).
        local pf
        while IFS= read -r pf; do
            [[ -z "$pf" ]] && continue
            # shellcheck disable=SC2053
            if [[ "$pf" == $pattern ]]; then
                return 0
            fi
        done <<< "$plan_files"
    done < "$paths_file"

    return 1
}

# ─── _impact_parse_shape_counts <standard_yaml_path> ────────────────────────
# Counts entries under top-level `flow:` AND legacy `stages:` keys. Prints
# unique non-zero counts, one per line. Handles ADR-027 dual-shape templates.
_impact_parse_shape_counts() {
    local yaml_path="$1"
    [[ -f "$yaml_path" ]] || return 0

    local flow_count stages_count
    # Count `flow:` entries (top-level only — block syntax: `flow:\n  - foo\n  - bar`).
    # Skip blank lines and comment lines inside the block — they don't end it
    # (review: `#` would match /^[^[:space:]-]/ and prematurely close the block).
    flow_count="$(awk '
        BEGIN { in_block = 0; count = 0 }
        /^flow:[[:space:]]*$/ { in_block = 1; next }
        in_block && /^[[:space:]]*$/ { next }
        in_block && /^[[:space:]]*#/ { next }
        in_block && /^[[:space:]]*-[[:space:]]+/ { count++; next }
        in_block && /^[^[:space:]-]/ { in_block = 0 }
        END { print count }
    ' "$yaml_path" 2>/dev/null || echo 0)"

    stages_count="$(awk '
        BEGIN { in_block = 0; count = 0 }
        /^stages:[[:space:]]*$/ { in_block = 1; next }
        in_block && /^[[:space:]]*$/ { next }
        in_block && /^[[:space:]]*#/ { next }
        in_block && /^[[:space:]]*-[[:space:]]+/ { count++; next }
        in_block && /^[^[:space:]-]/ { in_block = 0 }
        END { print count }
    ' "$yaml_path" 2>/dev/null || echo 0)"

    local seen=""
    for c in "$flow_count" "$stages_count"; do
        [[ "$c" -gt 0 ]] || continue
        case " $seen " in
            *" $c "*) ;;
            *) printf '%s\n' "$c"; seen="$seen $c" ;;
        esac
    done
}

# ─── _impact_grep_numeric_candidates <N> <tests_root> <step_files_csv> ──────
# Greps tests/ for occurrences of the integer N that ALSO appear near a
# pipeline-shape keyword (stage|pipeline|flow|dispatch|cycle). Excludes any
# file already listed in step_files_csv. Returns one path per line.
#
# Contextual regex avoids false-positives on unrelated literals
# (e.g. "sleep 7", "port 7777", "retries=7").
_impact_grep_numeric_candidates() {
    local n="$1"
    local tests_root="$2"
    local step_files_csv="${3:-}"

    [[ -z "$n" || ! -d "$tests_root" ]] && return 0
    [[ "$n" =~ ^[0-9]+$ ]] || return 0

    # Two passes: (stage|pipeline|...) BEFORE N, then AFTER. Egrep handles both.
    local pattern="(stage|pipeline|flow|dispatch|cycle).{0,40}\\b${n}\\b|\\b${n}\\b.{0,40}(stage|pipeline|flow|dispatch|cycle)"

    local matches
    matches="$(grep -rlE "$pattern" "$tests_root" 2>/dev/null || true)"
    [[ -z "$matches" ]] && return 0

    # Filter out files already in step_files_csv.
    local m
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        # Convert absolute match path to repo-relative if step_files uses
        # relative paths. Heuristic: strip leading $tests_root prefix +
        # everything before "tests/".
        local rel="${m#"$tests_root/"}"
        rel="${rel/#/tests/}"
        # Match-as-substring on CSV (commas + boundary).
        case ",$step_files_csv," in
            *",$rel,"*) continue ;;
        esac
        printf '%s\n' "$rel"
    done <<< "$matches"
}

# ─── _impact_list_event_goldens <tests_root> ────────────────────────────────
# Returns all tests/golden/**/event-sequence.golden paths (repo-relative).
# When shape-change is detected, these are ALWAYS forced candidates per
# CLAUDE.md (any shape change touches event sequences).
_impact_list_event_goldens() {
    local tests_root="$1"
    [[ -d "$tests_root/golden" ]] || return 0

    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local rel="${f#"$tests_root/"}"
        rel="tests/$rel"
        printf '%s\n' "$rel"
    done < <(find "$tests_root/golden" -name 'event-sequence.golden' -type f 2>/dev/null || true)
}

# ─── _impact_scope_prefilter <plan_json> <repo_root> ────────────────────────
# Orchestrator. Returns a JSON array (potentially empty). Each element:
#   {
#     "step_id": "prefilter",
#     "files_to_add": ["..."],
#     "reason": "deterministic prefilter (CLAUDE.md test-scope rule): ...",
#     "source": "shape-change-numeric" | "shape-change-golden"
#   }
#
# Empty array when no shape change detected (no-op for non-shape plans).
_impact_scope_prefilter() {
    local plan_json="$1"
    local repo_root="${2:-$(pwd)}"

    if ! _impact_detect_shape_change "$plan_json" "$repo_root" >/dev/null 2>&1; then
        printf '[]\n'
        return 0
    fi

    # Collect existing step.files[] as CSV to exclude from candidate matches.
    local step_files_csv
    step_files_csv="$(printf '%s' "$plan_json" | jq -r '
        [.steps[]? | .files[]?] | join(",")
    ' 2>/dev/null || true)"

    local tests_root="$repo_root/tests"
    local results="[]"

    # Numeric candidates per shape count.
    local n
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        local candidates
        candidates="$(_impact_grep_numeric_candidates "$n" "$tests_root" "$step_files_csv")"
        [[ -z "$candidates" ]] && continue
        # Convert candidates (newline-separated) to JSON array.
        local files_json
        files_json="$(printf '%s\n' "$candidates" | jq -R . | jq -s .)"
        results="$(printf '%s' "$results" | jq --argjson files "$files_json" --arg n "$n" '
            . + [{
                step_id: "prefilter",
                files_to_add: $files,
                reason: ("deterministic prefilter (CLAUDE.md test-scope rule): " +
                         "shape-change detected; tests pinning numeric \"" + $n + "\" near pipeline keywords"),
                source: "shape-change-numeric"
            }]
        ' 2>/dev/null || printf '%s' "$results")"
    done < <(_impact_parse_shape_counts "$repo_root/config/templates/standard.yaml")

    # Golden snapshots — always candidates when shape change detected.
    local goldens
    goldens="$(_impact_list_event_goldens "$tests_root")"
    if [[ -n "$goldens" ]]; then
        # Filter out goldens already in step_files_csv.
        local g rel filtered=""
        while IFS= read -r g; do
            [[ -z "$g" ]] && continue
            case ",$step_files_csv," in
                *",$g,"*) ;;
                *) filtered+="$g"$'\n' ;;
            esac
        done <<< "$goldens"
        filtered="${filtered%$'\n'}"
        if [[ -n "$filtered" ]]; then
            local goldens_json
            goldens_json="$(printf '%s\n' "$filtered" | jq -R . | jq -s .)"
            results="$(printf '%s' "$results" | jq --argjson files "$goldens_json" '
                . + [{
                    step_id: "prefilter",
                    files_to_add: $files,
                    reason: ("deterministic prefilter (CLAUDE.md test-scope rule): " +
                             "shape-change detected; event-sequence golden snapshots pin pipeline event order"),
                    source: "shape-change-golden"
                }]
            ' 2>/dev/null || printf '%s' "$results")"
        fi
    fi

    printf '%s\n' "$results"
}
