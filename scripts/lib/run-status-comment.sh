#!/usr/bin/env bash
# scripts/lib/run-status-comment.sh — one live GitHub issue comment per run
# (#2131, ADR-064; keeper e-1 lifted from legacy/scripts/lib/pipeline-github.sh).
#
# A sidecar the runner spawns beside a run and reaps in its EXIT trap. It READS
# events.jsonl (never writes it — it has no path to the event bus at all) and
# keeps a single comment on the run's issue edited in place: header pinned at
# the top, one row per stage dispatch, newest first, bounded under GitHub's
# 65,536-byte limit. Every GitHub failure is logged to status-comment.log and
# ignored: the run never fails because GitHub did.
#
# Source-only library (`rsc_*`) with a `main` when executed:
#   bash run-status-comment.sh --events <jsonl> --state-dir <dir> --parent-pid <pid> [--once]
#
# No `set -e` at top level — sourced into the runner, which owns its options.

[[ -n "${_ZBUILD_RUN_STATUS_COMMENT_LOADED:-}" ]] && return 0 2>/dev/null
_ZBUILD_RUN_STATUS_COMMENT_LOADED=1

_RSC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RSC_ROOT="$(cd "$_RSC_DIR/../.." && pwd)"
# shellcheck source=./helpers.sh
[[ -n "${_ZBUILD_HELPERS_LOADED:-}" ]] || source "$_RSC_ROOT/scripts/lib/helpers.sh"
# shellcheck source=./identity.sh
source "$_RSC_ROOT/scripts/lib/identity.sh"

# Tunables — one place. Tests shrink the intervals; operators rarely touch them.
: "${ZBUILD_STATUS_COMMENT_MIN_INTERVAL:=5}"    # seconds between PATCHes (coalesce)
: "${ZBUILD_STATUS_COMMENT_POLL:=1}"            # seconds between events.jsonl checks
: "${ZBUILD_STATUS_COMMENT_GH_TIMEOUT:=30}"     # seconds per gh call
: "${ZBUILD_STATUS_COMMENT_MAX_BYTES:=60000}"   # GitHub rejects > 65,536; keep headroom
: "${ZBUILD_STATUS_COMMENT_SUMMARY_CHARS:=200}" # first line of a stage summary
_RSC_MARKER_PREFIX='<!-- zbuild-run-status run_id='

# ─── rsc_log <state_dir> <msg> — the sidecar's only sink ─────────────────────
rsc_log() {
    local state_dir="$1"; shift
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$state_dir/status-comment.log" 2>/dev/null || true
}

# ─── rsc_byte_len <string> — bytes, not chars (the GitHub limit is bytes) ───
rsc_byte_len() {
    local LC_ALL=C
    local s="$1"
    printf '%s' "${#s}"
}

