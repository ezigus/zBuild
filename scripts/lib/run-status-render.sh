#!/usr/bin/env bash
# scripts/lib/run-status-render.sh — the pure half of the run-status comment
# (#2131, ADR-064): events.jsonl + state dir → markdown body. No gh, no
# network, no writes. Sourced by run-status-comment.sh, which owns the
# GitHub I/O and the loop; split so each side stays under the 500-line mark
# and the renderer can be exercised without a fake `gh`.

[[ -n "${_ZBUILD_RUN_STATUS_RENDER_LOADED:-}" ]] && return 0 2>/dev/null
_ZBUILD_RUN_STATUS_RENDER_LOADED=1

_RSC_RENDER_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)"
_RSC_ROOT="${_RSC_ROOT:-$(cd "$_RSC_RENDER_DIR/../.." && pwd)}"
: "${ZBUILD_STATUS_COMMENT_MAX_BYTES:=60000}"   # GitHub rejects > 65,536; keep headroom
_RSC_MARKER_PREFIX='<!-- zbuild-run-status run_id='
# shellcheck source=./run-open-items.sh
source "$_RSC_ROOT/scripts/lib/run-open-items.sh"   # run_end_words, open_items_* (#2330)
# shellcheck source=./run-status-pages.sh
source "$_RSC_ROOT/scripts/lib/run-status-pages.sh"  # rsc_render_pages, rsc_outbound_pages
# shellcheck source=./run-status-rows.sh
source "$_RSC_ROOT/scripts/lib/run-status-rows.sh"   # rsc_rows_json

# ─── rsc_byte_len <string> — bytes, not chars (the GitHub limit is bytes) ───
rsc_byte_len() {
    local LC_ALL=C
    local s="$1"
    printf '%s' "${#s}"
}

# ─── rsc_duration <start_ts> <end_ts> — `<1s`, `45s`, `61m33s` ──────────────
rsc_duration() { local _rd; rsc_duration_v _rd "$@"; printf '%s' "$_rd"; }
rsc_duration_v() {   # <var> <start_ts> <end_ts>
    local _rdv_a _rdv_b _rdv_s _rdv_o
    _rsc_epoch_to _rdv_a "$2"; _rsc_epoch_to _rdv_b "$3"
    _rdv_s=0; (( _rdv_a > 0 && _rdv_b > 0 )) && _rdv_s=$(( _rdv_b - _rdv_a ))
    if [[ "$_rdv_s" -le 0 ]]; then _rdv_o='<1s'
    elif [[ "$_rdv_s" -lt 60 ]]; then printf -v _rdv_o '%ds' "$_rdv_s"
    else printf -v _rdv_o '%dm%02ds' $(( _rdv_s / 60 )) $(( _rdv_s % 60 ))
    fi
    printf -v "$1" '%s' "$_rdv_o"
}

