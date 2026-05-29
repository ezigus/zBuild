#!/usr/bin/env bash
# core/output/stage-io.sh — ADR-015 v1 stage-io capture chokepoint (issue #438)
# All stage I/O artifacts (LLM prompt/response, computed outputs) flow through
# capture_stage_io and are persisted under
# ${ZBUILD_STATE_DIR:-$HOME/.zbuild/state}/artifacts/stage-io/<stage>-<seq>.json
# when the template's stage declares io.destinations. When no destinations
# are configured, this is a hot-path no-op (zero I/O, zero events).
#
# v1 scope: --kind=llm only (router call-site). command/computed deferred to
# downstream issues. Recognized destinations: file (functional), stdout and
# gh_comment (stubs — log "deferred to #440", return 0).
#
# Sourced library: inherits caller's pipefail settings; do not add
# set -euo pipefail at file scope (would mutate caller options).

[[ -n "${_ZBUILD_STAGE_IO_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_IO_LOADED=1

_STAGE_IO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT_FOR_STAGE_IO="$(cd "$_STAGE_IO_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$_ZBUILD_ROOT_FOR_STAGE_IO/scripts/lib/helpers.sh"
# shellcheck source=../event-bus/event-bus.sh
source "$_ZBUILD_ROOT_FOR_STAGE_IO/core/event-bus/event-bus.sh"
# shellcheck source=../pipeline/template.sh
source "$_ZBUILD_ROOT_FOR_STAGE_IO/core/pipeline/template.sh"
# shellcheck source=../redaction/scope-redaction.sh
source "$_ZBUILD_ROOT_FOR_STAGE_IO/core/redaction/scope-redaction.sh"

# ─── capture_stage_io — chokepoint ────────────────────────────────────────────
# Usage:
#   capture_stage_io --stage <id> --kind llm|command|computed \
#                    --input <str> --output <str> \
#                    [--exit-code N] [--duration-ms N] \
#                    [--metadata k=v]...
#
# Returns:
#   0 — success (capture written, or no destinations configured: no-op)
#   2 — usage error (missing required flag, unknown --kind, bad --metadata,
#                    schema-invalid built record)
capture_stage_io() {
    if [[ $# -eq 0 ]]; then
        error "capture_stage_io: usage: --stage <id> --kind llm|command|computed --input <s> --output <s> [--exit-code N] [--duration-ms N] [--metadata k=v]..."
        return 2
    fi

    local stage="" kind=""
    # Sentinels distinguish "flag never provided" from "flag provided with empty value".
    # Empty --input/--output is legitimate (e.g. LLM timeout/refusal producing empty output);
    # we only reject when the flag itself was omitted.
    local input="__ZBUILD_STAGE_IO_UNSET__"
    local output="__ZBUILD_STAGE_IO_UNSET__"
    local exit_code="" duration_ms=""
    # Bash 3.2: no associative arrays — use parallel arrays for metadata
    local -a meta_keys=() meta_vals=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stage)        stage="${2:-}"; shift 2 ;;
            --kind)         kind="${2:-}"; shift 2 ;;
            --input)        input="${2:-}"; shift 2 ;;
            --output)       output="${2:-}"; shift 2 ;;
            --exit-code)    exit_code="${2:-}"; shift 2 ;;
            --duration-ms)  duration_ms="${2:-}"; shift 2 ;;
            --metadata)
                local kv="${2:-}"
                if [[ "$kv" != *"="* ]]; then
                    error "capture_stage_io: malformed --metadata '$kv' (expected key=value)"
                    return 2
                fi
                meta_keys+=("${kv%%=*}")
                meta_vals+=("${kv#*=}")
                shift 2
                ;;
            *)
                error "capture_stage_io: unknown flag '$1'"
                return 2
                ;;
        esac
    done

    # Required-flag validation
    if [[ -z "$stage" ]]; then
        error "capture_stage_io: --stage is required"
        return 2
    fi
    if [[ -z "$kind" ]]; then
        error "capture_stage_io: --kind is required"
        return 2
    fi
    case "$kind" in
        llm|command|computed) : ;;
        *) error "capture_stage_io: unknown --kind '$kind' (valid: llm, command, computed)"; return 2 ;;
    esac
    # --input / --output: empty string is legitimate (e.g. LLM timeout/refusal).
    # Sentinel tracking distinguishes "flag never provided" from "flag with empty value".
    if [[ "$input" == "__ZBUILD_STAGE_IO_UNSET__" ]]; then
        error "capture_stage_io: --input is required"
        return 2
    fi
    if [[ "$output" == "__ZBUILD_STAGE_IO_UNSET__" ]]; then
        error "capture_stage_io: --output is required"
        return 2
    fi
    # Strip sentinel before JSON build (defensive — both should be non-sentinel here).
    [[ "$input" == "__ZBUILD_STAGE_IO_UNSET__" ]] && input=""
    [[ "$output" == "__ZBUILD_STAGE_IO_UNSET__" ]] && output=""

    # ── Destination lookup — no destinations means no-op (hot path) ──────────
    local dests_nl
    dests_nl="$(template_stage_io_dests "$stage" 2>/dev/null || true)"
    if [[ -z "$dests_nl" ]]; then
        return 0
    fi

    # Build comma-delimited dest_list for event payload + iteration list
    local dests_comma
    dests_comma="$(printf '%s' "$dests_nl" | tr '\n' ',' | sed 's/,$//')"

    # ── seq: count existing <stage>-*.json under artifacts/stage-io ──────────
    # TODO: wrap with flock(1) once fanout strategy concurrently captures
    #       (out-of-scope for v1 single-writer LLM path).
    local state_dir="${ZBUILD_STATE_DIR:-$HOME/.zbuild/state}"
    local io_dir="$state_dir/artifacts/stage-io"
    local existing_count=0
    if [[ -d "$io_dir" ]]; then
        # shellcheck disable=SC2012
        existing_count=$(ls -1 "$io_dir"/"${stage}"-*.json 2>/dev/null | wc -l | tr -d ' ')
    fi
    local seq=$((existing_count + 1))

    # ── Build JSON via jq --arg (NEVER string interp) ─────────────────────────
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    local run_id="${ZBUILD_RUN_ID:-}"

    # Build metadata object
    local metadata_json='{}'
    local mi
    for (( mi=0; mi<${#meta_keys[@]}; mi++ )); do
        metadata_json="$(printf '%s' "$metadata_json" | \
            jq -c --arg k "${meta_keys[$mi]}" --arg v "${meta_vals[$mi]}" '. + {($k): $v}')" || {
            error "capture_stage_io: failed to assemble metadata"
            return 2
        }
    done

    # Numeric fields: default exit_code/duration_ms to null when unset.
    local record
    record="$(jq -n \
        --arg schema_version "1" \
        --arg run_id "$run_id" \
        --arg stage "$stage" \
        --arg kind "$kind" \
        --arg seq "$seq" \
        --arg input "$input" \
        --arg output "$output" \
        --arg exit_code "$exit_code" \
        --arg duration_ms "$duration_ms" \
        --argjson metadata "$metadata_json" \
        --arg ts "$ts" \
        '{
            schema_version: ($schema_version|tonumber),
            run_id: $run_id,
            stage: $stage,
            kind: $kind,
            seq: ($seq|tonumber),
            input: $input,
            output: $output,
            exit_code: (if $exit_code == "" then null else ($exit_code|tonumber) end),
            duration_ms: (if $duration_ms == "" then null else ($duration_ms|tonumber) end),
            metadata: $metadata,
            ts: $ts
        }')" || {
        error "capture_stage_io: jq assembly failed"
        eb_emit_event "stage.io.error" "stage=$stage" "reason=jq_assembly_failed" 2>/dev/null || true
        return 2
    }

    # Validate against locked schema
    if ! printf '%s' "$record" | jq -e \
        'has("schema_version") and .schema_version==1 and has("stage") and has("kind") and (.kind|IN("llm","command","computed")) and has("input") and has("output") and has("ts")' \
        >/dev/null 2>&1; then
        eb_emit_event "stage.io.error" "stage=$stage" "reason=schema_invalid" 2>/dev/null || true
        return 2
    fi

    # ── Dispatch to each destination ─────────────────────────────────────────
    local dest artifact_path=""
    local IFS_save="$IFS"; IFS=$'\n'
    local -a dests_arr=()
    # shellcheck disable=SC2206
    dests_arr=( $dests_nl )
    IFS="$IFS_save"

    for dest in "${dests_arr[@]}"; do
        [[ -z "$dest" ]] && continue
        case "$dest" in
            file)
                local _p
                _p="$(_stage_io_to_file "$stage" "$seq" "$record")" || return 2
                [[ -z "$artifact_path" ]] && artifact_path="$_p"
                ;;
            stdout)
                # Banner goes to ZBUILD_STAGE_IO_FD (default 3, opened by the
                # runner at startup; see core/pipeline/runner.sh). This fd
                # survives both the route_to_model stdout-as-response-carrier
                # contention AND the plugin-side `2>/dev/null` suppression
                # that plan and intake plugins wrap around route_to_model /
                # run_captured_command (plugins/agent/plan/plugin.sh:163,
                # plugins/agent/intake/plugin.sh:90). When unset (ad-hoc CLI
                # invocations outside a pipeline), fall back to fd 2 so the
                # banner is still visible somewhere.
                # gh_comment renderer's *inner* call to _stage_io_to_stdout
                # for content production is on stdout (no redirect) and
                # unchanged.
                _stage_io_to_stdout "$record" >&"${ZBUILD_STAGE_IO_FD:-2}" || true
                ;;
            gh_comment)
                _stage_io_to_gh_comment "$record" || true
                ;;
            *)
                # Should be impossible — template loader rejects unknown tokens.
                error "capture_stage_io: unknown destination '$dest' (should have failed at template load)"
                return 2
                ;;
        esac
    done

    # ── Emit stage.io.captured AFTER successful write, BEFORE return ─────────
    eb_emit_event "stage.io.captured" \
        "stage=$stage" \
        "kind=$kind" \
        "seq=$seq" \
        "dest_list=$dests_comma" \
        "artifact_path=${artifact_path:-}" 2>/dev/null || true

    return 0
}

