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

# ── #481: per-process begin/end pairing state ─────────────────────────────────
# Bash 5+ associative arrays. zBuild already enforces Bash 5 (scripts/lib/compat.sh).
# Keyed by "<stage>:<seq>" so multiple in-flight captures (per stage) can coexist.
declare -gA _STAGE_IO_START_NS
declare -gA _STAGE_IO_PENDING        # holds the begin-time metadata JSON keyed by stage:seq
declare -gA _STAGE_IO_PENDING_INPUT  # holds the begin-time input by stage:seq
declare -gA _STAGE_IO_PENDING_KIND   # holds the begin-time kind by stage:seq
declare -gA _STAGE_IO_PENDING_DESTS  # holds the begin-time dests by stage:seq
declare -gA _STAGE_IO_PENDING_LABEL  # #682: holds the begin-time seq label (e.g. "1.2") by stage:seq
_STAGE_IO_LAST_SEQ=""

_STAGE_IO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT_FOR_STAGE_IO="$(cd "$_STAGE_IO_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$_ZBUILD_ROOT_FOR_STAGE_IO/scripts/lib/helpers.sh"
# shellcheck source=./stage-colors.sh
source "$_ZBUILD_ROOT_FOR_STAGE_IO/core/output/stage-colors.sh"
# shellcheck source=../event-bus/event-bus.sh
source "$_ZBUILD_ROOT_FOR_STAGE_IO/core/event-bus/event-bus.sh"
# shellcheck source=../pipeline/template.sh
source "$_ZBUILD_ROOT_FOR_STAGE_IO/core/pipeline/template.sh"
# shellcheck source=../redaction/scope-redaction.sh
source "$_ZBUILD_ROOT_FOR_STAGE_IO/core/redaction/scope-redaction.sh"
# shellcheck source=../../scripts/lib/artifact-render.sh
source "$_ZBUILD_ROOT_FOR_STAGE_IO/scripts/lib/artifact-render.sh"

# ─── _stage_io_validate_fd — refuse 0/1 and require an open fd ────────────────
# #491 §v4: the banner fd MUST NOT collide with stdin (0) or the action's
# stdout (1). Routing the banner to fd 1 would interleave it with $() captures
# and corrupt downstream parsing; routing to fd 0 is nonsensical. Default is
# fd 2 (stderr), which the chokepoint's caller-level redirect already targets.
# Called once at module load time so the failure shows up at source-time, not
# at the moment a stage tries to emit a banner.
_stage_io_validate_fd() {
    local fd="${ZBUILD_STAGE_IO_FD:-2}"
    if [[ ! "$fd" =~ ^[0-9]+$ ]]; then
        error "ZBUILD_STAGE_IO_FD must be a non-negative integer; got '$fd'"
        return 2
    fi
    if [[ "$fd" == "0" || "$fd" == "1" ]]; then
        error "ZBUILD_STAGE_IO_FD=$fd is forbidden (0=stdin, 1=stdout would collide with action capture); use fd 2 (default) or a dedicated >=3 fd"
        return 2
    fi
    # Verify the fd is actually open in the caller's shell. `>&"$fd"` succeeds
    # only if fd is open for write. Defensive guard wrapped in a subshell so a
    # closed fd error doesn't leak to the caller's terminal.
    #
    # #586: relaxed from hard `error → return 2` to warn-once + fall back to
    # fd 2 (stderr). The production runner (core/pipeline/runner.sh:869)
    # opens fd 3 before any plugin spawn, so this branch should never fire
    # in normal pipeline operation; if it does fire, we emit a structured
    # `stage_io.fd_fallback` event so the fallback is grep-able in
    # events.jsonl (suppressed under ZBUILD_TEST_MODE=1 to keep the test
    # event stream clean).
    if ! ( : >&"$fd" ) 2>/dev/null; then
        if [[ -z "${_STAGE_IO_FD_FALLBACK_WARNED:-}" ]]; then
            warn "ZBUILD_STAGE_IO_FD=$fd not open for write; falling back to fd 2 (stderr)"
            _STAGE_IO_FD_FALLBACK_WARNED=1
            if [[ "${ZBUILD_TEST_MODE:-}" != "1" ]]; then
                eb_emit_event "stage_io.fd_fallback" \
                    "requested_fd=$fd" \
                    "actual_fd=2" \
                    "pid=$$" 2>/dev/null || true
            fi
        fi
        export ZBUILD_STAGE_IO_FD=2
    fi
    return 0
}

# Run validation exactly once per process at module load. The outer guard at
# the top of this file (`_ZBUILD_STAGE_IO_LOADED`) ensures we don't re-validate
# on re-source. Failure here aborts the source via `return 2` so the caller
# sees an immediate, actionable error instead of a silently swallowed banner.
_stage_io_validate_fd || return $?

