#!/usr/bin/env bash
# plugins/tool/test/lib/report.sh — the suite's output, events, failures summary and timing (moved from plugin.sh, #2565:
# plugin.sh under 500 lines).
#
# Sourced by plugin.sh after its bootstrap. Sourced library: no set -euo.

[[ -n "${_ZBUILD_TEST_REPORT_LOADED:-}" ]] && return 0
_ZBUILD_TEST_REPORT_LOADED=1

# #2573 (ADR-054): the suite's marker and tally lines are read by the one reader.
# shellcheck source=../../../../scripts/lib/test-output-read.sh
declare -F zb_test_output_normalize >/dev/null 2>&1 \
    || source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/test-output-read.sh"

# ─── _test_write_output_log <path> <raw_output> ─────────────────────────────
# The suite's raw output, sanitized, replaced each run (#2180). Bounded by
# ZBUILD_TEST_OUTPUT_MAX_BYTES (default 4 MiB): the TAIL is kept, because a
# suite that dies mid-way says why at the end, and the truncation is stated —
# a silently clipped log reads as a complete one. Best-effort throughout: a
# diagnostic artifact must never change the stage's verdict.
_test_write_output_log() {
    local path="${1:-}" raw="${2:-}"
    [[ -n "$path" ]] || return 0
    local cap="${ZBUILD_TEST_OUTPUT_MAX_BYTES:-4194304}"
    [[ "$cap" =~ ^[0-9]+$ ]] || cap=4194304
    mkdir -p "$(dirname "$path")" 2>/dev/null || true
    local clean
    if declare -F _zbuild_sanitize_test_output >/dev/null 2>&1; then
        clean="$(_zbuild_sanitize_test_output <<< "$raw" 2>/dev/null || printf '%s' "$raw")"
    else
        clean="$raw"
    fi
    local n=${#clean}
    {
        if (( n > cap )); then
            printf '[… %s of %s bytes truncated — the tail is kept, it is where a dying suite says why]\n' \
                "$(( n - cap ))" "$n"
            printf '%s\n' "${clean: -$cap}"
        else
            printf '%s\n' "$clean"
        fi
    } > "$path" 2>/dev/null || true
    return 0
}

# ─── _test_extract_failing_blocks <raw_output> ──────────────────────────────
# Everything the suite printed between a file's FAIL marker and the next tier
# summary — the failing file's own output, verbatim (#2183). The extractor that
# feeds the SUMMARY is deliberately lossy (80 lines, matched patterns); this is
# not: a failure nobody has seen before does not match a pattern, which is
# exactly when it is needed.
_test_extract_failing_blocks() {
    zb_test_output_normalize "${1:-}" | awk -v mre="$ZB_TEST_MARKER_ERE" -v sre="$ZB_TEST_TALLY_ERE" '
        $0 ~ mre { inblk = 1; print; next }
        $0 ~ sre { inblk = 0; next }
        inblk { print }
    ' 2>/dev/null || true
}

# ─── _test_emit_io_end ───────────────────────────────────────────────────────
# #497: close the stage-io banner pair opened by stage_io_begin at the start of
# _test_run_inner. Computes wall duration from $t0_us, then calls stage_io_end
# with the derived one-line summary as --output. Best-effort — failures are
# swallowed so they can never destabilize the test verdict path. Skips entirely
# when seq is empty (begin was suppressed, e.g. no template destinations).
# Usage: _test_emit_io_end <seq> <t0_us> <verdict> <exit_code> <passed> <failed> <summary>
_test_emit_io_end() {
    local seq="$1" t0_us="$2" verdict="$3" exit_code="$4"
    local passed="$5" failed="$6" summary="$7"
    [[ -z "$seq" ]] && return 0
    local t1_us="${EPOCHREALTIME/./}"
    local dur_ms=$(( (10#${t1_us} - 10#${t0_us}) / 1000 ))
    (( dur_ms < 0 )) && dur_ms=0
    stage_io_end --stage test --kind command --seq "$seq" \
        --output "$summary" \
        --exit-code "$exit_code" \
        --duration-ms "$dur_ms" \
        --metadata "verdict=$verdict" \
        --metadata "passed=$passed" \
        --metadata "failed=$failed" \
        --metadata "exit_code=$exit_code" 2>/dev/null || true
    return 0
}

# ─── _test_emit_failures_summary (#511 F2, ADR-055 §9) ──────────────────────
# This stage's SUMMARY output. Written on EVERY terminal verdict — pass, fail
# and error alike — because §9 (amended #1988) makes absence illegitimate: "this
# stage ran and found nothing" and "this stage published nothing" are different
# facts, and if the file may be missing the pipeline cannot tell them apart. A
# summary states what the stage DID, not only what went wrong, so a passing run
# still reports the suite it ran and the counts it saw.
#
# This inverts the older #511 F2 "missing == empty" contract, and the clear-on-
# non-fail step it needed goes with it: when every run rewrites the file, a
# stale summary from a previous iter can no longer render as a current finding.
#
# Size cap: 8 KB (summaries are injected as prompt context and must stay small).
# When truncated, append a `[truncated]` marker so the reader knows the slice is
# partial.
#
# Usage: _test_emit_failures_summary <out_path> <verdict> <failed_count>
#                                    <exit_code> <raw_output> [passed_count]
_test_emit_failures_summary() {
    local out_path="$1" verdict="$2" failed_count="$3" exit_code="$4" raw_output="$5"
    local passed_count="${6:-}" findings_md="${7:-}"

    # Extract failing test lines (best-effort across common formats).
    # We keep matched lines verbatim — the build agent reads them as-is.
    local extracted=""
    if [[ "$verdict" != "pass" ]]; then
        # #2124: what the builder needs comes FIRST — the assertion failures
        # (✗/✘, each with its detail line) and the tier's FAIL/TIMEOUT markers —
        # then the broad matches. A replayed nested run puts dozens of
        # Error:/FAIL lines ahead of the one ✗ that matters, and a first-60
        # window of the broad pattern shipped a summary with no ✗ in it.
        # #2138: and the REASON a file died. Run 35355623656's builder was
        # told "review-lens-test.sh FAIL" and nothing else — the raw output
        # ended "line 557: …: command not found" after 60 ✓ lines, which no
        # pattern matched. Per tier FAIL/TIMEOUT block: bash's own error
        # shapes, lint findings (SCnnnn / "In <file> line N:"), and the last
        # 6 non-blank lines of the block — the tail is where bash puts why.
        local _ex_first _ex_rest _ex_tail
        # #2573: marker and tally lines in the shared reader's one form first.
        raw_output="$(zb_test_output_normalize "$raw_output")"
        # #2460: each failure with its whole message — every line after the ✗
        # up to the next check, a blank line or the tally of its file — on one
        # line, its line breaks shown as ⏎, so no continued line is lost or
        # merged away as a repeat.
        _ex_first="$(printf '%s\n' "$raw_output" | awk -v nre="$ZB_TEST_NAMED_LINE_ERE" '
            function flush() { if (blk != "") print blk; blk = "" }
            { line = $0; sub(/^[[:space:]]+/, "", line) }
            line ~ /^(✗|✘)/ { flush(); blk = $0; next }
            blk != "" && (line == "" || line ~ /^✓/ || line ~ /^[0-9]+ of [0-9]+ tests failed/ || line ~ /^All [0-9]+ tests passed/ || $0 ~ nre) { flush(); next }
            blk != "" { blk = blk " ⏎ " line }
            END { flush() }' 2>/dev/null | head -n 40 || true)"  # sigpipe-ok: || true, and an explicit empty-check follows
        # sigpipe-ok: || true
        _ex_first="${_ex_first}${_ex_first:+$'\n'}$(printf '%s' "$raw_output" \
            | grep -E "$ZB_TEST_MARKER_ERE" | head -n 10 || true)"
        _ex_tail="$(printf '%s\n' "$raw_output" | awk -v mre="$ZB_TEST_MARKER_ERE" -v sre="$ZB_TEST_TALLY_ERE" '
            function flush(   i, n) {
                n = cnt < 6 ? cnt : 6
                for (i = cnt - n + 1; i <= cnt; i++) print tail[i]
                cnt = 0
            }
            $0 ~ mre { if (inblk) flush(); inblk = 1; cnt = 0; next }
            $0 ~ sre { if (inblk) flush(); inblk = 0; next }
            inblk && NF {
                if ($0 ~ /line [0-9]+: |command not found|syntax error|No such file|unbound variable|SC[0-9][0-9][0-9][0-9]|^In .* line [0-9]+:/) print
                tail[++cnt] = $0
            }
            END { if (inblk) flush() }' 2>/dev/null || true)"
        # sigpipe-ok: || true, and an explicit empty-check follows
        _ex_rest="$(printf '%s' "$raw_output" \
            | grep -E '(FAIL|✗|✘|Error:|Failure:|AssertionError|expected|Expected)' \
            | head -n 60 || true)"
        extracted="$(printf '%s\n%s\n%s' "$_ex_first" "$_ex_tail" "$_ex_rest" | awk 'NF && !seen[$0]++' | head -n 80 || true)"  # sigpipe-ok: || true

        # If nothing matched but verdict says fail/error, fall back to first ~40
        # lines of raw output so the build agent at least sees something.
        if [[ -z "$extracted" ]]; then
            extracted="$(printf '%s' "$raw_output" | head -n 40 || true)"  # sigpipe-ok: || true, empty-check follows
        fi

        # Whitespace-only extraction carries no signal — treat as none, and let
        # the no-output branch below say so explicitly. §9 forbids the file
        # being absent; it does not permit it to be empty-but-present.
        local _nows
        _nows="$(printf '%s' "$extracted" | tr -d '[:space:]')"
        [[ -z "$_nows" ]] && extracted=""
    fi

    mkdir -p "$(dirname "$out_path")" 2>/dev/null || true
    local tmp; tmp="$(mktemp "${out_path}.XXXXXX" 2>/dev/null || echo "${out_path}.tmp")"
    local _head; _test_summary_head_v _head "$verdict" "$passed_count" "$failed_count" "$exit_code" "$findings_md"
    {
        printf '# Test stage summary\n\n'
        printf -- '- %s\n' "$_head"
        # `--` is mandatory: bash's printf option-parses a format beginning with
        # `-` and dies with "invalid option". The group redirects stderr to
        # /dev/null, so without this the metadata lines vanished in silence —
        # every summary shipped as heading + body with no verdict or counts.
        printf -- '- verdict: %s\n' "$verdict"
        if [[ -n "$passed_count" ]]; then
            printf -- '- passed: %s\n' "$passed_count"
        fi
        printf -- '- failed: %s\n' "$failed_count"
        printf -- '- exit_code: %s\n\n' "$exit_code"
        if [[ "$verdict" == "pass" ]]; then
            printf 'The suite ran to completion with no failing assertions.\n'
        elif [[ -n "$extracted" ]]; then
            # $( ) strips the section's trailing newlines — restore the gap.
            [[ -n "$findings_md" ]] && printf '%s\n\n' "$findings_md"
            printf '## Failing lines (extracted)\n\n'
            printf '```\n%s\n```\n' "$extracted"
        else
            printf 'The suite produced no readable test output, so no failing\n'
            printf 'assertions could be extracted. Treat the verdict above as the\n'
            printf 'only reliable signal from this run.\n'
        fi
    } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }

    # 8 KB cap with truncation marker.
    local _max=8192
    local _bytes
    _bytes="$(wc -c 2>/dev/null < "$tmp" | tr -d ' ')"
    if [[ "$_bytes" =~ ^[0-9]+$ && "$_bytes" -gt "$_max" ]]; then
        local _tmp2; _tmp2="$(mktemp "${out_path}.XXXXXX" 2>/dev/null || echo "${out_path}.tmp2")"
        head -c "$_max" "$tmp" > "$_tmp2" 2>/dev/null
        printf '\n\n[truncated]\n' >> "$_tmp2"
        mv -f "$_tmp2" "$tmp"
    fi

    mv -f "$tmp" "$out_path" 2>/dev/null || rm -f "$tmp"
    return 0
}

# ─── _test_summarize_timing (#1058 Phase A) ──────────────────────────────────
# _test_timing_mark_run <log> <mode> <bytes_before> (#2167) — after a run,
# label the rows it appended with a `run <n> <mode>` line above them. A run
# that appended nothing (a suite that writes no timing) leaves the log alone,
# so a run with no measurements adds no artifact.
_test_timing_mark_run() {
    local log="$1" mode="${2:-full}" before="${3:-0}" n=0 tmp
    [[ -f "$log" ]] || return 0
    [[ "$before" =~ ^[0-9]+$ ]] || before=0
    local after; after="$(wc -c 2>/dev/null < "$log" | tr -d ' ')"
    [[ "$after" =~ ^[0-9]+$ && "$after" -gt "$before" ]] || return 0
    n="$(grep -c '^run ' "$log" 2>/dev/null || true)"; [[ "$n" =~ ^[0-9]+$ ]] || n=0
    tmp="$(mktemp "${log}.XXXXXX" 2>/dev/null)" || return 0
    {
        [[ "$before" -gt 0 ]] && head -c "$before" "$log"
        printf 'run %d %s\n' "$((n + 1))" "$mode"
        tail -c +"$((before + 1))" "$log"
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$log" || rm -f "$tmp"
    return 0
}

# Parse a run-tests.sh timing log into a compact JSON object for test-results.json.
# #2167: the log holds every run's block; the summary describes the LAST one.
# The log holds two line kinds (whitespace-separated):
#   tier <ms> <name>
#   file <ms> <path>
# Emits a JSON object:
#   { "tiers": {"<name>": <total_ms>, ...},
#     "slowest_files": [ {"file": "<path>", "ms": <ms>}, ... (top 10) ] }
# Per-tier value SUMS all `tier` lines for that name (a tier may run more than
# once across --tier all paths). slowest_files is the top-10 `file` lines by ms,
# descending. Emits nothing (return 1) when the log is absent/empty/unparseable,
# so the caller omits the `timing` field entirely rather than writing `null`.
# Usage: _test_summarize_timing <timing_log_path>
_test_summarize_timing() {
    local log="$1"
    [[ -n "$log" && -s "$log" ]] || return 1
    local _out
    _out="$(awk '
        $1 == "run" { delete tier; n = 0; have = 0; next }
        $1 == "tier" && $2 ~ /^[0-9]+$/ { tier[$3] += $2; have = 1 }
        $1 == "file" && $2 ~ /^[0-9]+$/ {
            # path may contain spaces: rejoin fields 3..NF
            p = $3
            for (i = 4; i <= NF; i++) p = p " " $i
            fms[++n] = $2; fpath[n] = p; have = 1
        }
        END {
            if (!have) exit 1
            # jq -n consumes this as two streams via --slurpfile-style stdin?
            # Simpler: emit TSV the jq filter below reshapes. tier rows first.
            for (t in tier) printf "T\t%s\t%d\n", t, tier[t]
            for (i = 1; i <= n; i++) printf "F\t%s\t%d\n", fpath[i], fms[i]
        }
    ' "$log" 2>/dev/null)" || return 1
    [[ -n "$_out" ]] || return 1

    printf '%s\n' "$_out" | jq -Rn '
        [inputs | split("\t")] as $rows
        | {
            tiers: ( [ $rows[] | select(.[0] == "T") | {key: .[1], value: (.[2]|tonumber)} ] | from_entries ),
            slowest_files: ( [ $rows[] | select(.[0] == "F") | {file: .[1], ms: (.[2]|tonumber)} ]
                             | sort_by(-.ms) | .[0:10] )
          }
    ' 2>/dev/null || return 1
}
