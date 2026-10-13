#!/usr/bin/env bash
# scripts/lib/stage-previous-work.sh — the Previous work block of the engine's
# prompt contract (ADR-067 §8).
#
# Every stage receives the latest output of every stage that has run, its own
# included, whichever try or run wrote it (ADR-068 §8, ADR-050 §9). Sourced by
# scripts/lib/stage-prompt.sh, which defines the helpers used here
# (_sp_unit, stage_notes_path, the _ZB_SP_* bounds).
#
# Sourced library: inherits the caller's shell options; do NOT add set -euo.

[[ -n "${_ZBUILD_STAGE_PREVIOUS_WORK_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_PREVIOUS_WORK_LOADED=1

# ─── What this issue's work has changed ─────────────────────────────────────
# _sp_work_changed_line <state_dir> <repo_root> — one line naming the files this
# issue's work has changed, against the commit it started from (the baseline
# intake records). Said once, at the top: it is the same for every stage. No
# baseline, or no readable repository: no line.
_sp_work_changed_line() {
    local state_dir="$1" repo_root="$2" base="" files line n=0 shown=""
    [[ -s "$state_dir/intake-baseline-ref.txt" ]] && base="$(<"$state_dir/intake-baseline-ref.txt")"
    base="${base%%[[:space:]]*}"
    [[ -n "$base" && -n "$repo_root" ]] || return 0
    files="$(git -C "$repo_root" diff --name-only "$base" -- 2>/dev/null)" || return 0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        n=$((n + 1))
        (( n <= 20 )) && shown+="${shown:+, }$line"
    done <<< "$files"
    if (( n == 0 )); then
        printf "Files this issue's work has changed so far: none.\n"
    else
        (( n > 20 )) && shown+=", … ($n in all)"
        printf "Files this issue's work has changed so far: %s\n" "$shown"
    fi
}

# _sp_last_good_attempt <state_dir> <stage> <primary-basename> — the newest
# archived attempt of <stage> whose primary result is not an error, i.e. the
# last attempt that produced its output (core/plugin-registry/attempt-archive.sh
# keeps a copy of every dispatch's outputs). Prints its directory; nothing when
# there is none.
_sp_last_good_attempt() {
    local base="$1/artifacts/attempts/${2//[^A-Za-z0-9_-]/_}" name="$3" d best="" content
    [[ -d "$base" && -n "$name" ]] || return 0
    while IFS= read -r d; do
        [[ -s "$d/$name" ]] || continue
        content="$(<"$d/$name")"
        [[ "$content" =~ \"verdict\"[[:space:]]*:[[:space:]]*\"error\" ]] && continue
        best="$d"
    done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -name 'iter-*-attempt-*' 2>/dev/null \
                | awk -F'iter-|-attempt-' '{ printf "%09d %09d %s\n", $(NF-1), $NF, $0 }' \
                | LC_ALL=C sort | cut -d' ' -f3-)
    [[ -n "$best" ]] && printf '%s' "$best"
    return 0
}

# ─── Previous work ───────────────────────────────────────────────────────────
# _sp_manifest_roles <manifest> <state_dir> — one line per output that plays a
# role: "S<TAB>path" (summary: true), "E<TAB>path" (errors: true), "P<TAB>path"
# (primary: true). Read once per manifest per run and kept under the run's
# runtime/ folder: the block is written at every dispatch, each dispatch is its
# own subshell, and the fork budget (ADR-065) counts every read.
_sp_manifest_roles() {
    local m="$1" state_dir="$2" c
    c="$state_dir/runtime/manifest-roles/${m//[^A-Za-z0-9._-]/_}"
    if [[ ! -e "$c" ]]; then
        [[ -d "${c%/*}" ]] || mkdir -p "${c%/*}" 2>/dev/null
        awk '
            function flush() {
                if (path != "") {
                    if (summ) print "S\t" path
                    if (err)  print "E\t" path
                    if (prim) print "P\t" path
                }
                path = ""; summ = 0; err = 0; prim = 0
            }
            /^outputs:[[:space:]]*$/ { inb = 1; next }
            inb && /^[a-zA-Z_]/ { flush(); inb = 0 }
            inb && /^[[:space:]]*-[[:space:]]/ { flush() }
            inb && /^[[:space:]]+path:[[:space:]]*/ {
                p = $0; sub(/^[[:space:]]+path:[[:space:]]*/, "", p); sub(/[[:space:]]*#.*/, "", p)
                gsub(/^["\047]|["\047]$/, "", p); path = p }
            inb && /^[[:space:]]+summary:[[:space:]]*true/ { summ = 1 }
            inb && /^[[:space:]]+errors:[[:space:]]*true/  { err = 1 }
            inb && /^[[:space:]]+primary:[[:space:]]*true/ { prim = 1 }
            END { flush() }' "$m" > "$c.$$" 2>/dev/null && mv -f "$c.$$" "$c" 2>/dev/null \
            || { rm -f "$c.$$" 2>/dev/null; return 0; }
    fi
    printf '%s' "$(<"$c")"
}

# _sp_read <file> <max> — the first <max> bytes of a file, without a fork.
_sp_read() { local c; [[ -r "$1" ]] || return 0; c="$(<"$1")"; printf '%s' "${c:0:$2}"; }

# _stage_block_previous_work <stage> <state_dir> <plugins_root> <index> <repo_root>
_stage_block_previous_work() {
    local stage="$1" state_dir="$2" plugins_root="$3" index="$4" repo_root="$5"
    local state_file="$state_dir/pipeline-state.json"
    declare -F _inputs_build_producer_index >/dev/null 2>&1 \
        || source "$_ZBUILD_SP_ROOT/core/pipeline/input-resolve.sh"
    declare -F _zbuild_sanitize_for_llm >/dev/null 2>&1 \
        || source "$_ZBUILD_SP_ROOT/scripts/lib/test-output-sanitize.sh" 2>/dev/null || true
    _inputs_build_producer_index "$plugins_root" "$state_dir"

    printf 'The latest output of every stage that has run, with where to find it. Use\n'
    printf 'what your job needs.\n'
    local changed; changed="$(_sp_work_changed_line "$state_dir" "$repo_root")"
    [[ -n "$changed" ]] && printf '\n%s\n' "$changed"

    # Everything read once: the stages in the order they first completed with
    # their verdicts, then every output in the index.
    local -a order=()
    local -A verdicts=() outs=() seen=()
    local line k v id
    while IFS=$'\t' read -r k v; do
        [[ -n "$k" && -z "${seen[$k]:-}" ]] || continue
        seen[$k]=1; order+=("$k"); verdicts[$k]="$v"
    done < <(jq -r '. as $r | ($r.stage_statuses // {}) | keys_unsorted[]
                    | "\(.)\t\($r.stage_verdicts[.] // "")"' "$state_file" 2>/dev/null || true)
    while IFS= read -r k; do
        [[ -n "$k" && -z "${seen[$k]:-}" ]] || continue
        seen[$k]=1; order+=("$k")
    done < <(_inputs_flow_stages 2>/dev/null)
    if [[ -n "$index" && -s "$index" ]]; then
        while IFS=$'\t' read -r id v; do
            [[ -n "$id" ]] || continue
            k="${_IR_PRODUCER[$id]:-}"; [[ -n "$k" ]] || continue
            if [[ "$v" == *$'\x1f'* ]]; then
                outs[$k]+="- $id:"$'\n'
                local m; while IFS= read -r m; do [[ -n "$m" ]] && outs[$k]+="    - $m"$'\n'; done <<< "${v//$'\x1f'/$'\n'}"
            else
                outs[$k]+="- $id: $v"$'\n'
            fi
        done < <(jq -r '(.inputs // {}) | to_entries[]
                        | "\(.key)\t\(if (.value|type) == "array" then (.value | join("\u001f")) + "\u001f" else .value end)"' \
                        "$index" 2>/dev/null | LC_ALL=C sort)
    fi

    local s manifest roles summ errp res notes verdict own body any=0 raw content
    for s in "${order[@]}"; do
        # Only a stage's own notes come back to it (ADR-067 §8); another
        # stage's notes are its working file, not its output.
        notes=""
        [[ "$s" == "$stage" ]] && notes="$(stage_notes_path "$state_dir" "$s")"
        [[ -n "$notes" && -s "$notes" ]] || notes=""
        [[ -n "${outs[$s]:-}" || -n "$notes" ]] || continue
        any=1
        manifest="$(_inputs_stage_manifest "$s" "$plugins_root" 2>/dev/null || true)"
        summ=""; errp=""; res=""
        if [[ -n "$manifest" ]]; then
            roles="$(_sp_manifest_roles "$manifest" "$state_dir")"
            while IFS=$'\t' read -r k raw; do
                case "$k" in
                    S) [[ -z "$summ" ]] && { summ="$(_inputs_output_paths "$s" "$raw" "$state_dir")"; summ="${summ%%$'\n'*}"; } ;;
                    E) [[ -z "$errp" ]] && errp="$(_verdict_resolve_path "$raw" "$state_dir")" ;;
                    P) [[ -z "$res" ]] && res="$(_verdict_resolve_path "$raw" "$state_dir")" ;;
                esac
            done <<< "$roles"
        fi
        [[ "$res" == *.json && -s "$res" ]] || res=""
        verdict="${verdicts[$s]:-}"
        content=""; [[ -n "$res" && -r "$res" ]] && content="$(<"$res")"
        if [[ -z "$verdict" && -n "$content" && "$content" =~ \"verdict\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
            verdict="${BASH_REMATCH[1]}"
        fi
        own=""; [[ "$s" == "$stage" ]] && own=" — your own"
        printf '\n### %s (verdict: %s)%s\n' "$s" "${verdict:-unknown}" "$own"
        [[ -n "${outs[$s]:-}" ]] && printf 'Outputs:\n%s' "${outs[$s]}"

        if [[ "$content" == *'"findings"'* ]]; then
            body="$(jq -r --arg s "$s" '(.data.findings // [])[]?
                    | select(type == "object" and (.n|type) == "number")
                    | "- \($s) finding \(.n) (opened by \($s)): \(.text|tostring|gsub("[\r\n]+"; " "))"' "$res" 2>/dev/null || true)"
            [[ -n "$body" ]] && printf '\nFindings:\n%s\n' "$body"
        fi
        if [[ -n "$summ" && -s "$summ" ]]; then
            body="$(<"$summ")"
            local full=${#body}
            body="${body:0:$_ZB_SP_SUMMARY_MAX_BYTES}"
            # The sanitizer forks twice; run it only on text it would change.
            if [[ "$body" == *$'\e'* || "$body" == *"══"* || "$body" == *"──"* || "$body" == *"<out-of-scope-context>"* ]] \
                    && declare -F _zbuild_sanitize_for_llm >/dev/null 2>&1; then
                body="$(printf '%s' "$body" | _zbuild_sanitize_for_llm 2>/dev/null || printf '%s' "$body")"
            fi
            printf '\nSummary:\n%s\n' "$body"
            (( full > _ZB_SP_SUMMARY_MAX_BYTES )) \
                && printf '[… cut at %sB — read %s for the rest]\n' "$_ZB_SP_SUMMARY_MAX_BYTES" "$summ"
        fi
        case "$verdict" in
            fail|failed|error|broken|partial|mismatch)
                if [[ -n "$errp" && -s "$errp" ]]; then
                    body="$(<"$errp")"
                    (( ${#body} > _ZB_SP_ERRORS_MAX_BYTES )) && body="${body: -$_ZB_SP_ERRORS_MAX_BYTES}"
                    printf '\nErrors it hit (last %sB of %s):\n%s\n' "$_ZB_SP_ERRORS_MAX_BYTES" "$errp" "$body"
                fi ;;
        esac
        # An attempt that ended in error produced no output: show the last
        # output this stage did produce, from the attempt that wrote it.
        if [[ -n "$res" && "$content" =~ \"verdict\"[[:space:]]*:[[:space:]]*\"error\" ]]; then
            local good f
            good="$(_sp_last_good_attempt "$state_dir" "$s" "${res##*/}")"
            if [[ -n "$good" ]]; then
                printf '\nIts last good output, from an earlier attempt:\n'
                for f in "$good"/*; do
                    [[ -f "$f" && "${f##*/}" != attempt.json ]] && printf -- '- %s\n' "$f"
                done
                if [[ -n "$summ" && -s "$good/${summ##*/}" ]]; then
                    printf '\nSummary of that output:\n%s\n' "$(_sp_read "$good/${summ##*/}" "$_ZB_SP_SUMMARY_MAX_BYTES")"
                fi
            fi
        fi
        if [[ -n "$own" && -n "$notes" ]]; then
            printf '\nYour notes so far:\n%s\n' "$(_sp_read "$notes" "$_ZB_SP_NOTES_MAX_BYTES")"
        fi
    done
    [[ "$any" -eq 1 ]] || printf '\nNo stage has run before this one.\n'
    return 0
}