# ─── _stage_io_to_file <stage> <seq> <record_json> ───────────────────────────
# Writes the record to ${ZBUILD_STATE_DIR}/artifacts/stage-io/<stage>-<seq>.json
# atomically. Prints the resulting path on stdout so the caller can include it
# in the stage.io.captured event payload.
_stage_io_to_file() {
    local stage="$1" seq="$2" record="$3"
    local state_dir="${ZBUILD_STATE_DIR:-$HOME/.zbuild/state}"
    local io_dir="$state_dir/artifacts/stage-io"
    mkdir -p "$io_dir" || { error "_stage_io_to_file: cannot create $io_dir"; return 1; }
    local path="$io_dir/${stage}-${seq}.json"
    if ! printf '%s\n' "$record" | atomic_write "$path"; then
        error "_stage_io_to_file: atomic_write failed for $path"
        return 1
    fi
    printf '%s' "$path"
    return 0
}

# ─── _stage_io_render_status — derive OK/FAIL/empty indicator ────────────────
# Args: <kind> <exit_code> <metadata_json>
# Prints "OK" or "FAIL". LLM kind defaults to OK; only renders FAIL when
# metadata.error is set.
_stage_io_render_status() {
    local kind="$1" exit_code="$2" metadata_json="$3"
    case "$kind" in
        command)
            if [[ "$exit_code" == "0" ]]; then printf 'OK'
            else printf 'FAIL'
            fi
            ;;
        llm)
            local has_err
            has_err="$(printf '%s' "$metadata_json" | jq -r 'if has("error") then "1" else "0" end' 2>/dev/null || printf '0')"
            if [[ "$has_err" == "1" ]]; then printf 'FAIL'
            else printf 'OK'
            fi
            ;;
        computed)
            printf 'OK'
            ;;
    esac
}