# ─── #2145: times in the reader's zone, Eastern by default ──────────────────
# Events and logs stay UTC; the comment is for a person. ZBUILD_STATUS_TZ
# names any zoneinfo zone; America/New_York is labelled "ET" whatever the
# season (EDT/EST is what `%Z` would print, and nobody reads it that way).
_RSC_DEFAULT_TZ="America/New_York"
_rsc_tz() { printf '%s' "${ZBUILD_STATUS_TZ:-$_RSC_DEFAULT_TZ}"; }
_rsc_ceiling_min() { local m="${ZBUILD_STATUS_CEILING_MIN:-360}"; [[ "$m" =~ ^[0-9]+$ ]] || m=360; printf '%s' "$m"; }   # GitHub's job ceiling
# ISO-8601 UTC (`…Z`, with or without fractional seconds) → epoch seconds in
# <var>, 0 when it is not one. Arithmetic, not jq: every time on the comment
# went through a jq and a date (ADR-065 §5). Days from the civil date are
# Howard Hinnant's days_from_civil. Every local is prefixed: a nameref to a
# caller's `m` would otherwise resolve to this function's own `m`.
_rsc_epoch_to() {   # <var> <iso>
    local -n _rsce_out="$1"; _rsce_out=0
    [[ "${2:-}" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?Z$ ]] || return 0
    local _rsce_y=$((10#${BASH_REMATCH[1]})) _rsce_m=$((10#${BASH_REMATCH[2]})) _rsce_d=$((10#${BASH_REMATCH[3]}))
    local _rsce_hh=$((10#${BASH_REMATCH[4]})) _rsce_mi=$((10#${BASH_REMATCH[5]})) _rsce_ss=$((10#${BASH_REMATCH[6]}))
    (( _rsce_m >= 1 && _rsce_m <= 12 && _rsce_d >= 1 && _rsce_d <= 31 && _rsce_hh < 24 && _rsce_mi < 60 && _rsce_ss < 61 )) || return 0
    (( _rsce_m <= 2 )) && _rsce_y=$(( _rsce_y - 1 ))
    local _rsce_era=$(( _rsce_y / 400 )) _rsce_yoe _rsce_doy _rsce_doe
    _rsce_yoe=$(( _rsce_y - _rsce_era * 400 ))
    _rsce_doy=$(( (153 * ((_rsce_m + 9) % 12) + 2) / 5 + _rsce_d - 1 ))
    _rsce_doe=$(( _rsce_yoe * 365 + _rsce_yoe / 4 - _rsce_yoe / 100 + _rsce_doy ))
    _rsce_out=$(( (_rsce_era * 146097 + _rsce_doe - 719468) * 86400 + _rsce_hh * 3600 + _rsce_mi * 60 + _rsce_ss ))
}
_rsc_epoch() { local e; _rsc_epoch_to e "${1:-}"; printf '%s' "$e"; }
_rsc_fmt_local() { local _rf; _rsc_fmt_local_v _rf "$1"; printf '%s' "$_rf"; }
_rsc_fmt_local_v() {   # <var> <epoch> → "9:39 PM ET"
    local _rfl_out _rfl_label _rfl_tz="${ZBUILD_STATUS_TZ:-$_RSC_DEFAULT_TZ}"
    TZ="$_rfl_tz" printf -v _rfl_out '%(%l:%M %p %Z)T' "$2"
    _rfl_out="${_rfl_out# }"
    case "$_rfl_tz" in
        America/New_York) _rfl_label="ET" ;;
        America/Chicago)  _rfl_label="CT" ;;
        America/Denver)   _rfl_label="MT" ;;
        America/Los_Angeles) _rfl_label="PT" ;;
        *) _rfl_label="${_rfl_out##* }" ;;
    esac
    printf -v "$1" '%s %s' "${_rfl_out% *}" "$_rfl_label"
}
# "9:39 PM ET" from an ISO timestamp.
_rsc_clock() { local _rc; _rsc_clock_v _rc "${1:-}"; printf '%s' "$_rc"; }
_rsc_clock_v() {   # <var> <iso>
    local _rcv_e; _rsc_epoch_to _rcv_e "${2:-}"
    if (( _rcv_e > 0 )); then _rsc_fmt_local_v "$1" "$_rcv_e"; else printf -v "$1" '%s' "${2:-}"; fi
}
# "1h 20m" from seconds.
_rsc_hm() { local s="$1"; if (( s >= 3600 )); then printf '%dh %02dm' $(( s / 3600 )) $(( (s % 3600) / 60 )); else printf '%dm' $(( s / 60 )); fi; }

# ─── rsc_row_inputs_line <state_dir> <stage> — what the stage was given ─────
rsc_row_inputs_line() { local _ri; rsc_row_inputs_line_v _ri "$@"; printf '%s' "$_ri"; }
rsc_row_inputs_line_v() {   # <var> <state_dir> <stage>
    local _riv_idx="$2/stage-inputs/$3.json" _riv_s=""
    printf -v "$1" '%s' ""
    [[ -s "$_riv_idx" ]] || return 0
    _riv_s="$(jq -r '(.inputs // {}) | keys_unsorted | join(", ")' "$_riv_idx" 2>/dev/null || true)"
    printf -v "$1" '%s' "${_riv_s:0:120}"
}

