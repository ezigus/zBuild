#!/usr/bin/env bash
# scripts/lib/run-status-rows.sh — events.jsonl → the run-status comment's
# header and rows (#2131, ADR-064). Pure: one jq pass, no gh, no writes.
# Sourced by run-status-render.sh; split from it to keep each under 500 lines.

[[ -n "${_ZBUILD_RUN_STATUS_ROWS_LOADED:-}" ]] && return 0 2>/dev/null
_ZBUILD_RUN_STATUS_ROWS_LOADED=1

# ─── rsc_rows_json <events_jsonl> — one jq pass: events → header + rows ─────
# Rows are keyed by the envelope `seq` (#2131 stamp). A closer that carries no
# seq — `stage.fail` and the cycle-unit `stage.complete` fire after the label
# is unset — closes the LATEST open row for its stage name. "Open" means no
# verdict yet: `plugin.run.complete` precedes the verdict-bearing closer, so it
# only records an end time. Nested plugin_hook_calls re-emit `plugin.run.start`
# for the same seq; only the first opens a row. Reused members collapse to one
# row per (cycle, iteration), keyed under the cycle's cardinal.
# #2439 (ADR-064, amended 2026-10-31): a stage the engine runs again
# (`stage.retry`) gets one row per try. The retry closes the try's row on the
# outcome it ended on; the next start opens `<seq>~<try>`, and `.cur[<seq>]`
# names the row that the seq's closers now reach.
rsc_rows_json() {
    local events="$1"
    [[ -s "$events" ]] || { printf '{"header":{},"rows":{},"order":[],"terminal":{},"pr":{}}'; return 0; }
    jq -cs '
      def open_for($st; $s): [$st.order[] | select($st.rows[.].stage == $s and $st.rows[.].verdict == null)] | last;
      def cur($st; $q): ($st.cur[$q] // $q);
      def close($k; $e; $f): if $k == null then . else .rows[$k] |= (. + {ended_ts: $e.ts} + $f) end;
      reduce (.[] | select(type == "object")) as $e (
        {header:{}, rows:{}, order:[], terminal:{}, pr:{}, cardinal:"", cur:{}, next_try:{}};
        ($e.type // "") as $t
        | ($e.seq // "") as $seq
        | ($e.data // {}) as $d
        | if $t == "pipeline.start" or $t == "pipeline.resume" then
            .header += {run_id: ($d.run_id // $e.run_id), issue: ($d.issue // ($e.issue|tostring)),
                        engine_sha: ($d.engine_sha // .header.engine_sha // ""),
                        engine_branch: ($d.engine_branch // .header.engine_branch // ""),
                        started: (.header.started // $e.ts)}
          elif ($t == "plugin.run.start" or $t == "parallel.group.start") and $seq != "" then
            (if $t == "parallel.group.start" then .groups[$seq] = true else . end)
            | cur(.; $seq) as $ck
            | if .next_try[$seq] != null and .rows[$ck].verdict != null then
              # The engine ran the stage again: this try has its own row.
              .next_try[$seq] as $nt
              | ($seq + "~" + $nt.try) as $nk
              | .rows[$nk] = (.rows[$ck] + {key:$nk, started_ts:$e.ts, ended_ts:null, verdict:null, rc:null,
                                            reason:null, summaries:null, resolve:null, try:$nt.try, of:$nt.of})
              | .order += [$nk] | .cur[$seq] = $nk | del(.next_try[$seq])
            elif .rows[$seq] == null then
              .rows[$seq] = {key:$seq, seq:$seq, stage:($e.stage // ""), kind:($d.kind // ""), started_ts:$e.ts,
                             ended_ts:null, verdict:null, rc:null, reason:null, summaries:null, resolve:null,
                             # A map member (<group>.<n>) is not a loop iteration.
                             member: (.groups[$seq | split(".")[:-1] | join(".")] // false)}
              | .order += [$seq]
              | (if ($seq|contains(".")) then .cardinal = ($seq|split(".")[0]) else . end)
            elif .rows[$ck].verdict != null then
              # A start the engine did not announce as a retry, after the row
              # ended: the row shows the latest start.
              .rows[$ck] += {started_ts:$e.ts, ended_ts:null, verdict:null, rc:null, reason:null, summaries:null, resolve:null}
            else . end
          elif $t == "stage.retry" then
            (if $seq != "" and .rows[cur(.; $seq)] != null then cur(.; $seq) else open_for(.; ($d.stage // $e.stage // "")) end) as $k
            | if $k == null then . else
                ((($d.try // "2") | tostring | tonumber? // 2) - 1 | tostring) as $prev
                | .rows[$k] |= (. + {ended_ts: $e.ts, verdict: ($d.outcome // "retry"), rc: null,
                                     try: (.try // $prev), of: ($d.of // null)})
                | (if $seq != "" then .next_try[$seq] = {try: ($d.try // "2"), of: ($d.of // null)} else . end)
              end
          elif $t == "stage.previous_work.written" then
            open_for(.; ($d.stage // $e.stage // "")) as $k
            | if $k == null then . else .rows[$k] += {summaries: $d.stages, resolve: $d.failing} end
          elif $t == "cycle.member.dispatch.complete" then
            (if $seq != "" and .rows[cur(.; $seq)] != null then cur(.; $seq) else open_for(.; ($d.member // "")) end) as $k
            | close($k; $e; {verdict: ($d.verdict // "unknown"), rc: $d.rc, status: $d.status, disposition: $d.disposition})
          elif $t == "parallel.group.complete" and $seq != "" and .rows[$seq] != null then
            close($seq; $e; {verdict: ($d.verdict // "pass")})
          elif $t == "parallel.member.dispatch.complete" and $seq != "" and .rows[cur(.; $seq)] != null then
            # A map member: its own name, outcome and summary (ADR-064 §4). It
            # ended when its run did, not when the group was summed up.
            cur(.; $seq) as $k
            | .rows[$k] += {stage: ($d.member // .rows[$k].stage), verdict: ($d.verdict // "unknown"),
                            reason: $d.reason, summary_path: $d.summary_path,
                            ended_ts: (.rows[$k].ended_ts // $e.ts)}
          elif $t == "stage.complete" then
            (if $seq != "" and .rows[cur(.; $seq)] != null then cur(.; $seq) else open_for(.; ($d.stage // "")) end) as $k
            | close($k; $e; {verdict: ($d.verdict // "pass")})
          elif $t == "stage.fail" then
            (if $seq != "" and .rows[cur(.; $seq)] != null then cur(.; $seq) else open_for(.; ($d.stage // "")) end) as $k
            | close($k; $e; {verdict: "fail", rc: $d.rc, reason: $d.reason})
          elif $t == "plugin.run.error" then
            (if $seq != "" and .rows[cur(.; $seq)] != null then cur(.; $seq) else open_for(.; ($e.stage // "")) end) as $k
            | close($k; $e; {verdict: "error", rc: $d.rc, reason: $d.reason})
          elif $t == "plugin.run.complete" and $seq != "" and .rows[cur(.; $seq)] != null then
            cur(.; $seq) as $k
            | if .rows[$k].ended_ts == null then .rows[$k].ended_ts = $e.ts else . end
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