# ─── _stage_io_render_duration — duration_ms → "N.Ns" or "-" ─────────────────
_stage_io_render_duration() {
    local ms="$1"
    if [[ -z "$ms" || "$ms" == "null" ]]; then printf -- '-'; return; fi
    awk -v m="$ms" 'BEGIN{printf "%.1fs", m/1000}'
}

# ─── _stage_io_render_command_argv — human-readable argv for command-kind ────
# Input: the .input field of a command-kind record (printf '%q '-encoded argv
# emitted by run_captured_command). The %q encoding round-trips through the
# shell but surfaces ugly $'...' ANSI-C quoting and \-escapes when shown raw.
# This helper decodes back to argv and re-renders with shell-friendly but
# human-readable quoting: simple identifiers bare, anything with whitespace or
# shell metacharacters single-quoted with embedded newlines kept as real
# newlines (so multi-line --jq filters render readably). For multi-line args,
# subsequent lines get a 2-space hanging indent so the structure is visually
# clear even when the prompt and arg blur together.
#
# Safety note: `eval "set -- $input"` is safe because $input came from our
# own run_captured_command's printf '%q' — that produces shell-literal
# escapes, not interpretable expressions. We are NOT eval'ing user input.
# Falls back to printing the raw input if decoding fails for any reason.
_stage_io_render_command_argv() {
    local input="$1"
    # Decode in a subshell so a malformed input can't corrupt the caller's
    # positional parameters or environment.
    local decoded_argv_count=0
    if ! eval "set -- $input" 2>/dev/null; then
        printf '$ %s\n' "$input"
        return 0
    fi
    decoded_argv_count=$#
    if [[ $decoded_argv_count -eq 0 ]]; then
        printf '$ %s\n' "$input"
        return 0
    fi

    printf '$ '
    local i=0 arg
    for arg in "$@"; do
        i=$((i + 1))
        # Separator (space after first arg)
        [[ $i -gt 1 ]] && printf ' '
        # Render rule:
        #   - empty string -> ''
        #   - plain word (alphanumeric, ., /, -, _, =, :, ,, @, +, %) -> bare
        #   - everything else -> single-quoted; embedded single quotes
        #     become '\'' (close, escape, reopen). Real newlines inside the
        #     single quotes stay as real newlines for visual readability;
        #     continuation lines get a 2-space hang indent.
        if [[ -z "$arg" ]]; then
            printf "''"
        elif [[ "$arg" =~ ^[A-Za-z0-9._/@:,=+%-]+$ ]]; then
            printf '%s' "$arg"
        else
            # Single-quote with embedded-quote escape and hang indent for
            # any continuation lines.
            local quoted="${arg//\'/\'\\\'\'}"
            # Hang indent: every \n in the value gets a 2-space prefix after.
            quoted="${quoted//$'\n'/$'\n'  }"
            printf "'%s'" "$quoted"
        fi
    done
    printf '\n'
}

