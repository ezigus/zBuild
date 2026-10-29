#!/usr/bin/env bash
# scripts/lib/run-status-pages.sh — the run-status comment, in as many parts as
# the run needs (ADR-064 §6, amended 2026-10-28). Sourced by
# run-status-render.sh; pure like it: events + state dir → part files.
#
# A run that outgrew one comment used to drop its oldest rows ("… N earlier
# rows omitted"). Nothing a stage reported may be lost from the issue, so the
# run continues in a new comment instead. Rows fill the parts oldest first, so
# a full part never changes again: a new row only ever lands in the newest
# part, which carries the run's header (status, open items, current stage).

[[ -n "${_ZBUILD_RUN_STATUS_PAGES_LOADED:-}" ]] && return 0 2>/dev/null
_ZBUILD_RUN_STATUS_PAGES_LOADED=1

# Room kept in every part for the header, so where a part ends does not move
# when the header grows (open items, the end reason).
: "${ZBUILD_STATUS_COMMENT_HEADER_RESERVE:=20000}"

# ─── rsc_render_pages <events_jsonl> <state_dir> <out_dir> [status_override] ─
# Writes <out_dir>/part-1.md … part-N.md and prints N. Part 1 keeps the run's
# marker; part k > 1 is marked `run_id=<id> part=<k>`, so each is found again
# on its own.
rsc_render_pages() {
    local events="$1" state_dir="$2" out="$3" override="${4:-}"
    local model header run_id issue row
    model="$(rsc_rows_json "$events")"
    header="$(rsc_render_header "$model" "$state_dir" "$override")"
    IFS=$'\t' read -r run_id issue < <(jq -r '[.header.run_id // "", (.header.issue // "" | tostring)] | @tsv' <<< "$model")
    # #2154: rows are rendered in THIS shell so the snapshot they freeze
    # survives the loop and is saved once at the end.
    _rsc_snapshot_load "$state_dir" "$run_id"
    local -a rows=()
    local rf; rf="$(mktemp "${TMPDIR:-$state_dir}/rsc-row.XXXXXX")" || return 1
    while IFS= read -r row; do
        # Not $( ): the row must render in this shell to freeze its summary.
        rsc_render_row "$state_dir" "$row" > "$rf"
        rows+=("$(<"$rf")")
    done < <(jq -c '. as $m | $m.order | .[] | select((. // "") != "") as $k | $m.rows[$k | tostring]' <<< "$model")
    rm -f "$rf"
    _rsc_snapshot_save "$state_dir"

    # Oldest first into parts of at most `budget` bytes of rows.
    local budget=$(( ZBUILD_STATUS_COMMENT_MAX_BYTES - ZBUILD_STATUS_COMMENT_HEADER_RESERVE ))
    local -a part_of=()
    local p=1 used=0 i n r
    for i in "${!rows[@]}"; do
        r="${rows[$i]}"
        n=$(( $(rsc_byte_len "$r") + 1 ))
        if (( n > budget )) && [[ "$r" == *$'\n<details>'* ]]; then
            # One row larger than a whole part: its first line stays, the
            # folded rest is pointed at instead.
            r="${r%%$'\n<details>'*} _(the rest of what it reported is too long for a comment — see the run log)_"
            rows[$i]="$r"; n=$(( $(rsc_byte_len "$r") + 1 ))
        fi
        if (( used > 0 && used + n > budget )); then p=$(( p + 1 )); used=0; fi
        part_of[$i]=$p; used=$(( used + n ))
    done
    local last=$p k
    for (( k = 1; k <= last; k++ )); do
        {
            if (( k == last )); then
                if (( last > 1 )); then
                    printf '%s%s part=%s -->\n' "$_RSC_MARKER_PREFIX" "$run_id" "$k"
                    printf '%s\n' "${header#*$'\n'}"
                else
                    printf '%s\n' "$header"
                fi
            else
                if (( k == 1 )); then printf '%s%s -->\n' "$_RSC_MARKER_PREFIX" "$run_id"
                else printf '%s%s part=%s -->\n' "$_RSC_MARKER_PREFIX" "$run_id" "$k"; fi
                printf '### zbuild run `%s` · issue #%s · part %s — earlier stages (the run continues in the next comment)\n' \
                    "$run_id" "$issue" "$k"
            fi
            printf '\n'
            # Newest first within a part.
            for (( i = ${#rows[@]} - 1; i >= 0; i-- )); do
                [[ "${part_of[$i]}" == "$k" ]] && printf '%s\n' "${rows[$i]}"
            done
        } > "$out/part-${k}.md"
    done
    printf '%s' "$last"
}

# ─── rsc_outbound_pages <events_jsonl> <state_dir> <out_dir> [status_override] ─
# The parts after scope redaction, each on its own; prints N. A redactor
# failure returns 1 and leaves no part behind: never post unredacted.
rsc_outbound_pages() {
    local events="$1" state_dir="$2" out="$3" override="${4:-}" n k manifest="$2/scope-manifest.md"
    n="$(rsc_render_pages "$events" "$state_dir" "$out" "$override")" || return 1
    if [[ -s "$manifest" ]]; then
        if ! declare -F apply_scope_redaction >/dev/null 2>&1; then
            # shellcheck source=../../core/redaction/scope-redaction.sh
            source "$_RSC_ROOT/core/redaction/scope-redaction.sh" 2>/dev/null || { rm -f "$out"/part-*.md; return 1; }
        fi
        for (( k = 1; k <= n; k++ )); do
            if ! apply_scope_redaction "$out/part-${k}.md" "$out/part-${k}.red" "$manifest" "" "0" >/dev/null 2>&1; then
                rm -f "$out"/part-*.md "$out"/part-*.red; return 1
            fi
            mv -f "$out/part-${k}.red" "$out/part-${k}.md"
        done
    fi
    printf '%s' "$n"
}
