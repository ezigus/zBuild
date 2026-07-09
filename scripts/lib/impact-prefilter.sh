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
#   _impact_parse_shape_counts <template_yaml_path> → dedup'd integers, one per line
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

# ─── _impact_parse_shape_counts <template_yaml_path> ────────────────────────
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

# ─── _impact_list_order_assertions <tests_root> ─────────────────────────────
# PREV-1 (#881): tests that pin a stage by its POSITION in the canonical order
# via the indexed form `_TPL_STAGES[N]`. A reorder invalidates these even though
# the stage SET is unchanged — invisible to the numeric-count and golden
# detectors. Anchored strictly to the indexed form so bare `impact`/`design`
# names or un-indexed membership checks never over-match. Repo-relative output.
_impact_list_order_assertions() {
    local tests_root="$1"
    [[ -d "$tests_root" ]] || return 0
    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local rel="${f#"$tests_root/"}"
        rel="tests/$rel"
        printf '%s\n' "$rel"
    done < <(grep -rlE '(^|[^A-Za-z0-9_])_TPL_STAGES\[[0-9]+\]' "$tests_root" 2>/dev/null || true)
}

# ─── _impact_scope_prefilter <plan_json> <repo_root> ────────────────────────
# Orchestrator. Returns a JSON array (potentially empty). Each element:
#   {
#     "step_id": "prefilter",
#     "files_to_add": ["..."],
#     "reason": "deterministic prefilter (CLAUDE.md test-scope rule): ...",
#     "source": "shape-change-numeric" | "shape-change-golden" | "shape-change-order"
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
    done < <(_impact_parse_shape_counts "$repo_root/config/templates/simple.yaml")

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

    # Stage-order assertions — PREV-1 (#881): tests pinning a stage by its index
    # (`_TPL_STAGES[N]`). Always candidates when shape change detected, mirroring
    # the golden floor. Filtered against step_files_csv like the others.
    local order_files
    order_files="$(_impact_list_order_assertions "$tests_root")"
    if [[ -n "$order_files" ]]; then
        local of filtered_order=""
        while IFS= read -r of; do
            [[ -z "$of" ]] && continue
            case ",$step_files_csv," in
                *",$of,"*) ;;
                *) filtered_order+="$of"$'\n' ;;
            esac
        done <<< "$order_files"
        filtered_order="${filtered_order%$'\n'}"
        if [[ -n "$filtered_order" ]]; then
            local order_json
            order_json="$(printf '%s\n' "$filtered_order" | jq -R . | jq -s .)"
            results="$(printf '%s' "$results" | jq --argjson files "$order_json" '
                . + [{
                    step_id: "prefilter",
                    files_to_add: $files,
                    reason: ("deterministic prefilter (CLAUDE.md test-scope rule): " +
                             "shape-change detected; tests pin stage order via _TPL_STAGES[N] index"),
                    source: "shape-change-order"
                }]
            ' 2>/dev/null || printf '%s' "$results")"
        fi
    fi

    printf '%s\n' "$results"
}