# ─── _stage_io_tail — last N lines of input string ───────────────────────────
# Appends trailing newline so the next section divider (── … ──) starts on its
# own line, even when the original content lacked a final newline.
_stage_io_tail() {
    local content="$1" n="$2"
    printf '%s\n' "$content" | tail -n "$n"
}

# ─── _stage_io_head — first N lines of input string ──────────────────────────
# Appends trailing newline so the next section divider (── … ──) starts on its
# own line, even when the original content lacked a final newline.
_stage_io_head() {
    local content="$1" n="$2"
    printf '%s\n' "$content" | head -n "$n"
}

# ─── _stage_io_to_stdout <record_json> — renders stage-io capture to stdout ──
_stage_io_to_stdout() {
    local record="$1"
    local stage kind seq input output exit_code duration_ms metadata
    stage="$(printf '%s' "$record" | jq -r '.stage')"
    kind="$(printf '%s' "$record" | jq -r '.kind')"
    seq="$(printf '%s' "$record" | jq -r '.seq')"
    input="$(printf '%s' "$record" | jq -r '.input')"
    output="$(printf '%s' "$record" | jq -r '.output')"
    exit_code="$(printf '%s' "$record" | jq -r '.exit_code // ""')"
    duration_ms="$(printf '%s' "$record" | jq -r '.duration_ms // ""')"
    metadata="$(printf '%s' "$record" | jq -c '.metadata // {}')"

    local tail_lines
    tail_lines="$(template_stage_io_tail_lines "$stage" 2>/dev/null || true)"
    [[ -z "$tail_lines" ]] && tail_lines=40

    local status; status="$(_stage_io_render_status "$kind" "$exit_code" "$metadata")"
    local dur; dur="$(_stage_io_render_duration "$duration_ms")"

    # Header
    local status_field=""
    [[ -n "$status" ]] && status_field=" ${status}"
    printf '── stage-io: %s [%s] seq=%s%s %s ──\n' "$stage" "$kind" "$seq" "$status_field" "$dur"

    case "$kind" in
        llm)
            printf '── input ──\n'
            _stage_io_head "$input" "$tail_lines"
            printf '\n── output ──\n'
            _stage_io_tail "$output" "$tail_lines"
            printf '\n'
            ;;
        command)
            printf '── input ──\n'
            _stage_io_render_command_argv "$input"
            printf '── output ──\n'
            _stage_io_tail "$output" "$tail_lines"
            printf '\n── exit: %s ──\n' "${exit_code:-?}"
            ;;
        computed)
            printf 'in: %s\nout: %s\n' "$input" "$output"
            ;;
    esac

    printf '── end stage-io: %s ──\n' "$stage"
    return 0
}