# ─── rsc_row_summary_line <state_dir> <stage> — what the stage reported ─────
# ADR-055 §9: the stage's ONE declared summary. Resolved through the manifest
# when the engine libs are reachable, else `artifacts/<stage>-summary.md`.
# Its first non-empty non-heading line, `- ` stripped, `|` escaped, whole; and
# the rest of the summary folded under it in a <details> block (ADR-064 §4,
# amended 2026-10-28: nothing a stage reported is cut).
rsc_row_summary_line() { local _rs; rsc_row_summary_line_v _rs "$@"; printf '%s' "$_rs"; }
rsc_row_summary_line_v() {   # <var> <state_dir> <stage>
    local _rsv_sd="$2" _rsv_st="$3" _rsv_p="" _rsv_l=""
    printf -v "$1" '%s' ""
    if declare -F _summaries_stage_summary_path >/dev/null 2>&1; then
        _rsv_p="$(_summaries_stage_summary_path "$_rsv_st" "${ZBUILD_PLUGINS_ROOT:-$_RSC_ROOT/plugins}" "$_rsv_sd" 2>/dev/null || true)"
    fi
    [[ -n "$_rsv_p" && -s "$_rsv_p" ]] || _rsv_p="$_rsv_sd/artifacts/${_rsv_st}-summary.md"
    _rsc_first_line_v "$1" "$_rsv_p"
}