# ─── _impact_drop_nonexistent_missing <repo_root> ────────────────────────────
# Post-LLM hallucination filter (#911). Strips missing[].files_to_add paths
# that do not exist on disk (relative to repo_root). Drops missing[] entries
# whose files_to_add becomes empty after stripping. If missing[] empties out
# and the original verdict was 'incomplete', flips verdict to 'complete'.
#
# Reads and modifies $impact_json in the caller's scope.
# Emits impact.hallucination.filtered with dropped_count and verdict_flipped.
#
# Must run AFTER the prefilter floor merge so forced-existing floor entries
# are never targeted by this drop.
_impact_drop_nonexistent_missing() {
    local _repo_root="${1:-${ZBUILD_REPO_ROOT:-$(pwd)}}"

    # Collect every files_to_add path from missing[] (whitespace-stripped).
    local _raw_paths
    _raw_paths="$(printf '%s' "$impact_json" \
        | jq -r '.missing[]?.files_to_add[]?' 2>/dev/null \
        | sed 's/[[:space:]]//g; /^$/d')" || true
    [[ -z "$_raw_paths" ]] && return 0

    # Identify ghost paths (do not exist on disk).
    local _ghost_paths=()
    local _p
    while IFS= read -r _p; do
        [[ -z "$_p" ]] && continue
        if [[ ! -e "$_repo_root/$_p" ]]; then
            _ghost_paths+=("$_p")
        fi
    done <<< "$_raw_paths"

    [[ ${#_ghost_paths[@]} -eq 0 ]] && return 0

    # Build jq-consumable JSON array of ghost paths.
    local _ghost_json
    _ghost_json="$(printf '%s\n' "${_ghost_paths[@]}" \
        | jq -Rsc 'split("\n") | map(select(length > 0))')"

    local _original_verdict
    _original_verdict="$(printf '%s' "$impact_json" | jq -r '.verdict' 2>/dev/null || echo "incomplete")"

    # Filter: strip ghost paths; drop entries with empty files_to_add.
    # Normalize each path by removing ALL whitespace (gsub "\\s") so the
    # comparison key matches _ghost_paths, which was built with the same
    # `sed 's/[[:space:]]//g'` normalization. A space-only trim here would let a
    # path with a tab or trailing \r be detected-as-ghost yet not removed
    # (Copilot review): detection (bash) and removal (jq) must normalize alike.
    local _filtered
    _filtered="$(printf '%s' "$impact_json" | jq -c --argjson ghosts "$_ghost_json" '
        .missing |= map(
            .files_to_add |= map(
                gsub("\\s";"") | select(length > 0)
            ) |
            .files_to_add |= map(
                . as $p | select(($ghosts | index($p)) == null)
            ) |
            select(.files_to_add | length > 0)
        )
    ' 2>/dev/null)" || true

    [[ -z "$_filtered" ]] && return 0

    local _dropped="${#_ghost_paths[@]}"
    local _verdict_flipped=false

    # Flip verdict incomplete→complete only if missing[] became empty.
    local _new_len
    _new_len="$(printf '%s' "$_filtered" | jq '.missing | length' 2>/dev/null || echo 1)"
    if [[ "$_new_len" -eq 0 && "$_original_verdict" == "incomplete" ]]; then
        _filtered="$(printf '%s' "$_filtered" | jq -c '.verdict = "complete"' 2>/dev/null)" || true
        [[ -n "$_filtered" ]] && _verdict_flipped=true
    fi

    [[ -n "$_filtered" ]] && impact_json="$_filtered"

    emit_event "impact.hallucination.filtered" \
        "plugin=impact" \
        "dropped_count=${_dropped}" \
        "verdict_flipped=${_verdict_flipped}" 2>/dev/null || true
}

# ─── _impact_envelope_schema_ok <json> ───────────────────────────────────────
# The impact envelope schema gate, factored out so the happy-path validation in
# plugin.sh AND the recovery helper below share ONE definition and never drift.
# rc=0 iff $1 is a valid impact envelope.
_impact_envelope_schema_ok() {
    printf '%s' "${1:-}" | jq -e '
        type == "object"
        and (.schema_version == 1)
        and (.verdict | type == "string" and (. == "complete" or . == "incomplete" or . == "error"))
        and (.missing | type == "array")
        and (.impact_feedback_md | type == "string")
    ' >/dev/null 2>&1
}

# ─── _impact_recover_envelope_json <raw_response> (#908) ──────────────────────
# Schema-aware recovery from a LAST-wins misselection. The shared parser
# extract_json_and_surrounding_prose (helpers.sh) returns the LAST top-level
# balanced object — deliberate (#478/ADR-018) to defend brace-bearing PREAMBLE.
# Impact's OUTPUT CONTRACT emits the envelope FIRST, so a brace-bearing
# POSTAMBLE ("...: {note:x}", or an example after a stray ```json fence) makes
# LAST-wins hand back the wrong object and the schema gate fails -> empty
# iteration (#908). This re-scans the ORIGINAL raw response, enumerates EVERY
# top-level balanced object in document order (same string/escape/array-depth
# grammar as the shared parser), and prints the FIRST that passes the impact
# schema gate. rc=0 + object on stdout when recovered; rc=1 + empty otherwise
# (caller falls through to the genuine-malformed error path). Impact-local on
# purpose: the shared LAST-wins contract (X6/E8/E16) is untouched.
_impact_recover_envelope_json() {
    local _raw="${1:-}"
    [[ -z "$_raw" ]] && return 1

    # Enumerate every top-level balanced object, in order, RS-delimited (\x1e)
    # so embedded newlines/braces inside an object survive the boundary.
    local _candidates
    _candidates="$(printf '%s' "$_raw" | awk '
        BEGIN { buf = "" }
        { buf = buf $0 "\n" }
        END {
            # Pre-pass mirrors extract_json_and_surrounding_prose (helpers.sh):
            # BOM, opening/closing ```json|``` fences, trailing newline. We
            # ADDITIONALLY strip CR (gsub /\r/) — a hardening beyond the shared
            # parser pre-pass, harmless for single-byte JSON.
            sub(/^\xef\xbb\xbf/, "", buf)
            gsub(/\r/, "", buf)
            sub(/^[[:space:]]*```json[[:space:]]*\n?/, "", buf)
            sub(/^[[:space:]]*```[[:space:]]*\n?/, "", buf)
            sub(/\n?[[:space:]]*```[[:space:]]*$/, "", buf)
            sub(/\n$/, "", buf)

            n = length(buf); depth = 0; arr_depth = 0
            in_string = 0; escape = 0; start = -1
            for (i = 1; i <= n; i++) {
                c = substr(buf, i, 1)
                if (escape) { escape = 0; continue }
                if (in_string) {
                    if (c == "\\") { escape = 1; continue }
                    if (c == "\"") { in_string = 0 }
                    continue
                }
                if (c == "\"") { in_string = 1; continue }
                if (c == "[") { if (depth == 0) arr_depth++; continue }
                if (c == "]") { if (depth == 0 && arr_depth > 0) arr_depth--; continue }
                if (c == "{") {
                    if (depth == 0 && arr_depth > 0) continue   # object inside top-level array
                    if (depth == 0) start = i
                    depth++; continue
                }
                if (c == "}") {
                    if (depth > 0) {
                        depth--
                        if (depth == 0 && start > 0) {
                            # RS-delimit with \x1e. Keep \x1e the TRAILING token
                            # of this format: the awk \x escape is greedy, so a
                            # following hex digit (\x1e then B) would fold into
                            # one byte and silently corrupt the delimiter. A raw
                            # 0x1e inside a model string would mis-split, but
                            # control bytes below 0x20 are invalid in JSON and
                            # fail the schema gate anyway, so no envelope is lost.
                            printf "%s\x1e", substr(buf, start, i - start + 1)
                            start = -1
                        }
                    }
                }
            }
        }
    ')"
    [[ -z "$_candidates" ]] && return 1

    # Recover ONLY when exactly one top-level object bears a `schema_version`
    # key. The brace-bearing-postamble case #908 targets has exactly one such
    # envelope (the postamble junk — {note}, {summary} — lacks schema_version).
    # If MORE than one object bears schema_version the response is AMBIGUOUS — a
    # preamble EXAMPLE plus the real answer (Codex review): recovering the first
    # would risk shipping the example as the verdict when the real (LAST) object
    # is malformed, re-introducing the half-validated-plan risk the strict gate
    # avoids. Fail closed in that case; the honest schema_violation error is
    # safer than a fabricated recovery. Zero bearers → nothing to recover.
    local _obj _envelope="" _count=0
    while IFS= read -r -d $'\x1e' _obj || [[ -n "$_obj" ]]; do
        [[ -z "$_obj" ]] && continue
        if printf '%s' "$_obj" | jq -e 'has("schema_version")' >/dev/null 2>&1; then
            _count=$((_count + 1))
            _envelope="$_obj"
        fi
    done < <(printf '%s' "$_candidates")
    [[ "$_count" -eq 1 ]] || return 1
    if _impact_envelope_schema_ok "$_envelope"; then
        printf '%s' "$_envelope"
        return 0
    fi
    return 1
}

# ─── _impact_path_is_collateral <path> (#936) ────────────────────────────────
# rc=0 if the path is a downstream-recoverable collateral class (tests/, config/,
# docs/ — what ADR-030 scope-governance auto-grants); rc=1 for structural source
# paths (core/, scripts/, plugins/, root) which are NOT recoverable if
# under-scoped. Mirrors scope_collateral_class (scripts/lib/scope-governance.sh)
# without pulling that lib into the impact path.
_impact_path_is_collateral() {
    case "${1:-}" in
        tests/*|config/*|docs/*) return 0 ;;
        *) return 1 ;;
    esac
}

# ─── _impact_converge_on_overscope <repo_root> <artifact_dir> <plan_json> (#936)
# Over-scope-safe deterministic convergence backstop. design_impact_cycle never
# converges when impact re-flags real-but-irrelevant adjacent files: missing[]
# stays non-empty with REAL paths, #911 never flips the verdict, and the cycle
# maxes out (on_max=continue) instead of converging. This flips verdict
# incomplete->complete ONLY in the provably-safe over-scope case, so a real
# reference gap or a structural omission is NEVER masked. Never drops a file;
# only flips the verdict. Reads/mutates $impact_json in caller scope (mirrors
# _impact_drop_nonexistent_missing).
#
# Fires iff ALL hold (else returns 0, no event):
#   1. verdict == "incomplete"                       (error is never flipped)
#   2. NOT _impact_detect_shape_change               (shape regime: run full budget)
#   3. no missing[] entry has step_id=="prefilter"   (#781/#881 floor veto)
#   4. ZBUILD_CYCLE_ITER>=2 AND the non-floor missing[] file SET is IDENTICAL to
#      the prior verdict-producing iter (true plateau, per-run sidecar) — not a
#      one-shot existence check; a cascade (different set each iter) never fires
#   5. EVERY remaining file is collateral-class (tests/|config/|docs/) — the only
#      classes recoverable downstream if this convergence under-scoped
#   6. EVERY remaining file EXISTS on disk (defensive; #911 already dropped ghosts)
#
# The sidecar is written EVERY verdict-producing iter (this function only runs on
# genuine schema-valid responses; the #782/#892/#937 synthetic envelopes early-
# return before reaching it), so it records this iter set for the NEXT compare.
_impact_converge_on_overscope() {
    local _repo_root="${1:-${ZBUILD_REPO_ROOT:-$(pwd)}}"
    local _artifact_dir="${2:-}"
    local _plan_json="${3:-}"
    local _design_scope_csv="${4:-}"

    # (1) verdict must be incomplete.
    local _verdict
    _verdict="$(printf '%s' "$impact_json" | jq -r '.verdict' 2>/dev/null || echo "")"
    [[ "$_verdict" == "incomplete" ]] || return 0

    # Current NON-FLOOR missing[] file set (sorted, deduped, whitespace-stripped).
    # sort -u handles dedup; no separate jq `unique` needed (Codex review).
    local _nonfloor
    _nonfloor="$(printf '%s' "$impact_json" | jq -r '
        .missing[]? | select(.step_id != "prefilter") | .files_to_add[]?' 2>/dev/null \
        | sed 's/[[:space:]]//g; /^$/d' | sort -u)"

    # Persist this iter set for the NEXT iter compare; capture prior first.
    # Sidecar is a newline-delimited path list (.txt), NOT JSON (Codex review).
    local _sidecar="" _prior=""
    if [[ -n "$_artifact_dir" ]]; then
        _sidecar="$_artifact_dir/impact-prior-missing.txt"
        [[ -f "$_sidecar" ]] && _prior="$(cat "$_sidecar" 2>/dev/null || true)"
        printf '%s\n' "$_nonfloor" > "$_sidecar" 2>/dev/null || true
    fi

    # (3) floor veto — any prefilter entry present blocks the flip.
    local _floor_n
    _floor_n="$(printf '%s' "$impact_json" \
        | jq '[.missing[]? | select(.step_id=="prefilter")] | length' 2>/dev/null || echo 1)"
    [[ "$_floor_n" == "0" ]] || return 0

    # Non-floor set must be non-empty (something to converge on).
    [[ -n "$_nonfloor" ]] || return 0

    # (2) shape-change suppression — a shape change is exactly when a silent
    # omission is unrecoverable. Check BOTH the plan AND the design.md scope
    # block: in design_impact_cycle the AUTHORITATIVE scope is design.md, and
    # design can add a shape file the plan omitted; the floor keys off the plan,
    # so without the design check a shape change could slip through as a plateau
    # (Codex review).
    if [[ -n "$_plan_json" ]] && _impact_detect_shape_change "$_plan_json" "$_repo_root" >/dev/null 2>&1; then
        return 0
    fi
    if [[ -n "$_design_scope_csv" ]]; then
        local _design_plan
        _design_plan="$(printf '%s' "$_design_scope_csv" \
            | jq -Rs 'rtrimstr("\n") | {steps:[{files:(split(",") | map(select(length>0)))}]}' 2>/dev/null || echo "")"
        if [[ -n "$_design_plan" ]] && _impact_detect_shape_change "$_design_plan" "$_repo_root" >/dev/null 2>&1; then
            return 0
        fi
    fi

    # (4) iter-awareness + TRUE plateau: iter>=2 AND identical set since prior.
    local _iter="${ZBUILD_CYCLE_ITER:-}"
    [[ "$_iter" =~ ^[0-9]+$ ]] || return 0
    (( _iter >= 2 )) || return 0
    [[ -n "$_prior" ]] || return 0
    [[ "$_prior" == "$_nonfloor" ]] || return 0

    # (5)+(6) every remaining file collateral-class AND present on disk.
    # Reject absolute paths and any `..` traversal FIRST: a non-canonical path
    # like `tests/../scripts/lib/x.sh` would pass the prefix-based collateral
    # check yet resolve (via -e) to a structural file, hiding a structural
    # omission. ADR-030's floor denies such paths; mirror that here (Codex review).
    local _p
    while IFS= read -r _p; do
        [[ -z "$_p" ]] && continue
        case "$_p" in /*|*..*) return 0 ;; esac
        _impact_path_is_collateral "$_p" || return 0
        [[ -e "$_repo_root/$_p" ]] || return 0
    done <<< "$_nonfloor"

    # All conditions met — flip verdict, emit plateau event.
    local _carried
    _carried="$(printf '%s' "$_nonfloor" | tr '\n' ',')"
    _carried="${_carried%,}"

    local _flipped
    _flipped="$(printf '%s' "$impact_json" | jq -c '.verdict = "complete"' 2>/dev/null)" || return 0
    [[ -n "$_flipped" ]] && impact_json="$_flipped"

    emit_event "impact.scope.plateau" \
        "plugin=impact" \
        "reason=overscope_only" \
        "carried_files=${_carried}" \
        "iter=${_iter}" \
        "verdict_flipped=true" 2>/dev/null || true
}