# ─── _stage_io_byte_len <string> — byte length (UTF-8 safe) ──────────────────
# Char count via ${#s} is multi-byte aware under UTF-8 locales; the GitHub
# comment limit (65_536) is in BYTES. Force LC_ALL=C so ${#s} counts bytes.
_stage_io_byte_len() {
    local LC_ALL=C
    local s="$1"
    printf '%s' "${#s}"
}

# ─── _stage_io_redact_outbound <content> ─────────────────────────────────────
# Outputs redacted content to stdout, returns 0 on success, 1 on redactor failure.
# Pass-through when no scope manifest is present (e.g. intake before scope bound).
_stage_io_redact_outbound() {
    local content="$1"
    local state_dir="${ZBUILD_STATE_DIR:-$HOME/.zbuild/state}"
    local manifest="$state_dir/scope-manifest.md"
    if [[ ! -s "$manifest" ]]; then
        printf '%s' "$content"
        return 0
    fi
    local tmp_in tmp_out
    tmp_in="$(mktemp "${TMPDIR:-/tmp}/zbio-in.XXXXXX" 2>/dev/null)" || { return 1; }
    tmp_out="$(mktemp "${TMPDIR:-/tmp}/zbio-out.XXXXXX" 2>/dev/null)" || { rm -f "$tmp_in"; return 1; }
    # Cleanup on every return path including SIGPIPE. Double-quote the trap arg
    # so $tmp_in/$tmp_out expand to literal paths at trap-registration time —
    # protects against the locals going out of scope before the trap fires and
    # avoids re-evaluation hazards if another RETURN trap is layered on top.
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_in' '$tmp_out'" RETURN
    printf '%s' "$content" > "$tmp_in"
    if apply_scope_redaction "$tmp_in" "$tmp_out" "$manifest" "" "0" >/dev/null 2>&1; then
        cat "$tmp_out"
        return 0
    fi
    return 1
}