# _rsc_first_line_v <var> <summary_file> — the first line with a non-blank
# character that is not a heading, `- ` stripped, `|` escaped, whole; the rest
# folded under it.
_rsc_first_line_v() {
    local _rsv_p="$2" _rsv_l=""
    printf -v "$1" '%s' ""
    [[ -s "$_rsv_p" ]] || return 0
    # The first line with a non-blank character that is not a heading, read by
    # the shell (it was an awk: `NF && $0 !~ /^#/`).
    local _rsv_found=0 _rsv_rest="" _rsv_x
    while IFS= read -r _rsv_x || [[ -n "$_rsv_x" ]]; do
        if (( _rsv_found )); then
            _rsv_rest+="${_rsv_x}"$'\n'
        elif [[ "$_rsv_x" =~ [^[:space:]] && "$_rsv_x" != \#* ]]; then
            _rsv_found=1; _rsv_l="$_rsv_x"
        fi
    done < "$_rsv_p"
    (( _rsv_found )) || return 0
    _rsv_l="${_rsv_l#- }"
    _rsv_l="${_rsv_l//|/\\|}"
    # The rest, without its leading and trailing blank lines.
    while [[ "$_rsv_rest" == $'\n'* ]]; do _rsv_rest="${_rsv_rest#$'\n'}"; done
    while [[ "$_rsv_rest" == *$'\n' ]]; do _rsv_rest="${_rsv_rest%$'\n'}"; done
    [[ "$_rsv_rest" =~ [^[:space:]] ]] \
        && _rsv_l+=$'\n'"<details><summary>the rest of what it reported</summary>"$'\n\n'"${_rsv_rest}"$'\n\n'"</details>"
    printf -v "$1" '%s' "$_rsv_l"
}

# ─── #2154: a closed row's summary is a snapshot ─────────────────────────────
# A stage writes ONE summary file and a later iteration overwrites it, so a
# live re-read made iteration-1 rows change after the fact (#1840 run 5). The
# first render after a row closes captures its summary line into
# <state_dir>/status-comment-rows.json ({run_id, rows:{seq: line}}); every
# later render — the sidecar loop, the post-run finalize, a fresh process —
# serves the snapshot. Keyed by run id: a resumed run has its own comment.
# Only a non-empty line is frozen; a row whose summary arrives later still
# reads live until it has one. #2166: the snapshot follows the LAST close — a
# retry closes the same row again with a new ended_ts, and the line it froze
# on the first close (the failure) must give way to what the retry reported.
# `ends` records the ended_ts each line was frozen at; a legacy file without
# it keeps its lines.
declare -gA _RSC_SNAP=()
declare -gA _RSC_SNAP_END=()
_RSC_SNAP_RUN=""
_RSC_SNAP_DIRTY=0
_rsc_snapshot_path() { printf '%s/status-comment-rows.json' "$1"; }
_rsc_esc_v() {     # <var> <text> — \\, newline and tab as two-character escapes
    local _t="${2//\\/\\\\}"; _t="${_t//$'\n'/\\n}"; printf -v "$1" '%s' "${_t//$'\t'/\\t}"
}
_rsc_unesc_v() {   # <var> <text> — the reverse of _rsc_esc_v
    local _t="${2//\\\\/$'\x01'}"; _t="${_t//\\n/$'\n'}"; _t="${_t//\\t/$'\t'}"; printf -v "$1" '%s' "${_t//$'\x01'/\\}"
}
_rsc_snapshot_load() {   # <state_dir> <run_id>
    local f; f="$(_rsc_snapshot_path "$1")"
    _RSC_SNAP=(); _RSC_SNAP_END=(); _RSC_SNAP_RUN="$2"; _RSC_SNAP_DIRTY=0
    [[ -s "$f" ]] || return 0
    [[ "$(jq -r '.run_id // ""' "$f" 2>/dev/null)" == "$2" ]] || return 0
    local k v esc
    # esc:1 — values are stored with \\ \n \t escaped, so a multi-line summary
    # survives the tab-and-newline transport; a file without it holds raw lines.
    esc="$(jq -r '.esc // 0' "$f" 2>/dev/null || true)"
    while IFS=$'\t' read -r k v; do
        [[ "$esc" == "1" ]] && _rsc_unesc_v v "$v"
        [[ -n "$k" ]] && _RSC_SNAP["$k"]="$v"
    # Not @tsv: it escapes a tab inside the value as the two characters `\t`,
    # and the save side stores the raw line (review on #2156).
    done < <(jq -r '(.rows // {}) | to_entries[] | "\(.key)\t\(.value)"' "$f" 2>/dev/null)
    while IFS=$'\t' read -r k v; do
        [[ -n "$k" ]] && _RSC_SNAP_END["$k"]="$v"
    done < <(jq -r '(.ends // {}) | to_entries[] | "\(.key)\t\(.value)"' "$f" 2>/dev/null)
}
_rsc_snapshot_save() {   # <state_dir> — atomic; only when something new was frozen
    [[ "$_RSC_SNAP_DIRTY" -eq 1 && -n "$_RSC_SNAP_RUN" ]] || return 0
    local f tmp k; f="$(_rsc_snapshot_path "$1")"
    tmp="$(mktemp "${f}.XXXXXX" 2>/dev/null)" || return 0
    local ends; ends="$(for k in "${!_RSC_SNAP_END[@]}"; do printf '%s\t%s\n' "$k" "${_RSC_SNAP_END[$k]}"; done \
        | jq -Rs '[split("\n")[] | select(length > 0) | split("\t") | {key: .[0], value: .[1]}] | from_entries' 2>/dev/null)"
    # review on #2168: an `ends` that failed to encode must not be saved as
    # `{}` — every row would then read as legacy-frozen (the stale first close).
    if [[ -z "$ends" && "${#_RSC_SNAP_END[@]}" -gt 0 ]]; then rm -f "$tmp"; return 0; fi
    {
        local _e
        for k in "${!_RSC_SNAP[@]}"; do _rsc_esc_v _e "${_RSC_SNAP[$k]}"; printf '%s\t%s\n' "$k" "$_e"; done
    } | jq -Rs --arg run "$_RSC_SNAP_RUN" --argjson ends "${ends:-{\}}" '
        {run_id: $run, esc: 1,
         rows: ([split("\n")[] | select(length > 0) | split("\t") | {key: .[0], value: (.[1:] | join("\t"))}] | from_entries),
         ends: $ends}' \
        > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" || rm -f "$tmp"
    _RSC_SNAP_DIRTY=0
}

# ─── rsc_render_row <state_dir> <row_json> — one markdown line ──────────────
rsc_render_row() {
    local state_dir="$1" row="$2"
    local kind seq stage started ended verdict rc summaries resolve iter line
    # One jq for every field (ADR-065 §4), joined by the unit separator so an
    # empty field stays a field; a value may carry a newline, so `read -d ''`.
    local members from reason it _f
    _f="$(jq -r '[.kind, .seq, .started_ts, .stage, .ended_ts, .verdict, .rc, .summaries,
                  (.resolve // "0"), ((.members // []) | map(tostring) | join(", ")), .from_iter, .reason, .iter,
                  .summary_path, (.member // false), (.key // .seq), .try, .of]
                 | map(. // "" | tostring) | join("\u001f")' <<< "$row")"
    local spath member key try of
    IFS=$'\x1f' read -r -d '' kind seq started stage ended verdict rc summaries resolve members from reason it spath member key try of <<< "$_f" || true
    of="${of%$'\n'}"
    # #2439: a try the engine ran again says which, of how many.
    local tries=""
    [[ -n "$try" ]] && tries=" · try ${try}${of:+ of ${of}}"
    if [[ "$kind" == "reused" ]]; then
        printf '**%s** · **%s reused** · iter %s · %s from iter %s (%s)' \
            "$(_rsc_clock "$started")" "$seq" "$it" "$members" "$from" "$reason"
        return 0
    fi
    # iter = second-to-last segment: `6.1.3` → 1, `1.2` → 1, `6.1.3.2.1` → 2.
    iter=""
    if [[ "$seq" == *.* && "$member" != true ]]; then
        local _s="${seq%.*}"; iter="${_s##*.}"
    fi
    # #2145: WHEN first — a reader scanning the feed wants the clock before
    # the name. seq + stage stay bold and second.
    if [[ -z "$verdict" ]]; then
        local _c1; _rsc_clock_v _c1 "$started"
        line="**${_c1} → running** · **${seq} ${stage}**"
        [[ -n "$iter" ]] && line+=" · iter ${iter}"
        line+="$tries"
        [[ -n "$summaries" ]] && line+=" · previous work from ${summaries} stage(s) (${resolve} failing)"
    else
        [[ -z "$ended" ]] && ended="$started"
        local _c1 _c2 _du; _rsc_clock_v _c1 "$started"; _rsc_clock_v _c2 "$ended"; rsc_duration_v _du "$started" "$ended"
        line="**${_c1} → ${_c2} (${_du})** · **${seq} ${stage}**"
        [[ -n "$iter" ]] && line+=" · iter ${iter}"
        line+="$tries"
        local v="$verdict"
        [[ "$v" != "pass" && -n "$rc" && "$rc" != "0" ]] && v+=" rc=${rc}"
        line+=" · **${v}**"
        local summary
        # Frozen for THIS close: a retry closes again with a new ended_ts and
        # the line re-freezes from the live file (#2166).
        # Keyed by the row (#2439: two tries share a seq).
        if [[ -n "${_RSC_SNAP[$key]+x}" && ( -z "${_RSC_SNAP_END[$key]+x}" || "${_RSC_SNAP_END[$key]}" == "$ended" ) ]]; then
            summary="${_RSC_SNAP[$key]}"
        else
            # A map member names its own summary file; any other row's is its stage's.
            if [[ -n "$spath" && -s "$spath" ]]; then _rsc_first_line_v summary "$spath"
            else rsc_row_summary_line_v summary "$state_dir" "$stage"; fi
            if [[ -n "$summary" && -n "$_RSC_SNAP_RUN" ]]; then
                _RSC_SNAP["$key"]="$summary"; _RSC_SNAP_END["$key"]="$ended"; _RSC_SNAP_DIRTY=1
            fi
        fi
        if [[ -n "$summary" ]]; then
            line+=" — ${summary}"
        else
            local inputs; rsc_row_inputs_line_v inputs "$state_dir" "$stage"
            [[ -n "$inputs" ]] && line+=" · inputs: ${inputs}"
        fi
    fi
    printf '%s' "$line"
}

# ─── rsc_render_header <model_json> <state_dir> [status_override] ───────────
rsc_render_header() {
    local model="$1" state_dir="$2" override="${3:-}"
    local run_id issue sha branch started status reason detail pr current updated end_reason
    # One jq for the whole header (ADR-065 §4); see rsc_render_row for the join.
    local _f
    _f="$(jq -r '. as $m | [.header.run_id, .header.issue, .header.engine_sha, .header.engine_branch,
                  .header.started, .terminal.status, .terminal.reason, .terminal.detail,
                  .terminal.end_reason, .pr.url,
                  ([$m.order[]? | $m.rows[. | tostring] | select(. != null and .kind != "reused" and .verdict == null)]
                   | last | if . == null then "" else "\(.seq) \(.stage)" end)]
                 | map(. // "" | tostring) | join("\u001f")' <<< "$model")"
    IFS=$'\x1f' read -r -d '' run_id issue sha branch started status reason detail end_reason pr current <<< "$_f" || true
    current="${current%$'\n'}"
    sha="${sha:0:7}"
    started="${started%%.*}"; [[ -n "$started" ]] && started="${started%Z}Z"
    if [[ -z "$status" && -s "$state_dir/pipeline-state.json" ]]; then
        # Events silent on the end → the state file is the next best witness.
        local st; st="$(jq -r '.status // ""' "$state_dir/pipeline-state.json" 2>/dev/null || true)"
        case "$st" in aborted|interrupted|failed|complete|success)
            status="$st"
            [[ -z "$reason" ]] && reason="$(jq -r '.reason // ""' "$state_dir/pipeline-state.json" 2>/dev/null || true)"
            [[ -z "$detail" ]] && detail="$(jq -r '.rate_limit.message // ""' "$state_dir/pipeline-state.json" 2>/dev/null || true)"
            ;;
        esac
    fi
    [[ -n "$override" ]] && status="$override"
    [[ -z "$status" ]] && status="running"
    # ZBUILD_STATUS_NOW: tests pin "now"; production reads the clock.
    updated="${ZBUILD_STATUS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    # #2145: the ceiling — GitHub kills the job at ZBUILD_STATUS_CEILING_MIN
    # after start; the reader should not have to add six hours in their head.
    local _st_e _now_e _ceil_e ceiling=""
    _st_e="$(_rsc_epoch "$started")"; _now_e="$(_rsc_epoch "$updated")"
    if [[ "$_st_e" -gt 0 ]]; then
        _ceil_e=$(( _st_e + $(_rsc_ceiling_min) * 60 ))
        if (( _now_e > 0 && _now_e >= _ceil_e )); then
            ceiling="ceiling $(_rsc_fmt_local "$_ceil_e") (past ceiling)"
        elif (( _now_e > 0 )); then
            ceiling="ceiling $(_rsc_fmt_local "$_ceil_e") ($(_rsc_hm $(( _ceil_e - _now_e ))) left)"
        else
            ceiling="ceiling $(_rsc_fmt_local "$_ceil_e")"
        fi
    fi

    printf '%s%s -->\n' "$_RSC_MARKER_PREFIX" "$run_id"
    printf '### zbuild run `%s` · issue #%s · **%s**\n' "$run_id" "$issue" "$status"
    local meta="engine \`${sha}\`"
    [[ -n "$branch" ]] && meta+=" (\`${branch}\`)"
    meta+=" · started $(_rsc_clock "$started")"
    [[ -n "$ceiling" ]] && meta+=" · ${ceiling}"
    meta+=" · updated $(_rsc_clock "$updated")"
    [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]] \
        && meta+=" · [run log](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID})"
    [[ -n "$pr" ]] && meta+=" · PR ${pr}"
    # #2330: the reason in words; the events keep the engine's code.
    if [[ -n "$reason" ]]; then
        meta+=" · $(run_end_words "$reason" 0)"
        [[ -n "$detail" ]] && meta+=" — ${detail}"
    fi
    printf '%s\n' "$meta"
    # #2330 (ADR-068 §8): once the run has ended without passing, each open
    # item, with what would settle it.
    case "$status" in
        running|complete|success|complete_unconverged) ;;
        *)
            local items; items="$(open_items_markdown "$state_dir")"
            if [[ -n "$items" ]]; then
                local words; words="$(run_end_words "${end_reason:-$reason}" "$(grep -c '^[0-9][0-9]*\. ' <<< "$items" || true)")"
                printf '\n**%s:**\n\n%s\n' "${words^}" "$items"
            fi
            ;;
    esac
    # Current stage: the newest open row, only while the run is live.
    if [[ "$status" == "running" ]]; then
        [[ -n "$current" ]] && printf 'current: **%s**\n' "$current"
    fi
}

# ─── rsc_render_body <events_jsonl> <state_dir> [status_override] ───────────
# The newest part of the comment: the run's header and its newest rows
# (run-status-pages.sh splits a run that outgrows one comment).
rsc_render_body() {
    local d n
    d="$(mktemp -d "${TMPDIR:-$2}/rsc-body.XXXXXX")" || return 1
    n="$(rsc_render_pages "$1" "$2" "$d" "${3:-}")" || { rm -rf "$d"; return 1; }
    cat "$d/part-${n}.md"; rm -rf "$d"
}

# ─── rsc_outbound_body <events_jsonl> <state_dir> [status_override] ─────────
# The newest part after scope redaction. A redactor failure returns 1 with
# nothing on stdout: never post unredacted.
rsc_outbound_body() {
    local d n
    d="$(mktemp -d "${TMPDIR:-$2}/rsc-out.XXXXXX")" || return 1
    n="$(rsc_outbound_pages "$1" "$2" "$d" "${3:-}")" || { rm -rf "$d"; return 1; }
    cat "$d/part-${n}.md"; rm -rf "$d"
}

# ─── rsc_cancel_status [<started_iso>] (#2166) ──────────────────────────────
# "cancelled at the N-minute ceiling" only when the clock says the ceiling was
# reached (within 5 minutes — GitHub's kill is not to the second); a cancel
# well before it is "cancelled by the operator (Xh Ym in)"; no start time →
# "cancelled". ZBUILD_STATUS_NOW pins "now" for tests.
rsc_cancel_status() {
    local started="${1:-}" st_e now_e ceil_e
    st_e="$(_rsc_epoch "$started")"
    if [[ "$st_e" -le 0 ]]; then printf 'cancelled'; return 0; fi
    now_e="$(_rsc_epoch "${ZBUILD_STATUS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}")"
    # No usable "now", or a now before the start (clock skew): say only what is known.
    if (( now_e <= 0 || now_e < st_e )); then printf 'cancelled'; return 0; fi
    ceil_e=$(( st_e + $(_rsc_ceiling_min) * 60 ))
    if (( now_e >= ceil_e - 300 )); then
        printf 'cancelled at the %s-minute ceiling' "$(_rsc_ceiling_min)"
    else
        printf 'cancelled by the operator (%s in)' "$(_rsc_hm $(( now_e - st_e )))"
    fi
}
# rsc_cancel_closing [<started_iso>] — the post-run closing comment's sentence.
rsc_cancel_closing() {
    printf '**zbuild pipeline %s.** State was persisted — re-add `zbuild-run` to resume.' "$(rsc_cancel_status "${1:-}")"
}

# ─── rsc_finalize_body <body> <result> (#2145) ──────────────────────────────
# The runner's tail loop dies with the job on a 360-minute cancel, so the
# post-run step finishes the comment itself: the header's **running** becomes
# the result, the `current:` line goes, and a closing line says what to do.
# #2166: GitHub says `cancelled` for the ceiling AND for a hand cancel; the
# clock tells them apart. <started_iso> is optional — without it the wording
# stays neutral rather than claiming a ceiling that was hours away.
rsc_finalize_body() {
    local body="$1" result="${2:-}" started="${3:-}" status closing=""
    case "$result" in
        cancelled)
            status="$(rsc_cancel_status "$started")"
            closing="**${status}** — state persisted — re-add \`zbuild-run\` to resume" ;;
        "") status="finished" ;;
        *)  status="$result" ;;
    esac
    # The closing line is appended only when this call flipped **running**:
    # a body the runner already finished (or post-run already finalized) is
    # returned unchanged, so two finalizers cannot stack two closing lines.
    printf '%s\n' "$body" | awk -v st="$status" -v closing="$closing" '
        NR <= 3 && /· \*\*running\*\*/ { sub(/\*\*running\*\*/, "**" st "**"); hit = 1 }
        /^current: / { next }
        { print }
        END { if (hit && closing != "") print closing }'
}