# ─── _stage_io_now_ms — millisecond clock with override hook ──────────────────
# Used by stage_io_begin/_end for deterministic golden snapshots.
# When ZBUILD_STAGE_IO_NOW_MS_OVERRIDE is set, returns its value verbatim
# (single test-injected timestamp). Otherwise reads $EPOCHREALTIME (Bash 5+).
_stage_io_now_ms() {
    if [[ -n "${ZBUILD_STAGE_IO_NOW_MS_OVERRIDE:-}" ]]; then
        printf '%s' "$ZBUILD_STAGE_IO_NOW_MS_OVERRIDE"
        return 0
    fi
    local us="${EPOCHREALTIME/./}"
    # us is microseconds when EPOCHREALTIME is "<sec>.<usec>"
    printf '%s' $(( 10#${us} / 1000 ))
}

# ─── _stage_io_now_short — HH:MM:SS UTC clock for banner heading (#492) ──────
# Used by _stage_io_stdout_begin/_end to right-align a wall-time stamp on the
# banner heading. Honors ZBUILD_STAGE_IO_NOW_MS_OVERRIDE so goldens / visual
# determinism tests can pin the timestamp. macOS BSD `date -r <sec>` and GNU
# `date -d @<sec>` differ — we use `-r` first (BSD/macOS) with a GNU fallback.
_stage_io_now_short() {
    local sec
    if [[ -n "${ZBUILD_STAGE_IO_NOW_MS_OVERRIDE:-}" ]]; then
        sec=$(( ZBUILD_STAGE_IO_NOW_MS_OVERRIDE / 1000 ))
    else
        sec=${EPOCHSECONDS:-$(date -u +%s)}
    fi
    # BSD date (macOS): `date -u -r <sec>`. GNU date: `date -u -d @<sec>`.
    # Try BSD form first; fall back to GNU; final fallback is current time.
    local out
    out="$(date -u -r "$sec" +'%H:%M:%S UTC' 2>/dev/null \
        || date -u -d "@$sec" +'%H:%M:%S UTC' 2>/dev/null \
        || date -u +'%H:%M:%S UTC')"
    printf '%s' "$out"
}

# ─── _stage_io_orphan_finalizer — EXIT trap helper for unpaired begins ────────
# Walks any keys still in _STAGE_IO_PENDING and emits a stage.io.error with
# reason=output_never_emitted, plus a partial file record at the reserved seq.
# Best-effort: failures are swallowed (already on the exit path).
_stage_io_orphan_finalizer() {
    local key stage seq kind input
    for key in "${!_STAGE_IO_PENDING[@]}"; do
        stage="${key%%:*}"
        seq="${key##*:}"
        kind="${_STAGE_IO_PENDING_KIND[$key]:-llm}"
        input="${_STAGE_IO_PENDING_INPUT[$key]:-}"
        eb_emit_event "stage.io.error" \
            "stage=$stage" "seq=$seq" "kind=$kind" \
            "reason=output_never_emitted" 2>/dev/null || true
        # #833: kind=cycle is fd-2-only chrome and must NEVER touch the
        # filesystem (SPEC-5 "NEVER file"). An orphaned cycle begin (e.g. the
        # cycle aborted between the INPUT begin and OUTPUT end) still gets the
        # diagnostic event above, but no .partial.json artifact. This branch
        # matters now that the runner's MAIN process sources stage-io (#833) —
        # the orphan finalizer is armed for all kinds there, not just plugin
        # subshells.
        if [[ "$kind" == "cycle" ]]; then
            continue
        fi
        # Best-effort partial record so the operator can still inspect the input.
        local state_dir="${ZBUILD_STATE_DIR:-${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}}"
        local io_dir="$state_dir/artifacts/stage-io"
        mkdir -p "$io_dir" 2>/dev/null || continue
        local path="$io_dir/${stage}-${seq}.partial.json"
        local ts; ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        local rec
        rec="$(jq -n \
            --arg stage "$stage" --arg kind "$kind" --arg seq "$seq" \
            --arg input "$input" --arg ts "$ts" \
            '{schema_version:1, stage:$stage, kind:$kind, seq:($seq|tonumber),
              input:$input, output:"", exit_code:null, duration_ms:null,
              metadata:{partial:"output_never_emitted"}, ts:$ts}' 2>/dev/null)" || continue
        printf '%s\n' "$rec" > "$path" 2>/dev/null || true
    done
}

# Install the orphan trap exactly once per process when stage-io is sourced.
# CAUTION: do NOT compose with the inherited EXIT trap. Bash subshells
# INHERIT trap definitions for the purpose of `trap -p` reads but the
# inherited trap is reset (does not fire) on subshell exit. If we read the
# parent's body and re-install it here, the subshell will erroneously fire
# the parent's trap on its own exit — which, for the runner's
# `_runner_abort_trap`, mistakenly emits pipeline.abort once per plugin
# subshell (regression caught by tests/e2e/parity-local-vs-ci-test.sh).
# Install only our own finalizer. The runner's own EXIT trap continues to
# fire when the runner process exits, independently of our trap here.
if [[ -z "${_ZBUILD_STAGE_IO_TRAP_INSTALLED:-}" ]]; then
    _ZBUILD_STAGE_IO_TRAP_INSTALLED=1
    trap '_stage_io_orphan_finalizer' EXIT
fi

# ─── stage_io_begin — #481 input-phase emitter ────────────────────────────────
# Usage:
#   stage_io_begin --stage <id> --kind llm|command|computed \
#                  --input <s> [--metadata k=v]...
#
# Effects (when stage has destinations configured):
#   - reserves the next seq under <stage>-*.json
#   - emits "── stage-io: <stage> [<kind>] seq=N input ──\n<input head>\n" to
#     stdout destination (via ZBUILD_STAGE_IO_FD; default fd 2)
#   - stashes start time and pending metadata in per-process maps
#   - does NOT yet write the file artifact or post the gh_comment (deferred
#     to stage_io_end so the comment is a single merged record).
#
# Output:
#   stdout: the reserved seq (so callers can pass it to stage_io_end --seq N)
#   also exports _STAGE_IO_LAST_SEQ
#
# Returns:
#   0 — success (or no-op when no destinations configured; still prints seq 0)
#   2 — usage error
stage_io_begin() {
    local stage="" kind=""
    local input="__ZBUILD_STAGE_IO_UNSET__"
    local persist_input_path=""
    # #682 (Wave 15-D): hierarchical seq label. When non-empty, the rendered
    # banner heading uses this string verbatim in place of `seq=N`. The
    # internal cardinal counter (_STAGE_IO_LAST_SEQ + the seq stored in the
    # artifact record) is unchanged — only the on-screen label diverges.
    # Operator effect: cycle members render `seq=1.1`, `seq=1.2`, ...;
    # linear stages render `seq=1`, `seq=2`, ... while pairing logic stays
    # cardinal-integer-keyed for stage_io_end.
    local seq_label="${ZBUILD_STAGE_IO_SEQ_LABEL:-}"
    local -a meta_keys=() meta_vals=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stage)    stage="${2:-}"; shift 2 ;;
            --kind)     kind="${2:-}"; shift 2 ;;
            --input)    input="${2:-}"; shift 2 ;;
            --seq-label) seq_label="${2:-}"; shift 2 ;;
            # #505: optional override — banner uses --input (operator-facing,
            # possibly deduped), but artifact .input reads from this file
            # (full LLM payload, postmortem fidelity). Default off; plan/
            # review/security-lens callers untouched. See ADR-018 §Pattern 2.5.
            --persist-input) persist_input_path="${2:-}"; shift 2 ;;
            --metadata)
                local kv="${2:-}"
                if [[ "$kv" != *"="* ]]; then
                    error "stage_io_begin: malformed --metadata '$kv'"
                    return 2
                fi
                meta_keys+=("${kv%%=*}"); meta_vals+=("${kv#*=}"); shift 2
                ;;
            *)
                error "stage_io_begin: unknown flag '$1'"
                return 2
                ;;
        esac
    done

    [[ -z "$stage" ]] && { error "stage_io_begin: --stage required"; return 2; }
    [[ -z "$kind"  ]] && { error "stage_io_begin: --kind required";  return 2; }
    # #833: `cycle` joins the kind enum for per-iter cycle boundary banners.
    case "$kind" in llm|command|computed|cycle) : ;;
        *) error "stage_io_begin: unknown --kind '$kind'"; return 2 ;;
    esac
    [[ "$input" == "__ZBUILD_STAGE_IO_UNSET__" ]] && \
        { error "stage_io_begin: --input required"; return 2; }

    local dests_nl
    dests_nl="$(template_stage_io_dests "$stage" 2>/dev/null || true)"
    # #833: cycles have NO template io: block, so template_stage_io_dests is
    # empty and the dest-gated banner path below would suppress the cycle
    # banner. Force stdout-only (fd-2 routing) so the banner renders; never
    # file, never gh_comment — mirrors the §v6 cycle-divider operator-chrome.
    if [[ "$kind" == "cycle" ]]; then dests_nl="stdout"; fi

    # Reserve seq even when no destinations (callers may still pair end);
    # but skip filesystem ls when no io_dir exists.
    local state_dir="${ZBUILD_STATE_DIR:-${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}}"
    local io_dir="$state_dir/artifacts/stage-io"
    local existing_count=0
    if [[ -d "$io_dir" ]]; then
        # shellcheck disable=SC2012
        # `|| true` suffix: `ls` returning rc=2 (no match) is normal and would
        # otherwise trip set -e in callers that wrap with pipefail.
        existing_count=$( { ls -1 "$io_dir"/"${stage}"-*.json 2>/dev/null || true; } | wc -l | tr -d ' ')
    fi
    # Also count already-reserved-but-not-yet-finalized seqs for this stage
    # so back-to-back begins reserve distinct numbers. Use `if` rather than
    # `[[ ]] && ...` so a false test result doesn't trip `set -e` in callers.
    local pending_for_stage=0 _k
    for _k in "${!_STAGE_IO_PENDING[@]}"; do
        if [[ "${_k%%:*}" == "$stage" ]]; then
            pending_for_stage=$((pending_for_stage + 1))
        fi
    done
    local seq=$((existing_count + pending_for_stage + 1))
    _STAGE_IO_LAST_SEQ="$seq"

    # Build a metadata-keys list as TSV in pending map (so end can merge).
    local meta_blob=""
    local mi
    for (( mi=0; mi<${#meta_keys[@]}; mi++ )); do
        meta_blob+="${meta_keys[$mi]}=${meta_vals[$mi]}"$'\n'
    done

    local key="${stage}:${seq}"
    _STAGE_IO_PENDING[$key]="$meta_blob"
    # #505: artifact .input stores the persisted file's contents when caller
    # passed --persist-input <path>; otherwise the begin-time --input string.
    # Banner (below) always uses $input — divergence is intentional.
    if [[ -n "$persist_input_path" && -f "$persist_input_path" ]]; then
        _STAGE_IO_PENDING_INPUT[$key]="$(cat "$persist_input_path")"
    else
        _STAGE_IO_PENDING_INPUT[$key]="$input"
    fi
    _STAGE_IO_PENDING_KIND[$key]="$kind"
    _STAGE_IO_PENDING_DESTS[$key]="$dests_nl"
    # #682: stash label for stage_io_end to use on the output heading.
    # Empty string means "fall back to cardinal seq" (back-compat).
    _STAGE_IO_PENDING_LABEL[$key]="$seq_label"
    _STAGE_IO_START_NS[$key]="$(_stage_io_now_ms)"

    # Banner — only emit if stdout destination is configured.
    if [[ -n "$dests_nl" ]] && printf '%s\n' "$dests_nl" | grep -qx "stdout"; then
        # Find metadata.artifact key if provided (so #470's input-side renderer
        # dispatch can run during the input phase, before end-time merge).
        local _artifact_id="" _i
        for (( _i=0; _i<${#meta_keys[@]}; _i++ )); do
            if [[ "${meta_keys[$_i]}" == "artifact" ]]; then
                _artifact_id="${meta_vals[$_i]}"
                break
            fi
        done
        # #682: display label (e.g. "1.2") for banner; empty falls back to seq.
        local _display_seq="${seq_label:-$seq}"
        _stage_io_stdout_begin "$stage" "$kind" "$_display_seq" "$input" "$_artifact_id" \
            >&"${ZBUILD_STAGE_IO_FD:-2}" || true
    fi

    # Return the seq on stdout so callers can capture it.
    printf '%s' "$seq"
    return 0
}

# ─── stage_io_end — #481 output-phase emitter ─────────────────────────────────
# Usage:
#   stage_io_end --stage <id> --kind k --seq <N> --output <s> \
#                [--exit-code N] [--duration-ms N] [--metadata k=v]...
#
# Effects:
#   - computes duration_ms from begin's stash (unless --duration-ms overrides)
#   - emits "── stage-io: <stage> [<kind>] seq=N output STATUS DUR ──\n<output tail>\n── end stage-io: <stage> ──\n"
#   - writes a single merged file record at the reserved seq path
#   - renders gh_comment once with the merged record
#   - emits stage.io.captured event (one per pair)
stage_io_end() {
    local stage="" kind="" seq=""
    local output="__ZBUILD_STAGE_IO_UNSET__"
    local exit_code="" duration_ms=""
    local -a meta_keys=() meta_vals=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stage)        stage="${2:-}"; shift 2 ;;
            --kind)         kind="${2:-}"; shift 2 ;;
            --seq)          seq="${2:-}"; shift 2 ;;
            --output)       output="${2:-}"; shift 2 ;;
            --exit-code)    exit_code="${2:-}"; shift 2 ;;
            --duration-ms)  duration_ms="${2:-}"; shift 2 ;;
            --metadata)
                local kv="${2:-}"
                if [[ "$kv" != *"="* ]]; then
                    error "stage_io_end: malformed --metadata '$kv'"
                    return 2
                fi
                meta_keys+=("${kv%%=*}"); meta_vals+=("${kv#*=}"); shift 2
                ;;
            *)
                error "stage_io_end: unknown flag '$1'"
                return 2
                ;;
        esac
    done
    [[ -z "$stage" ]] && { error "stage_io_end: --stage required"; return 2; }
    [[ -z "$kind"  ]] && { error "stage_io_end: --kind required";  return 2; }
    [[ -z "$seq"   ]] && { error "stage_io_end: --seq required (call stage_io_begin first)"; return 2; }
    [[ "$output" == "__ZBUILD_STAGE_IO_UNSET__" ]] && \
        { error "stage_io_end: --output required"; return 2; }

    local key="${stage}:${seq}"
    if [[ -z "${_STAGE_IO_PENDING[$key]+x}" ]]; then
        # No matching begin — bad pairing.
        eb_emit_event "stage.io.error" \
            "stage=$stage" "seq=$seq" "kind=$kind" "reason=end_without_begin" \
            2>/dev/null || true
        error "stage_io_end: no matching stage_io_begin for ${stage}:${seq}"
        return 2
    fi

    local input="${_STAGE_IO_PENDING_INPUT[$key]:-}"
    local dests_nl="${_STAGE_IO_PENDING_DESTS[$key]:-}"
    # #682: snapshot the hierarchical seq label before pending unset below.
    # Empty string means "render cardinal seq" (back-compat fallback).
    local seq_label_snap="${_STAGE_IO_PENDING_LABEL[$key]:-}"

    # Merge metadata: begin's stash first, then end's.
    local meta_blob="${_STAGE_IO_PENDING[$key]}"
    local mi
    for (( mi=0; mi<${#meta_keys[@]}; mi++ )); do
        meta_blob+="${meta_keys[$mi]}=${meta_vals[$mi]}"$'\n'
    done

    # Compute duration unless override.
    if [[ -z "$duration_ms" ]]; then
        local start_ms="${_STAGE_IO_START_NS[$key]:-}"
        local now_ms; now_ms="$(_stage_io_now_ms)"
        if [[ -n "$start_ms" && "$start_ms" =~ ^[0-9]+$ && "$now_ms" =~ ^[0-9]+$ ]]; then
            duration_ms=$(( now_ms - start_ms ))
            (( duration_ms < 0 )) && duration_ms=0
        fi
    fi

    # Clean up pending state — finalize is now happening.
    unset '_STAGE_IO_PENDING[$key]'
    unset '_STAGE_IO_PENDING_INPUT[$key]'
    unset '_STAGE_IO_PENDING_KIND[$key]'
    unset '_STAGE_IO_PENDING_DESTS[$key]'
    unset '_STAGE_IO_PENDING_LABEL[$key]'
    unset '_STAGE_IO_START_NS[$key]'

    # If no destinations were configured, nothing more to do.
    if [[ -z "$dests_nl" ]]; then
        return 0
    fi

    # ── Build merged record via jq --arg ────────────────────────────────────
    local ts; ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    local run_id="${ZBUILD_RUN_ID:-}"
    local metadata_json='{}'
    while IFS='=' read -r mk mv; do
        [[ -z "$mk" ]] && continue
        metadata_json="$(printf '%s' "$metadata_json" | \
            jq -c --arg k "$mk" --arg v "$mv" '. + {($k): $v}')" || {
            error "stage_io_end: failed to assemble metadata"
            return 2
        }
    done <<< "$meta_blob"

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
        error "stage_io_end: jq assembly failed"
        eb_emit_event "stage.io.error" "stage=$stage" "reason=jq_assembly_failed" 2>/dev/null || true
        return 2
    }

    # Validate against locked schema
    if ! printf '%s' "$record" | jq -e \
        'has("schema_version") and .schema_version==1 and has("stage") and has("kind") and (.kind|IN("llm","command","computed","cycle")) and has("input") and has("output") and has("ts")' \
        >/dev/null 2>&1; then
        eb_emit_event "stage.io.error" "stage=$stage" "reason=schema_invalid" 2>/dev/null || true
        return 2
    fi

    local dests_comma
    dests_comma="$(printf '%s' "$dests_nl" | tr '\n' ',' | sed 's/,$//')"

    # Dispatch destinations.
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
                # Output-phase banner only (begin already emitted the input
                # section). Uses the same fd-3 convention.
                # #682: pass seq-display label (e.g. "1.2") so output heading
                # matches the input heading. Empty label → cardinal seq.
                _stage_io_stdout_end "$record" "$seq_label_snap" \
                    >&"${ZBUILD_STAGE_IO_FD:-2}" || true
                ;;
            gh_comment)
                _stage_io_to_gh_comment "$record" || true
                ;;
            *)
                error "stage_io_end: unknown destination '$dest'"
                return 2
                ;;
        esac
    done

    eb_emit_event "stage.io.captured" \
        "stage=$stage" "kind=$kind" "seq=$seq" \
        "dest_list=$dests_comma" "artifact_path=${artifact_path:-}" \
        2>/dev/null || true

    return 0
}