# ─── _stage_io_to_gh_comment <record_json> ───────────────────────────────────
_stage_io_to_gh_comment() {
    local record="$1"

    # Silent skips — mirror destinations.sh
    if [[ -z "${ZBUILD_ISSUE:-}" || "${ZBUILD_ISSUE}" == "0" ]]; then
        return 0
    fi
    local toggle="${ZBUILD_OUTPUT_GH_COMMENT:-1}"
    [[ "$toggle" == "0" ]] && return 0

    local stage kind seq input output exit_code duration_ms metadata
    stage="$(printf '%s' "$record" | jq -r '.stage')"
    kind="$(printf '%s' "$record" | jq -r '.kind')"
    seq="$(printf '%s' "$record" | jq -r '.seq')"
    input="$(printf '%s' "$record" | jq -r '.input')"
    output="$(printf '%s' "$record" | jq -r '.output')"
    exit_code="$(printf '%s' "$record" | jq -r '.exit_code // ""')"
    duration_ms="$(printf '%s' "$record" | jq -r '.duration_ms // ""')"
    metadata="$(printf '%s' "$record" | jq -c '.metadata // {}')"

    local status; status="$(_stage_io_render_status "$kind" "$exit_code" "$metadata")"
    local dur; dur="$(_stage_io_render_duration "$duration_ms")"

    # Apply outbound redaction (output first, then input) — BEFORE truncate.
    # LLM kind always redacts; command/computed honor template_stage_io_redact.
    local skip_redact=0
    if [[ "$kind" != "llm" ]]; then
        local redact_pref
        redact_pref="$(template_stage_io_redact "$stage" 2>/dev/null || true)"
        [[ "$redact_pref" == "false" ]] && skip_redact=1
    fi

    local r_output="$output" r_input="$input"
    if [[ "$skip_redact" -eq 0 ]]; then
        if ! r_output="$(_stage_io_redact_outbound "$output")"; then
            eb_emit_event "stage.io.error" "stage=$stage" "reason=redaction_failed" 2>/dev/null || true
            return 0
        fi
        if ! r_input="$(_stage_io_redact_outbound "$input")"; then
            eb_emit_event "stage.io.error" "stage=$stage" "reason=redaction_failed" 2>/dev/null || true
            return 0
        fi
    fi

    # Build inner rendered text — reuse stdout renderer shape, but using
    # the already-redacted input/output. Construct a synthetic record that
    # carries the redacted strings.
    local rendered_record
    rendered_record="$(printf '%s' "$record" | jq -c --arg i "$r_input" --arg o "$r_output" '.input = $i | .output = $o')"
    local rendered_body
    rendered_body="$(_stage_io_to_stdout "$rendered_record" 2>/dev/null)"

    # Build the comment body:
    # <details><summary>OK stage: <id> (<kind>, <dur>)</summary>
    # ```
    # <rendered_body>
    # ```
    # </details>
    local summary_status=""
    [[ -n "$status" ]] && summary_status="${status} "
    local artifact_path
    artifact_path="${ZBUILD_STATE_DIR:-$HOME/.zbuild/state}/artifacts/stage-io/${stage}-${seq}.json"

    # Compose initial body
    local body
    body="$(printf '<details><summary>%sstage: %s (%s, %s)</summary>\n\n```\n%s\n```\n</details>\n' \
        "$summary_status" "$stage" "$kind" "$dur" "$rendered_body")"

    # Truncate if > 60_000 bytes by trimming the rendered output portion.
    # GitHub's hard limit is 65_536 BYTES (not chars); use byte-length helper so
    # multi-byte UTF-8 content is sized correctly under any locale.
    local max=60000
    if [[ $(_stage_io_byte_len "$body") -gt $max ]]; then
        local orig_bytes
        orig_bytes="$(_stage_io_byte_len "$output")"
        local trunc_marker
        trunc_marker="$(printf '\n[truncated — see %s for full %d-byte capture]' "$artifact_path" "$orig_bytes")"
        # Conservative: keep the header/input intact; shrink the rendered body's tail.
        # Strategy: rebuild with progressively shorter trailing slice of rendered_body
        # until under cap, then re-wrap.
        local overhead_template
        overhead_template="$(printf '<details><summary>%sstage: %s (%s, %s)</summary>\n\n```\n\n```\n</details>\n' \
            "$summary_status" "$stage" "$kind" "$dur")"
        local overhead_len marker_len
        overhead_len="$(_stage_io_byte_len "$overhead_template")"
        marker_len="$(_stage_io_byte_len "$trunc_marker")"
        local room=$(( max - overhead_len - marker_len ))
        [[ $room -lt 0 ]] && room=0
        # Byte-accurate slice (head -c counts bytes regardless of locale).
        # iconv -c strips invalid UTF-8 sequences that would result from cutting
        # mid-codepoint, ensuring GitHub API accepts the body. If iconv is
        # unavailable (empty result), fall back to the raw bytewise slice.
        local trimmed_rendered raw_slice
        raw_slice="$(printf '%s' "$rendered_body" | head -c "$room")"
        trimmed_rendered="$(printf '%s' "$raw_slice" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)"
        if [[ -z "$trimmed_rendered" && -n "$raw_slice" ]]; then
            trimmed_rendered="$raw_slice"
        fi
        body="$(printf '<details><summary>%sstage: %s (%s, %s)</summary>\n\n```\n%s%s\n```\n</details>\n' \
            "$summary_status" "$stage" "$kind" "$dur" "$trimmed_rendered" "$trunc_marker")"
    fi

    if ! gh issue comment "$ZBUILD_ISSUE" --body "$body" >/dev/null 2>&1; then
        eb_emit_event "stage.io.error" "stage=$stage" "reason=gh_comment_post_failed" 2>/dev/null || true
        return 0
    fi
    return 0
}