# ─── rsc_enabled <state_dir> <repo_root> — every reason NOT to post ─────────
# Logs the first failing gate. The repo-slug gate is what keeps a test's temp
# repository (no github.com origin) from ever reaching GitHub.
rsc_enabled() {
    local state_dir="$1" repo_root="${2:-}"
    local why=""
    if [[ "${ZBUILD_STATUS_COMMENT:-1}" == "0" ]]; then why="ZBUILD_STATUS_COMMENT=0"
    elif [[ "${NO_GITHUB:-}" == "true" ]]; then why="NO_GITHUB=true"
    elif ! [[ "${ZBUILD_ISSUE:-0}" =~ ^[1-9][0-9]*$ ]]; then why="no issue number (goal run)"
    elif ! command -v gh >/dev/null 2>&1; then why="gh not on PATH"
    elif ! gh auth status >/dev/null 2>&1; then why="gh auth status failed"
    elif ! zbuild_repo_slug "$repo_root" >/dev/null 2>&1; then why="origin is not a github.com repository"
    fi
    if [[ -n "$why" ]]; then
        rsc_log "$state_dir" "disabled: $why"
        return 1
    fi
    return 0
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

# HH:MM:SSZ from an ISO timestamp.
_rsc_clock() { local t="${1#*T}"; printf '%sZ' "${t%%.*}" | sed 's/ZZ$/Z/'; }

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
        printf '**%s reused** · iter %s · %s · %s from iter %s (%s)' \
            "$seq" "$it" "$(_rsc_clock "$started")" "$members" "$from" "$reason"
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
    line="**${seq} ${stage}**"
    [[ -n "$iter" ]] && line+=" · iter ${iter}"
    line+=" · $(_rsc_clock "$started")"
    if [[ -z "$verdict" ]]; then
        line+=" → running"
        local inputs; inputs="$(rsc_row_inputs_line "$state_dir" "$stage")"
        [[ -n "$inputs" ]] && line+=" · inputs: ${inputs}"
        [[ -n "$summaries" ]] && line+=" · ${summaries} stage summaries (${resolve} RESOLVE)"
    else
        [[ -z "$ended" ]] && ended="$started"
        line+=" → $(_rsc_clock "$ended") ($(rsc_duration "$started" "$ended"))"
        local v="$verdict"
        [[ "$v" != "pass" && -n "$rc" && "$rc" != "0" ]] && v+=" rc=${rc}"
        line+=" · **${v}**"
        local summary; summary="$(rsc_row_summary_line "$state_dir" "$stage")"
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
    updated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    printf '%s%s -->\n' "$_RSC_MARKER_PREFIX" "$run_id"
    printf '### zbuild run `%s` · issue #%s · **%s**\n' "$run_id" "$issue" "$status"
    local meta="engine \`${sha}\`"
    [[ -n "$branch" ]] && meta+=" (\`${branch}\`)"
    meta+=" · started ${started} · updated ${updated}"
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
    rows_file="$(mktemp "${TMPDIR:-$state_dir}/rsc-rows.XXXXXX")" || return 1
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        rsc_render_row "$state_dir" "$(jq -c --arg k "$key" '.rows[$k]' <<< "$model")"
        printf '\n'
    done < <(jq -r '.order | reverse | .[]' <<< "$model") > "$rows_file"
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

# ═══ GitHub I/O — advisory: every function here returns 0 ═══════════════════

# ─── rsc_gh <state_dir> <stdout_file> <args...> — gh under a watchdog ───────
# `timeout(1)` is not on macOS; the runner's bg+sleep+kill pattern is. The
# body travels as `-f body=@<file>` — a background job's stdin is /dev/null,
# and a 60 KB comment must never be an argv word. Returns gh's rc (124 on
# timeout) for the caller's LOG, never its exit; stderr is kept in
# _RSC_GH_ERR so a caller can tell a 404 from the rest.
_RSC_GH_ERR=""
rsc_gh() {
    local state_dir="$1" out="$2"; shift 2
    local err rc=0 pid wd
    _RSC_GH_ERR=""
    err="$(mktemp "${TMPDIR:-$state_dir}/rsc-gh-err.XXXXXX")" || return 1
    gh "$@" > "$out" 2> "$err" </dev/null &
    pid=$!
    # The watchdog must not inherit a caller's `$(...)` capture pipe: the
    # substitution would then block until the sleep ended, turning every
    # call into a GH_TIMEOUT-long wait.
    ( sleep "$ZBUILD_STATUS_COMMENT_GH_TIMEOUT"; kill -TERM "$pid" 2>/dev/null || true ) >/dev/null 2>&1 </dev/null &
    wd=$!
    wait "$pid" 2>/dev/null; rc=$?
    if kill -0 "$wd" 2>/dev/null; then
        kill -TERM "$wd" 2>/dev/null || true
        wait "$wd" 2>/dev/null || true
    else
        # Watchdog already fired → the call was cut.
        rc=124
    fi
    _RSC_GH_ERR="$(head -c 400 "$err" 2>/dev/null | tr '\n' ' ')"
    if [[ $rc -ne 0 ]]; then
        local detail="${_RSC_GH_ERR:0:200}"
        [[ $rc -eq 124 ]] && detail="timeout after ${ZBUILD_STATUS_COMMENT_GH_TIMEOUT}s ${detail}"
        rsc_log "$state_dir" "gh $1 $2 rc=$rc ${detail}"
    fi
    rm -f "$err"
    return $rc
}

# ─── rsc_id_save / rsc_id_load — <state_dir>/status-comment.json ────────────
# tmp+mv (legacy e-1): a concurrent reader never sees a truncated id.
rsc_id_save() {
    local state_dir="$1" slug="$2" issue="$3" run_id="$4" id="$5" tmp
    tmp="$(mktemp "$state_dir/status-comment.json.XXXXXX")" || return 0
    jq -n --arg slug "$slug" --arg issue "$issue" --arg run_id "$run_id" --arg id "$id" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{schema_version:1, repo:$slug, issue:($issue|tonumber), run_id:$run_id, comment_id:($id|tonumber), created_at:$at}' \
        > "$tmp" 2>/dev/null && mv -f "$tmp" "$state_dir/status-comment.json" || rm -f "$tmp"
    return 0
}
rsc_id_load() {
    local f="$1/status-comment.json"
    [[ -s "$f" ]] || return 0
    jq -r '.comment_id // empty' "$f" 2>/dev/null || true
}

# ─── rsc_comment_find <state_dir> <slug> <issue> <run_id> — by marker ───────
# Only when the id file is gone (resume, lost create response): this is what
# makes "exactly one comment per run" hold across a restart.
rsc_comment_find() {
    local state_dir="$1" slug="$2" issue="$3" run_id="$4" out id=""
    out="$(mktemp "${TMPDIR:-$state_dir}/rsc-find.XXXXXX")" || return 0
    if rsc_gh "$state_dir" "$out" api --paginate "repos/${slug}/issues/${issue}/comments" \
            --jq "[.[] | select(.body | contains(\"${_RSC_MARKER_PREFIX}${run_id} -->\")) | .id] | first // empty" 2>/dev/null; then
        # --paginate may print one id per page; the first non-empty line wins.
        id="$(awk 'NF { print; exit }' "$out" 2>/dev/null || true)"
        # A fake or an older gh may hand back the raw page; select in-process.
        if [[ -n "$id" && ! "$id" =~ ^[0-9]+$ ]]; then
            id="$(jq -r --arg m "${_RSC_MARKER_PREFIX}${run_id} -->" \
                '[.[]? | select((.body // "") | contains($m)) | .id] | first // empty' "$out" 2>/dev/null || true)"
        fi
    fi
    rm -f "$out"
    [[ "$id" =~ ^[0-9]+$ ]] && printf '%s' "$id"
    return 0
}

# ─── rsc_comment_create / rsc_comment_patch ─────────────────────────────────
rsc_comment_create() {
    local state_dir="$1" slug="$2" issue="$3" body_file="$4" out id=""
    out="$(mktemp "${TMPDIR:-$state_dir}/rsc-create.XXXXXX")" || return 0
    if rsc_gh "$state_dir" "$out" api "repos/${slug}/issues/${issue}/comments" -f "body=@${body_file}" --jq .id; then
        id="$(tr -d '[:space:]' < "$out")"
    fi
    rm -f "$out"
    [[ "$id" =~ ^[0-9]+$ ]] && printf '%s' "$id"
    return 0
}
rsc_comment_patch() {
    local state_dir="$1" slug="$2" id="$3" body_file="$4" out rc=0
    out="$(mktemp "${TMPDIR:-$state_dir}/rsc-patch.XXXXXX")" || return 0
    rsc_gh "$state_dir" "$out" api "repos/${slug}/issues/comments/${id}" -X PATCH -f "body=@${body_file}" || rc=$?
    # A 404 means the comment is gone (deleted by a human); report it so the
    # caller can re-create ONCE.
    if [[ $rc -ne 0 && "$_RSC_GH_ERR" == *"404"* ]]; then rc=44; fi
    rm -f "$out"
    return $rc
}

# ─── rsc_upsert <state_dir> <slug> <issue> <run_id> <body_file> ─────────────
# id known → PATCH; else marker search → PATCH; else POST. A PATCH 404 clears
# the id and allows one re-create per process, so a vandalised comment cannot
# fan out. Always returns 0.
_RSC_RECREATED=0
_RSC_GIVEN_UP=0
rsc_upsert() {
    local state_dir="$1" slug="$2" issue="$3" run_id="$4" body_file="$5"
    local id rc=0
    [[ "$_RSC_GIVEN_UP" -eq 1 ]] && return 0
    id="$(rsc_id_load "$state_dir")"
    if [[ -z "$id" ]]; then
        id="$(rsc_comment_find "$state_dir" "$slug" "$issue" "$run_id")"
        [[ -n "$id" ]] && rsc_id_save "$state_dir" "$slug" "$issue" "$run_id" "$id"
    fi
    if [[ -n "$id" ]]; then
        rsc_comment_patch "$state_dir" "$slug" "$id" "$body_file"; rc=$?
        if [[ $rc -eq 0 ]]; then return 0; fi
        if [[ $rc -ne 44 ]]; then return 0; fi
        # Gone. Forget it; re-create at most once.
        rm -f "$state_dir/status-comment.json"
        if [[ "$_RSC_RECREATED" -ge 1 ]]; then
            _RSC_GIVEN_UP=1
            rsc_log "$state_dir" "comment ${id} gone again; giving up for this run"
            return 0
        fi
        _RSC_RECREATED=1
        rsc_log "$state_dir" "comment ${id} gone (404); re-creating once"
    fi
    id="$(rsc_comment_create "$state_dir" "$slug" "$issue" "$body_file")"
    if [[ -n "$id" ]]; then
        rsc_id_save "$state_dir" "$slug" "$issue" "$run_id" "$id"
        [[ "${GITHUB_ACTIONS:-}" == "true" ]] && \
            echo "::notice title=zbuild status comment::https://github.com/${slug}/issues/${issue}#issuecomment-${id}"
    fi
    return 0
}

# ═══ Loop / lifecycle ═══════════════════════════════════════════════════════

_RSC_STOP=0
_rsc_on_stop() { _RSC_STOP=1; }

# ─── rsc_flush <events> <state_dir> <slug> <issue> <run_id> [override] ──────
# Render → redact → upsert. A redactor failure posts nothing (logged).
rsc_flush() {
    local events="$1" state_dir="$2" slug="$3" issue="$4" run_id="$5" override="${6:-}"
    local body_file
    body_file="$(mktemp "${TMPDIR:-$state_dir}/rsc-body.XXXXXX")" || return 0
    if ! rsc_outbound_body "$events" "$state_dir" "$override" > "$body_file"; then
        rsc_log "$state_dir" "redaction_failed: body not posted"
        rm -f "$body_file"; return 0
    fi
    rsc_upsert "$state_dir" "$slug" "$issue" "$run_id" "$body_file"
    rm -f "$body_file"
    return 0
}

_rsc_has_type() {   # _rsc_has_type <events> <regex-of-types>
    [[ -s "$1" ]] && grep -qE "\"type\":\"($2)\"" "$1" 2>/dev/null
}

# ─── rsc_tail_loop <events> <state_dir> <parent_pid> <slug> <issue> <run_id> ─
# Poll (not tail -F: the file may not exist yet, and a size check is enough at
# this cadence). No GitHub call before pipeline.start|resume — a refused lock
# or a preflight return between spawn and start must never create a comment.
# A terminal event flushes at once but does NOT end the loop: always-run
# stages emit after pipeline.end, and the runner's EXIT trap reaps us after
# them. TERM/INT → final render; parent death → final render marked as such.
rsc_tail_loop() {
    local events="$1" state_dir="$2" parent="$3" slug="$4" issue="$5" run_id="$6"
    local last_size=-1 size dirty=0 seen_start=0 terminal_seen=0 last_flush=0 now flushed_once=0
    trap '_rsc_on_stop' TERM INT
    trap '' HUP
    while :; do
        if [[ "$_RSC_STOP" -eq 1 ]]; then
            local ov=""
            _rsc_has_type "$events" 'pipeline\.end|pipeline\.aborted|pipeline\.abort' || ov="interrupted"
            [[ "$seen_start" -eq 1 ]] && rsc_flush "$events" "$state_dir" "$slug" "$issue" "$run_id" "$ov"
            rsc_log "$state_dir" "stopped on signal"
            return 0
        fi
        if [[ -n "$parent" ]] && ! kill -0 "$parent" 2>/dev/null; then
            local ov=""
            _rsc_has_type "$events" 'pipeline\.end|pipeline\.aborted|pipeline\.abort' \
                || ov="interrupted (runner exited without a terminal event)"
            [[ "$seen_start" -eq 1 ]] && rsc_flush "$events" "$state_dir" "$slug" "$issue" "$run_id" "$ov"
            rsc_log "$state_dir" "parent ${parent} gone; final render done"
            return 0
        fi
        size=0; [[ -f "$events" ]] && size="$(wc -c < "$events" 2>/dev/null | tr -d ' ')"
        if [[ "$size" != "$last_size" ]]; then dirty=1; last_size="$size"; fi
        if [[ $dirty -eq 1 && $seen_start -eq 0 ]]; then
            _rsc_has_type "$events" 'pipeline\.start|pipeline\.resume' && seen_start=1
        fi
        local terminal_now=0
        if [[ $dirty -eq 1 && $terminal_seen -eq 0 ]]; then
            if _rsc_has_type "$events" 'pipeline\.end|pipeline\.aborted|pipeline\.abort'; then
                terminal_seen=1; terminal_now=1
            fi
        fi
        now="$(date +%s)"
        if [[ $dirty -eq 1 && $seen_start -eq 1 ]] && \
           [[ $flushed_once -eq 0 || $terminal_now -eq 1 || $(( now - last_flush )) -ge "${ZBUILD_STATUS_COMMENT_MIN_INTERVAL%.*}" ]]; then
            rsc_flush "$events" "$state_dir" "$slug" "$issue" "$run_id"
            dirty=0; flushed_once=1; last_flush="$now"
        fi
        # Interruptible sleep: a TERM lands on `wait`, not inside `sleep`.
        sleep "$ZBUILD_STATUS_COMMENT_POLL" & wait $! 2>/dev/null
    done
}

# ─── main ───────────────────────────────────────────────────────────────────
#   --events <jsonl> --state-dir <dir> [--parent-pid <pid>] [--slug o/r]
#   [--issue N] [--run-id id] [--repo-root <dir>] [--once]
# Identity falls back to status-comment.json, then the environment.
rsc_main() {
    local events="" state_dir="" parent="" slug="" issue="" run_id="" repo_root="" once=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --events) events="${2:-}"; shift 2 ;;
            --state-dir) state_dir="${2:-}"; shift 2 ;;
            --parent-pid) parent="${2:-}"; shift 2 ;;
            --slug) slug="${2:-}"; shift 2 ;;
            --issue) issue="${2:-}"; shift 2 ;;
            --run-id) run_id="${2:-}"; shift 2 ;;
            --repo-root) repo_root="${2:-}"; shift 2 ;;
            --once) once=1; shift ;;
            *) echo "run-status-comment: unknown argument: $1" >&2; return 2 ;;
        esac
    done
    [[ -n "$state_dir" ]] || { echo "run-status-comment: --state-dir required" >&2; return 2; }
    [[ -n "$events" ]] || events="$state_dir/events.jsonl"
    if [[ -s "$state_dir/status-comment.json" ]]; then
        [[ -n "$slug" ]] || slug="$(jq -r '.repo // empty' "$state_dir/status-comment.json" 2>/dev/null || true)"
        [[ -n "$issue" ]] || issue="$(jq -r '.issue // empty' "$state_dir/status-comment.json" 2>/dev/null || true)"
        [[ -n "$run_id" ]] || run_id="$(jq -r '.run_id // empty' "$state_dir/status-comment.json" 2>/dev/null || true)"
    fi
    [[ -n "$issue" ]] || issue="${ZBUILD_ISSUE:-}"
    [[ -n "$run_id" ]] || run_id="${ZBUILD_RUN_ID:-}"
    [[ -n "$slug" ]] || slug="$(zbuild_repo_slug "${repo_root:-$PWD}" 2>/dev/null || true)"
    if [[ -z "$slug" || ! "$issue" =~ ^[1-9][0-9]*$ ]]; then
        rsc_log "$state_dir" "cannot post: slug='${slug}' issue='${issue}'"
        return 0
    fi
    # The summary path resolver lives in the engine; optional (fixtures use
    # the artifacts/<stage>-summary.md fallback).
    if ! declare -F _summaries_stage_summary_path >/dev/null 2>&1; then
        # shellcheck source=../../core/pipeline/input-resolve.sh
        source "$_RSC_ROOT/core/pipeline/input-resolve.sh" 2>/dev/null || true
    fi
    rsc_log "$state_dir" "start: repo=${slug} issue=${issue} run_id=${run_id} parent=${parent:-none} events=${events}"
    if [[ $once -eq 1 ]]; then
        rsc_flush "$events" "$state_dir" "$slug" "$issue" "$run_id"
        return 0
    fi
    rsc_tail_loop "$events" "$state_dir" "$parent" "$slug" "$issue" "$run_id"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    rsc_main "$@"
    exit $?
fi
