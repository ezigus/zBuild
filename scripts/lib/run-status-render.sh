#!/usr/bin/env bash
# scripts/lib/run-status-render.sh — the pure half of the run-status comment
# (#2131, ADR-064): events.jsonl + state dir → markdown body. No gh, no
# network, no writes. Sourced by run-status-comment.sh, which owns the
# GitHub I/O and the loop; split so each side stays under the 500-line mark
# and the renderer can be exercised without a fake `gh`.

[[ -n "${_ZBUILD_RUN_STATUS_RENDER_LOADED:-}" ]] && return 0 2>/dev/null
_ZBUILD_RUN_STATUS_RENDER_LOADED=1

_RSC_RENDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RSC_ROOT="${_RSC_ROOT:-$(cd "$_RSC_RENDER_DIR/../.." && pwd)}"
: "${ZBUILD_STATUS_COMMENT_MAX_BYTES:=60000}"   # GitHub rejects > 65,536; keep headroom
: "${ZBUILD_STATUS_COMMENT_SUMMARY_CHARS:=200}" # first line of a stage summary
_RSC_MARKER_PREFIX='<!-- zbuild-run-status run_id='

# ─── rsc_byte_len <string> — bytes, not chars (the GitHub limit is bytes) ───
rsc_byte_len() {
    local LC_ALL=C
    local s="$1"
    printf '%s' "${#s}"
}