# ─── capture_stage_io — chokepoint (now a compat shim over begin+end) ────────
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
    local input="__ZBUILD_STAGE_IO_UNSET__"
    local output="__ZBUILD_STAGE_IO_UNSET__"
    local exit_code="" duration_ms=""
    local -a begin_args=() end_args=()

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
                # Forward to begin so end's merge preserves both halves.
                begin_args+=( --metadata "$kv" )
                shift 2
                ;;
            *)
                error "capture_stage_io: unknown flag '$1'"
                return 2
                ;;
        esac
    done

    # Required-flag validation (own checks so the error messages stay
    # capture_stage_io-prefixed for existing tests).
    if [[ -z "$stage" ]]; then
        error "capture_stage_io: --stage is required"
        return 2
    fi
    if [[ -z "$kind" ]]; then
        error "capture_stage_io: --kind is required"
        return 2
    fi
    case "$kind" in
        llm|command|computed|cycle) : ;;
        *) error "capture_stage_io: unknown --kind '$kind' (valid: llm, command, computed, cycle)"; return 2 ;;
    esac
    if [[ "$input" == "__ZBUILD_STAGE_IO_UNSET__" ]]; then
        error "capture_stage_io: --input is required"
        return 2
    fi
    if [[ "$output" == "__ZBUILD_STAGE_IO_UNSET__" ]]; then
        error "capture_stage_io: --output is required"
        return 2
    fi

    # Shim over begin+end. We MUST NOT capture begin via $(...) — its assoc-array
    # side effects would be lost in the subshell. Instead call directly and
    # read the reserved seq from _STAGE_IO_LAST_SEQ. Suppress stdout so the
    # printed seq doesn't leak to the caller (capture_stage_io has never
    # printed to stdout).
    stage_io_begin --stage "$stage" --kind "$kind" \
        --input "$input" "${begin_args[@]}" >/dev/null || return 2
    local _reserved_seq="$_STAGE_IO_LAST_SEQ"

    [[ -n "$exit_code"   ]] && end_args+=( --exit-code   "$exit_code"   )
    [[ -n "$duration_ms" ]] && end_args+=( --duration-ms "$duration_ms" )

    stage_io_end --stage "$stage" --kind "$kind" --seq "$_reserved_seq" \
        --output "$output" "${end_args[@]}" || return $?

    return 0
}

# ─── _stage_io_to_file <stage> <seq> <record_json> ───────────────────────────
# Writes the record to ${ZBUILD_STATE_DIR}/artifacts/stage-io/<stage>-<seq>.json
# atomically. Prints the resulting path on stdout so the caller can include it
# in the stage.io.captured event payload.
_stage_io_to_file() {
    local stage="$1" seq="$2" record="$3"
    local state_dir="${ZBUILD_STATE_DIR:-${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}}"
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
        cycle)
            # #833: cycle boundary banners have no exit-code / error semantics
            # at the banner layer — termination evidence lives in the OUTPUT
            # body. Status icon is always OK.
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

# ─── _stage_io_strip_ansi — remove ANSI/CSI escape sequences ────────────────
# Captured LLM responses and command outputs (gh, git, anything that detects
# a tty) can contain ANSI escape sequences that hose the operator's terminal
# when echoed back through the banner. The xterm bracketed-paste-mode-start
# code (`\e[200~`) is particularly nasty: once received, the terminal treats
# everything after as pasted-input until it sees the matching end code,
# which corrupts the shell prompt and may execute lines as commands.
#
# Strips:
#   - CSI: ESC [ <params> <final>, where params is [0-9;?]* and final is a
#     letter or `~` (covers the BPM markers \e[200~ / \e[201~).
#   - Bare ESC followed by a single character (OSC, single-shift, etc.).
# Leaves real newlines, tabs, and other printable content alone.
#
# Always emits content on stdout; never errors. Safe to use on any captured
# string field.
_stage_io_strip_ansi() {
    local content="$1"
    # Use sed with the GNU/BSD-common ERE form. \x1b is the ESC character.
    # Two passes: first strip CSI (ESC [ ... <letter|~>), then strip any
    # remaining bare-ESC sequences (ESC <char>).
    # #830: LC_ALL=C so sed processes raw bytes. Without it, BSD sed aborts
    # with "RE error: illegal byte sequence" on any non-UTF-8 byte (binary
    # fragments embedded in captured LLM/command output). Helper is called
    # from multiple paths so inline prefix is safer than caller-side env.
    printf '%s' "$content" | LC_ALL=C sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z~]//g; s/\x1b.//g'
}