# ─── rsc_rows_json <events_jsonl> — one jq pass: events → header + rows ─────
# Rows are keyed by the envelope `seq` (#2131 stamp). A closer that carries no
# seq — `stage.fail` and the cycle-unit `stage.complete` fire after the label
# is unset — closes the LATEST open row for its stage name. "Open" means no
# verdict yet: `plugin.run.complete` precedes the verdict-bearing closer, so it
# only records an end time. Nested plugin_hook_calls re-emit `plugin.run.start`
# for the same seq; only the first opens a row. Reused members collapse to one
# row per (cycle, iteration), keyed under the cycle's cardinal.
rsc_rows_json() {
    local events="$1"
    [[ -s "$events" ]] || { printf '{"header":{},"rows":{},"order":[],"terminal":{},"pr":{}}'; return 0; }
    jq -cs '
      def open_for($st; $s): [$st.order[] | select($st.rows[.].stage == $s and $st.rows[.].verdict == null)] | last;
      def close($k; $e; $f): if $k == null then . else .rows[$k] |= (. + {ended_ts: $e.ts} + $f) end;
      reduce (.[] | select(type == "object")) as $e (
        {header:{}, rows:{}, order:[], terminal:{}, pr:{}, cardinal:""};
        ($e.type // "") as $t
        | ($e.seq // "") as $seq
        | ($e.data // {}) as $d
        | if $t == "pipeline.start" or $t == "pipeline.resume" then
            .header += {run_id: ($d.run_id // $e.run_id), issue: ($d.issue // ($e.issue|tostring)),
                        engine_sha: ($d.engine_sha // .header.engine_sha // ""),
                        engine_branch: ($d.engine_branch // .header.engine_branch // ""),
                        started: (.header.started // $e.ts)}
          elif $t == "plugin.run.start" and $seq != "" then
            if .rows[$seq] == null then
              .rows[$seq] = {key:$seq, seq:$seq, stage:($e.stage // ""), kind:($d.kind // ""), started_ts:$e.ts,
                             ended_ts:null, verdict:null, rc:null, reason:null, summaries:null, resolve:null}
              | .order += [$seq]
              | (if ($seq|contains(".")) then .cardinal = ($seq|split(".")[0]) else . end)
            else . end
          elif $t == "prompt.summaries.injected" then
            open_for(.; ($d.stage // $e.stage // "")) as $k
            | if $k == null then . else .rows[$k] += {summaries: $d.stages, resolve: $d.resolve} end
          elif $t == "cycle.member.dispatch.complete" then
            (if $seq != "" and .rows[$seq] != null then $seq else open_for(.; ($d.member // "")) end) as $k
            | close($k; $e; {verdict: ($d.verdict // "unknown"), rc: $d.rc, status: $d.status, disposition: $d.disposition})
          elif $t == "stage.complete" then
            (if $seq != "" and .rows[$seq] != null then $seq else open_for(.; ($d.stage // "")) end) as $k
            | close($k; $e; {verdict: ($d.verdict // "pass")})
          elif $t == "stage.fail" then
            (if $seq != "" and .rows[$seq] != null then $seq else open_for(.; ($d.stage // "")) end) as $k
            | close($k; $e; {verdict: "fail", rc: $d.rc, reason: $d.reason})
          elif $t == "plugin.run.error" then
            (if $seq != "" and .rows[$seq] != null then $seq else open_for(.; ($e.stage // "")) end) as $k
            | close($k; $e; {verdict: "error", rc: $d.rc, reason: $d.reason})
          elif $t == "plugin.run.complete" and $seq != "" and .rows[$seq] != null then
            if .rows[$seq].ended_ts == null then .rows[$seq].ended_ts = $e.ts else . end
          elif $t == "cycle.iteration.reused" then
            ("reused:" + ($d.cycle_id // "") + ":" + ($d.iter // "")) as $k
            | if .rows[$k] == null then
                .rows[$k] = {key:$k, kind:"reused", seq:(.cardinal + "." + ($d.iter // "")), iter:($d.iter // ""),
                             started_ts:$e.ts, from_iter:($d.from_iter // ""), reason:($d.reason // ""), members:[]}
                | .order += [$k]
              else . end
            | .rows[$k].members += [($d.member // "")]
          elif $t == "pipeline.aborted" then
            .terminal += {aborted: true, reason: ($d.reason // ""), detail: ($d.detail // ""), status: ($d.status // .terminal.status // "aborted")}
          elif $t == "pipeline.end" then
            .terminal += {ended: true, status: ($d.status // "ended"), end_reason: ($d.reason // "")}
          elif $t == "pipeline.abort" then
            .terminal += {abort_trap: true, status: (.terminal.status // "interrupted")}
          elif $t == "plugin.result" and ((if ($e.plugin // "") != "" then $e.plugin else ($d.plugin // "") end) == "pr-open") and ($d.pr_url // "") != "" then
            .pr = {url: $d.pr_url, number: ($d.pr_number // "")}
          else . end
      )' "$events" 2>/dev/null || printf '{"header":{},"rows":{},"order":[],"terminal":{},"pr":{}}'
}

# ─── rsc_duration <start_ts> <end_ts> — `<1s`, `45s`, `61m33s` ──────────────
rsc_duration() {
    local a="$1" b="$2" s
    s="$(jq -rn --arg a "$a" --arg b "$b" '
        def t: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
        (($b|t) - ($a|t))' 2>/dev/null || echo 0)"
    if [[ "$s" -le 0 ]]; then printf '<1s'
    elif [[ "$s" -lt 60 ]]; then printf '%ds' "$s"
    else printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
    fi
}

# ─── #2145: times in the reader's zone, Eastern by default ──────────────────
# Events and logs stay UTC; the comment is for a person. ZBUILD_STATUS_TZ
# names any zoneinfo zone; America/New_York is labelled "ET" whatever the
# season (EDT/EST is what `%Z` would print, and nobody reads it that way).
_RSC_DEFAULT_TZ="America/New_York"
_rsc_tz() { printf '%s' "${ZBUILD_STATUS_TZ:-$_RSC_DEFAULT_TZ}"; }
_rsc_ceiling_min() { local m="${ZBUILD_STATUS_CEILING_MIN:-360}"; [[ "$m" =~ ^[0-9]+$ ]] || m=360; printf '%s' "$m"; }   # GitHub's job ceiling
_rsc_epoch() {   # ISO-8601 (with or without fractional seconds) → epoch seconds
    jq -rn --arg t "${1:-}" '($t | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch 0)' 2>/dev/null || echo 0
}
_rsc_fmt_local() {   # <epoch> → "9:39 PM ET"
    local epoch="$1" out label tz; tz="$(_rsc_tz)"
    if out="$(TZ="$tz" date -r "$epoch" '+%l:%M %p %Z' 2>/dev/null)"; then :
    else out="$(TZ="$tz" date -d "@$epoch" '+%l:%M %p %Z' 2>/dev/null || true)"; fi
    out="${out# }"
    case "$tz" in
        America/New_York) label="ET" ;;
        America/Chicago)  label="CT" ;;
        America/Denver)   label="MT" ;;
        America/Los_Angeles) label="PT" ;;
        *) label="${out##* }" ;;
    esac
    printf '%s %s' "${out% *}" "$label"
}
# "9:39 PM ET" from an ISO timestamp.
_rsc_clock() { local e; e="$(_rsc_epoch "$1")"; [[ "$e" -gt 0 ]] && _rsc_fmt_local "$e" || printf '%s' "${1:-}"; }
# "1h 20m" from seconds.
_rsc_hm() { local s="$1"; if (( s >= 3600 )); then printf '%dh %02dm' $(( s / 3600 )) $(( (s % 3600) / 60 )); else printf '%dm' $(( s / 60 )); fi; }

# ─── rsc_row_inputs_line <state_dir> <stage> — what the stage was given ─────
rsc_row_inputs_line() {
    local idx="$1/stage-inputs/$2.json" s
    [[ -s "$idx" ]] || return 0
    s="$(jq -r '(.inputs // {}) | keys_unsorted | join(", ")' "$idx" 2>/dev/null || true)"
    printf '%s' "${s:0:120}"
}

# ─── rsc_row_summary_line <state_dir> <stage> — what the stage reported ─────
# ADR-055 §9: the stage's ONE declared summary. Resolved through the manifest
# when the engine libs are reachable, else `artifacts/<stage>-summary.md`.
# First non-empty non-heading line, `- ` stripped, `|` escaped, cut to
# ZBUILD_STATUS_COMMENT_SUMMARY_CHARS.
rsc_row_summary_line() {
    local state_dir="$1" stage="$2" path="" line=""
    if declare -F _summaries_stage_summary_path >/dev/null 2>&1; then
        path="$(_summaries_stage_summary_path "$stage" "${ZBUILD_PLUGINS_ROOT:-$_RSC_ROOT/plugins}" "$state_dir" 2>/dev/null || true)"
    fi
    [[ -n "$path" && -s "$path" ]] || path="$state_dir/artifacts/${stage}-summary.md"
    [[ -s "$path" ]] || return 0
    line="$(awk 'NF && $0 !~ /^#/ { sub(/^- /, ""); print; exit }' "$path" 2>/dev/null || true)"
    line="${line//|/\\|}"
    if [[ "${#line}" -gt "$ZBUILD_STATUS_COMMENT_SUMMARY_CHARS" ]]; then
        line="${line:0:$ZBUILD_STATUS_COMMENT_SUMMARY_CHARS}…"
    fi
    printf '%s' "$line"
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
_rsc_snapshot_load() {   # <state_dir> <run_id>
    local f; f="$(_rsc_snapshot_path "$1")"
    _RSC_SNAP=(); _RSC_SNAP_END=(); _RSC_SNAP_RUN="$2"; _RSC_SNAP_DIRTY=0
    [[ -s "$f" ]] || return 0
    [[ "$(jq -r '.run_id // ""' "$f" 2>/dev/null)" == "$2" ]] || return 0
    local k v
    while IFS=$'\t' read -r k v; do
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
        for k in "${!_RSC_SNAP[@]}"; do printf '%s\t%s\n' "$k" "${_RSC_SNAP[$k]}"; done
    } | jq -Rs --arg run "$_RSC_SNAP_RUN" --argjson ends "${ends:-{\}}" '
        {run_id: $run,
         rows: ([split("\n")[] | select(length > 0) | split("\t") | {key: .[0], value: (.[1:] | join("\t"))}] | from_entries),
         ends: $ends}' \
        > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" || rm -f "$tmp"
    _RSC_SNAP_DIRTY=0
}

# ─── rsc_render_row <state_dir> <row_json> — one markdown line ──────────────
rsc_render_row() {
    local state_dir="$1" row="$2"
    local kind seq stage started ended verdict rc summaries resolve iter line
    kind="$(jq -r '.kind // ""' <<< "$row")"
    seq="$(jq -r '.seq // ""' <<< "$row")"
    started="$(jq -r '.started_ts // ""' <<< "$row")"
    if [[ "$kind" == "reused" ]]; then
        local members from reason it
        members="$(jq -r '.members | join(", ")' <<< "$row")"
        from="$(jq -r '.from_iter // ""' <<< "$row")"; reason="$(jq -r '.reason // ""' <<< "$row")"
        it="$(jq -r '.iter // ""' <<< "$row")"
        printf '**%s** · **%s reused** · iter %s · %s from iter %s (%s)' \
            "$(_rsc_clock "$started")" "$seq" "$it" "$members" "$from" "$reason"
        return 0
    fi
    stage="$(jq -r '.stage // ""' <<< "$row")"
    ended="$(jq -r '.ended_ts // ""' <<< "$row")"
    verdict="$(jq -r '.verdict // ""' <<< "$row")"
    rc="$(jq -r '.rc // ""' <<< "$row")"
    summaries="$(jq -r '.summaries // ""' <<< "$row")"
    resolve="$(jq -r '.resolve // "0"' <<< "$row")"
    # iter = second-to-last segment: `6.1.3` → 1, `1.2` → 1, `6.1.3.2.1` → 2.
    iter=""
    if [[ "$seq" == *.* ]]; then
        local _s="${seq%.*}"; iter="${_s##*.}"
    fi
    # #2145: WHEN first — a reader scanning the feed wants the clock before
    # the name. seq + stage stay bold and second.
    if [[ -z "$verdict" ]]; then
        line="**$(_rsc_clock "$started") → running** · **${seq} ${stage}**"
        [[ -n "$iter" ]] && line+=" · iter ${iter}"
        local inputs; inputs="$(rsc_row_inputs_line "$state_dir" "$stage")"
        [[ -n "$inputs" ]] && line+=" · inputs: ${inputs}"
        [[ -n "$summaries" ]] && line+=" · ${summaries} stage summaries (${resolve} RESOLVE)"
    else
        [[ -z "$ended" ]] && ended="$started"
        line="**$(_rsc_clock "$started") → $(_rsc_clock "$ended") ($(rsc_duration "$started" "$ended"))** · **${seq} ${stage}**"
        [[ -n "$iter" ]] && line+=" · iter ${iter}"
        local v="$verdict"
        [[ "$v" != "pass" && -n "$rc" && "$rc" != "0" ]] && v+=" rc=${rc}"
        line+=" · **${v}**"
        local summary
        # Frozen for THIS close: a retry closes again with a new ended_ts and
        # the line re-freezes from the live file (#2166).
        if [[ -n "${_RSC_SNAP[$seq]+x}" && ( -z "${_RSC_SNAP_END[$seq]+x}" || "${_RSC_SNAP_END[$seq]}" == "$ended" ) ]]; then
            summary="${_RSC_SNAP[$seq]}"
        else
            summary="$(rsc_row_summary_line "$state_dir" "$stage")"
            if [[ -n "$summary" && -n "$_RSC_SNAP_RUN" ]]; then
                _RSC_SNAP["$seq"]="$summary"; _RSC_SNAP_END["$seq"]="$ended"; _RSC_SNAP_DIRTY=1
            fi
        fi
        if [[ -n "$summary" ]]; then
            line+=" — ${summary}"
        else
            local inputs; inputs="$(rsc_row_inputs_line "$state_dir" "$stage")"
            [[ -n "$inputs" ]] && line+=" · inputs: ${inputs}"
        fi
    fi
    printf '%s' "$line"
}

# ─── rsc_render_header <model_json> <state_dir> [status_override] ───────────
rsc_render_header() {
    local model="$1" state_dir="$2" override="${3:-}"
    local run_id issue sha branch started status reason detail pr current updated
    run_id="$(jq -r '.header.run_id // ""' <<< "$model")"
    issue="$(jq -r '.header.issue // ""' <<< "$model")"
    sha="$(jq -r '.header.engine_sha // ""' <<< "$model")"; sha="${sha:0:7}"
    branch="$(jq -r '.header.engine_branch // ""' <<< "$model")"
    started="$(jq -r '.header.started // ""' <<< "$model")"; started="${started%%.*}"; [[ -n "$started" ]] && started="${started%Z}Z"
    status="$(jq -r '.terminal.status // ""' <<< "$model")"
    reason="$(jq -r '.terminal.reason // ""' <<< "$model")"
    detail="$(jq -r '.terminal.detail // ""' <<< "$model")"
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
    pr="$(jq -r '.pr.url // ""' <<< "$model")"
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
    if [[ -n "$reason" ]]; then
        meta+=" · ${reason}"
        [[ -n "$detail" ]] && meta+=" — ${detail}"
    fi
    printf '%s\n' "$meta"
    # Current stage: the newest open row, only while the run is live.
    if [[ "$status" == "running" ]]; then
        current="$(jq -r '. as $m | [$m.order[] | $m.rows[.] | select(.kind != "reused" and .verdict == null)] | last | if . == null then "" else "\(.seq) \(.stage)" end' <<< "$model")"
        [[ -n "$current" ]] && printf 'current: **%s**\n' "$current"
    fi
}

# ─── rsc_bound_body <header> <rows_file> — newest rows first, under the cap ─
# Rows arrive newest-first, one per line. Add until the next would overflow,
# then say how many were dropped — the count is what keeps an elision
# distinguishable from a stage that never ran.
rsc_bound_body() {
    local header="$1" rows_file="$2"
    local max="$ZBUILD_STATUS_COMMENT_MAX_BYTES"
    local total; total="$(wc -l < "$rows_file" | tr -d ' ')"
    local omit_tpl="_… ${total} earlier rows omitted — see run log_"
    local budget=$(( max - $(rsc_byte_len "$header") - $(rsc_byte_len "$omit_tpl") - 4 ))
    local used=0 kept=0 out="" line
    while IFS= read -r line; do
        local n; n=$(( $(rsc_byte_len "$line") + 1 ))
        if [[ $kept -gt 0 && $(( used + n )) -gt $budget ]]; then break; fi
        out+="${line}"$'\n'
        used=$(( used + n )); kept=$(( kept + 1 ))
    done < "$rows_file"
    printf '%s\n%s' "$header" "$out"
    if [[ $kept -lt $total ]]; then
        printf '_… %d earlier rows omitted — see run log_\n' $(( total - kept ))
    fi
}

# ─── rsc_render_body <events_jsonl> <state_dir> [status_override] ───────────
rsc_render_body() {
    local events="$1" state_dir="$2" override="${3:-}"
    local model header rows_file key
    model="$(rsc_rows_json "$events")"
    header="$(rsc_render_header "$model" "$state_dir" "$override")"
    # #2154: rows are rendered in THIS shell (`< <( )`, not a pipe) so the
    # snapshot they freeze survives the loop and is saved once at the end.
    _rsc_snapshot_load "$state_dir" "$(jq -r '.header.run_id // ""' <<< "$model")"
    rows_file="$(mktemp "${TMPDIR:-$state_dir}/rsc-rows.XXXXXX")" || return 1
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        rsc_render_row "$state_dir" "$(jq -c --arg k "$key" '.rows[$k]' <<< "$model")"
        printf '\n'
    done < <(jq -r '.order | reverse | .[]' <<< "$model") > "$rows_file"
    _rsc_snapshot_save "$state_dir"
    rsc_bound_body "$header" "$rows_file"
    rm -f "$rows_file"
}

# ─── rsc_outbound_body <events_jsonl> <state_dir> [status_override] ─────────
# The rendered body after scope redaction (mirror of _stage_io_redact_outbound).
# A redactor failure returns 1 with nothing on stdout: never post unredacted.
rsc_outbound_body() {
    local events="$1" state_dir="$2" override="${3:-}"
    local body manifest="$state_dir/scope-manifest.md"
    body="$(rsc_render_body "$events" "$state_dir" "$override")" || return 1
    if [[ ! -s "$manifest" ]]; then printf '%s' "$body"; return 0; fi
    if ! declare -F apply_scope_redaction >/dev/null 2>&1; then
        # shellcheck source=../../core/redaction/scope-redaction.sh
        source "$_RSC_ROOT/core/redaction/scope-redaction.sh" 2>/dev/null || return 1
    fi
    local tin tout
    tin="$(mktemp "${TMPDIR:-$state_dir}/rsc-in.XXXXXX")" || return 1
    tout="$(mktemp "${TMPDIR:-$state_dir}/rsc-out.XXXXXX")" || { rm -f "$tin"; return 1; }
    printf '%s' "$body" > "$tin"
    if apply_scope_redaction "$tin" "$tout" "$manifest" "" "0" >/dev/null 2>&1; then
        cat "$tout"; rm -f "$tin" "$tout"; return 0
    fi
    rm -f "$tin" "$tout"
    return 1
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
    ceil_e=$(( st_e + $(_rsc_ceiling_min) * 60 ))
    if (( now_e <= 0 )); then printf 'cancelled'; return 0; fi
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