# ─── _stage_io_pretty_print — pretty-print JSON, pass through otherwise ─────
# LLM outputs and some command outputs (gh --json) are JSON; minified, they
# render as one ~4KB line that scrolls off-screen and is unreadable. When the
# content parses as JSON (after stripping optional ```json … ``` fences),
# reformat through `jq .` for indented multi-line output. Otherwise return
# the original text unchanged. Always returns content on stdout; jq's
# "couldn't parse" error and the fallback are silenced.
_stage_io_pretty_print() {
    local content="$1"
    # Cheap precheck — only attempt jq on content that starts with { or [
    # (post leading whitespace). Avoids the cost of jq -e for plain prose.
    local trimmed="${content#"${content%%[![:space:]]*}"}"
    [[ "$trimmed" != \{* && "$trimmed" != \[* ]] && {
        # Strip a ```json … ``` wrapper if that's the only thing keeping it
        # from parsing (the plan plugin's response sometimes has these).
        if [[ "$trimmed" == '```json'* || "$trimmed" == '```'* ]]; then
            content="$(printf '%s' "$content" \
                | sed 's/^[[:space:]]*```json[[:space:]]*//' \
                | sed 's/^[[:space:]]*```[[:space:]]*//' \
                | sed 's/[[:space:]]*```[[:space:]]*$//')"
            trimmed="${content#"${content%%[![:space:]]*}"}"
            [[ "$trimmed" != \{* && "$trimmed" != \[* ]] && { printf '%s' "$content"; return 0; }
        else
            printf '%s' "$content"; return 0
        fi
    }
    # Try to pretty-print. On failure (invalid JSON despite starting with
    # {/[) fall back to the original text.
    local pretty
    if pretty="$(printf '%s' "$content" | jq . 2>/dev/null)"; then
        printf '%s' "$pretty"
    else
        printf '%s' "$content"
    fi
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

# ─── _stage_io_truncation_hint <total> <shown> <stage> <seq> ─────────────────
# (#492) Emit "↪ [<remaining> more lines · full at <path>]" when content was
# truncated. When stage/seq omitted (no deterministic path), skips path portion.
# Always prints with a leading newline so it visually separates from content.
_stage_io_truncation_hint() {
    local total="$1" shown="$2" stage="${3:-}" seq="${4:-}"
    [[ "$total" -le "$shown" ]] && return 0
    local remaining=$(( total - shown ))
    local state_dir="${ZBUILD_STATE_DIR:-${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}}"
    if [[ -n "$stage" && -n "$seq" ]]; then
        local path="$state_dir/artifacts/stage-io/${stage}-${seq}.json"
        printf '↪ [%d more lines · full at %s]\n' "$remaining" "$path"
    else
        printf '↪ [%d more lines]\n' "$remaining"
    fi
}

# ─── _stage_io_head_with_hint <content> <n> [<stage> <seq>] ──────────────────
# Like _stage_io_head, plus a truncation hint when wc -l > n.
_stage_io_head_with_hint() {
    local content="$1" n="$2" stage="${3:-}" seq="${4:-}"
    local total
    total="$(printf '%s\n' "$content" | wc -l | tr -d ' ')"
    printf '%s\n' "$content" | head -n "$n"
    _stage_io_truncation_hint "$total" "$n" "$stage" "$seq"
}

# ─── _stage_io_tail_with_hint <content> <n> [<stage> <seq>] ──────────────────
# Like _stage_io_tail, plus a truncation hint when wc -l > n.
_stage_io_tail_with_hint() {
    local content="$1" n="$2" stage="${3:-}" seq="${4:-}"
    local total
    total="$(printf '%s\n' "$content" | wc -l | tr -d ' ')"
    printf '%s\n' "$content" | tail -n "$n"
    _stage_io_truncation_hint "$total" "$n" "$stage" "$seq"
}

# ─── _stage_io_banner_use_color (#492) ───────────────────────────────────────
# Decide whether to emit ANSI color in banner output. Returns 0 (true) when
# colors should render, 1 (false) when they should be stripped. Used by
# _stage_io_stdout_begin/_end so a banner being captured to a non-tty fd
# (file, pipe — common in tests and CI logs) renders as plain text without
# ANSI escapes interleaving with substring assertions.
#
# Rules (in order):
#   - NO_COLOR set                                 → no color
#   - FORCE_COLOR=1                                → color (overrides tty)
#   - ZBUILD_STAGE_IO_FORCE_COLOR=1                → color (test/golden pin)
#   - banner fd (ZBUILD_STAGE_IO_FD, default 2) is a tty → color
#   - otherwise                                    → no color
_stage_io_banner_use_color() {
    [[ -n "${NO_COLOR:-}" ]] && return 1
    # ZBUILD_STAGE_IO_FORCE_COLOR is the banner-specific opt-in (test/golden
    # pin). FORCE_COLOR alone is NOT enough — it only populates the helpers
    # palette; the banner fd's tty-ness still gates whether colors interleave
    # with the operator-visible stream, since callers commonly capture banners
    # to files for grep-based assertions.
    [[ "${ZBUILD_STAGE_IO_FORCE_COLOR:-0}" == "1" ]] && return 0
    local fd="${ZBUILD_STAGE_IO_FD:-2}"
    if [[ -t "$fd" ]] 2>/dev/null; then
        return 0
    fi
    return 1
}

# ─── _stage_io_visible_len <string> — visible (no-ANSI) byte length (#492) ────
# Strip ANSI escapes via the existing sed pattern in helpers.sh's strip_ansi
# (we re-implement inline rather than piping to a subshell — banner rendering
# is hot-ish and forks add up). Used by the banner padder to compute right-
# alignment math against the *visible* length, not the ANSI-laden raw length.
_stage_io_visible_len() {
    local LC_ALL=C
    local s="$1"
    # Strip CSI: ESC [ <params> <final>; then bare ESC <char>.
    s="$(printf '%s' "$s" | sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z~]//g; s/\x1b.//g')"
    printf '%s' "${#s}"
}

# ─── _stage_io_dashes <n> — emit n × ─ (horizontal-bar U+2500) ───────────────
# Empty when n <= 0. Light divider — used by the end-trailer ("── end stage-io
# ──") for a softer close than the heavy I/O banner header.
_stage_io_dashes() {
    local n="${1:-0}"
    [[ "$n" -le 0 ]] && return 0
    local dashes
    printf -v dashes '%*s' "$n" ''
    printf '%s' "${dashes// /─}"
}

# ─── _stage_io_heavy_dashes <n> — emit n × ═ (double-bar U+2550, #499) ───────
# Medium-weight divider used in the I/O banner header (begin + end output line
# headings). The three-tier visual hierarchy is: ═ LIGHT_BLUE structural / ─
# rc-colored closer / stage-name BLUE+BOLD identity (ADR-015 §v5 / #499).
_stage_io_heavy_dashes() {
    local n="${1:-0}"
    [[ "$n" -le 0 ]] && return 0
    local dashes
    printf -v dashes '%*s' "$n" ''
    printf '%s' "${dashes// /═}"
}

# ─── _stage_io_compose_banner — assemble heading with right-aligned timestamp ─
# Args: <prefix_visible> <prefix_with_ansi> <timestamp_str> [<divider_color>]
# Strategy:
#   visible_text = "═══ <prefix_visible> ═══ ... ═══ HH:MM:SS UTC ═══"
#   width        = _term_width
#   pad          = width - len(prefix) - len(ts) - bookend chars
# When pad <= 2 (terminal < 70 cols), degrade to the legacy format: just emit
# the prefix without timestamp / right-alignment.
#
# #499: I/O banner header dividers use the medium-weight ═ (U+2550) glyph,
# wrapped in LIGHT_BLUE when colored. Bookends and the right-pad run use the
# same glyph for visual consistency. Each ═ run is wrapped individually so
# the COLOR escape goes around the divider, never inside the asserted prefix
# substring ("<stage> [...] seq=N <input|output>"; #523 dropped the "stage-io:"
# prefix that previously preceded the stage name). The end-trailer
# (── end stage-io ──) keeps the lighter ─ via a separate emitter — see
# _stage_io_stdout_end's printf.
#
# Prints the assembled line (no trailing newline) on stdout. Color escapes
# pass through unchanged via the *_with_ansi* prefix.
_stage_io_compose_banner() {
    local prefix_visible="$1" prefix_ansi="$2" ts="$3" divider_color="${4:-}"
    local width
    width="$(_term_width)"
    # Bookend layout: `══ <prefix> ` + dashes + ` <ts> ══`
    # Fixed glyph cost: "══ " (3) + " " (1) + " " (1) + " ══" (3) = 8 visible cols.
    local fixed=8
    local pad=$(( width - ${#prefix_visible} - ${#ts} - fixed ))
    local _reset=""
    [[ -n "$divider_color" ]] && _reset="${RESET:-}"
    if [[ "$pad" -le 2 ]]; then
        # Degraded: heavy bookends only, no timestamp / right-alignment.
        printf '%b══%b %b %b══%b' "$divider_color" "$_reset" "$prefix_ansi" "$divider_color" "$_reset"
        return 0
    fi
    local dashes
    dashes="$(_stage_io_heavy_dashes "$pad")"
    # Each ═ run wrapped in (divider_color … reset). Prefix carries its own
    # color escapes via prefix_ansi. Substring invariant: tokens inside
    # prefix_visible remain byte-identical to v4.
    printf '%b══%b %b %b%s%b %s %b══%b' \
        "$divider_color" "$_reset" \
        "$prefix_ansi" \
        "$divider_color" "$dashes" "$_reset" \
        "$ts" \
        "$divider_color" "$_reset"
}

# ─── _stage_io_stdout_begin — #481 input-phase banner emitter ─────────────────
# Emits only the input section of the split banner:
#   ── stage-io: <stage> [<kind>] seq=N input ──
#   <input head>
# No "end stage-io:" trailer — that fires at end-time. Honors the consumer-side
# artifact renderer dispatch (#470) when metadata.artifact is in the begin args
# — but since this helper doesn't have the merged metadata yet, we accept an
# optional artifact_id argument for that dispatch.
_stage_io_stdout_begin() {
    # #785: artifact_id was previously used to dispatch render_artifact on
    # the input side; renderer dispatch is now output-only and this
    # parameter is no longer read. Kept for API stability with callers that
    # already pass it.
    # shellcheck disable=SC2034
    local stage="$1" kind="$2" seq="$3" input="$4" artifact_id="${5:-}"

    local tail_lines
    tail_lines="$(template_stage_io_tail_lines "$stage" 2>/dev/null || true)"
    [[ -z "$tail_lines" ]] && tail_lines=40

    # #506: operator-banner input override. When set, the on-screen banner
    # uses this value as .input INSTEAD of the (potentially huge) raw prompt.
    # The persisted artifact record still receives the full prompt — only the
    # rendered banner body is substituted. Used by the review stage to show
    # a numstat file-change summary while the LLM still gets the full diff.
    # #785: artifact_id is no longer read on the input side (renderer dispatch
    # is output-only). The override body is plain text so it just flows
    # through _stage_io_head; no need to clear artifact_id.
    if [[ -n "${ZBUILD_ROUTER_BANNER_INPUT_OVERRIDE:-}" ]]; then
        input="${ZBUILD_ROUTER_BANNER_INPUT_OVERRIDE}"
    fi

    input="$(_stage_io_strip_ansi "$input")"

    # #492 v5: build a colored heading with right-aligned HH:MM:SS UTC.
    # Color application is ONLY here (fd-2 path); _stage_io_to_stdout
    # (gh_comment body assembler) remains plain-text by construction.
    # When the banner fd isn't a tty (file/pipe — tests, CI logs), strip ANSI
    # so existing substring assertions (token order: <prefix> <pad> <ts>)
    # see the literal prefix without intervening escapes.
    local _color="" _bold="" _dim="" _reset="" _light_blue=""
    if _stage_io_banner_use_color; then
        _color="$(_stage_color "$stage")"
        _bold="${BOLD:-}"; _dim="${DIM:-}"; _reset="${RESET:-}"
        # #499: structural ═ dividers in medium-weight LIGHT_BLUE.
        _light_blue="${LIGHT_BLUE:-}"
    fi
    local _ts _prefix_v _prefix_a
    _ts="$(_stage_io_now_short)"
    # #523: drop literal "stage-io:" label from the heading. The bracketed
    # [kind] token remains — it is load-bearing (renderer dispatch + integration
    # test grep). End-trailer keeps its "end stage-io:" prefix (closer aids
    # scrollback search; minimizes golden churn).
    _prefix_v="${stage} [${kind}] seq=${seq} input"
    # Colored prefix: colored bold stage name, plain rest.
    _prefix_a="${_color}${_bold}${stage}${_reset} [${kind}] seq=${seq} input"

    # #491 §v4 layer-2 fd contract: route ALL banner writes from this helper to
    # ${ZBUILD_STAGE_IO_FD:-2}. The caller-level redirect in stage_io_begin is
    # belt; this is suspenders — a caller that wraps the action in $(...) cannot
    # capture the banner into a string even if the caller-level redirect is
    # bypassed, because every printf below lands on fd 2 directly.
    {
        _stage_io_compose_banner "$_prefix_v" "$_prefix_a" "$_ts" "$_light_blue"
        printf '\n'
        local _persona="${ZBUILD_STAGE_IO_PERSONA:-}"
        if [[ "$_persona" == *:fallback ]]; then
            printf 'persona: none (fallback)\n'
        elif [[ -n "$_persona" ]]; then
            printf 'persona: %s\n' "$_persona"
        fi
        case "$kind" in
            llm)
                # #785: artifact-id renderer dispatch is OUTPUT-side only.
                # The INPUT to an LLM stage is the prompt — a text artifact,
                # not the structured response shape the renderer expects.
                # Dispatching render_impact_md / render_plan_md on a prompt
                # mis-renders the embedded JSON schema literal and shunts the
                # OUTPUT CONTRACT into a "── llm comment ──" block. Always
                # pretty-print the input as plain text.
                _stage_io_head_with_hint "$input" "$tail_lines" "$stage" "$seq"
                ;;
            cycle)
                # #833: cycle INPUT is a pre-formatted feedback-edge digest
                # (plain text). Render head-with-hint like llm, but no artifact
                # renderer — the digest is already operator-ready.
                _stage_io_head_with_hint "$input" "$tail_lines" "$stage" "$seq"
                ;;
            command)
                _stage_io_render_command_argv "$input"
                ;;
            computed)
                printf 'in: %s\n' "$input"
                ;;
        esac
    } >&"${ZBUILD_STAGE_IO_FD:-2}"
    return 0
}

# ─── _stage_io_stdout_end <record_json> — #481 output-phase banner emitter ────
# Emits the output section + closing trailer of the split banner:
#   ── stage-io: <stage> [<kind>] seq=N output STATUS DUR ──
#   <output tail>
#   ── end stage-io: <stage> ──
_stage_io_stdout_end() {
    local record="$1"
    # #682: optional display label (e.g. "1.2"). When non-empty, replaces the
    # cardinal `seq=N` token on the banner heading. The artifact record's
    # `.seq` (and pairing logic) stays cardinal integer.
    local seq_label="${2:-}"
    local stage kind seq output exit_code duration_ms metadata
    stage="$(printf '%s' "$record" | jq -r '.stage')"
    kind="$(printf '%s' "$record" | jq -r '.kind')"
    seq="$(printf '%s' "$record" | jq -r '.seq')"
    # Use label for on-screen rendering; fall back to cardinal seq.
    local display_seq="${seq_label:-$seq}"
    output="$(printf '%s' "$record" | jq -r '.output')"
    exit_code="$(printf '%s' "$record" | jq -r '.exit_code // ""')"
    duration_ms="$(printf '%s' "$record" | jq -r '.duration_ms // ""')"
    metadata="$(printf '%s' "$record" | jq -c '.metadata // {}')"

    local tail_lines
    tail_lines="$(template_stage_io_tail_lines "$stage" 2>/dev/null || true)"
    [[ -z "$tail_lines" ]] && tail_lines=40

    local status; status="$(_stage_io_render_status "$kind" "$exit_code" "$metadata")"
    local dur;    dur="$(_stage_io_render_duration "$duration_ms")"

    output="$(_stage_io_strip_ansi "$output")"

    local _artifact_id
    _artifact_id="$(printf '%s' "$metadata" | jq -r '.artifact // empty' 2>/dev/null || true)"

    # #492 v5: color the status icon (✓/✗) and right-align ts + dur on heading.
    # #499: structural ═ dividers in LIGHT_BLUE on the output-heading line; the
    # end-trailer keeps the lighter ── (rc-colored per #492).
    local _color="" _bold="" _dim="" _reset="" _green="" _red="" _light_blue=""
    if _stage_io_banner_use_color; then
        _color="$(_stage_color "$stage")"
        _bold="${BOLD:-}"; _dim="${DIM:-}"; _reset="${RESET:-}"
        _green="${GREEN:-}"; _red="${RED:-}"
        _light_blue="${LIGHT_BLUE:-}"
    fi
    local _ts _prefix_v _prefix_a _icon _icon_color _end_color _status_color
    _ts="$(_stage_io_now_short)"
    # Status colorization: OK=green, FAIL=red. Icon (✓/✗) is placed on the
    # end-trailer line, NOT on the output heading — that keeps the legacy
    # substring "seq=N output OK <dur>" intact for existing assertions.
    if [[ "$status" == "OK" ]]; then
        _icon='✓'; _icon_color="$_green"; _status_color="$_green"
    else
        _icon='✗'; _icon_color="$_red"; _status_color="$_red"
    fi
    # rc-colored end trailer: green when no exit_code or exit_code==0 (LLM kind
    # has no exit_code — treat as OK); red otherwise. Mirrors status above.
    if [[ -z "$exit_code" || "$exit_code" == "0" ]]; then
        [[ "$status" == "OK" ]] && _end_color="$_green" || _end_color="$_red"
    else
        _end_color="$_red"
    fi
    # #523: drop literal "stage-io:" label from the heading (see input-banner
    # comment above). End-trailer prefix retained at L1049.
    _prefix_v="${stage} [${kind}] seq=${display_seq} output ${status} ${dur}"
    _prefix_a="${_color}${_bold}${stage}${_reset} [${kind}] seq=${display_seq} output ${_status_color}${status}${_reset} ${dur}"

    # #491 §v4 layer-2 fd contract: route ALL banner writes from this helper to
    # ${ZBUILD_STAGE_IO_FD:-2}. Mirrors _stage_io_stdout_begin; see comment there.
    {
        _stage_io_compose_banner "$_prefix_v" "$_prefix_a" "$_ts" "$_light_blue"
        printf '\n'
        case "$kind" in
            llm)
                if [[ -n "$_artifact_id" ]]; then
                    local _rendered_output
                    _rendered_output="$(render_artifact "$_artifact_id" "$output" 2>/dev/null)"
                    _stage_io_tail_with_hint "$_rendered_output" "$tail_lines" "$stage" "$seq"
                else
                    local _pretty_out
                    _pretty_out="$(_stage_io_pretty_print "$output")"
                    _stage_io_tail_with_hint "$_pretty_out" "$tail_lines" "$stage" "$seq"
                fi
                ;;
            command)
                local _pretty_cmd_out
                _pretty_cmd_out="$(_stage_io_pretty_print "$output")"
                _stage_io_tail_with_hint "$_pretty_cmd_out" "$tail_lines" "$stage" "$seq"
                printf '── exit: %s ──\n' "${exit_code:-?}"
                ;;
            computed)
                printf 'out: %s\n' "$output"
                ;;
            cycle)
                # #833: cycle OUTPUT is the termination-predicate eval +
                # health score (pre-formatted plain text). Reuse the llm
                # no-artifact body; NO `── exit: ──` line (cycles have no
                # command-style exit code).
                local _pretty_cyc_out
                _pretty_cyc_out="$(_stage_io_pretty_print "$output")"
                _stage_io_tail_with_hint "$_pretty_cyc_out" "$tail_lines" "$stage" "$seq"
                ;;
        esac
        # #499: end-trailer keeps the lighter ── close (rc-colored per #492).
        printf '%b── end stage-io: %s %s ──%b\n' "$_end_color" "$stage" "$_icon" "$_reset"
    } >&"${ZBUILD_STAGE_IO_FD:-2}"
    return 0
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
    # #523: drop "stage-io:" prefix from gh_comment renderer header for
    # banner/comment schema symmetry (the bracketed [kind] token + stage are
    # the load-bearing pieces; closer trailer at L1144 unchanged).
    printf '── %s [%s] seq=%s%s %s ──\n' "$stage" "$kind" "$seq" "$status_field" "$dur"

    # Sanitize input/output: strip ANSI/CSI escape sequences before they
    # reach the operator's terminal. Captured LLM responses and command
    # output can contain xterm control codes (notably bracketed-paste-mode
    # \e[200~/\e[201~) that hose the shell prompt and can cause subsequent
    # terminal content to be interpreted as pasted-and-executed commands.
    # Strip before everything else so pretty-print's JSON sniffer can't be
    # fooled by leading escapes either.
    input="$(_stage_io_strip_ansi "$input")"
    output="$(_stage_io_strip_ansi "$output")"

    case "$kind" in
        llm)
            printf '── input ──\n'
            # #785: artifact-id renderer dispatch is OUTPUT-side only. The
            # INPUT to an LLM stage is the prompt — a text artifact, not the
            # structured response shape the renderer expects. Pretty-print
            # input as text so the operator sees the prompt verbatim, not a
            # mis-rendered JSON-schema split. Output-side reads metadata.artifact
            # below.
            _stage_io_head "$input" "$tail_lines"
            printf '\n── output ──\n'
            local _artifact_id
            _artifact_id="$(printf '%s' "$metadata" | jq -r '.artifact // empty' 2>/dev/null || true)"
            # ADR-018 (#483): symmetric output-side dispatch. When the producer
            # plugin tagged the capture with metadata.artifact (e.g. plan,
            # review), route the output through the renderer registry so the
            # producer's OWN banner shows markdown instead of raw JSON. The
            # #470 wave only handled the input side (consumer-facing). Falls
            # through to the pretty-print branch on unknown id (render_artifact
            # passthrough + stage.io.render.fallback event).
            if [[ -n "$_artifact_id" ]]; then
                local _rendered_output
                _rendered_output="$(render_artifact "$_artifact_id" "$output" 2>/dev/null)"
                _stage_io_tail "$_rendered_output" "$tail_lines"
            else
                # Pretty-print JSON outputs so a 4KB minified response renders as
                # a readable indented block instead of one giant line. Falls back
                # to the raw text when the content isn't JSON.
                local _pretty_out
                _pretty_out="$(_stage_io_pretty_print "$output")"
                _stage_io_tail "$_pretty_out" "$tail_lines"
            fi
            printf '\n'
            ;;
        command)
            printf '── input ──\n'
            _stage_io_render_command_argv "$input"
            printf '── output ──\n'
            # Command output is typically free-form text (gh issue body, git
            # output) but occasionally JSON (gh ... --json). Pretty-print
            # opportunistically.
            local _pretty_cmd_out
            _pretty_cmd_out="$(_stage_io_pretty_print "$output")"
            _stage_io_tail "$_pretty_cmd_out" "$tail_lines"
            printf '\n── exit: %s ──\n' "${exit_code:-?}"
            ;;
        computed)
            printf 'in: %s\nout: %s\n' "$input" "$output"
            ;;
        cycle)
            # #833: cycle banners route to fd-2 only (never gh_comment), so
            # this renderer is never reached for kind=cycle in production.
            # Provide a plain input/output symmetry arm for completeness so a
            # direct caller (or future dest) renders the digest + predicate
            # text verbatim.
            printf '── input ──\n'
            _stage_io_head "$input" "$tail_lines"
            printf '\n── output ──\n'
            _stage_io_tail "$output" "$tail_lines"
            printf '\n'
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
    local state_dir="${ZBUILD_STATE_DIR:-${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}}"
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
# #492 v5 color-asymmetry note: color escapes are emitted only in
# `_stage_io_stdout_begin` / `_stage_io_stdout_end` (fd-2 path). The
# `_stage_io_to_stdout` renderer (used here to assemble the gh_comment body)
# remains plain-text by construction so the comment posted to GitHub never
# contains ANSI escapes. Do not add color to `_stage_io_to_stdout` without
# stripping it back out here.
#
# #491 §v4 fd-asymmetry note: the stdout-destination banner writes to fd
# ${ZBUILD_STAGE_IO_FD:-2} (stderr by default — never captured by $()), but the
# gh_comment renderer builds its body via $() capture of _stage_io_to_stdout
# (fd 1). This is intentional: the gh_comment body is *content* that must be
# assembled as a string for the GitHub API call, whereas the stdout-banner is
# *operator-visible logging* that must survive callers wrapping the action in
# $(). Do not collapse this asymmetry — moving the gh_comment renderer to fd 2
# would make the body unavailable for the gh CLI invocation. See ADR-015 §v4.
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
    artifact_path="${ZBUILD_STATE_DIR:-${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}}/artifacts/stage-io/${stage}-${seq}.json"

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
